// Widget tests for the read-only Audit Log Explorer: searching entries and
// viewing one's full before/after detail.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/auditlog/audit_log_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

Widget _wrapWithProviders({required http.Client httpClient, required Widget child}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  return MultiProvider(
    providers: [
      Provider<SecureStorage>.value(value: storage),
      Provider<ApiClient>.value(value: apiClient),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('Audit log lists entries and shows detail on tap', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/audit-logs') {
        return _jsonOk({
          'entries': [
            {
              'id': 'log-1', 'action_code': 'EOD_CLOSED', 'entity_type': 'eod_session',
              'entity_id': 'eod-1', 'actor_name': 'Store Owner', 'created_at': '2026-09-12T18:00:00+05:30',
              'after': {'expected_cash': '3520.00', 'actual_cash': '3520.00'},
            },
            {
              'id': 'log-2', 'action_code': 'CREDIT_LIMIT_OVERRIDE', 'entity_type': 'invoice',
              'entity_id': 'inv-1', 'actor_name': 'Cashier One', 'reason': 'Regular customer, approved by owner',
              'created_at': '2026-09-12T17:00:00+05:30',
            },
          ],
          'total': 2,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const AuditLogScreen()));
    await tester.pumpAndSettle();

    expect(find.text('EOD_CLOSED'), findsOneWidget);
    expect(find.text('CREDIT_LIMIT_OVERRIDE'), findsOneWidget);
    expect(find.textContaining('Store Owner'), findsOneWidget);

    await tester.tap(find.byKey(const Key('audit_log_item_log-2')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Regular customer, approved by owner'), findsOneWidget);
    expect(find.text('By: Cashier One'), findsOneWidget);
  });

  testWidgets('Audit log shows an empty state with no results', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/audit-logs') {
        return _jsonOk({'entries': [], 'total': 0});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const AuditLogScreen()));
    await tester.pumpAndSettle();

    expect(find.text('No audit entries found'), findsOneWidget);
  });

  testWidgets('Audit log search filters via the q query param', (tester) async {
    String? sentQuery;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/audit-logs') {
        sentQuery = request.url.queryParameters['q'];
        if (sentQuery == 'EOD') {
          return _jsonOk({
            'entries': [
              {
                'id': 'log-1', 'action_code': 'EOD_CLOSED', 'entity_type': 'eod_session',
                'created_at': '2026-09-12T18:00:00+05:30',
              }
            ],
            'total': 1,
          });
        }
        return _jsonOk({'entries': [], 'total': 0});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const AuditLogScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('audit_log_search_field')), 'EOD');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(sentQuery, 'EOD');
    expect(find.text('EOD_CLOSED'), findsOneWidget);
  });
}
