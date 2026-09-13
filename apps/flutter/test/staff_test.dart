// Widget tests for Staff/User management: browsing accounts, creating one
// with roles assigned, and the detail screen's status toggle + role chips.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/staff/staff_detail_screen.dart';
import 'package:feedmate_app/features/staff/staff_list_screen.dart';

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

Map<String, dynamic> _ownerRole() => {'id': 'role-owner', 'name': 'Owner', 'is_system_role': true};
Map<String, dynamic> _cashierRole() => {'id': 'role-cashier', 'name': 'Cashier', 'is_system_role': true};

void main() {
  testWidgets('Staff list shows accounts and their status', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/users') {
        return _jsonOk({
          'users': [
            {'id': 'u1', 'username': 'owner1', 'display_name': 'Store Owner', 'status': 'ACTIVE'},
            {'id': 'u2', 'username': 'cashier1', 'display_name': 'Cashier One', 'status': 'DISABLED'},
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const StaffListScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Store Owner'), findsOneWidget);
    expect(find.text('Cashier One'), findsOneWidget);
    expect(find.textContaining('DISABLED'), findsOneWidget);
  });

  testWidgets('Add Staff creates a new user with selected roles', (tester) async {
    Map<String, dynamic>? createdBody;
    var listCallCount = 0;

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/users') {
        createdBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'id': 'u-new'}), 201);
      }
      if (request.url.path == '/api/v1/roles') {
        return _jsonOk({
          'roles': [_ownerRole(), _cashierRole()]
        });
      }
      if (request.url.path == '/api/v1/users') {
        listCallCount++;
        if (listCallCount == 1) return _jsonOk({'users': []});
        return _jsonOk({
          'users': [
            {'id': 'u-new', 'username': 'newcashier', 'display_name': 'New Cashier', 'status': 'ACTIVE'}
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const StaffListScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add_staff_fab')));
    await tester.pumpAndSettle();
    // Roles load asynchronously (post-frame callback) — settle again.
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('staff_username_field')), 'newcashier');
    await tester.enterText(find.byKey(const Key('staff_password_field')), 'a-strong-password');
    await tester.enterText(find.byKey(const Key('staff_display_name_field')), 'New Cashier');
    await tester.tap(find.byKey(const Key('staff_role_chip_role-cashier')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('staff_form_submit')));
    await tester.pumpAndSettle();

    expect(createdBody, isNotNull);
    expect(createdBody!['username'], 'newcashier');
    expect(createdBody!['display_name'], 'New Cashier');
    expect(createdBody!['role_ids'], ['role-cashier']);

    expect(find.textContaining('New Cashier added to staff'), findsOneWidget);
    expect(find.text('New Cashier'), findsOneWidget);
  });

  testWidgets('Add Staff form rejects a short password client-side', (tester) async {
    var createCallCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/users' && request.method == 'GET') {
        return _jsonOk({'users': []});
      }
      if (request.url.path == '/api/v1/roles') {
        return _jsonOk({'roles': []});
      }
      if (request.url.path == '/api/v1/users' && request.method == 'POST') {
        createCallCount++;
        return _jsonOk({'id': 'x'});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const StaffListScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add_staff_fab')));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('staff_username_field')), 'x');
    await tester.enterText(find.byKey(const Key('staff_password_field')), 'short');
    await tester.enterText(find.byKey(const Key('staff_display_name_field')), 'X');
    await tester.tap(find.byKey(const Key('staff_form_submit')));
    await tester.pumpAndSettle();

    expect(find.text('At least 8 characters'), findsOneWidget);
    expect(createCallCount, 0);
  });

  testWidgets('Staff detail toggles active status with confirmation and role chips', (tester) async {
    var status = 'ACTIVE';
    var roleIds = <String>['role-owner'];
    Map<String, dynamic>? statusBody;

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/users/u1/status') {
        statusBody = jsonDecode(request.body) as Map<String, dynamic>;
        status = statusBody!['active'] == true ? 'ACTIVE' : 'DISABLED';
        return http.Response('', 204);
      }
      if (request.method == 'PUT' && request.url.path == '/api/v1/users/u1/roles') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        roleIds = (body['role_ids'] as List<dynamic>).cast<String>();
        return http.Response('', 204);
      }
      if (request.url.path == '/api/v1/users/u1') {
        return _jsonOk({
          'id': 'u1', 'username': 'cashier1', 'display_name': 'Cashier One', 'status': status, 'role_ids': roleIds,
        });
      }
      if (request.url.path == '/api/v1/roles') {
        return _jsonOk({
          'roles': [_ownerRole(), _cashierRole()]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const StaffDetailScreen(userId: 'u1')));
    await tester.pumpAndSettle();

    expect(find.text('Status: ACTIVE'), findsOneWidget);

    await tester.tap(find.byKey(const Key('toggle_staff_active_button')));
    await tester.pumpAndSettle();
    expect(find.text('Deactivate Staff?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('staff_toggle_active_confirm')));
    await tester.pumpAndSettle();

    expect(statusBody!['active'], false);
    expect(find.text('Status: DISABLED'), findsOneWidget);

    await tester.tap(find.byKey(const Key('staff_detail_role_chip_role-cashier')));
    await tester.pumpAndSettle();

    expect(roleIds.toSet(), {'role-owner', 'role-cashier'});
  });
}
