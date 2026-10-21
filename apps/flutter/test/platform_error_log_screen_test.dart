// Widget tests for the platform admin's error-log viewer: listing entries
// with the new full-detail fields, filtering, opening the detail view, and
// paginating — replacing the old flat unfiltered scrolling list that
// showed almost nothing because the backend itself used to capture almost
// nothing.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/features/platform/platform_api_client.dart';
import 'package:feedmate_app/features/platform/platform_error_log_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

Widget _wrap({required http.Client httpClient, required Widget child}) {
  final client = PlatformApiClient(baseUrl: 'http://test.invalid', httpClient: httpClient);
  client.seedTokensForTesting(accessToken: 'test-access-token', refreshToken: 'test-refresh-token');
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<PlatformApiClient>.value(value: client),
    ],
    child: MaterialApp(home: Scaffold(backgroundColor: const Color(0xFF0F172A), body: child)),
  );
}

Map<String, dynamic> _entry({
  required String id,
  int statusCode = 400,
  String message = 'Validation failed',
  String createdAt = '2026-01-01T10:00:00Z',
  String? method,
  String? path,
  String? code,
  String? requestId,
  Map<String, dynamic>? requestBody,
  String? stackTrace,
}) {
  return {
    'id': id,
    'status_code': statusCode,
    'message': message,
    'created_at': createdAt,
    if (method != null) 'method': method,
    if (path != null) 'path': path,
    if (code != null) 'code': code,
    if (requestId != null) 'request_id': requestId,
    if (requestBody != null) 'request_body': requestBody,
    if (stackTrace != null) 'stack_trace': stackTrace,
  };
}

void main() {
  testWidgets('lists error entries with method/path, status pill and panic badge', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/error-logs') {
        return _jsonOk({
          'entries': [
            _entry(id: 'e1', statusCode: 400, method: 'POST', path: '/api/v1/customers', code: 'VALIDATION_ERROR'),
            _entry(id: 'e2', statusCode: 500, message: 'panic recovered', stackTrace: 'goroutine 1 [running]:\nmain.foo()'),
          ],
          'total': 2,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const PlatformErrorLogScreen()));
    await tester.pumpAndSettle();

    expect(find.text('POST /api/v1/customers'), findsOneWidget);
    expect(find.text('400'), findsOneWidget);
    expect(find.text('500'), findsOneWidget);
    expect(find.byKey(const Key('platform_error_panic_badge_e2')), findsOneWidget);
    expect(find.byKey(const Key('platform_error_panic_badge_e1')), findsNothing);
  });

  testWidgets('applying filters sends them as query params', (tester) async {
    Uri? lastUri;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/error-logs') {
        lastUri = request.url;
        return _jsonOk({'entries': [], 'total': 0});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const PlatformErrorLogScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('error_log_filter_status_code')), '404');
    await tester.enterText(find.byKey(const Key('error_log_filter_search')), 'customers');
    await tester.tap(find.byKey(const Key('error_log_filter_method')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('POST').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('error_log_apply_filters')));
    await tester.pumpAndSettle();

    expect(lastUri, isNotNull);
    expect(lastUri!.queryParameters['status_code'], '404');
    expect(lastUri!.queryParameters['q'], 'customers');
    expect(lastUri!.queryParameters['method'], 'POST');
  });

  testWidgets('tapping a row opens the detail view with pretty-printed request body and stack trace', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/error-logs') {
        return _jsonOk({
          'entries': [
            _entry(
              id: 'e1',
              statusCode: 500,
              method: 'POST',
              path: '/api/v1/customers',
              requestId: 'req-123',
              requestBody: {'name': 'Acme', 'password': '[REDACTED]'},
              stackTrace: 'goroutine 1 [running]:\nmain.foo()\n\t/app/main.go:42',
            ),
          ],
          'total': 1,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const PlatformErrorLogScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('platform_error_entry_e1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('error_log_detail_screen')), findsOneWidget);
    expect(find.byKey(const Key('error_log_detail_request_body')), findsOneWidget);
    expect(find.textContaining('"name": "Acme"'), findsOneWidget);
    expect(find.textContaining('"[REDACTED]"'), findsOneWidget);
    expect(find.byKey(const Key('error_log_detail_stack_trace')), findsOneWidget);
    expect(find.textContaining('goroutine 1 [running]'), findsOneWidget);
    expect(find.textContaining('req-123'), findsOneWidget);
  });

  testWidgets('pagination requests the next page with the right offset', (tester) async {
    final requestedOffsets = <String?>[];
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/error-logs') {
        requestedOffsets.add(request.url.queryParameters['offset']);
        return _jsonOk({
          'entries': [_entry(id: 'e1')],
          'total': 45,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const PlatformErrorLogScreen()));
    await tester.pumpAndSettle();

    expect(requestedOffsets, ['0']);

    await tester.tap(find.byKey(const Key('error_log_page_next')));
    await tester.pumpAndSettle();

    expect(requestedOffsets.last, '20');

    await tester.tap(find.byKey(const Key('error_log_page_prev')));
    await tester.pumpAndSettle();

    expect(requestedOffsets.last, '0');
  });
}
