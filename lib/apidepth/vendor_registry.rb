# lib/apidepth/vendor_registry.rb

module Apidepth
  module VendorRegistry
    BUNDLED_BASELINE = {
      "version" => "bundled",
      "vendors" => {
        "stripe" => {
          "hosts" => ["api.stripe.com"],
          "patterns" => [
            { "match" => '/v1/charges/ch_\w+', "replace" => "/v1/charges/:id" },
            { "match" => '/v1/customers/cus_\w+',          "replace" => "/v1/customers/:id" },
            { "match" => '/v1/payment_intents/pi_\w+',     "replace" => "/v1/payment_intents/:id" },
            { "match" => '/v1/subscriptions/sub_\w+',      "replace" => "/v1/subscriptions/:id" },
            { "match" => '/v1/invoices/in_\w+',            "replace" => "/v1/invoices/:id" },
            { "match" => '/v1/refunds/re_\w+',             "replace" => "/v1/refunds/:id" }
          ]
        },
        "openai" => {
          "hosts" => ["api.openai.com"],
          "patterns" => [
            { "match" => "/v1/chat/completions",           "replace" => "/v1/chat/completions" },
            { "match" => "/v1/embeddings",                 "replace" => "/v1/embeddings" },
            { "match" => "/v1/images/generations",         "replace" => "/v1/images/generations" },
            { "match" => '/v1/files/file-\w+',             "replace" => "/v1/files/:id" }
          ]
        },
        "anthropic" => {
          "hosts" => ["api.anthropic.com"],
          "patterns" => [
            { "match" => "/v1/messages",                   "replace" => "/v1/messages" }
          ]
        },
        "twilio" => {
          "hosts" => ["api.twilio.com"],
          "patterns" => [
            { "match" => '/2010-04-01/Accounts/AC\w+/Messages/SM\w+', "replace" => "/Accounts/:id/Messages/:id" },
            { "match" => '/2010-04-01/Accounts/AC\w+/Messages',       "replace" => "/Accounts/:id/Messages" },
            { "match" => '/2010-04-01/Accounts/AC\w+/Calls/CA\w+',    "replace" => "/Accounts/:id/Calls/:id" },
            { "match" => '/2010-04-01/Accounts/AC\w+/Calls',          "replace" => "/Accounts/:id/Calls" }
          ]
        },
        "resend" => {
          "hosts" => ["api.resend.com"],
          "patterns" => [
            { "match" => "/emails/[0-9a-f-]{36}", "replace" => "/emails/:id" }
          ]
        },
        "github" => {
          "hosts" => ["api.github.com"],
          "patterns" => [
            { "match" => '/repos/[^/]+/[^/]+/pulls/\d+',  "replace" => "/repos/:owner/:repo/pulls/:number" },
            { "match" => '/repos/[^/]+/[^/]+/issues/\d+', "replace" => "/repos/:owner/:repo/issues/:number" },
            { "match" => "/repos/[^/]+/[^/]+",            "replace" => "/repos/:owner/:repo" },
            { "match" => "/users/[^/]+", "replace" => "/users/:username" }
          ]
        }
      }
    }.freeze

    GENERIC_PATTERNS = [
      [%r{/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}}, "/:uuid"],
      [%r{/\d{4,}},        "/:id"],
      [%r{/[a-z0-9]{24,}}, "/:token"]
    ].freeze

    # True when the runtime supports Regexp.timeout (introduced in Ruby 3.2).
    # Used by apply_vendor_normalizers to enable ReDoS protection when available.
    RUBY_GTE_3_2 = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2")

    class << self
      def identify(host, raw_path)
        hosts, patterns = @mutex.synchronize { [@hosts, @patterns] }
        vendor = hosts[host]
        return nil unless vendor

        path = strip_query_string(raw_path)
        path = apply_vendor_normalizers(patterns[vendor] || [], path)
        path = apply_generic_normalizers(path)
        [vendor, path]
      end

      # Merge customer-defined host→vendor mappings from config.extra_vendors.
      # Called once at Railtie boot after the user's configure block has run.
      # Does not touch @patterns — custom vendors use generic path normalization only.
      def load_extra_vendors(extra_vendors)
        return if extra_vendors.nil? || extra_vendors.empty?

        @mutex.synchronize do
          extra_vendors.each { |name, host| @hosts[host.to_s] = name.to_s }
        end
      end

      def replace(registry_json)
        new_hosts    = build_hosts(registry_json)
        new_patterns = build_patterns(registry_json)

        # Re-apply extra_vendors so a registry refresh never wipes customer-defined
        # host mappings. The config value wins over any registry entry for the same host.
        (Apidepth.configuration.extra_vendors || {}).each do |name, host|
          new_hosts[host.to_s] = name.to_s
        end

        @mutex.synchronize do
          @hosts    = new_hosts
          @patterns = new_patterns
          @version  = registry_json["version"]
        end

        Apidepth.logger&.debug(
          "[Apidepth] Registry updated — version=#{Apidepth.sanitize_log(registry_json['version'])} " \
          "vendors=#{new_hosts.values.uniq.count}"
        )
      end

      def version
        @mutex.synchronize { @version }
      end

      def vendor_count
        @mutex.synchronize { @hosts.values.uniq.count }
      end

      private

      # Called at require time — Apidepth.logger is not yet defined so we
      # can't call replace (which logs). Initialize state directly instead.
      def initialize_registry
        @mutex    = Mutex.new
        @version  = BUNDLED_BASELINE["version"]
        @hosts    = build_hosts(BUNDLED_BASELINE)
        @patterns = build_patterns(BUNDLED_BASELINE)
      end

      def build_hosts(registry)
        {}.tap do |hosts|
          (registry["vendors"] || {}).each do |slug, config|
            (config["hosts"] || []).each { |h| hosts[h] = slug }
          end
        end
      end

      def build_patterns(registry)
        {}.tap do |patterns|
          (registry["vendors"] || {}).each do |slug, config|
            patterns[slug] = (config["patterns"] || []).filter_map do |rule|
              match = rule["match"].to_s

              # Block constructs that enable arbitrary code execution in some
              # Ruby/Oniguruma versions. This is a blocklist — it does not prevent
              # catastrophic-backtracking ReDoS (e.g. (a+)+) from a compromised
              # registry, but legitimate path patterns never need these constructs.
              if match.match?(/\(\?[{<!=]|\(\?#|\+\?|\*\?{2}/)
                Apidepth.logger&.warn(
                  "[Apidepth] Skipping unsafe pattern for #{Apidepth.sanitize_log(slug)}: #{match.inspect}"
                )
                next
              end

              [Regexp.new(match), rule["replace"].to_s]
            rescue RegexpError => e
              Apidepth.logger&.warn(
                "[Apidepth] Skipping invalid pattern for #{Apidepth.sanitize_log(slug)} " \
                "#{match.inspect}: #{e.message}"
              )
              nil
            end
          end
        end
      end

      def strip_query_string(path)
        path.split("?").first
      end

      # First-match-wins: iteration stops at the first pattern that matches the
      # path. Vendor authors must order rules from most-specific to least-specific
      # to ensure that narrower patterns (e.g. /v1/charges/:id) are tested before
      # broader catch-alls (e.g. /v1/:resource/:id). A less-specific rule placed
      # earlier will shadow any more-specific rules that follow it.
      #
      # ReDoS protection: on Ruby >= 3.2 we apply a per-match timeout of 1ms so
      # that a pathological pattern from a compromised or misconfigured registry
      # cannot stall the request thread indefinitely. On older Ruby, Regexp.timeout
      # is not available — use a trusted, internally-reviewed registry source.
      def apply_vendor_normalizers(rules, path)
        if RUBY_GTE_3_2
          saved_timeout = Regexp.timeout
          Regexp.timeout = 0.001
        end

        rules.each do |pattern, replacement|
          return path.gsub(pattern, replacement) if path.match?(pattern)
        end
        path
      ensure
        Regexp.timeout = saved_timeout if RUBY_GTE_3_2
      end

      def apply_generic_normalizers(path)
        GENERIC_PATTERNS.reduce(path) do |p, (pattern, replacement)|
          p.gsub(pattern, replacement)
        end
      end
    end

    initialize_registry
  end
end
