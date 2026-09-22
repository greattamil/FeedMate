import 'dart:convert';
import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'secure_storage.dart';

/// Thin HTTP client for the Andipatti Animal Feed System Go backend. It owns
/// token attachment and refresh-on-401 retry; it does not implement any
/// business logic or offline queuing — the server is always the authority
/// (see PRD A28: "the server is authoritative for finalized invoices,
/// payments, inventory, accounting, customer ledger, tax, compliance state").
///
/// baseUrl defaults to the Android emulator's host-loopback alias
/// (10.0.2.2), which is how an emulator reaches a server running on the
/// host machine's localhost; pass a different baseUrl for physical devices,
/// Windows desktop (use 127.0.0.1), or a real deployment.
class ApiClient {
  final String baseUrl;
  final SecureStorage storage;
  final http.Client _http;

  ApiClient({required this.baseUrl, required this.storage, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, dynamic>> login({
    required String deviceUuid,
    required String username,
    required String password,
  }) async {
    final response = await _http.post(
      _uri('/api/v1/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'device_uuid': deviceUuid,
        'username': username,
        'password': password,
      }),
    );
    return _decodeOrThrow(response);
  }

  /// For endpoints that must work before any login has happened (e.g. device
  /// registration via a pairing code — see PosApi/DeviceApi) — there is no
  /// access token to attach yet.
  Future<Map<String, dynamic>> postUnauthed(String path, Map<String, dynamic> body) async {
    final response = await _send(
      (_) => _http.post(_uri(path), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body)),
      '',
    );
    return _decodeOrThrow(response);
  }

  /// Same as [postUnauthed] but for a GET — e.g. resolving branding (app
  /// name/logo/color) on the login screen, before any token exists.
  Future<Map<String, dynamic>> getUnauthed(String path) async {
    final response = await _send((_) => _http.get(_uri(path)), '');
    return _decodeOrThrow(response);
  }

  Future<Map<String, dynamic>> refresh({
    required String tenantId,
    required String refreshToken,
  }) async {
    final response = await _http.post(
      _uri('/api/v1/auth/refresh'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'tenant_id': tenantId, 'refresh_token': refreshToken}),
    );
    return _decodeOrThrow(response);
  }

  /// Performs an authenticated GET, transparently retrying once after a
  /// token refresh if the access token has expired (401). Never retries
  /// silently more than once — a second 401 is surfaced to the caller so the
  /// app can force a fresh login rather than looping forever.
  Future<Map<String, dynamic>> getAuthed(String path) async {
    return _withAuthRetry((token) => _http.get(_uri(path), headers: _authHeaders(token)));
  }

  Future<Map<String, dynamic>> postAuthed(String path, Map<String, dynamic> body) async {
    return _withAuthRetry((token) => _http.post(
          _uri(path),
          headers: _authHeaders(token),
          body: jsonEncode(body),
        ));
  }

  Future<Map<String, dynamic>> putAuthed(String path, Map<String, dynamic> body) async {
    return _withAuthRetry((token) => _http.put(
          _uri(path),
          headers: _authHeaders(token),
          body: jsonEncode(body),
        ));
  }

  Map<String, String> _authHeaders(String token) => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> _withAuthRetry(
    Future<http.Response> Function(String accessToken) request,
  ) async {
    var token = await storage.getAccessToken();
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

  Future<http.Response> _send(
    Future<http.Response> Function(String accessToken) request,
    String token,
  ) async {
    try {
      return await request(token);
    } on Exception catch (e) {
      throw ApiError.network(e.toString());
    }
  }

  Future<String?> _tryRefresh() async {
    final tenantId = await storage.getTenantId();
    final refreshToken = await storage.getRefreshToken();
    if (tenantId == null || refreshToken == null) return null;
    try {
      final result = await refresh(tenantId: tenantId, refreshToken: refreshToken);
      final newAccess = result['access_token'] as String;
      final newRefresh = result['refresh_token'] as String;
      await storage.saveTokens(accessToken: newAccess, refreshToken: newRefresh, tenantId: tenantId);
      return newAccess;
    } on ApiError {
      // Refresh token itself is invalid/expired — caller must re-authenticate.
      await storage.clearTokens();
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

  void close() => _http.close();
}
