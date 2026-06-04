# lib/apidepth/model_name_extractor.rb
require "set"
#
# Extracts the model name from AI vendor JSON response bodies.
#
# WHY response body rather than headers?
# AI vendors (OpenAI, Anthropic, Gemini, Mistral, Cohere) return the active
# model in the response body ({"model":"claude-3-opus-20240229",...}), not in
# headers. This is the only reliable source.
#
# WHY only for known AI vendor hosts?
# Body reads add a tiny overhead. Scoping to a hard-coded allowlist keeps the
# hot path for non-AI vendors completely unaffected.
#
# Body safety: Net::HTTP::HTTPResponse#body memoizes after the first read.
# Calling it here and returning the response to the application is safe — the
# application receives the same cached body bytes.
#
# Streaming safety: streamed responses have Content-Type: text/event-stream, not
# application/json. The content-type guard exits early before any body read.
#
# Extraction strategy (RUBY-018): scan for the JSON "model": "<value>" field
# with a linear regex rather than JSON.parse-ing a truncated body. Embeddings
# and batch responses place `model` AFTER a large `data` array, so the old
# parse-after-8KB-truncate approach produced invalid JSON and silently dropped
# the model. The regex finds the first structural model field wherever it sits.

module Apidepth
  module ModelNameExtractor
    AI_VENDOR_HOSTS = %w[
      api.openai.com
      api.anthropic.com
      generativelanguage.googleapis.com
      api.mistral.ai
      api.cohere.com
    ].to_set.freeze

    # Upper bound on how far into the body we scan for the model field. 256 KB
    # comfortably covers realistic embeddings/batch responses (a few-input OpenAI
    # embeddings body is ~23 KB) while bounding work on pathologically large bodies.
    MODEL_SCAN_MAX_BYTES = 262_144

    # Matches a structural JSON "model": "<value>" pair. Escaped quotes inside
    # string values appear as \" so this never matches a "model" mentioned inside
    # another JSON string. First match wins (the top-level model field).
    MODEL_RE = /"model"\s*:\s*"([^"]+)"/.freeze

    def self.extract(host, response)
      return nil unless Apidepth.configuration.capture_model_names
      # Case-insensitive host match (RUBY-019): DNS hostnames are case-insensitive,
      # so a vendor declared with mixed case (e.g. via extra_vendors) still matches.
      return nil unless AI_VENDOR_HOSTS.include?(host.to_s.downcase)
      return nil unless response["content-type"]&.include?("application/json")

      body = response.body
      return nil if body.nil? || body.empty?

      scan = body.byteslice(0, MODEL_SCAN_MAX_BYTES).to_s.dup.force_encoding("UTF-8")
      match = MODEL_RE.match(scan)
      match && !match[1].empty? ? match[1] : nil
    rescue StandardError
      # Covers malformed/invalid-encoding bodies and non-buffered streaming
      # bodies (e.g. Net::ReadAdapter, which has no #empty?). Returning nil keeps
      # the surrounding telemetry event intact rather than dropping it (RUBY-017).
      nil
    end
  end
end
