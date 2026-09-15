import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;

import 'api_client.dart';

class PairingCodeResult {
  final String code;
  final DateTime expiresAt;

  PairingCodeResult({required this.code, required this.expiresAt});

  factory PairingCodeResult.fromJson(Map<String, dynamic> json) {
    return PairingCodeResult(
      code: json['code'] as String,
      expiresAt: DateTime.parse(json['expires_at'] as String),
    );
  }
}

/// One registered device, for the device-management screen. Mirrors
/// services/api/internal/httpapi/device_handlers.go's List response.
class RegisteredDevice {
  final String id;
  final String displayName;
  final String platform;
  final String status; // PENDING, ACTIVE, REVOKED, DEACTIVATED
  final String securityState;
  final DateTime? lastSeenAt;
  final DateTime registeredAt;

  RegisteredDevice({
    required this.id,
    required this.displayName,
    required this.platform,
    required this.status,
    required this.securityState,
    required this.lastSeenAt,
    required this.registeredAt,
  });

  factory RegisteredDevice.fromJson(Map<String, dynamic> json) {
    return RegisteredDevice(
      id: json['id'] as String,
      displayName: json['display_name'] as String,
      platform: json['platform'] as String,
      status: json['status'] as String,
      securityState: json['security_state'] as String,
      lastSeenAt: json['last_seen_at'] == null ? null : DateTime.parse(json['last_seen_at'] as String),
      registeredAt: DateTime.parse(json['registered_at'] as String),
    );
  }
}

/// Wraps the device-pairing endpoints (services/api/internal/domain/
/// devicepairing): an already-paired device with device.manage generates a
/// short-lived code, and a brand-new device redeems it to register itself —
/// the sanctioned self-service alternative to an administrator manually
/// inserting a devices row.
class DeviceApi {
  final ApiClient client;

  DeviceApi(this.client);

  Future<PairingCodeResult> generatePairingCode() async {
    final response = await client.postAuthed('/api/v1/devices/pairing-codes', {});
    return PairingCodeResult.fromJson(response);
  }

  Future<void> registerDevice({required String code, required String deviceUuid, required String displayName}) async {
    await client.postUnauthed('/api/v1/devices/register', {
      'code': code,
      'device_uuid': deviceUuid,
      'display_name': displayName,
      'platform': _platformName(),
    });
  }

  Future<List<RegisteredDevice>> list({String query = ''}) async {
    final path = query.isEmpty
        ? '/api/v1/devices'
        : '/api/v1/devices?q=${Uri.encodeQueryComponent(query)}';
    final response = await client.getAuthed(path);
    return (response['devices'] as List<dynamic>)
        .map((d) => RegisteredDevice.fromJson(d as Map<String, dynamic>))
        .toList();
  }

  /// Locks a device out immediately — flips its status to REVOKED and
  /// invalidates every one of its still-valid refresh tokens server-side
  /// (see devicepairing.Service.RevokeDevice). Use when a device is lost or
  /// stolen.
  Future<void> revoke(String deviceId, {String? reason}) async {
    await client.postAuthed('/api/v1/devices/$deviceId/revoke', {
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    });
  }

  // Must match the devices.platform CHECK constraint exactly
  // (db/migrations/0002_identity_rbac.up.sql): 'ANDROID', 'IOS', 'WEB', or
  // 'OTHER' — there is no 'WINDOWS' value, so a Windows desktop client (an
  // always-connected back-office role, not a distinct platform the backend
  // tracks separately) registers as 'OTHER'.
  String _platformName() {
    if (kIsWeb) return 'WEB';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'ANDROID';
      case TargetPlatform.iOS:
        return 'IOS';
      default:
        return 'OTHER';
    }
  }
}
