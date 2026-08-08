# otel_dio

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
