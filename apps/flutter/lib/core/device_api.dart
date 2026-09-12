import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

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

  String _platformName() {
    if (kIsWeb) return 'WEB';
    if (Platform.isAndroid) return 'ANDROID';
    if (Platform.isIOS) return 'IOS';
    if (Platform.isWindows) return 'WINDOWS';
    return 'OTHER';
  }
}
