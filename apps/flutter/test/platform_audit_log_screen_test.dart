// Widget tests for the platform admin's audit-log viewer: listing entries
// with the new full-detail fields (actor identity, tenant, before/after
// state), filtering, opening the detail view, and paginating.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/features/platform/platform_api_client.dart';
import 'package:feedmate_app/features/platform/platform_audit_log_screen.dart';

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
  String actionCode = 'INVOICE_FINALIZED',
  String entityType = 'sales_invoice',
  String createdAt = '2026-01-01T10:00:00Z',
  String? tenantName,
  String? actorName,
  String? actorPlatformAdminName,
  String? reason,
  Map<String, dynamic>? beforeJson,
  Map<String, dynamic>? afterJson,
}) {
  return {
    'id': id,
    'action_code': actionCode,
    'entity_type': entityType,
    'created_at': createdAt,
    if (tenantName != null) 'tenant_name': tenantName,
    if (actorName != null) 'actor_name': actorName,
    if (actorPlatformAdminName != null) 'actor_platform_admin_name': actorPlatformAdminName,
    if (reason != null) 'reason': reason,
    if (beforeJson != null) 'before_json': beforeJson,
    if (afterJson != null) 'after_json': afterJson,
  };
}

void main() {
  testWidgets('lists audit entries with action, entity, actor and tenant', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/audit-logs') {
        return _jsonOk({
          'entries': [
            _entry(id: 'a1', actionCode: 'INVOICE_FINALIZED', tenantName: 'Acme Store', actorName: 'Jane Staff'),
            _entry(id: 'a2', actionCode: 'TENANT_SUSPENDED', actorPlatformAdminName: 'Root Admin'),
          ],
          'total': 2,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const PlatformAuditLogScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Invoice Finalized'), findsOneWidget);
    expect(find.textContaining('Acme Store'), findsOneWidget);
    expect(find.textContaining('Jane Staff'), findsOneWidget);
    expect(find.text('Tenant Suspended'), findsOneWidget);
    expect(find.textContaining('Platform-level'), findsOneWidget);
    expect(find.textContaining('Root Admin'), findsOneWidget);
  });

  testWidgets('applying filters sends them as query params', (tester) async {
    Uri? lastUri;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/audit-logs') {
        lastUri = request.url;
        return _jsonOk({'entries': [], 'total': 0});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const PlatformAuditLogScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('audit_log_filter_action_code')), 'INVOICE_FINALIZED');
    await tester.enterText(find.byKey(const Key('audit_log_filter_entity_type')), 'sales_invoice');
    await tester.enterText(find.byKey(const Key('audit_log_filter_search')), 'Jane');

    await tester.tap(find.byKey(const Key('audit_log_apply_filters')));
    await tester.pumpAndSettle();

    expect(lastUri, isNotNull);
    expect(lastUri!.queryParameters['action_code'], 'INVOICE_FINALIZED');
    expect(lastUri!.queryParameters['entity_type'], 'sales_invoice');
    expect(lastUri!.queryParameters['q'], 'Jane');
  });

  testWidgets('tapping a row opens the detail view with pretty-printed before/after json', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/audit-logs') {
        return _jsonOk({
          'entries': [
            _entry(
              id: 'a1',
              actionCode: 'TENANT_PLAN_CHANGED',
              tenantName: 'Acme Store',
              actorPlatformAdminName: 'Root Admin',
              reason: 'Customer upgrade request',
              beforeJson: {'plan_code': 'BASIC'},
              afterJson: {'plan_code': 'PRO'},
            ),
          ],
          'total': 1,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const PlatformAuditLogScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('platform_audit_entry_a1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('audit_log_detail_screen')), findsOneWidget);
    expect(find.byKey(const Key('audit_log_detail_before_json')), findsOneWidget);
    expect(find.byKey(const Key('audit_log_detail_after_json')), findsOneWidget);
    expect(find.textContaining('"plan_code": "BASIC"'), findsOneWidget);
    expect(find.textContaining('"plan_code": "PRO"'), findsOneWidget);
    expect(find.textContaining('Customer upgrade request'), findsOneWidget);
  });

  testWidgets('only after_json present shows no empty Before block', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/audit-logs') {
        return _jsonOk({
          'entries': [
            _entry(id: 'a1', actionCode: 'DEVICE_REGISTERED', afterJson: {'device_uuid': 'abc-123'}),
          ],
          'total': 1,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const PlatformAuditLogScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('platform_audit_entry_a1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('audit_log_detail_before_json')), findsNothing);
    expect(find.byKey(const Key('audit_log_detail_after_json')), findsOneWidget);
  });

  testWidgets('pagination requests the next page with the right offset', (tester) async {
    final requestedOffsets = <String?>[];
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/audit-logs') {
        requestedOffsets.add(request.url.queryParameters['offset']);
        return _jsonOk({
          'entries': [_entry(id: 'a1')],
          'total': 45,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const PlatformAuditLogScreen()));
    await tester.pumpAndSettle();

    expect(requestedOffsets, ['0']);

    await tester.tap(find.byKey(const Key('audit_log_page_next')));
    await tester.pumpAndSettle();

    expect(requestedOffsets.last, '20');

    await tester.tap(find.byKey(const Key('audit_log_page_prev')));
    await tester.pumpAndSettle();

    expect(requestedOffsets.last, '0');
  });
}
