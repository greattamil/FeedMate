import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'api_error.dart';
import 'firebase_options_web.dart';
import 'push_diagnostics.dart';
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

  /// Clears a stale error left over from a prior failed login attempt — the
  /// login screen calls this after the device-pairing flow succeeds so a
  /// "device not registered" message doesn't keep showing once it no longer
  /// applies, without the user having to retry the login form first.
  void clearError() {
    if (lastError == null) return;
    lastError = null;
    notifyListeners();
  }

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

  /// Best-effort — a device with push notifications unavailable (Windows, a
  /// permission denial, or any FCM/plugin error) must still be able to log
  /// in and use the app normally. Fire-and-forget: this never blocks or
  /// fails the login/restore flow that calls it, and every failure is
  /// swallowed rather than surfaced, since push is a nice-to-have
  /// (internal/domain/notify's event pushes), not core functionality.
  /// Runs on Android and web — the two platforms with a registered
  /// Firebase app (see core/firebase_options_web.dart) — and skips
  /// Windows, which has none.
  StreamSubscription<String>? _tokenRefreshSubscription;

  Future<void> _registerPushToken() async {
    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.requestPermission();
      // Denied/not-determined must not fall through to getToken(): on web
      // specifically, calling it without permission has been observed to
      // resolve with an empty string rather than null or a thrown error —
      // silently "succeeding" with a token that isn't actually usable, and
      // overwriting any previously-good token server-side with garbage.
      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional) {
        PushDiagnostics.report(
          'Notification permission not granted',
          'browser/OS reported "${settings.authorizationStatus}" — notifications will not work until this is allowed for this site',
        );
        return;
      }
      final token = await messaging.getToken(vapidKey: kIsWeb ? webVapidKey : null);
      if (token != null && token.isNotEmpty) {
        await apiClient.putAuthed('/api/v1/devices/fcm-token', {'token': token});
      } else {
        PushDiagnostics.report('Push token registration', 'getToken() returned no usable token (null or empty)');
      }
      // FCM can rotate a device's token at any time (app reinstall, data
      // clear, internal token-rotation policy) — without this, a device
      // that rotates mid-session would silently stop receiving pushes
      // until its next login/restoreSession. Subscribed at most once per
      // process: login() and restoreSession() can both call
      // _registerPushToken() in the same run, and a second listen on the
      // same broadcast-less stream would otherwise stack subscriptions.
      _tokenRefreshSubscription ??= messaging.onTokenRefresh.listen((newToken) {
        apiClient.putAuthed('/api/v1/devices/fcm-token', {'token': newToken}).catchError((_) => <String, dynamic>{});
      });
    } catch (e) {
      // Never rethrown/blocks login — see doc comment above — but reported
      // so it's at least visible on-screen instead of silently invisible.
      PushDiagnostics.report('Push registration failed', e);
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
