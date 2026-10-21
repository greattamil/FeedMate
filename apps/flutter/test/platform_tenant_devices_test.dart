// Widget tests for the platform admin's tenant-device management tab:
// listing devices, revoking one, and generating a pairing code on a
// tenant's behalf (the new UI that replaces the owner having to
// hand-write a pairing-code row in production when a tenant forgot to
// generate their own).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/features/platform/platform_api_client.dart';
import 'package:feedmate_app/features/platform/tenant_devices_tab.dart';

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

Map<String, dynamic> _device({
  required String id,
  required String displayName,
  String platform = 'ANDROID',
  String status = 'ACTIVE',
}) {
  return {
    'id': id,
    'device_uuid': 'uuid-$id',
    'display_name': displayName,
    'platform': platform,
    'status': status,
    'security_state': 'OK',
    'registered_at': '2026-09-01T10:00:00+05:30',
  };
}

void main() {
  testWidgets('lists tenant devices with platform and status', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/tenants/t1/devices') {
        return _jsonOk({
          'devices': [
            _device(id: 'd1', displayName: 'Front Counter Tablet'),
            _device(id: 'd2', displayName: 'Old Phone', status: 'REVOKED'),
          ],
          'total': 2,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const TenantDevicesTab(tenantId: 't1')));
    await tester.pumpAndSettle();

    expect(find.text('Front Counter Tablet'), findsOneWidget);
    expect(find.text('Old Phone'), findsOneWidget);
    expect(find.text('REVOKED'), findsOneWidget);
  });

  testWidgets('revoking a device requires confirmation and posts the reason', (tester) async {
    Map<String, dynamic>? revokeBody;
    var status = 'ACTIVE';

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/platform/tenants/t1/devices/d1/revoke') {
        revokeBody = jsonDecode(request.body) as Map<String, dynamic>;
        status = 'REVOKED';
        return http.Response('', 204);
      }
      if (request.method == 'GET' && request.url.path == '/api/v1/platform/tenants/t1/devices') {
        return _jsonOk({'devices': [_device(id: 'd1', displayName: 'Front Counter Tablet', status: status)], 'total': 1});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const TenantDevicesTab(tenantId: 't1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('platform_revoke_device_d1')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('platform_revoke_reason_field')), 'Lost device');
    await tester.tap(find.byKey(const Key('platform_revoke_confirm_button')));
    await tester.pumpAndSettle();

    expect(revokeBody, isNotNull);
    expect(revokeBody!['reason'], 'Lost device');
    expect(find.text('REVOKED'), findsOneWidget);
  });

  testWidgets('generating a pairing code shows the code and an expiry countdown', (tester) async {
    final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 10));
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/platform/tenants/t1/devices/pairing-codes') {
        return _jsonOk({'code': 'ABCD1234', 'expires_at': expiresAt.toIso8601String()});
      }
      if (request.method == 'GET' && request.url.path == '/api/v1/platform/tenants/t1/devices') {
        return _jsonOk({'devices': [], 'total': 0});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const TenantDevicesTab(tenantId: 't1')));
    await tester.pumpAndSettle();

    // Deliberately avoid pumpAndSettle while this dialog is open: its
    // live countdown runs on a real periodic Timer (ticks every real
    // second), which would otherwise make pumpAndSettle's "wait until no
    // more frames are scheduled" loop forever. A couple of targeted
    // pumps are enough to flush the dialog opening and its one network
    // round trip.
    await tester.tap(find.byKey(const Key('platform_generate_pairing_code_fab')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('platform_pairing_code_dialog')), findsOneWidget);
    expect(find.text('ABCD1234'), findsOneWidget);
    expect(find.byKey(const Key('platform_pairing_code_expiry')), findsOneWidget);
    expect(find.textContaining('Expires in'), findsOneWidget);

    await tester.tap(find.byKey(const Key('platform_pairing_code_close')));
    await tester.pump();

    expect(find.byKey(const Key('platform_pairing_code_dialog')), findsNothing);
  });
}
