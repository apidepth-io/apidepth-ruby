# lib/apidepth/model_name_extractor.rb
require "json"
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
# The 8KB truncation is a belt-and-suspenders guard against unusually large bodies.

module Apidepth
  module ModelNameExtractor
    AI_VENDOR_HOSTS = %w[
      api.openai.com
      api.anthropic.com
      generativelanguage.googleapis.com
      api.mistral.ai
      api.cohere.com
    ].to_set.freeze

    MAX_BODY_BYTES = 8_192

    def self.extract(host, response)
      return nil unless Apidepth.configuration.capture_model_names
      return nil unless AI_VENDOR_HOSTS.include?(host)
      return nil unless response["content-type"]&.include?("application/json")

      body = response.body
      return nil if body.nil? || body.empty?

      parsed = JSON.parse(body.byteslice(0, MAX_BODY_BYTES), symbolize_names: true)
      model = parsed[:model]
      model.is_a?(String) && !model.empty? ? model : nil
    rescue JSON::ParserError, Encoding::UndefinedConversionError, TypeError
      nil
    end
  end
end
