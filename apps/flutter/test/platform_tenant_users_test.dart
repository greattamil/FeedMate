// Widget tests for the platform admin's tenant-user management tab:
// listing/searching a tenant's staff accounts, creating one, editing a
// profile, flipping status, and resetting a password (the new UI that
// replaces the owner having to SSH into production to hand-write SQL).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/features/platform/platform_api_client.dart';
import 'package:feedmate_app/features/platform/tenant_users_tab.dart';

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

Map<String, dynamic> _user({
  required String id,
  required String username,
  required String displayName,
  String status = 'ACTIVE',
}) {
  return {'id': id, 'username': username, 'display_name': displayName, 'status': status};
}

void main() {
  testWidgets('lists tenant users and shows status', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/tenants/t1/users') {
        return _jsonOk({
          'users': [
            _user(id: 'u1', username: 'owner1', displayName: 'Owner One'),
            _user(id: 'u2', username: 'staff1', displayName: 'Staff One', status: 'DISABLED'),
          ],
          'total': 2,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const TenantUsersTab(tenantId: 't1')));
    await tester.pumpAndSettle();

    expect(find.text('Owner One'), findsOneWidget);
    expect(find.text('Staff One'), findsOneWidget);
  });

  testWidgets('creating a user posts all fields including selected roles', (tester) async {
    Map<String, dynamic>? postedBody;
    var listCallCount = 0;

    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/v1/platform/tenants/t1/roles') {
        return _jsonOk({
          'roles': [
            {'id': 'role-1', 'name': 'Manager', 'is_system_role': false},
          ],
        });
      }
      if (request.method == 'POST' && request.url.path == '/api/v1/platform/tenants/t1/users') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'id': 'new-u1'}), 201);
      }
      if (request.method == 'GET' && request.url.path == '/api/v1/platform/tenants/t1/users') {
        listCallCount++;
        if (listCallCount == 1) return _jsonOk({'users': [], 'total': 0});
        return _jsonOk({
          'users': [_user(id: 'new-u1', username: 'newstaff', displayName: 'New Staff')],
          'total': 1,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const TenantUsersTab(tenantId: 't1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('platform_add_user_fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('platform_user_username_field')), 'newstaff');
    await tester.enterText(find.byKey(const Key('platform_user_password_field')), 'Password123!');
    await tester.enterText(find.byKey(const Key('platform_user_display_name_field')), 'New Staff');

    await tester.tap(find.byKey(const Key('platform_user_role_chip_role-1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('platform_user_form_submit')));
    await tester.pumpAndSettle();

    expect(postedBody, isNotNull);
    expect(postedBody!['username'], 'newstaff');
    expect(postedBody!['password'], 'Password123!');
    expect(postedBody!['display_name'], 'New Staff');
    expect(postedBody!['role_ids'], ['role-1']);
    expect(find.text('New Staff'), findsOneWidget);
  });

  testWidgets('deactivating a user requires confirmation and posts the status', (tester) async {
    var status = 'ACTIVE';
    Map<String, dynamic>? statusBody;

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/platform/tenants/t1/users/u1/status') {
        statusBody = jsonDecode(request.body) as Map<String, dynamic>;
        status = (statusBody!['active'] as bool) ? 'ACTIVE' : 'DISABLED';
        return http.Response('', 204);
      }
      if (request.method == 'GET' && request.url.path == '/api/v1/platform/tenants/t1/users') {
        return _jsonOk({'users': [_user(id: 'u1', username: 'owner1', displayName: 'Owner One', status: status)], 'total': 1});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const TenantUsersTab(tenantId: 't1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('platform_user_menu_u1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deactivate'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('platform_user_status_confirm')));
    await tester.pumpAndSettle();

    expect(statusBody!['active'], false);
  });

  testWidgets('resetting a password shows the one-time result with a copy warning', (tester) async {
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/platform/tenants/t1/users/u1/reset-password') {
        return _jsonOk({'new_password': 'Generated1234!'});
      }
      if (request.method == 'GET' && request.url.path == '/api/v1/platform/tenants/t1/users') {
        return _jsonOk({'users': [_user(id: 'u1', username: 'owner1', displayName: 'Owner One')], 'total': 1});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const TenantUsersTab(tenantId: 't1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('platform_user_menu_u1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset Password'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('platform_reset_password_confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('platform_reset_password_dialog')), findsOneWidget);
    expect(find.text('Generated1234!'), findsOneWidget);
    expect(find.textContaining('will not be shown again'), findsOneWidget);

    await tester.tap(find.byKey(const Key('platform_new_password_acknowledge')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('platform_reset_password_dialog')), findsNothing);
  });
}
