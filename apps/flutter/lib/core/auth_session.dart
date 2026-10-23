import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'api_error.dart';
import 'secure_storage.dart';

enum AuthStatus { unknown, loggedOut, loggedIn }

/// Holds the current login state and drives the login/logout flow. Screens
/// listen to this via Provider rather than talking to SecureStorage/ApiClient
/// directly for auth concerns.
class AuthSession extends ChangeNotifier {
  final ApiClient apiClient;
  final SecureStorage storage;

  AuthSession({required this.apiClient, required this.storage});

  AuthStatus status = AuthStatus.unknown;
  String? tenantId;
  String? displayName;
  List<String> permissions = [];
  String? lastError;

  /// Restores a session after an app restart. Deliberately always exchanges
  /// the stored refresh token for a fresh access token — rather than just
  /// trusting the persisted access token and flipping straight to
  /// loggedIn — because a persisted access token carries no display name or
  /// permissions with it. Without this, every permission-gated screen
  /// (device pairing, the supplier ledger) would silently vanish after any
  /// app restart even though the user's role never changed, since
  /// `permissions` would stay at its empty default forever.
  Future<void> restoreSession() async {
    final tenant = await storage.getTenantId();
    final refreshToken = await storage.getRefreshToken();
    if (tenant == null || refreshToken == null) {
      status = AuthStatus.loggedOut;
      notifyListeners();
      return;
    }
    try {
      final result = await apiClient.refresh(tenantId: tenant, refreshToken: refreshToken);
      await storage.saveTokens(
        accessToken: result['access_token'] as String,
        refreshToken: result['refresh_token'] as String,
        tenantId: tenant,
      );
      tenantId = tenant;
      displayName = result['display_name'] as String?;
      permissions = (result['permissions'] as List<dynamic>? ?? []).cast<String>();
      status = AuthStatus.loggedIn;
      _registerPushToken();
    } on ApiError {
      // The stored refresh token is invalid or expired — the user must log
      // in again with their password; there is no way to silently recover.
      await storage.clearTokens();
      status = AuthStatus.loggedOut;
    }
    notifyListeners();
  }

  bool hasPermission(String code) => permissions.contains(code);

  Future<bool> login({required String username, required String password}) async {
    lastError = null;
    try {
      final deviceUuid = await storage.getOrCreateDeviceUuid();
      final result = await apiClient.login(
        deviceUuid: deviceUuid,
        username: username,
        password: password,
      );
      final tenant = result['tenant_id'] as String;
      await storage.saveTokens(
        accessToken: result['access_token'] as String,
        refreshToken: result['refresh_token'] as String,
        tenantId: tenant,
      );
      tenantId = tenant;
      displayName = result['display_name'] as String?;
      permissions = (result['permissions'] as List<dynamic>? ?? []).cast<String>();
      status = AuthStatus.loggedIn;
      notifyListeners();
      _registerPushToken();
      return true;
    } on ApiError catch (e) {
      lastError = e.message;
      status = AuthStatus.loggedOut;
      notifyListeners();
      return false;
    }
  }

  /// Best-effort — a device with push notifications unavailable (web,
  /// Windows, a permission denial, or any FCM/plugin error) must still be
  /// able to log in and use the app normally. Fire-and-forget: this never
  /// blocks or fails the login/restore flow that calls it, and every
  /// failure is swallowed rather than surfaced, since push is a nice-to-have
  /// (internal/domain/pushnotify's credit-limit alert), not core
  /// functionality.
  Future<void> _registerPushToken() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token == null) return;
      await apiClient.putAuthed('/api/v1/devices/fcm-token', {'token': token});
    } catch (_) {
      // Swallowed deliberately — see doc comment above.
    }
  }

  Future<void> logout() async {
    // Best-effort: clear this device's token server-side so it stops
    // receiving pushes once logged out. Never blocks logout itself.
    try {
      await apiClient.putAuthed('/api/v1/devices/fcm-token', {'token': ''});
    } catch (_) {}
    await storage.clearTokens();
    tenantId = null;
    displayName = null;
    permissions = [];
    status = AuthStatus.loggedOut;
    notifyListeners();
  }
}
