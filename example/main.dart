// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

/// Minimal example: initialize OTel, add the interceptor to a Dio
/// instance, make a request inside an active server-side span, then
/// shut down cleanly.
library;

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dio/dio.dart';
import 'package:otel_dio/otel_dio.dart';

Future<void> main() async {
  await OTel.initialize(
    serviceName: 'dio-otel-example',
    serviceVersion: '0.0.1',
  );

  final dio = Dio(BaseOptions(baseUrl: 'https://httpbin.org'))
    ..interceptors.add(OTelDioInterceptor());

  // Wrap the outbound call in a parent span so the client span has
  // somewhere to be attached. In a real server, the parent would be
  // the incoming-request span you got from your framework's interceptor.
  final tracer = OTel.tracer();
  await tracer.startActiveSpanAsync<void>(
    name: 'serve-request',
    fn: (_) async {
      final response = await dio.get<dynamic>('/status/200');
      print('status: ${response.statusCode}');
    },
  );

  await OTel.shutdown();
}
