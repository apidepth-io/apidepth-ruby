# lib/apidepth/configuration.rb

module Apidepth
  class Configuration
    attr_accessor :api_key,
                  :collector_url,
                  :enabled,
                  :flush_interval,
                  :registry_refresh_interval,
                  :registry_cache_path,
                  :ignored_hosts,
                  :on_flush_error,
                  :environment,      # e.g. "production" — set by Railtie from Rails.env
                  :sample_rate       # Float 0.0–1.0, default 1.0 (100% of events captured)

    def initialize
      @enabled                   = true
      @flush_interval            = 20
      @registry_refresh_interval = 6 * 60 * 60
      @registry_cache_path       = "/tmp/apidepth_registry.json"
      @collector_url             = nil
      @ignored_hosts             = []
      @on_flush_error            = nil
      @environment               = nil   # Railtie sets this to Rails.env at boot
      @sample_rate               = 1.0   # capture everything by default
    end
  end
end
