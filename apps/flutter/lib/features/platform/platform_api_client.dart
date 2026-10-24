import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_error.dart';
import '../../core/secure_storage.dart';

enum PlatformAuthStatus { unknown, loggedOut, loggedIn }

/// A small, self-contained HTTP client for the platform-admin control plane
/// — deliberately NOT the tenant [ApiClient]'s token pair, since a platform
/// admin session has no tenant_id and no device at all (see
/// services/api/internal/domain/platformadmin's doc comment). It does,
/// however, persist its own refresh token via the same [KeyValueStore]
/// abstraction the tenant side uses (under a separate key, never mixed
/// with tenant tokens) — this app turned out to be used routinely, not
/// rarely as first assumed, so losing the session on every browser
/// refresh/reload was a real usability bug, not an acceptable trade.
class PlatformApiClient extends ChangeNotifier {
  final String baseUrl;
  final http.Client _http;
  final KeyValueStore _store;
  String? _accessToken;
  String? _refreshToken;
  String? displayName;
  PlatformAuthStatus status = PlatformAuthStatus.unknown;

  static const _keyRefreshToken = 'platform_refresh_token';

  PlatformApiClient({required this.baseUrl, http.Client? httpClient, KeyValueStore? store})
      : _http = httpClient ?? http.Client(),
        _store = store ?? PlatformSecureKeyValueStore();

  bool get isLoggedIn => _accessToken != null;

  /// Test-only: seeds an already-authenticated session without going
  /// through a real login call, for widget tests that exercise a screen
  /// reachable only after login (tenant list/detail, audit/error logs).
  /// Never call this from production code.
  void seedTokensForTesting({required String accessToken, required String refreshToken}) {
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    status = PlatformAuthStatus.loggedIn;
    notifyListeners();
  }

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  /// Called once at app startup (see main.dart's `_SessionGate`), mirroring
  /// the tenant `AuthSession.restoreSession()`: exchanges a persisted
  /// refresh token for a fresh access token rather than trusting anything
  /// stale, so `displayName` is always correct after a restore. No
  /// persisted token, or an expired/invalid one, both just mean a normal
  /// logged-out start — never an error shown to the admin.
  Future<void> restoreSession() async {
    final refreshToken = await _store.read(_keyRefreshToken);
    if (refreshToken == null) {
      status = PlatformAuthStatus.loggedOut;
      notifyListeners();
      return;
    }
    _refreshToken = refreshToken;
    final refreshed = await _tryRefresh();
    status = refreshed != null ? PlatformAuthStatus.loggedIn : PlatformAuthStatus.loggedOut;
    notifyListeners();
  }

  Future<void> login(String username, String password) async {
    final response = await _http.post(
      _uri('/api/v1/platform/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );
    final body = _decodeOrThrow(response);
    _accessToken = body['access_token'] as String;
    _refreshToken = body['refresh_token'] as String;
    displayName = body['display_name'] as String?;
    status = PlatformAuthStatus.loggedIn;
    await _store.write(_keyRefreshToken, _refreshToken!);
    notifyListeners();
  }

  Future<void> logout() async {
    final refreshToken = _refreshToken;
    _accessToken = null;
    _refreshToken = null;
    displayName = null;
    status = PlatformAuthStatus.loggedOut;
    await _store.delete(_keyRefreshToken);
    notifyListeners();
    if (refreshToken != null) {
      try {
        await _http.post(
          _uri('/api/v1/platform/auth/logout'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'refresh_token': refreshToken}),
        );
      } catch (_) {
        // Best-effort — the local session is already cleared either way.
      }
    }
  }

  Future<Map<String, dynamic>> getAuthed(String path) => _withAuthRetry((t) => _http.get(_uri(path), headers: _headers(t)));

  Future<Map<String, dynamic>> postAuthed(String path, Map<String, dynamic> body) =>
      _withAuthRetry((t) => _http.post(_uri(path), headers: _headers(t), body: jsonEncode(body)));

  Future<Map<String, dynamic>> putAuthed(String path, Map<String, dynamic> body) =>
      _withAuthRetry((t) => _http.put(_uri(path), headers: _headers(t), body: jsonEncode(body)));

  Map<String, String> _headers(String token) => {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'};

  Future<Map<String, dynamic>> _withAuthRetry(Future<http.Response> Function(String accessToken) request) async {
    final token = _accessToken;
    if (token == null) {
      throw ApiError(code: 'UNAUTHENTICATED', message: 'Not logged in', statusCode: 401);
    }
    var response = await _send(request, token);
    if (response.statusCode == 401) {
      final refreshed = await _tryRefresh();
      if (refreshed != null) {
        response = await _send(request, refreshed);
      }
    }
    return _decodeOrThrow(response);
  }

  Future<http.Response> _send(Future<http.Response> Function(String) request, String token) async {
    try {
      return await request(token);
    } on Exception catch (e) {
      throw ApiError.network(e.toString());
    }
  }

  Future<String?> _tryRefresh() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null) return null;
    try {
      final response = await _http.post(
        _uri('/api/v1/platform/auth/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': refreshToken}),
      );
      final body = _decodeOrThrow(response);
      _accessToken = body['access_token'] as String;
      _refreshToken = body['refresh_token'] as String;
      displayName = body['display_name'] as String? ?? displayName;
      await _store.write(_keyRefreshToken, _refreshToken!);
      return _accessToken;
    } on ApiError {
      _accessToken = null;
      _refreshToken = null;
      displayName = null;
      status = PlatformAuthStatus.loggedOut;
      await _store.delete(_keyRefreshToken);
      notifyListeners();
      return null;
    }
  }

  Map<String, dynamic> _decodeOrThrow(http.Response response) {
    Map<String, dynamic> body;
    try {
      body = response.body.isEmpty ? {} : jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      body = {};
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return body;
    }
    throw ApiError.fromJson(body, response.statusCode);
  }
}
