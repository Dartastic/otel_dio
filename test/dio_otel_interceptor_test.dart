// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dio/dio.dart';
import 'package:otel_dio/otel_dio.dart';
import 'package:test/test.dart';

/// Adapter that returns a canned response and records the request it saw.
/// Lets us inspect the headers we injected without doing real network I/O.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({
    this.statusCode = 200,
    this.statusMessage = 'OK',
    this.responseBody = '{}',
    this.exception,
  });

  final int statusCode;
  final String statusMessage;
  final String responseBody;
  final Exception? exception;

  RequestOptions? lastOptions;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    if (exception != null) {
      throw exception!;
    }
    return ResponseBody.fromBytes(
      utf8.encode(responseBody),
      statusCode,
      statusMessage: statusMessage,
      headers: const <String, List<String>>{
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// In-memory span exporter so we can assert what the interceptor produced.
class _MemorySpanExporter implements SpanExporter {
  final List<Span> spans = [];
  bool _shutdown = false;

  @override
  Future<void> export(List<Span> s) async {
    if (_shutdown) return;
    spans.addAll(s);
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {
    _shutdown = true;
  }
}

void main() {
  group('OTelDioInterceptor', () {
    late _MemorySpanExporter exporter;
    late Dio dio;
    late _FakeAdapter adapter;

    setUp(() async {
      await OTel.reset();
      exporter = _MemorySpanExporter();
      await OTel.initialize(
        serviceName: 'dio-otel-test',
        detectPlatformResources: false,
        spanProcessor: SimpleSpanProcessor(exporter),
      );
      adapter = _FakeAdapter();
      dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
        ..httpClientAdapter = adapter
        ..interceptors.add(OTelDioInterceptor());
    });

    tearDown(() async {
      await OTel.shutdown();
      await OTel.reset();
    });

    test('happy path: GET produces a CLIENT span with semconv attributes',
        () async {
      await dio.get<dynamic>('/users/42?expand=true');

      expect(exporter.spans, hasLength(1));
      final span = exporter.spans.single;

      expect(span.name, equals('GET'));
      expect(span.kind, equals(SpanKind.client));

      final attrs = {
        for (final a in span.attributes.toList()) a.key: a.value,
      };
      expect(attrs['http.request.method'], equals('GET'));
      expect(attrs['url.full'],
          equals('https://api.example.com/users/42?expand=true'));
      expect(attrs['url.scheme'], equals('https'));
      expect(attrs['url.path'], equals('/users/42'));
      expect(attrs['url.query'], equals('expand=true'));
      expect(attrs['server.address'], equals('api.example.com'));
      expect(attrs['http.response.status_code'], equals(200));
      // The SDK initializes spans with status Ok (see SDK README) and
      // the interceptor only flips that to Error on 4xx/5xx.
      expect(span.status, isNot(equals(SpanStatusCode.Error)));
    });

    test('injects traceparent into outgoing request headers', () async {
      await dio.get<dynamic>('/things');

      final headers = adapter.lastOptions!.headers;
      expect(headers['traceparent'], isA<String>());
      final tp = headers['traceparent'] as String;
      // version-traceId-spanId-flags = 2 + 32 + 16 + 2 + 3 dashes = 55
      expect(tp.length, equals(55));
      expect(tp.startsWith('00-'), isTrue);
    });

    test('500 response sets span status to Error', () async {
      dio.httpClientAdapter = _FakeAdapter(
        statusCode: 500,
        statusMessage: 'Internal Server Error',
        responseBody: '{"error":"boom"}',
      );
      // validateStatus accepts 500 so dio calls onResponse instead of
      // onError; responseType is plain so dio doesn't reject odd bodies.
      await dio.get<dynamic>(
        '/oops',
        options: Options(
          validateStatus: (_) => true,
          responseType: ResponseType.plain,
        ),
      );

      expect(exporter.spans, hasLength(1));
      final span = exporter.spans.single;
      expect(span.status, equals(SpanStatusCode.Error));
      final attrs = {
        for (final a in span.attributes.toList()) a.key: a.value,
      };
      expect(attrs['http.response.status_code'], equals(500));
    });

    test('transport exception records error.type and Error status', () async {
      dio.httpClientAdapter = _FakeAdapter(
        exception: const FakeSocketException('connection refused'),
      );

      Object? caught;
      try {
        await dio.get<dynamic>('/things');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<DioException>());

      expect(exporter.spans, hasLength(1));
      final span = exporter.spans.single;
      expect(span.status, equals(SpanStatusCode.Error));
      final attrs = {
        for (final a in span.attributes.toList()) a.key: a.value,
      };
      expect(attrs['error.type'], equals('FakeSocketException'));
    });

    test('span name is overridable via spanNameBuilder', () async {
      dio.interceptors.clear();
      dio.interceptors.add(
        OTelDioInterceptor(
          spanNameBuilder: (o) => '${o.method.toUpperCase()} ${o.path}',
        ),
      );

      await dio.get<dynamic>('/users/42');

      expect(exporter.spans.single.name, equals('GET /users/42'));
    });

    test('userinfo in URL is redacted from url.full', () async {
      await dio.getUri<dynamic>(
        Uri.parse('https://alice:secret@api.example.com/me'),
      );

      final attrs = {
        for (final a in exporter.spans.single.attributes.toList())
          a.key: a.value,
      };
      expect(attrs['url.full'], isNot(contains('secret')));
      expect(attrs['url.full'], contains('REDACTED:REDACTED'));
    });

    test('does not crash when no span is stashed (defensive on extra)',
        () async {
      // Simulate a foreign interceptor wiping options.extra before our
      // onResponse fires. The interceptor must tolerate the missing key.
      dio.interceptors.clear();
      dio.interceptors
        ..add(OTelDioInterceptor())
        ..add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              options.extra.remove(OTelDioInterceptor.spanExtraKey);
              handler.next(options);
            },
          ),
        );

      await dio.get<dynamic>('/things');
      // No span was ended via the response path, but no exception either.
    });
  });
}

/// Stand-in for a transport error. Avoids `dart:io` so the test runs on
/// every Dart platform.
class FakeSocketException implements Exception {
  const FakeSocketException(this.message);
  final String message;
  @override
  String toString() => 'FakeSocketException: $message';
}
