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

  Future<void> restoreSession() async {
    final token = await storage.getAccessToken();
    final tenant = await storage.getTenantId();
    if (token != null && tenant != null) {
      tenantId = tenant;
      status = AuthStatus.loggedIn;
    } else {
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
      return true;
    } on ApiError catch (e) {
      lastError = e.message;
      status = AuthStatus.loggedOut;
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    await storage.clearTokens();
    tenantId = null;
    displayName = null;
    permissions = [];
    status = AuthStatus.loggedOut;
    notifyListeners();
  }
}
