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
/// The interceptor must be added **first** (i.e. before auth /
/// retry / logging interceptors) so the span encloses everything the
/// other interceptors do. This is a requirement, not a preference: a
/// span started after a retry interceptor would miss retried
/// attempts, and one started after auth would miss auth latency.
///
/// ## Deduplication contract
///
/// If the same request could also be observed by a lower-layer HTTP
/// instrumentation (a global `HttpOverrides`-based tracker, an
/// instrumented `HttpClient`, or another `OTelDioInterceptor`
/// accidentally added twice), the contract is: **the layer closest to
/// the application wins; lower layers defer.** The standards-based
/// guard is the W3C `traceparent` header — this interceptor injects
/// it into the outgoing headers, so any transport-layer
/// instrumentation that sees `traceparent` already present at send
/// time should suppress its own span (and per-request metrics) for
/// that request. No sentinel headers, no cross-package coordination.
///
/// Within Dio itself, the guard is the span stashed in
/// `RequestOptions.extra`: if a second `OTelDioInterceptor` sees a
/// span already present it does nothing, so double-adding the
/// interceptor cannot leak an unended span or double-emit.
///
/// Known edge: if you deliberately strip `traceparent` for certain
/// hosts (e.g. CORS-sensitive third parties), a lower-layer tracker
/// loses the guard for those hosts — add them to that tracker's
/// ignore list.
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
  /// - [ignoreUrlPatterns] — requests whose full URL matches any of
  ///   these patterns (`String` substring or `RegExp`) are not
  ///   instrumented at all: no span, no header injection. Use this to
  ///   exclude telemetry-upload endpoints (an OTLP exporter going
  ///   through this Dio instance would otherwise instrument its own
  ///   uploads) or hosts you never want traced.
  OTelDioInterceptor({
    Tracer? tracer,
    String Function(RequestOptions options)? spanNameBuilder,
    this.recordRequestBodySize = true,
    this.recordResponseBodySize = true,
    this.ignoreUrlPatterns = const <Pattern>[],
  })  : _tracer = tracer ?? OTel.tracerProvider().getTracer('otel_dio'),
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

  /// URL patterns (matched against the full request URL) that are
  /// excluded from instrumentation entirely.
  final List<Pattern> ignoreUrlPatterns;

  static String _defaultSpanName(RequestOptions options) =>
      options.method.toUpperCase();

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    // Dedup guard: another OTelDioInterceptor earlier in the chain
    // already owns this request — starting a second span would leak
    // the first (it would never be ended) and double-emit.
    if (options.extra[spanExtraKey] is Span) {
      handler.next(options);
      return;
    }

    final uri = options.uri;

    final url = uri.toString();
    if (ignoreUrlPatterns.any(url.contains)) {
      handler.next(options);
      return;
    }

    final method = options.method.toUpperCase();

    final attrs = <String, Object>{
      Http.httpRequestMethod.key: method,
      Url.urlFull.key: _redactedUrl(uri),
      Url.urlScheme.key: uri.scheme,
      if (uri.host.isNotEmpty) Server.serverAddress.key: uri.host,
      if (uri.hasPort) Server.serverPort.key: uri.port,
      if (uri.path.isNotEmpty) Url.urlPath.key: uri.path,
      if (uri.hasQuery) Url.urlQuery.key: uri.query,
    };

    if (recordRequestBodySize) {
      final size = _contentLength(options.headers);
      if (size != null) {
        attrs[Http.httpRequestBodySize.key] = size;
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
    final span = response.requestOptions.extra.remove(spanExtraKey);
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
    final span = err.requestOptions.extra.remove(spanExtraKey);
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
        OTel.attributeInt(Http.httpResponseStatusCode.key, status),
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
        extra.add(OTel.attributeInt(Http.httpResponseBodySize.key, size));
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
            Http.httpResponseStatusCode.key,
            response!.statusCode!,
          ),
        ]),
      );
    }

    // error.type — runtime class of the underlying error (per OTel spec).
    span.addAttributes(
      OTel.attributes([
        OTel.attributeString(
          ErrorAttributes.errorType.key,
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
