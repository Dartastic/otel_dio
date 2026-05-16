// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

/// Runnable demo of `otel_dio` against a local LGTM stack.
///
/// Run the stack:
///   docker compose -f ../../../tool/lgtm/docker-compose.yml up -d
///
/// Then run this app:
///   dart run bin/main.dart
///
/// Open Grafana (http://localhost:3000), pick the Tempo datasource in
/// Explore, search for service `dio-otel-example-app`, and you'll see
/// one trace per scenario below — happy path, 4xx, 5xx, and a
/// transport timeout, each demonstrating a different interceptor
/// branch and the resulting span attributes.
library;

import 'dart:async';
import 'dart:io';

// Example apps use the Pro SDK to demonstrate the one-character
// switch (OTel.initialize -> DOTel.initialize). The package source
// still imports the OSS SDK directly so non-Pro users can use it.
import 'package:dartastic_opentelemetry_pro/dartastic_opentelemetry_pro.dart';
import 'package:dio/dio.dart';
import 'package:otel_dio/otel_dio.dart';

const _serviceName = 'dio-otel-example-app';
// 4318 = OTLP/HTTP default port (the SDK's default protocol is
// `http/protobuf`). Use 4317 only with `OTEL_EXPORTER_OTLP_PROTOCOL=grpc`.
const _defaultEndpoint = 'http://localhost:4318';

Future<void> main(List<String> args) async {
  // OTEL_EXPORTER_OTLP_ENDPOINT takes precedence so CI / Compose can
  // point at a non-default LGTM. Otherwise localhost:4317.
  final endpoint =
      Platform.environment['OTEL_EXPORTER_OTLP_ENDPOINT'] ?? _defaultEndpoint;

  print('==> exporting to $endpoint as $_serviceName');

  await DOTel.initialize(
    serviceName: _serviceName,
    serviceVersion: '0.0.1',
    endpoint: endpoint,
  );

  // httpbin.org is the de facto "I just want to see HTTP do a thing"
  // endpoint. /status/<code> echoes the given status; /delay/<seconds>
  // sleeps before responding; /anything echoes the request.
  final dio = Dio(BaseOptions(baseUrl: 'https://httpbin.org'))
    ..interceptors.add(OTelDioInterceptor());

  final tracer = DOTel.tracer();

  await tracer.startActiveSpanAsync<void>(
    name: 'run-scenarios',
    fn: (_) async {
      await _scenario('happy-path-get', () async {
        final r = await dio.get<dynamic>('/anything');
        print('  ok  ${r.statusCode}');
      });

      await _scenario('not-found-404', () async {
        try {
          await dio.get<dynamic>('/status/404');
        } on DioException catch (e) {
          print('  expected 4xx: ${e.response?.statusCode}');
        }
      });

      await _scenario('server-error-500', () async {
        try {
          await dio.get<dynamic>('/status/500');
        } on DioException catch (e) {
          print('  expected 5xx: ${e.response?.statusCode}');
        }
      });

      await _scenario('transport-timeout', () async {
        try {
          // /delay/3 sleeps 3 seconds; force a 500ms receive timeout
          // just for this request so the other scenarios stay snappy.
          await dio.get<dynamic>(
            '/delay/3',
            options: Options(
              receiveTimeout: const Duration(milliseconds: 500),
            ),
          );
        } on DioException catch (e) {
          print('  expected timeout: ${e.type.name}');
        }
      });

      await _scenario('post-with-body', () async {
        final r = await dio.post<dynamic>(
          '/anything',
          data: {'hello': 'tempo'},
        );
        print('  ok  ${r.statusCode}');
      });
    },
  );

  print('==> flushing + shutting down');
  await DOTel.tracerProvider().forceFlush();
  await DOTel.shutdown();
  print('==> done. open Grafana at http://localhost:3000 → Explore → '
      'Tempo, service = $_serviceName');
}

Future<void> _scenario(String name, Future<void> Function() body) async {
  print('--> $name');
  await DOTel.tracer().startActiveSpanAsync<void>(
    name: name,
    fn: (_) async {
      try {
        await body();
      } catch (e) {
        // Already recorded by the Dio interceptor as a client span; we
        // just don't let the parent scenario span bubble it up.
        print('  caught: $e');
      }
    },
  );
}
