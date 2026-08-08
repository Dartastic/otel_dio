# otel_dio example app

A standalone runnable demo of `otel_dio` exporting telemetry to a
local OTLP-capable backend with a trace UI.

## Run

```sh
# 1. Start any OTLP-compatible backend with a trace UI, e.g. an
#    all-in-one dev-observability container, publishing OTLP on
#    4317/4318 and the UI on 3000:
docker run --rm -p 3000:3000 -p 4317:4317 -p 4318:4318 <your-otlp-backend-image>

# 2. Run the app
cd example_app
dart pub get
dart run bin/main.dart
```

## What it does

Five scenarios, each in its own parent span so they appear as distinct
traces in your trace UI:

| Scenario | Interceptor branch exercised |
|---|---|
| `happy-path-get` | `onResponse`, 200 — span status stays Unset/Ok |
| `not-found-404` | `onResponse`, 4xx — span status flipped to Error |
| `server-error-500` | `onResponse`, 5xx — span status flipped to Error |
| `transport-timeout` | `onError`, no response — `recordException`, `error.type` set |
| `post-with-body` | `onRequest` body-size attribute, `onResponse` 200 |

## Where to look

In your trace UI (http://localhost:3000 for the container above):

- Service name: `dio-otel-example-app`
- Each scenario span has child spans named after the HTTP method
  (`GET`, `POST`) with the full HTTP semantic-convention attribute
  set: `http.request.method`, `url.full`, `url.scheme`, `url.path`,
  `server.address`, `server.port`, `http.response.status_code`,
  `user_agent.original`.

## Env

| Variable | Default | Purpose |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318` | OTLP HTTP endpoint (the SDK's default protocol). For gRPC, also set `OTEL_EXPORTER_OTLP_PROTOCOL=grpc` and point at port 4317. |
