import 'platform_api_client.dart';

class TenantSummary {
  final String id;
  final String legalName;
  final String? tradeName;
  final String city;
  final String status;
  final String planCode;
  final DateTime? planExpiresAt;
  final int userCount;
  final DateTime createdAt;

  TenantSummary({
    required this.id,
    required this.legalName,
    this.tradeName,
    required this.city,
    required this.status,
    required this.planCode,
    this.planExpiresAt,
    required this.userCount,
    required this.createdAt,
  });

  factory TenantSummary.fromJson(Map<String, dynamic> json) {
    return TenantSummary(
      id: json['id'] as String,
      legalName: json['legal_name'] as String,
      tradeName: json['trade_name'] as String?,
      city: json['city'] as String,
      status: json['status'] as String,
      planCode: json['plan_code'] as String,
      planExpiresAt: json['plan_expires_at'] == null ? null : DateTime.parse(json['plan_expires_at'] as String),
      userCount: json['user_count'] as int,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

class TenantDetail extends TenantSummary {
  final String addressLine1;
  final String stateCode;
  final String? phone;
  final String? email;
  final String? appDisplayName;
  final String? logoUrl;
  final String? primaryColor;
  final Map<String, bool> features;

  TenantDetail({
    required super.id,
    required super.legalName,
    super.tradeName,
    required super.city,
    required super.status,
    required super.planCode,
    super.planExpiresAt,
    required super.userCount,
    required super.createdAt,
    required this.addressLine1,
    required this.stateCode,
    this.phone,
    this.email,
    this.appDisplayName,
    this.logoUrl,
    this.primaryColor,
    required this.features,
  });

  factory TenantDetail.fromJson(Map<String, dynamic> json) {
    final summary = TenantSummary.fromJson(json);
    return TenantDetail(
      id: summary.id,
      legalName: summary.legalName,
      tradeName: summary.tradeName,
      city: summary.city,
      status: summary.status,
      planCode: summary.planCode,
      planExpiresAt: summary.planExpiresAt,
      userCount: summary.userCount,
      createdAt: summary.createdAt,
      addressLine1: json['address_line1'] as String,
      stateCode: json['state_code'] as String,
      phone: json['phone'] as String?,
      email: json['email'] as String?,
      appDisplayName: json['app_display_name'] as String?,
      logoUrl: json['logo_url'] as String?,
      primaryColor: json['primary_color'] as String?,
      features: (json['features'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, v as bool)),
    );
  }
}

class PlatformAuditLogEntry {
  final String id;
  final String? tenantId;
  final String? tenantName;
  final String? actorName;
  final String actionCode;
  final String entityType;
  final String? entityId;
  final String? reason;
  final DateTime createdAt;

  PlatformAuditLogEntry({
    required this.id,
    this.tenantId,
    this.tenantName,
    this.actorName,
    required this.actionCode,
    required this.entityType,
    this.entityId,
    this.reason,
    required this.createdAt,
  });

  factory PlatformAuditLogEntry.fromJson(Map<String, dynamic> json) {
    return PlatformAuditLogEntry(
      id: json['id'] as String,
      tenantId: json['tenant_id'] as String?,
      tenantName: json['tenant_name'] as String?,
      actorName: json['actor_name'] as String?,
      actionCode: json['action_code'] as String,
      entityType: json['entity_type'] as String,
      entityId: json['entity_id'] as String?,
      reason: json['reason'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

class PlatformErrorLogEntry {
  final String id;
  final String? requestId;
  final int statusCode;
  final String message;
  final DateTime createdAt;

  PlatformErrorLogEntry({
    required this.id,
    this.requestId,
    required this.statusCode,
    required this.message,
    required this.createdAt,
  });

  factory PlatformErrorLogEntry.fromJson(Map<String, dynamic> json) {
    return PlatformErrorLogEntry(
      id: json['id'] as String,
      requestId: json['request_id'] as String?,
      statusCode: json['status_code'] as int,
      message: json['message'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

/// Wraps every platform-admin endpoint (services/api/internal/httpapi
/// /platform_handlers.go). All business logic (bootstrap sequencing,
/// suspension enforcement) lives server-side — this only shapes requests.
class PlatformApi {
  final PlatformApiClient client;

  PlatformApi(this.client);

  Future<List<TenantSummary>> listTenants() async {
    final response = await client.getAuthed('/api/v1/platform/tenants');
    return (response['tenants'] as List<dynamic>).map((t) => TenantSummary.fromJson(t as Map<String, dynamic>)).toList();
  }

  Future<TenantDetail> getTenant(String id) async {
    final response = await client.getAuthed('/api/v1/platform/tenants/$id');
    return TenantDetail.fromJson(response);
  }

  Future<String> createTenant({
    required String legalName,
    String? tradeName,
    required String addressLine1,
    required String city,
    required String stateCode,
    String? phone,
    String? email,
    String? planCode,
    required String ownerUsername,
    required String ownerPassword,
    required String ownerName,
  }) async {
    final response = await client.postAuthed('/api/v1/platform/tenants', {
      'legal_name': legalName,
      if (tradeName != null && tradeName.isNotEmpty) 'trade_name': tradeName,
      'address_line1': addressLine1,
      'city': city,
      'state_code': stateCode,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (email != null && email.isNotEmpty) 'email': email,
      if (planCode != null && planCode.isNotEmpty) 'plan_code': planCode,
      'owner_username': ownerUsername,
      'owner_password': ownerPassword,
      'owner_name': ownerName,
    });
    return response['tenant_id'] as String;
  }

  Future<void> setTenantStatus(String id, String status) async {
    await client.postAuthed('/api/v1/platform/tenants/$id/status', {'status': status});
  }

  Future<void> setTenantPlan(String id, String planCode, DateTime? expiresAt) async {
    await client.putAuthed('/api/v1/platform/tenants/$id/plan', {
      'plan_code': planCode,
      if (expiresAt != null) 'plan_expires_at': expiresAt.toUtc().toIso8601String(),
    });
  }

  Future<void> setTenantBranding(String id, {String? appDisplayName, String? logoUrl, String? primaryColor}) async {
    await client.putAuthed('/api/v1/platform/tenants/$id/branding', {
      if (appDisplayName != null) 'app_display_name': appDisplayName,
      if (logoUrl != null) 'logo_url': logoUrl,
      if (primaryColor != null) 'primary_color': primaryColor,
    });
  }

  Future<void> setTenantFeature(String id, String featureCode, bool enabled) async {
    await client.putAuthed('/api/v1/platform/tenants/$id/features', {'feature_code': featureCode, 'enabled': enabled});
  }

  Future<List<PlatformAuditLogEntry>> listAuditLogs({int limit = 50, int offset = 0}) async {
    final response = await client.getAuthed('/api/v1/platform/audit-logs?limit=$limit&offset=$offset');
    return (response['entries'] as List<dynamic>).map((e) => PlatformAuditLogEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<PlatformErrorLogEntry>> listErrorLogs({int limit = 50, int offset = 0}) async {
    final response = await client.getAuthed('/api/v1/platform/error-logs?limit=$limit&offset=$offset');
    return (response['entries'] as List<dynamic>).map((e) => PlatformErrorLogEntry.fromJson(e as Map<String, dynamic>)).toList();
  }
}
