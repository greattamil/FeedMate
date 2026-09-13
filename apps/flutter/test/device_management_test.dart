// Widget tests for the Device Management screen: browsing registered
// devices and revoking one (with a confirmation dialog, since revocation
// is immediate and permanent from the device's point of view).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/auth/device_management_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

Widget _wrapWithProviders({required http.Client httpClient}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  return MultiProvider(
    providers: [
      Provider<SecureStorage>.value(value: storage),
      Provider<ApiClient>.value(value: apiClient),
    ],
    child: const MaterialApp(home: DeviceManagementScreen()),
  );
}

void main() {
  testWidgets('Device list shows registered devices with status', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/devices') {
        return _jsonOk({
          'devices': [
            {
              'id': 'dev-1', 'display_name': 'Front Counter Tablet', 'platform': 'ANDROID',
              'status': 'ACTIVE', 'security_state': 'TRUSTED', 'last_seen_at': '2026-09-12T18:00:00+05:30',
              'registered_at': '2026-01-01T10:00:00+05:30',
            },
            {
              'id': 'dev-2', 'display_name': 'Old Phone', 'platform': 'ANDROID',
              'status': 'REVOKED', 'security_state': 'UNKNOWN', 'registered_at': '2025-01-01T10:00:00+05:30',
            },
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.text('Front Counter Tablet'), findsOneWidget);
    expect(find.text('Old Phone'), findsOneWidget);

    // Active device gets a revoke button, an already-revoked one does not.
    expect(find.byKey(const Key('revoke_device_dev-1')), findsOneWidget);
    expect(find.byKey(const Key('revoke_device_dev-2')), findsNothing);
  });

  testWidgets('Revoking a device requires confirmation and posts the request', (tester) async {
    var revokeCallCount = 0;
    Map<String, dynamic>? postedBody;
    var deviceStatus = 'ACTIVE';

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/devices') {
        return _jsonOk({
          'devices': [
            {
              'id': 'dev-1', 'display_name': 'Cashier Phone', 'platform': 'ANDROID',
              'status': deviceStatus, 'security_state': 'TRUSTED', 'registered_at': '2026-01-01T10:00:00+05:30',
            }
          ]
        });
      }
      if (request.url.path == '/api/v1/devices/dev-1/revoke') {
        revokeCallCount++;
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        deviceStatus = 'REVOKED';
        return http.Response('', 204);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('revoke_device_dev-1')));
    await tester.pumpAndSettle();

    expect(find.text('Revoke Device?'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('revoke_reason_field')), 'Lost by cashier');
    await tester.tap(find.byKey(const Key('revoke_confirm_button')));
    await tester.pumpAndSettle();

    expect(revokeCallCount, 1);
    expect(postedBody!['reason'], 'Lost by cashier');
    expect(find.textContaining('Cashier Phone has been revoked'), findsOneWidget);
    expect(find.byKey(const Key('revoke_device_dev-1')), findsNothing);
  });

  testWidgets('Cancelling the revoke confirmation does not call the server', (tester) async {
    var revokeCallCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/devices') {
        return _jsonOk({
          'devices': [
            {
              'id': 'dev-1', 'display_name': 'Cashier Phone', 'platform': 'ANDROID',
              'status': 'ACTIVE', 'security_state': 'TRUSTED', 'registered_at': '2026-01-01T10:00:00+05:30',
            }
          ]
        });
      }
      if (request.url.path == '/api/v1/devices/dev-1/revoke') {
        revokeCallCount++;
        return http.Response('', 204);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('revoke_device_dev-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(revokeCallCount, 0);
    expect(find.byKey(const Key('revoke_device_dev-1')), findsOneWidget);
  });
}
