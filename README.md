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

Add `OTelDioInterceptor` **first** in your interceptor chain so the
span encloses everything other interceptors do (auth-token refresh,
retry, request logging). The propagated headers are injected at the end
of `onRequest`, so anything an auth interceptor adds afterwards is also
covered by the same span.

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
