# otel_dio example app

A standalone runnable demo of `otel_dio` exporting telemetry
to a local LGTM stack (Grafana + Loki + Tempo + Mimir).

## Run

```sh
# 1. Start the LGTM stack (from the dartastic-pro repo root)
docker compose -f tool/lgtm/docker-compose.yml up -d

# 2. Run the app
cd dart/otel_dio/example_app
dart pub get
dart run bin/main.dart
```

## What it does

Five scenarios, each in its own parent span so they appear as distinct
traces in Tempo:

| Scenario | Interceptor branch exercised |
|---|---|
| `happy-path-get` | `onResponse`, 200 — span status stays Unset/Ok |
| `not-found-404` | `onResponse`, 4xx — span status flipped to Error |
| `server-error-500` | `onResponse`, 5xx — span status flipped to Error |
| `transport-timeout` | `onError`, no response — `recordException`, `error.type` set |
| `post-with-body` | `onRequest` body-size attribute, `onResponse` 200 |

## Where to look

Grafana → Explore → Tempo datasource:

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
