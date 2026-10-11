# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-10-11

### Changed

- Requires `dartastic_opentelemetry_api >=1.0.0-rc.4 <1.0.0-rc.5`.
- Context is propagated with the app's configured propagators
  (`OTelAPI.textMapPropagator`: W3C trace context and baggage by
  default, `OTEL_PROPAGATORS` to change them) instead of a fixed W3C
  propagator.
- **Breaking:** depends on `dartastic_opentelemetry_api` only, no
  longer on the SDK. The application chooses and initializes the
  OpenTelemetry SDK. Parameters and fields typed with SDK classes
  now use the API types (`APITracer`, `APISpan`, `APILogger`, ...);
  SDK instances are still accepted wherever an API type is expected.

## [0.2.0] - 2026-08-09

### Changed

- Semantic conventions updated to the current OTel registry; no
  deprecated attribute keys are emitted (only the current
  `http.request.method`, never the legacy `http.method`).
- Dependency floors raised to `dartastic_opentelemetry ^1.1.0-beta.12` and
  `dartastic_opentelemetry_api ^1.0.0-rc.1`. The previous floors declared
  compatibility with API versions that predate the semconv enums this
  package uses and could not actually resolve-and-compile.
- `repository` URL corrected to the canonical `Dartastic` org casing so
  pub.dev repository verification succeeds.
- Attribute keys migrated to the rc.1 semconv enum member names
  (`Http.httpRequestMethod`, `Server.serverAddress`,
  `ErrorAttributes.errorType`, ...); emitted keys are unchanged.

### Added

- Deduplication guard: a second `OTelDioInterceptor` in the same chain
  now defers to the first (previously the first span was silently
  overwritten in `RequestOptions.extra` and never ended). The stashed
  span is also removed on completion so retries re-entering the chain
  get a fresh span. Documented the cross-layer contract: the layer
  closest to the application wins; transport-layer instrumentation
  should suppress when W3C `traceparent` is already present at send
  time.
- `ignoreUrlPatterns` — URL patterns (substring or `RegExp`) excluded
  from instrumentation entirely (no span, no header injection), e.g.
  telemetry-upload endpoints.
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
