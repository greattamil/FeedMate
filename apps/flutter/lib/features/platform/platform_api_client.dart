import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/api_error.dart';

/// A small, self-contained HTTP client for the platform-admin control plane
/// — deliberately NOT the tenant [ApiClient]/[SecureStorage] pair, since a
/// platform admin session has no tenant_id and no device at all (see
/// services/api/internal/domain/platformadmin's doc comment). Tokens live
/// only in memory: this app is used rarely, by the developer/operator, not
/// a shop's day-to-day staff, so requiring a fresh login after the process
/// restarts is an acceptable trade for not adding a second persisted-token
/// scheme alongside the tenant one.
class PlatformApiClient extends ChangeNotifier {
  final String baseUrl;
  final http.Client _http;
  String? _accessToken;
  String? _refreshToken;
  String? displayName;

  PlatformApiClient({required this.baseUrl, http.Client? httpClient}) : _http = httpClient ?? http.Client();

  bool get isLoggedIn => _accessToken != null;

  /// Test-only: seeds an already-authenticated session without going
  /// through a real login call, for widget tests that exercise a screen
  /// reachable only after login (tenant list/detail, audit/error logs).
  /// Never call this from production code.
  void seedTokensForTesting({required String accessToken, required String refreshToken}) {
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    notifyListeners();
  }

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

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
    notifyListeners();
  }

  Future<void> logout() async {
    final refreshToken = _refreshToken;
    _accessToken = null;
    _refreshToken = null;
    displayName = null;
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
      return _accessToken;
    } on ApiError {
      _accessToken = null;
      _refreshToken = null;
      displayName = null;
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
