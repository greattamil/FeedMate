import 'package:flutter/material.dart';

import 'api_client.dart';
import 'secure_storage.dart';

/// The single source of truth for the app's displayed name/tagline/logo/
/// color — resolved from GET /api/v1/branding (see
/// services/api/internal/domain/platformadmin.Service.ResolveBranding),
/// never hardcoded into widget source. A tenant's own whitelabel override
/// (set by a platform admin) wins field-by-field over the platform-wide
/// default; an unrecognized/absent device falls back to the platform
/// default too — there is always something sane to show, but it always
/// comes from the server, never a compile-time literal.
///
/// [fallbackAppName]/[fallbackTagline] are shown only for the brief instant
/// before the first successful fetch resolves (or if the device is fully
/// offline on first-ever launch with nothing cached yet) — they are a
/// loading placeholder, not the source of truth.
class BrandingProvider extends ChangeNotifier {
  final ApiClient client;
  final SecureStorage storage;

  String appName;
  String appTagline;
  String? logoUrl;
  String? primaryColor;
  bool _loaded = false;

  BrandingProvider({
    required this.client,
    required this.storage,
    String fallbackAppName = 'FeedMate',
    String fallbackTagline = 'Multi-Tenant Retail & Wholesale POS',
  })  : appName = fallbackAppName,
        appTagline = fallbackTagline;

  bool get isLoaded => _loaded;

  Color? get primaryColorValue {
    final hex = primaryColor;
    if (hex == null || hex.isEmpty) return null;
    final cleaned = hex.replaceFirst('#', '');
    final value = int.tryParse(cleaned, radix: 16);
    if (value == null) return null;
    return Color(0xFF000000 | value);
  }

  /// Fetches the effective branding for this device — call once at app
  /// startup, and again right after a tenant logs in (their own override,
  /// if freshly set by a platform admin, should show up without requiring
  /// an app restart).
  Future<void> refresh() async {
    try {
      final deviceUuid = await storage.getOrCreateDeviceUuid();
      final response = await client.getUnauthed('/api/v1/branding?device_uuid=$deviceUuid');
      appName = response['app_name'] as String? ?? appName;
      appTagline = response['app_tagline'] as String? ?? appTagline;
      logoUrl = response['logo_url'] as String?;
      primaryColor = response['primary_color'] as String?;
      _loaded = true;
      notifyListeners();
    } catch (_) {
      // Offline or the server is unreachable — keep whatever we last had
      // (the constructor fallback, or a previous successful fetch this
      // session). Never block the login screen from rendering on this.
    }
  }
}
