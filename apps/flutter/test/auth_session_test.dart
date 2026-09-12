// Tests for AuthSession.restoreSession(): a persisted session must come
// back with its display name and permissions intact, not just an
// authenticated status flag — otherwise every permission-gated screen
// (device pairing, the supplier ledger) would silently vanish after any
// app restart despite the user's role being unchanged. Plain test(), not
// testWidgets() — no widget tree needed here.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/auth_session.dart';
import 'package:feedmate_app/core/secure_storage.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

void main() {
  test('restoreSession with a valid stored refresh token restores display name and permissions', () async {
    final storage = SecureStorage(store: InMemoryKeyValueStore());
    await storage.saveTokens(accessToken: 'stale-access-token', refreshToken: 'valid-refresh-token', tenantId: 'tenant-123');

    final client = MockClient((request) async {
      expect(request.url.path, '/api/v1/auth/refresh');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['tenant_id'], 'tenant-123');
      expect(body['refresh_token'], 'valid-refresh-token');
      return _jsonOk({
        'access_token': 'fresh-access-token',
        'refresh_token': 'rotated-refresh-token',
        'tenant_id': 'tenant-123',
        'display_name': 'Shop Owner',
        'permissions': ['pos.sell', 'supplier.manage'],
      });
    });
    final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: client);
    final session = AuthSession(apiClient: apiClient, storage: storage);

    await session.restoreSession();

    expect(session.status, AuthStatus.loggedIn);
    expect(session.displayName, 'Shop Owner');
    expect(session.permissions, ['pos.sell', 'supplier.manage']);
    expect(session.hasPermission('supplier.manage'), isTrue);
    expect(session.hasPermission('credit.configure'), isFalse);

    // The rotated tokens must actually be persisted, not just held in memory.
    expect(await storage.getAccessToken(), 'fresh-access-token');
    expect(await storage.getRefreshToken(), 'rotated-refresh-token');
  });

  test('restoreSession with an expired/invalid refresh token clears storage and logs out', () async {
    final storage = SecureStorage(store: InMemoryKeyValueStore());
    await storage.saveTokens(accessToken: 'stale-access-token', refreshToken: 'expired-refresh-token', tenantId: 'tenant-123');

    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'error': {'code': 'UNAUTHORIZED', 'message': 'refresh token invalid or expired', 'retryable': false}
        }),
        401,
      );
    });
    final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: client);
    final session = AuthSession(apiClient: apiClient, storage: storage);

    await session.restoreSession();

    expect(session.status, AuthStatus.loggedOut);
    expect(session.permissions, isEmpty);
    expect(await storage.getAccessToken(), isNull);
    expect(await storage.getRefreshToken(), isNull);
  });

  test('restoreSession with no stored session logs out without any network call', () async {
    final storage = SecureStorage(store: InMemoryKeyValueStore());
    var networkCalls = 0;
    final client = MockClient((request) async {
      networkCalls++;
      return http.Response('not found', 404);
    });
    final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: client);
    final session = AuthSession(apiClient: apiClient, storage: storage);

    await session.restoreSession();

    expect(session.status, AuthStatus.loggedOut);
    expect(networkCalls, 0);
  });
}
