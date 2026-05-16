# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0-beta.1-wip]

### Added

- `OTelDioInterceptor` — a `package:dio` `Interceptor` that wraps every
  request in a `CLIENT`-kind span, sets HTTP semantic-convention
  attributes (`http.request.method`, `url.full`, `url.scheme`,
  `url.path`, `url.query`, `server.address`, `server.port`,
  `http.response.status_code`, `http.request.body.size`,
  `http.response.body.size`, `user_agent.original`), and injects W3C
  `traceparent` / `tracestate` / `baggage` headers so downstream OTel
  services join the same trace.
- 4xx and 5xx responses flip the span status to `Error`; transport
  failures (timeouts, connection errors, cancellation) record the
  exception via `recordException`, set `error.type` to the underlying
  exception class, and end the span.
- Userinfo (`https://user:pass@host`) in the request URL is redacted
  from `url.full` per OTel HTTP-semconv guidance.
- Span name and body-size recording are configurable via constructor
  parameters (`spanNameBuilder`, `recordRequestBodySize`,
  `recordResponseBodySize`).
