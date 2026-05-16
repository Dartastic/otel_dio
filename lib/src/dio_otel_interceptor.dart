// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dio/dio.dart';

/// OpenTelemetry client instrumentation for `package:dio`.
///
/// Add to a Dio instance to get a `CLIENT`-kind span around every request,
/// HTTP semantic-convention attributes set automatically, and W3C
/// `traceparent` / `tracestate` / `baggage` headers injected so any
/// downstream service that also speaks OTel joins the same trace.
///
/// ```dart
/// final dio = Dio()..interceptors.add(OTelDioInterceptor());
/// ```
///
/// The interceptor should be added **first** (i.e. before auth /
/// retry / logging interceptors) so the span encloses everything the
/// other interceptors do.
///
/// Span shape follows the OTel HTTP-client semantic conventions:
/// https://opentelemetry.io/docs/specs/semconv/http/http-spans/#http-client
class OTelDioInterceptor extends Interceptor {
  /// Creates an interceptor.
  ///
  /// - [tracer] — the tracer to use. Defaults to `OTel.tracer('otel_dio')`.
  /// - [spanNameBuilder] — overrides the default span name (`{METHOD}`).
  ///   Per spec, the recommended name is the HTTP method or
  ///   `{METHOD} {url-template}` when a route template is known.
  /// - [recordRequestBodySize] / [recordResponseBodySize] — set the
  ///   corresponding `http.{request,response}.body.size` attributes from
  ///   the `Content-Length` header when present. Defaults to `true`.
  OTelDioInterceptor({
    Tracer? tracer,
    String Function(RequestOptions options)? spanNameBuilder,
    this.recordRequestBodySize = true,
    this.recordResponseBodySize = true,
  })  : _tracer =
            tracer ?? OTel.tracerProvider().getTracer('otel_dio'),
        _spanNameBuilder = spanNameBuilder ?? _defaultSpanName,
        _traceContextPropagator = W3CTraceContextPropagator(),
        _baggagePropagator = W3CBaggagePropagator();

  /// Key under which the active span is stashed inside
  /// `RequestOptions.extra` so `onResponse` / `onError` can finish it.
  static const String spanExtraKey = 'otel_dio.span';

  final Tracer _tracer;
  final String Function(RequestOptions options) _spanNameBuilder;
  final W3CTraceContextPropagator _traceContextPropagator;
  final W3CBaggagePropagator _baggagePropagator;

  /// Whether to set `http.request.body.size` from `Content-Length`.
  final bool recordRequestBodySize;

  /// Whether to set `http.response.body.size` from `Content-Length`.
  final bool recordResponseBodySize;

  static String _defaultSpanName(RequestOptions options) =>
      options.method.toUpperCase();

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    final uri = options.uri;
    final method = options.method.toUpperCase();

    final attrs = <String, Object>{
      Http.requestMethod.key: method,
      Url.urlFull.key: _redactedUrl(uri),
      Url.urlScheme.key: uri.scheme,
      if (uri.host.isNotEmpty) ServerResource.serverAddress.key: uri.host,
      if (uri.hasPort) ServerResource.serverPort.key: uri.port,
      if (uri.path.isNotEmpty) Url.urlPath.key: uri.path,
      if (uri.hasQuery) Url.urlQuery.key: uri.query,
    };

    if (recordRequestBodySize) {
      final size = _contentLength(options.headers);
      if (size != null) {
        attrs[Http.requestBodySize.key] = size;
      }
    }

    final userAgent = _firstHeader(options.headers, 'user-agent');
    if (userAgent != null) {
      attrs[UserAgent.userAgentOriginal.key] = userAgent;
    }

    final span = _tracer.startSpan(
      _spanNameBuilder(options),
      kind: SpanKind.client,
      attributes: OTel.attributesFromMap(attrs),
    );

    // Inject W3C trace context + baggage into the outbound headers so
    // the receiving service joins this trace.
    final headerCarrier = <String, String>{};
    final setter = _MapSetter(headerCarrier);
    final ctx = Context.current.withSpan(span);
    _traceContextPropagator.inject(ctx, headerCarrier, setter);
    _baggagePropagator.inject(ctx, headerCarrier, setter);
    options.headers.addAll(headerCarrier);

    options.extra[spanExtraKey] = span;
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final span = response.requestOptions.extra[spanExtraKey];
    if (span is Span) {
      _finishWithResponse(span, response);
    }
    handler.next(response);
  }

  @override
  void onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) {
    final span = err.requestOptions.extra[spanExtraKey];
    if (span is Span) {
      _finishWithError(span, err);
    }
    handler.next(err);
  }

  void _finishWithResponse(Span span, Response<dynamic> response) {
    final status = response.statusCode;
    final extra = <Attribute<Object>>[];
    if (status != null) {
      extra.add(
        OTel.attributeInt(Http.responseStatusCode.key, status),
      );
      if (status >= 400) {
        span.setStatus(
          SpanStatusCode.Error,
          response.statusMessage ?? 'HTTP $status',
        );
      }
    }
    if (recordResponseBodySize) {
      final size = _contentLength(response.headers.map);
      if (size != null) {
        extra.add(OTel.attributeInt(Http.responseBodySize.key, size));
      }
    }
    if (extra.isNotEmpty) {
      span.addAttributes(OTel.attributes(extra));
    }
    span.end();
  }

  void _finishWithError(Span span, DioException err) {
    final response = err.response;
    if (response?.statusCode != null) {
      span.addAttributes(
        OTel.attributes([
          OTel.attributeInt(
            Http.responseStatusCode.key,
            response!.statusCode!,
          ),
        ]),
      );
    }

    // error.type — runtime class of the underlying error (per OTel spec).
    span.addAttributes(
      OTel.attributes([
        OTel.attributeString(
          ErrorResource.errorType.key,
          (err.error ?? err).runtimeType.toString(),
        ),
      ]),
    );

    span.recordException(err.error ?? err, stackTrace: err.stackTrace);
    span.setStatus(SpanStatusCode.Error, err.message ?? err.type.name);
    span.end();
  }

  /// Returns the URL with any userinfo redacted, per OTel HTTP semconv
  /// guidance ("URL.full SHOULD NOT contain credentials").
  static String _redactedUrl(Uri uri) {
    if (uri.userInfo.isEmpty) return uri.toString();
    return uri.replace(userInfo: 'REDACTED:REDACTED').toString();
  }

  static int? _contentLength(Map<String, dynamic> headers) {
    final raw = _firstHeader(headers, 'content-length');
    if (raw == null) return null;
    return int.tryParse(raw);
  }

  /// Headers in `RequestOptions.headers` may be `String` or
  /// `List<String>` (Dio normalizes inconsistently across versions);
  /// `Headers.map` on `Response` is always `List<String>`. This grabs
  /// the first value case-insensitively.
  static String? _firstHeader(Map<String, dynamic> headers, String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() != lower) continue;
      final v = entry.value;
      if (v is List && v.isNotEmpty) return v.first.toString();
      if (v != null) return v.toString();
    }
    return null;
  }
}

class _MapSetter implements TextMapSetter<String> {
  _MapSetter(this._carrier);

  final Map<String, String> _carrier;

  @override
  void set(String key, String value) {
    _carrier[key] = value;
  }
}
