<!-- dartastic-header:start -->
# OpenTelemetry instrumentation for `dio`

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![OpenTelemetry Specification](https://img.shields.io/badge/OpenTelemetry-Specification-blueviolet)](https://opentelemetry.io/docs/specs/otel/)

`otel_dio` is an [OpenTelemetry](https://opentelemetry.io/) instrumentation for `dio` that
easily adds standard observability to applications that use `dio`.  This package depends on 
[dartastic_opentelemetry_api](https://pub.dev/packages/dartastic_opentelemetry_api).

This package can be used with any OTel backend because it's compliant with the OpenTelemetry Specification.

This package supports Android, iOS, Linux, macOS, Web and Windows, for versions of `dio` that support those platforms. It is WASM-ready.

This Apache-2.0 package is professionally maintained and supported with 💙 by Michael Bushe,
Dart and Flutter Maintainer at OpenTelemetry and the creator of [dartastic_opentelemetry](https://pub.dev/packages/dartastic_opentelemetry)
and [dartastic_opentelemetry_api](https://pub.dev/packages/dartastic_opentelemetry_api). This package is professionally supported by
[Dartastic.io](https://dartastic.io).

---
## Dartastic.io: AI Code Healing and Real User Monitoring for Flutter

**See what your users experience. Find problems with Flutter apps in production. Fix them with AI.**

[Dartastic.io](https://dartastic.io) brings AI code healing, real user monitoring, and OpenTelemetry observability together in one platform built for Dart and Flutter. (Patents pending)

![Dartastic AI answering "Why did crashes jump after the last release?" over a Flutter App Health dashboard](https://dartastic.io/img/pub-dev/HomePageCrashesQuestion.png)

### Dartastic AI — From Production Problems to Code Fixes

Dartastic AI analyzes production telemetry alongside your application source code to diagnose problems and propose fixes.

- **Investigate production issues** using crashes, errors, traces, metrics, and real user telemetry.
- **Find the offending code** by connecting observed problems with your application's source in Dartastic Pub or your source code repos.
- **Generate code patches** that address the underlying problems.
- **Create actionable issues** in your issue tracker, complete with findings and the proposed code patch.

### Dartastic RUM — See What Your Users See

Understand how people actually experience your Flutter application.

- **Replay user sessions** in the Dartastic Observatory session player.
- **Choose your replay fidelity**, from privacy-preserving widget outlines to pixel-level reproductions of the user experience.
- **Investigate real user problems** using session replay and production observability data.

![Dartastic RUM Session Replay](https://dartastic.io/img/pub-dev/session-replay.png)

### Dartastic Observatory — Observability Built for Flutter

A complete observability backend where Flutter and Dart are first-class citizens.

- **Flutter-specific dashboards** for application performance, health, and reliability.
- **Alerts and notifications** through email, Slack, and PagerDuty.
- **Dartastic Cloud Observatory** — Start with a 30-day free trial on isolated, shared infrastructure, as low as $39/mo.
- **Dartastic Hosted Observatory** — Run the observability stack in a private managed environment, sized from Mini to Enterprise XL.
- **Dartastic Self-Hosted Observatory** — The whole platform inside your own network. Your keys, your cluster, with nothing leaving your perimeter.

### Dartastic Native OTel Runtime — Native OpenTelemetry Performance

Collect production telemetry without burdening Flutter's main isolate.

- **Native OpenTelemetry runtime** that moves telemetry processing off the main isolate.
- **Native crash reporting** for problems that Dart can't catch.
- **Widget performance diagnostics** to identify janky widgets.
- **On-device PII filtering** before sensitive data leaves your application.
- **Source-level error diagnostics** powered by the Dartastic Symbolizer API.
- **Platform-native metrics** for iOS, Android, and Linux, including iOS MetricKit and Android Vitals.
- **OpenTelemetry compatibility** — Send telemetry to Dartastic Observatory or any OpenTelemetry platform.

### Dartastic Labs — OpenTelemetry Integrations

Instrument more of your application without writing everything yourself.

- **650+ open-source integrations** for Dart and Flutter libraries and services, including Dio, Shelf, Logger, Anthropic, AWS, Azure, and Stripe. Look for otel_* on pub.dev.

### More Dartastic Tools

**[Dartastic Pub](https://dartastic.io/pub)**

A private Dart package registry for sharing packages and plugins with your team, partners, and customers.

**[Dartastic Symbolizer](https://dartastic.io/symbolizer)**

Turn production errors into lines of source code through a web API, while keeping your source code artifacts private.

### Professional Support and Training

Dartastic.io offers commercial support for the open-source `dartastic_opentelemetry` and `dartastic_opentelemetry_api` packages and the complete Dartastic product suite.

- **Professional support** with available around-the-clock coverage and response times under four hours on qualifying plans.
- **OpenTelemetry training** for teams instrumenting Dart, Flutter, mobile, and web applications.

### Open Standards. No Mandatory Backend.

The Dartastic OpenTelemetry API and SDK are open source and standards-based. You can use them independently of Dartastic's commercial services and send telemetry to any compatible OpenTelemetry backend.

Dartastic's commercial products add native performance, advanced diagnostics, session replay, AI-assisted remediation, and managed observability services.

**[Explore Dartastic.io](https://dartastic.io)**

---
<!-- dartastic-header:end -->

OpenTelemetry client instrumentation for [`package:dio`](https://pub.dev/packages/dio),
built on the [Dartastic OpenTelemetry SDK](https://pub.dev/packages/dartastic_opentelemetry).

Add one interceptor and every Dio request gets:

- A `CLIENT`-kind span around the call.
- The full HTTP semantic-convention attribute set (`http.request.method`,
  `url.full`, `server.address`, `http.response.status_code`, …).
- W3C `traceparent` / `tracestate` / `baggage` headers injected so the
  downstream service joins the same trace.
- Exception recording (`recordException` + `error.type` + `Error` status)
  on transport failures and 4xx / 5xx responses.

## Why

Every Dart and Flutter app that talks HTTP picks up Dio, and most of them
re-implement the same Interceptor: start a span, set the conventional
attributes, inject `traceparent`, end the span on response or error.
This package is that interceptor, written against the OTel semconv spec
once.

The bridge is **opt-in**: the OTel SDK does not depend on `package:dio`.
Add this package only when you want the integration.

## Usage

```dart
import 'package:otel_dio/otel_dio.dart';
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dio/dio.dart';

Future<void> main() async {
  await OTel.initialize(serviceName: 'my-app');

  final dio = Dio()
    // Add OTel first so its span encloses the work of every other
    // interceptor in the chain (auth, retry, logging, ...).
    ..interceptors.add(OTelDioInterceptor());

  // Inside a server-side / handler span so the client span has a parent.
  await OTel.tracer().startActiveSpanAsync<void>(
    name: 'serve-request',
    fn: (_) async {
      await dio.get<dynamic>('https://api.example.com/users/42');
    },
  );

  await OTel.shutdown();
}
```

Outbound requests carry trace context automatically:

```
GET /users/42 HTTP/1.1
Host: api.example.com
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
tracestate: ...
```

## Span shape

Follows the OTel
[HTTP client semantic conventions](https://opentelemetry.io/docs/specs/semconv/http/http-spans/#http-client).

| Attribute                       | Source                              | When set      |
| ------------------------------- | ----------------------------------- | ------------- |
| `http.request.method`           | uppercased `options.method`         | always        |
| `url.full`                      | `options.uri` (userinfo redacted)   | always        |
| `url.scheme`                    | `options.uri.scheme`                | always        |
| `url.path`                      | `options.uri.path`                  | when present  |
| `url.query`                     | `options.uri.query`                 | when present  |
| `server.address`                | `options.uri.host`                  | when present  |
| `server.port`                   | `options.uri.port`                  | when explicit |
| `http.request.body.size`        | `Content-Length` request header     | when present  |
| `user_agent.original`           | `User-Agent` request header         | when present  |
| `http.response.status_code`     | `response.statusCode`               | on response   |
| `http.response.body.size`       | `Content-Length` response header    | on response   |
| `error.type`                    | `runtimeType` of underlying error   | on exception  |

- **Span name** defaults to `{HTTP_METHOD}` (e.g. `GET`). Per the OTel
  spec the recommended name is `{METHOD} {url-template}` when the
  template is known; pass `spanNameBuilder` if you have one.
- **Span kind** is `CLIENT`.
- **Span status** is set to `Error` for 4xx / 5xx responses and any
  `DioException`; otherwise it follows the SDK default.

Userinfo in the URL (`https://alice:secret@host/...`) is redacted to
`https://REDACTED:REDACTED@host/...` per the spec's "URL.full SHOULD NOT
contain credentials" requirement.

## Interceptor ordering

Add `OTelDioInterceptor` **first** in your interceptor chain. This is
a requirement, not a preference: the span must enclose everything the
other interceptors do (auth-token refresh, retry, request logging). A
span started after a retry interceptor misses retried attempts; one
started after auth misses auth latency. The propagated headers are
injected at the end of `onRequest`, so anything an auth interceptor
adds afterwards is also covered by the same span.

## Deduplication contract

The same request can be observed at two layers: this interceptor
(closest to the application) and any transport-level HTTP
instrumentation underneath it (a global `HttpOverrides`-based tracker,
an instrumented `HttpClient` handed to the adapter, and so on). The
contract is: **the layer closest to the application wins; lower layers
defer.**

The standards-based guard is the W3C `traceparent` header. This
interceptor injects `traceparent` into the outgoing request, so a
transport-layer instrumentation that finds `traceparent` already
present at send time should suppress its own span and per-request
metrics for that request. Any OTel-compliant upper layer qualifies —
this interceptor, `package:http` instrumentation, or manual context
injection — with no sentinel headers and no coordination between
packages.

Within Dio itself the guard is the span stashed in
`RequestOptions.extra`: if `OTelDioInterceptor` is accidentally added
twice, the second instance sees the stashed span and does nothing, so
nothing double-emits and no span leaks unended.

Known edge: if you deliberately strip `traceparent` for certain hosts
(for example CORS-sensitive third parties), a lower-layer tracker
loses the guard for those hosts. Add those hosts to that tracker's
ignore list.

## Ignoring URLs

Requests whose full URL matches any entry in `ignoreUrlPatterns`
(`String` substring or `RegExp`) are not instrumented at all — no
span, no header injection:

```dart
OTelDioInterceptor(
  ignoreUrlPatterns: [
    RegExp(r'/v1/(traces|metrics|logs)$'), // OTLP upload endpoints
    'analytics.example.com',
  ],
)
```

If your telemetry exporter shares this Dio instance, ignore its
endpoints — otherwise every export becomes a span, which is itself
exported.

## Body sizes

`http.{request,response}.body.size` come from the `Content-Length`
header, not by reading the body, so there's no performance hit and no
PII risk. Pass `recordRequestBodySize: false` /
`recordResponseBodySize: false` to disable if your app sets
`Content-Length` to something synthetic.

## Caveats

- The interceptor calls `OTel.tracerProvider().getTracer(...)` in its
  constructor — `OTel.initialize()` must have already run.

## License

Apache 2.0 — see `LICENSE`.
