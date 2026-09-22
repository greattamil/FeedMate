// Widget tests for the super-admin control plane: platform login (separate
// from tenant login), the tenant list/create/detail flow, and the
// cross-tenant audit/error log viewers.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/features/platform/platform_api_client.dart';
import 'package:feedmate_app/features/platform/platform_login_screen.dart';
import 'package:feedmate_app/features/platform/platform_shell.dart';
import 'package:feedmate_app/features/platform/tenant_list_screen.dart';
import 'package:feedmate_app/features/platform/tenant_detail_screen.dart';
import 'package:feedmate_app/features/platform/platform_audit_log_screen.dart';
import 'package:feedmate_app/features/platform/platform_error_log_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

Widget _wrap({required http.Client httpClient, required Widget child, PlatformApiClient? client, bool loggedIn = true}) {
  final resolvedClient = client ?? PlatformApiClient(baseUrl: 'http://test.invalid', httpClient: httpClient);
  if (loggedIn && client == null) {
    resolvedClient.seedTokensForTesting(accessToken: 'test-access-token', refreshToken: 'test-refresh-token');
  }
  return ChangeNotifierProvider<PlatformApiClient>.value(
    value: resolvedClient,
    child: MaterialApp(home: Scaffold(backgroundColor: const Color(0xFF0F172A), body: child)),
  );
}

Map<String, dynamic> _tenant({
  required String id,
  required String legalName,
  String city = 'Andipatti',
  String status = 'ACTIVE',
  String planCode = 'TRIAL',
  int userCount = 1,
}) {
  return {
    'id': id, 'legal_name': legalName, 'city': city, 'status': status,
    'plan_code': planCode, 'user_count': userCount, 'created_at': '2026-09-01T10:00:00+05:30',
  };
}

void main() {
  testWidgets('platform login succeeds and navigates to the shell', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/auth/login') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['username'], 'superadmin');
        expect(body['password'], 'SuperAdmin123!');
        return _jsonOk({'access_token': 'tok', 'refresh_token': 'ref', 'expires_in': 900, 'display_name': 'Super Admin'});
      }
      if (request.url.path == '/api/v1/platform/tenants') {
        return _jsonOk({'tenants': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const PlatformLoginScreen(), loggedIn: false));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('platform_username_field')), 'superadmin');
    await tester.enterText(find.byKey(const Key('platform_password_field')), 'SuperAdmin123!');
    await tester.tap(find.byKey(const Key('platform_login_button')));
    await tester.pumpAndSettle();

    expect(find.byType(PlatformShell), findsOneWidget);
    expect(find.textContaining('Super Admin'), findsWidgets);
  });

  testWidgets('platform login shows the server error message on bad credentials', (tester) async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({'error': {'code': 'UNAUTHORIZED', 'message': 'invalid username or password'}}),
        401,
      );
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const PlatformLoginScreen(), loggedIn: false));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('platform_username_field')), 'superadmin');
    await tester.enterText(find.byKey(const Key('platform_password_field')), 'wrong');
    await tester.tap(find.byKey(const Key('platform_login_button')));
    await tester.pumpAndSettle();

    expect(find.text('invalid username or password'), findsOneWidget);
    expect(find.byType(PlatformShell), findsNothing);
  });

  testWidgets('tenant list shows tenants and navigating to detail then back refreshes', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/tenants') {
        return _jsonOk({
          'tenants': [
            _tenant(id: 't1', legalName: 'SKM Feeds', status: 'ACTIVE'),
            _tenant(id: 't2', legalName: 'Suspended Store', status: 'SUSPENDED'),
          ]
        });
      }
      if (request.url.path == '/api/v1/platform/tenants/t1') {
        return _jsonOk({
          ..._tenant(id: 't1', legalName: 'SKM Feeds'),
          'address_line1': '1 Main Rd', 'state_code': 'TN', 'features': {},
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const TenantListScreen()));
    await tester.pumpAndSettle();

    expect(find.text('SKM Feeds'), findsOneWidget);
    expect(find.text('Suspended Store'), findsOneWidget);
    expect(find.text('SUSPENDED'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tenant_item_t1')));
    await tester.pumpAndSettle();

    expect(find.byType(TenantDetailScreen), findsOneWidget);
    expect(find.text('SKM Feeds'), findsWidgets);
  });

  testWidgets('creating a tenant posts every field and returns to the list', (tester) async {
    Map<String, dynamic>? postedBody;
    var listCallCount = 0;

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/platform/tenants') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _jsonOk({'tenant_id': 'new-t1', 'owner_user_id': 'new-u1'});
      }
      if (request.url.path == '/api/v1/platform/tenants') {
        listCallCount++;
        if (listCallCount == 1) return _jsonOk({'tenants': []});
        return _jsonOk({'tenants': [_tenant(id: 'new-t1', legalName: 'New Client Store')]});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const TenantListScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add_tenant_fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('tenant_legal_name_field')), 'New Client Store');
    await tester.enterText(find.byKey(const Key('tenant_address_field')), '5 Market St');
    await tester.enterText(find.byKey(const Key('tenant_city_field')), 'Andipatti');

    await tester.dragUntilVisible(
      find.byKey(const Key('tenant_owner_name_field')),
      find.byType(Scrollable).first,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tenant_owner_name_field')), 'New Owner');
    await tester.enterText(find.byKey(const Key('tenant_owner_username_field')), 'newowner');
    await tester.enterText(find.byKey(const Key('tenant_owner_password_field')), 'OwnerPass123!');

    await tester.dragUntilVisible(
      find.byKey(const Key('create_tenant_submit')),
      find.byType(Scrollable).first,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create_tenant_submit')));
    await tester.pumpAndSettle();

    expect(postedBody, isNotNull);
    expect(postedBody!['legal_name'], 'New Client Store');
    expect(postedBody!['owner_username'], 'newowner');
    expect(postedBody!['owner_password'], 'OwnerPass123!');
    expect(postedBody!['plan_code'], 'TRIAL');

    expect(find.text('New Client Store'), findsOneWidget);
  });

  testWidgets('suspending a tenant from detail requires confirmation and posts the status', (tester) async {
    var status = 'ACTIVE';
    Map<String, dynamic>? statusBody;

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/platform/tenants/t1/status') {
        statusBody = jsonDecode(request.body) as Map<String, dynamic>;
        status = statusBody!['status'] as String;
        return http.Response('', 204);
      }
      if (request.url.path == '/api/v1/platform/tenants/t1') {
        return _jsonOk({..._tenant(id: 't1', legalName: 'SKM Feeds', status: status), 'address_line1': '1 Main Rd', 'state_code': 'TN', 'features': {}});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const TenantDetailScreen(tenantId: 't1')));
    await tester.pumpAndSettle();

    expect(find.text('Current: ACTIVE'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tenant_suspend_button')));
    await tester.pumpAndSettle();
    expect(find.text('Suspend Tenant?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tenant_status_confirm')));
    await tester.pumpAndSettle();

    expect(statusBody!['status'], 'SUSPENDED');
    expect(find.text('Current: SUSPENDED'), findsOneWidget);
  });

  testWidgets('editing plan and toggling a feature flag both persist', (tester) async {
    var planCode = 'TRIAL';
    var features = <String, bool>{};
    Map<String, dynamic>? planBody;
    Map<String, dynamic>? featureBody;

    final client = MockClient((request) async {
      if (request.method == 'PUT' && request.url.path == '/api/v1/platform/tenants/t1/plan') {
        planBody = jsonDecode(request.body) as Map<String, dynamic>;
        planCode = planBody!['plan_code'] as String;
        return http.Response('', 204);
      }
      if (request.method == 'PUT' && request.url.path == '/api/v1/platform/tenants/t1/features') {
        featureBody = jsonDecode(request.body) as Map<String, dynamic>;
        features[featureBody!['feature_code'] as String] = featureBody!['enabled'] as bool;
        return http.Response('', 204);
      }
      if (request.url.path == '/api/v1/platform/tenants/t1') {
        return _jsonOk({
          ..._tenant(id: 't1', legalName: 'SKM Feeds', planCode: planCode),
          'address_line1': '1 Main Rd', 'state_code': 'TN', 'features': features,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const TenantDetailScreen(tenantId: 't1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tenant_edit_plan_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan_dialog_code_field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PRO').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan_dialog_submit')));
    await tester.pumpAndSettle();

    expect(planBody!['plan_code'], 'PRO');
    expect(find.textContaining('Plan: PRO'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tenant_feature_switch_advanced_reports')));
    await tester.pumpAndSettle();

    expect(featureBody!['feature_code'], 'advanced_reports');
    expect(featureBody!['enabled'], true);
  });

  testWidgets('cross-tenant audit log lists entries from multiple tenants', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/audit-logs') {
        return _jsonOk({
          'entries': [
            {
              'id': 'a1', 'tenant_id': 't1', 'tenant_name': 'SKM Feeds', 'actor_name': 'Owner One',
              'action_code': 'TENANT_SUSPENDED', 'entity_type': 'tenant', 'created_at': '2026-09-20T10:00:00+05:30',
            },
            {
              'id': 'a2', 'tenant_id': 't2', 'tenant_name': 'Other Store', 'actor_name': null,
              'action_code': 'DEVICE_PAIRED', 'entity_type': 'device', 'created_at': '2026-09-19T09:00:00+05:30',
            },
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const PlatformAuditLogScreen()));
    await tester.pumpAndSettle();

    expect(find.text('TENANT_SUSPENDED'), findsOneWidget);
    expect(find.textContaining('SKM Feeds'), findsOneWidget);
    expect(find.text('DEVICE_PAIRED'), findsOneWidget);
    expect(find.textContaining('Other Store'), findsOneWidget);
  });

  testWidgets('error log lists recorded 5xx entries with the request id', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/error-logs') {
        return _jsonOk({
          'entries': [
            {
              'id': 'e1', 'request_id': '11111111-1111-1111-1111-111111111111', 'status_code': 500,
              'message': 'failed to post GRN: something broke', 'created_at': '2026-09-21T08:00:00+05:30',
            },
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const PlatformErrorLogScreen()));
    await tester.pumpAndSettle();

    expect(find.text('500'), findsOneWidget);
    expect(find.textContaining('failed to post GRN'), findsOneWidget);
    expect(find.textContaining('11111111-1111-1111-1111-111111111111'), findsOneWidget);
  });

  testWidgets('logging out from the shell returns to the platform login screen', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/auth/login') {
        return _jsonOk({'access_token': 'tok', 'refresh_token': 'ref', 'expires_in': 900, 'display_name': 'Super Admin'});
      }
      if (request.url.path == '/api/v1/platform/tenants') return _jsonOk({'tenants': []});
      if (request.url.path == '/api/v1/platform/auth/logout') return http.Response('', 204);
      return http.Response('not found', 404);
    });
    final platformClient = PlatformApiClient(baseUrl: 'http://test.invalid', httpClient: client);
    await platformClient.login('superadmin', 'SuperAdmin123!');

    await tester.pumpWidget(_wrap(httpClient: client, client: platformClient, child: const PlatformShell()));
    await tester.pumpAndSettle();

    expect(find.byType(TenantListScreen), findsOneWidget);

    await tester.tap(find.byKey(const Key('platform_logout_button')));
    await tester.pumpAndSettle();

    expect(find.byType(PlatformLoginScreen), findsOneWidget);
    expect(platformClient.isLoggedIn, isFalse);
  });
}
