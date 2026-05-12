# Changelog

All notable changes to this project will be documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

---

## [0.1.0] — 2026-05-11

Initial release.

### Added

**Core instrumentation**
- Passive outbound HTTP capture via `Module#prepend` on `Net::HTTP` — instruments Faraday, HTTParty, RestClient, and plain `Net::HTTP` with a single hook
- Per-event tagging: vendor slug, normalized endpoint path, HTTP method, status code, outcome (`:success`, `:client_error`, `:server_error`, `:timeout`, `:unknown`), duration in milliseconds, cold-start flag, environment, millisecond-resolution Unix timestamp
- Timeout capture — `Net::ReadTimeout` and `Net::OpenTimeout` are recorded as `:timeout` events and re-raised; previously invisible in any monitoring tool
- Cold-start tagging — first request to a vendor pays for DNS + SSL handshake; this flag lets the collector exclude warmup latency from percentile calculations
- Sample rate support — `config.sample_rate` (0.0–1.0) for high-traffic applications

**Vendor registry**
- Bundled baseline covering Stripe, OpenAI, Anthropic, Twilio, Resend, GitHub
- Remote registry hot-swap — vendor patterns fetched from Apidepth servers every 6 hours, applied without gem update or process restart
- Three-tier fallback: remote fetch → disk cache → bundled baseline
- Path normalization strips resource IDs before events leave your server (`/v1/charges/ch_abc` → `/v1/charges/:id`)
- Generic normalizers for UUIDs, numeric IDs, and long hex tokens not covered by vendor-specific rules

**Collector**
- Thread-safe singleton with class-level mutex — no duplicate flush threads on concurrent boot
- Persistent HTTP connection to the collector — single SSL handshake per process lifetime, not per flush
- Background flush thread batching up to 100 events every 20 seconds
- Watchdog thread — detects flush thread death and restarts it; logs a warning with instructions to file an issue
- `reset!` — kills background threads and closes the HTTP connection cleanly before clearing the singleton; safe to call in Puma `on_worker_boot`
- Backpressure — events silently dropped when queue exceeds 5,000; `total_dropped` counter tracks discards
- `stats` method — exposes `queue_size`, `consecutive_failures`, `total_dropped`, `last_flush_at` for health checks and dashboards
- `last_flush_at` only updated on actual event delivery, not on empty-queue flush ticks
- `on_flush_error` callback — route flush failures to Sentry, Honeybadger, Bugsnag, or any error tracker
- Consecutive failure tracking — warn-level log after 3 consecutive failures with actionable message

**Event schema**
- `Event.build` validates required fields at creation time — bugs surface in tests, not in production data
- Frozen hash output — immutable after creation, serializes directly via `JSON.generate`
- SDK metadata in every batch payload — Ruby version, platform, Rails version, app server

**Rails integration**
- Railtie wires instrumentation automatically after all initializers run
- Sets `config.environment` from `Rails.env` at boot — `resolve_env` is a cheap attribute read on the hot path, not a `defined?` check per request
- Nil `api_key` produces a warn-level log at boot rather than silent 401 failures at flush time
- `at_exit` flush — drains queue on graceful shutdown (SIGTERM)
- `ActiveSupport::ForkTracker` integration for Puma cluster mode on Rails 7.1+
- Warn-level log when Puma is detected but `ForkTracker` is unavailable (Rails < 7.1)

**Security**
- SSRF protection — `collector_url` must use HTTPS; private IP ranges, loopback, link-local, and decimal IP representations (e.g. `2130706433` = `127.0.0.1`) are rejected
- HTTP header injection guard — CRLF in `api_key` raises `ArgumentError` before the Authorization header is set
- Log injection sanitization — untrusted strings from the remote registry are stripped of `\r`, `\n`, `\t` before logging
- Path traversal validation on `registry_cache_path` — absolute paths only, no `..` segments
- Remote registry pattern validation — embedded code constructs and malformed regex patterns in registry responses are rejected with a warning
- Registry response size limit — responses over 512KB are rejected before parsing
- Explicit `OpenSSL::SSL::VERIFY_PEER` on all outbound connections — no reliance on platform defaults
- `private_class_method` on `RegistryLoader` internal methods — not part of the public API
- Error messages never include `api_key`, response bodies, or Authorization headers

**Testing**
- 116 RSpec examples covering unit, integration, security, and concurrency behavior
- WebMock for all HTTP stubs — no live network required
- Integration test exercises the full stack from `Net::HTTP.get` through instrumentation, event schema, collector, and batch delivery
- Test suite runnable with `bundle exec rspec` after `bundle install`

### Compatibility

- Ruby 2.7+
- Rails 6.1+
- Rack 2.2.12+ (CVE-2025-27111)

---

[Unreleased]: https://github.com/apidepth/apidepth-ruby/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/apidepth/apidepth-ruby/releases/tag/v0.1.0
