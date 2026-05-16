// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

/// Integration test: emit a Dio-interceptor client span against a
/// real OTLP endpoint, then poll Tempo's HTTP API to verify the trace
/// arrived and the HTTP semantic-convention attributes survived the
/// round trip.
///
/// Skipped when no LGTM stack is reachable. Bring one up first:
///   docker compose -f tool/lgtm/docker-compose.yml up -d
///
/// Env vars:
///   LGTM_OTLP_ENDPOINT — OTLP gRPC endpoint (default http://localhost:4317)
///   LGTM_TEMPO_URL    — Tempo HTTP API base (default http://localhost:3200)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dio/dio.dart';
import 'package:otel_dio/otel_dio.dart';
import 'package:test/test.dart';

// OTLP/HTTP default port — the SDK's default protocol is `http/protobuf`.
const _defaultOtlp = 'http://localhost:4318';
const _defaultOtlpPort = 4318;
const _defaultTempo = 'http://localhost:3200';

/// httpbin alternative we control; using a real `httpbin.org` request
/// in tests is flaky. The integration test takes the path of least
/// dependency: hit the LGTM container itself on its Grafana port
/// (3000), which always responds with a small page. The interceptor
/// produces the same span regardless of the body — we only care that
/// the OTLP export succeeded and Tempo can find it.
const _selfTargetUrl = 'http://localhost:3000/';

void main() {
  group('LGTM end-to-end', () {
    final otlpEndpoint =
        Platform.environment['LGTM_OTLP_ENDPOINT'] ?? _defaultOtlp;
    final tempoUrl = Platform.environment['LGTM_TEMPO_URL'] ?? _defaultTempo;

    test('Dio client span appears in Tempo', () async {
      // Skip unless BOTH Tempo's HTTP API and the OTLP gRPC port are
      // reachable. Just probing Tempo /ready can match an unrelated
      // service on 3200; the TCP probe on the OTLP port disambiguates.
      final tempoOk = await _tempoReachable(tempoUrl);
      final otlpOk = await _portOpen(otlpEndpoint);
      if (!tempoOk || !otlpOk) {
        markTestSkipped(
          'LGTM not reachable (tempo=$tempoOk otlp=$otlpOk) — start it '
          'with `docker compose -f tool/lgtm/docker-compose.yml up -d` and '
          'rerun.',
        );
        return;
      }

      final exportTimestamp = DateTime.now().toUtc();
      await OTel.reset();
      await OTel.initialize(
        serviceName: 'dio-otel-lgtm-itest',
        serviceVersion: '0.0.1',
        endpoint: otlpEndpoint,
      );

      final dio = Dio()..interceptors.add(OTelDioInterceptor());

      late String traceIdHex;
      await OTel.tracer().startActiveSpanAsync<void>(
        name: 'itest-root',
        fn: (rootSpan) async {
          traceIdHex = rootSpan.spanContext.traceId.hexString;
          try {
            await dio.get<dynamic>(_selfTargetUrl);
          } on DioException {
            // Even if the underlying HTTP fails, the interceptor still
            // produced a span; that's what we're verifying.
          }
        },
      );

      await OTel.tracerProvider().forceFlush();
      await OTel.shutdown();

      // Tempo has a few-second ingest-to-search lag. Poll up to 30s.
      final found = await _pollTempoForTrace(
        tempoUrl: tempoUrl,
        traceIdHex: traceIdHex,
        timeout: const Duration(seconds: 30),
      );

      expect(
        found,
        isNotNull,
        reason:
            'Tempo never returned trace $traceIdHex emitted at $exportTimestamp. '
            'Check the LGTM container logs.',
      );

      // Tempo's batch JSON shape: { batches: [ { resource, scopeSpans: [...] } ] }
      // We just confirm at least one span on this trace has the expected
      // HTTP semconv attributes set by the interceptor.
      final batches = found!['batches'] as List<dynamic>? ?? const [];
      final allSpans = <Map<String, dynamic>>[];
      for (final batch in batches) {
        final scopeSpans =
            (batch as Map<String, dynamic>)['scopeSpans'] as List<dynamic>? ??
                const [];
        for (final ss in scopeSpans) {
          final spans =
              (ss as Map<String, dynamic>)['spans'] as List<dynamic>? ??
                  const [];
          for (final s in spans) {
            allSpans.add(s as Map<String, dynamic>);
          }
        }
      }
      expect(allSpans, isNotEmpty,
          reason: 'Trace returned by Tempo had no spans.');

      final attrKeys = <String>{};
      for (final span in allSpans) {
        final attrs = span['attributes'] as List<dynamic>? ?? const [];
        for (final a in attrs) {
          attrKeys.add((a as Map<String, dynamic>)['key'] as String);
        }
      }
      expect(attrKeys, contains('http.request.method'));
      expect(attrKeys, contains('url.full'));
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}

/// Quick liveness probe — Tempo's /ready endpoint returns 200 once the
/// embedded backends have started.
Future<bool> _tempoReachable(String tempoUrl) async {
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    final req = await client.getUrl(Uri.parse('$tempoUrl/ready'));
    final resp = await req.close().timeout(const Duration(seconds: 2));
    await resp.drain<void>();
    client.close();
    return resp.statusCode == 200;
  } on Exception {
    return false;
  }
}

/// TCP probe — confirms the OTLP gRPC port is actually accepting
/// connections. Parsing the endpoint string with `Uri` handles the
/// `http://host:port` form even though gRPC doesn't speak HTTP.
Future<bool> _portOpen(String endpoint) async {
  try {
    final uri = Uri.parse(endpoint);
    final host = uri.host.isEmpty ? 'localhost' : uri.host;
    final port = uri.hasPort ? uri.port : _defaultOtlpPort;
    final socket =
        await Socket.connect(host, port, timeout: const Duration(seconds: 1));
    socket.destroy();
    return true;
  } on Exception {
    return false;
  }
}

/// Polls `GET {tempoUrl}/api/traces/{trace_id}` until the trace is
/// returned with at least one batch, or [timeout] elapses. Returns
/// the parsed JSON body on success, `null` on timeout.
Future<Map<String, dynamic>?> _pollTempoForTrace({
  required String tempoUrl,
  required String traceIdHex,
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  final client = HttpClient();
  try {
    while (DateTime.now().isBefore(deadline)) {
      try {
        final req = await client.getUrl(
          Uri.parse('$tempoUrl/api/traces/$traceIdHex'),
        );
        final resp = await req.close();
        if (resp.statusCode == 200) {
          final body = await resp.transform(utf8.decoder).join();
          final parsed = jsonDecode(body) as Map<String, dynamic>;
          final batches = parsed['batches'] as List<dynamic>? ?? const [];
          if (batches.isNotEmpty) {
            return parsed;
          }
        } else {
          await resp.drain<void>();
        }
      } on Exception {
        // Transient — keep polling.
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  } finally {
    client.close();
  }
  return null;
}
