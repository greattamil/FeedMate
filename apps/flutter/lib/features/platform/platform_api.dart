import 'package:decimal/decimal.dart';
import 'package:uuid/uuid.dart';

import '../../core/api_error.dart';
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
  final String? gstin;
  final String? fssaiLicenseNo;
  final String addressLine1;
  final String? addressLine2;
  final String? district;
  final String stateCode;
  final String? postalCode;
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
    this.gstin,
    this.fssaiLicenseNo,
    required this.addressLine1,
    this.addressLine2,
    this.district,
    required this.stateCode,
    this.postalCode,
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
      gstin: json['gstin'] as String?,
      fssaiLicenseNo: json['fssai_license_no'] as String?,
      addressLine1: json['address_line1'] as String,
      addressLine2: json['address_line2'] as String?,
      district: json['district'] as String?,
      stateCode: json['state_code'] as String,
      postalCode: json['postal_code'] as String?,
      phone: json['phone'] as String?,
      email: json['email'] as String?,
      appDisplayName: json['app_display_name'] as String?,
      logoUrl: json['logo_url'] as String?,
      primaryColor: json['primary_color'] as String?,
      features: (json['features'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, v as bool)),
    );
  }
}

/// A staff account inside one tenant, as seen by a platform admin — the
/// same shape the tenant's own staff directory sees (see StaffSummary in
/// features/staff/staff_api.dart), just reached through the platform-admin
/// control plane instead of a logged-in tenant session.
class PlatformTenantUser {
  final String id;
  final String username;
  final String displayName;
  final String? phone;
  final String? email;
  final String status;
  final DateTime? lastLoginAt;

  PlatformTenantUser({
    required this.id,
    required this.username,
    required this.displayName,
    this.phone,
    this.email,
    required this.status,
    this.lastLoginAt,
  });

  factory PlatformTenantUser.fromJson(Map<String, dynamic> json) {
    return PlatformTenantUser(
      id: json['id'] as String,
      username: json['username'] as String,
      displayName: json['display_name'] as String,
      phone: json['phone'] as String?,
      email: json['email'] as String?,
      status: json['status'] as String,
      lastLoginAt: json['last_login_at'] == null ? null : DateTime.parse(json['last_login_at'] as String),
    );
  }
}

class PlatformTenantUserDetail extends PlatformTenantUser {
  final List<String> roleIds;

  PlatformTenantUserDetail({
    required super.id,
    required super.username,
    required super.displayName,
    super.phone,
    super.email,
    required super.status,
    super.lastLoginAt,
    required this.roleIds,
  });

  factory PlatformTenantUserDetail.fromJson(Map<String, dynamic> json) {
    final user = PlatformTenantUser.fromJson(json);
    return PlatformTenantUserDetail(
      id: user.id,
      username: user.username,
      displayName: user.displayName,
      phone: user.phone,
      email: user.email,
      status: user.status,
      lastLoginAt: user.lastLoginAt,
      roleIds: (json['role_ids'] as List<dynamic>? ?? []).cast<String>(),
    );
  }
}

/// A role a tenant user can be assigned — same shape as the tenant-side
/// Role (features/staff/staff_api.dart), surfaced here because a platform
/// admin's role picker calls the platform-scoped roles endpoint instead.
class PlatformRole {
  final String id;
  final String name;
  final String? description;
  final bool isSystemRole;

  PlatformRole({required this.id, required this.name, this.description, required this.isSystemRole});

  factory PlatformRole.fromJson(Map<String, dynamic> json) {
    return PlatformRole(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      isSystemRole: json['is_system_role'] as bool? ?? false,
    );
  }
}

/// A device registered to a tenant, as seen by a platform admin — same
/// shape as the tenant-side RegisteredDevice (core/device_api.dart).
class PlatformDevice {
  final String id;
  final String deviceUuid;
  final String displayName;
  final String platform;
  final String status;
  final String securityState;
  final DateTime registeredAt;
  final DateTime? lastSeenAt;

  PlatformDevice({
    required this.id,
    required this.deviceUuid,
    required this.displayName,
    required this.platform,
    required this.status,
    required this.securityState,
    required this.registeredAt,
    this.lastSeenAt,
  });

  factory PlatformDevice.fromJson(Map<String, dynamic> json) {
    return PlatformDevice(
      id: json['id'] as String,
      deviceUuid: json['device_uuid'] as String,
      displayName: json['display_name'] as String,
      platform: json['platform'] as String,
      status: json['status'] as String,
      securityState: json['security_state'] as String,
      registeredAt: DateTime.parse(json['registered_at'] as String),
      lastSeenAt: json['last_seen_at'] == null ? null : DateTime.parse(json['last_seen_at'] as String),
    );
  }
}

/// A freshly generated device-pairing code — a one-time bearer credential
/// valid for exactly 10 minutes, shown once and never persisted (mirrors
/// the tenant-side PairingCodeResult in core/device_api.dart).
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

/// One row of the platform-wide audit trail
/// (platformadmin.Service.ListAuditLogsAllTenants) — now carrying full
/// before/after state, actor identity (tenant staff OR platform admin, at
/// most one of each pair is ever present) and request provenance, not just
/// the bare action/entity/reason the old thin DTO exposed.
class PlatformAuditLogEntry {
  final String id;
  final String actionCode;
  final String entityType;
  final DateTime createdAt;
  final String? tenantId;
  final String? tenantName;
  final String? actorUserId;
  final String? actorName;
  final String? actorDeviceId;
  final String? actorPlatformAdminId;
  final String? actorPlatformAdminName;
  final String? entityId;
  final Map<String, dynamic>? beforeJson;
  final Map<String, dynamic>? afterJson;
  final String? reason;
  final String? requestId;
  final String? ipAddress;
  final String? userAgent;

  PlatformAuditLogEntry({
    required this.id,
    required this.actionCode,
    required this.entityType,
    required this.createdAt,
    this.tenantId,
    this.tenantName,
    this.actorUserId,
    this.actorName,
    this.actorDeviceId,
    this.actorPlatformAdminId,
    this.actorPlatformAdminName,
    this.entityId,
    this.beforeJson,
    this.afterJson,
    this.reason,
    this.requestId,
    this.ipAddress,
    this.userAgent,
  });

  /// "Who did this" for display: a tenant staff member's name if one acted,
  /// else the platform admin's name if one acted, else "System" for a
  /// server-initiated action (e.g. an automated auto-suspend job).
  String get displayActor => actorName ?? actorPlatformAdminName ?? 'System';

  factory PlatformAuditLogEntry.fromJson(Map<String, dynamic> json) {
    return PlatformAuditLogEntry(
      id: json['id'] as String,
      actionCode: json['action_code'] as String,
      entityType: json['entity_type'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      tenantId: json['tenant_id'] as String?,
      tenantName: json['tenant_name'] as String?,
      actorUserId: json['actor_user_id'] as String?,
      actorName: json['actor_name'] as String?,
      actorDeviceId: json['actor_device_id'] as String?,
      actorPlatformAdminId: json['actor_platform_admin_id'] as String?,
      actorPlatformAdminName: json['actor_platform_admin_name'] as String?,
      entityId: json['entity_id'] as String?,
      beforeJson: json['before_json'] as Map<String, dynamic>?,
      afterJson: json['after_json'] as Map<String, dynamic>?,
      reason: json['reason'] as String?,
      requestId: json['request_id'] as String?,
      ipAddress: json['ip_address'] as String?,
      userAgent: json['user_agent'] as String?,
    );
  }
}

/// One row of the platform-wide error log (httpapi.SetErrorSink) — now
/// capturing genuinely complete debug-level detail for EVERY error (not
/// just 500s): the request that triggered it, the already-redacted request
/// body, caller identity/network provenance, and — only for a recovered
/// panic — a stack trace.
class PlatformErrorLogEntry {
  final String id;
  final int statusCode;
  final String message;
  final DateTime createdAt;
  final String? requestId;
  final String? code;
  final String? method;
  final String? path;
  final String? queryParams;
  final Map<String, dynamic>? requestBody;
  final String? ipAddress;
  final String? userAgent;
  final String? tenantId;
  final String? actorUserId;
  final String? actorPlatformAdminId;
  final String? stackTrace;

  PlatformErrorLogEntry({
    required this.id,
    required this.statusCode,
    required this.message,
    required this.createdAt,
    this.requestId,
    this.code,
    this.method,
    this.path,
    this.queryParams,
    this.requestBody,
    this.ipAddress,
    this.userAgent,
    this.tenantId,
    this.actorUserId,
    this.actorPlatformAdminId,
    this.stackTrace,
  });

  factory PlatformErrorLogEntry.fromJson(Map<String, dynamic> json) {
    return PlatformErrorLogEntry(
      id: json['id'] as String,
      statusCode: json['status_code'] as int,
      message: json['message'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      requestId: json['request_id'] as String?,
      code: json['code'] as String?,
      method: json['method'] as String?,
      path: json['path'] as String?,
      queryParams: json['query_params'] as String?,
      requestBody: json['request_body'] as Map<String, dynamic>?,
      ipAddress: json['ip_address'] as String?,
      userAgent: json['user_agent'] as String?,
      tenantId: json['tenant_id'] as String?,
      actorUserId: json['actor_user_id'] as String?,
      actorPlatformAdminId: json['actor_platform_admin_id'] as String?,
      stackTrace: json['stack_trace'] as String?,
    );
  }
}

/// A row in the subscription-plan catalogue (services/api/internal/httpapi
/// /subscription_handlers.go) — price + grace period a tenant subscription
/// is billed and enforced against.
class SubscriptionPlan {
  final String id;
  final String code;
  final String name;
  final Decimal price;
  final String currencyCode;
  final String billingPeriod;
  final int gracePeriodDays;
  final bool active;

  SubscriptionPlan({
    required this.id,
    required this.code,
    required this.name,
    required this.price,
    required this.currencyCode,
    required this.billingPeriod,
    required this.gracePeriodDays,
    required this.active,
  });

  factory SubscriptionPlan.fromJson(Map<String, dynamic> json) {
    return SubscriptionPlan(
      id: json['id'] as String,
      code: json['code'] as String,
      name: json['name'] as String,
      price: Decimal.parse(json['price'] as String),
      currencyCode: json['currency_code'] as String,
      billingPeriod: json['billing_period'] as String,
      gracePeriodDays: json['grace_period_days'] as int,
      active: json['active'] as bool,
    );
  }
}

/// A tenant's current subscription — which plan, the active billing period,
/// and its ACTIVE/PAST_DUE/SUSPENDED/CANCELLED status. [getTenantSubscription]
/// returns null (not an error) when the tenant has no subscription assigned
/// yet, which is the normal state for any tenant created before this
/// feature shipped or never assigned a plan.
class TenantSubscription {
  final String id;
  final String tenantId;
  final String planId;
  final String planCode;
  final String planName;
  final Decimal planPrice;
  final String status;
  final DateTime currentPeriodStart;
  final DateTime currentPeriodEnd;
  final int effectiveGracePeriodDays;
  final int? gracePeriodDaysOverride;
  final DateTime? pastDueSince;

  TenantSubscription({
    required this.id,
    required this.tenantId,
    required this.planId,
    required this.planCode,
    required this.planName,
    required this.planPrice,
    required this.status,
    required this.currentPeriodStart,
    required this.currentPeriodEnd,
    required this.effectiveGracePeriodDays,
    this.gracePeriodDaysOverride,
    this.pastDueSince,
  });

  factory TenantSubscription.fromJson(Map<String, dynamic> json) {
    return TenantSubscription(
      id: json['id'] as String,
      tenantId: json['tenant_id'] as String,
      planId: json['plan_id'] as String,
      planCode: json['plan_code'] as String,
      planName: json['plan_name'] as String,
      planPrice: Decimal.parse(json['plan_price'] as String),
      status: json['status'] as String,
      currentPeriodStart: DateTime.parse(json['current_period_start'] as String),
      currentPeriodEnd: DateTime.parse(json['current_period_end'] as String),
      effectiveGracePeriodDays: json['effective_grace_period_days'] as int,
      gracePeriodDaysOverride: json['grace_period_days_override'] as int?,
      pastDueSince: json['past_due_since'] == null ? null : DateTime.parse(json['past_due_since'] as String),
    );
  }
}

/// A manually-recorded subscription payment — there is no payment gateway
/// here, the platform admin collects money out of band (UPI/bank/cash) and
/// just records that it happened.
class SubscriptionPayment {
  final String id;
  final Decimal amount;
  final DateTime periodStart;
  final DateTime periodEnd;
  final String method;
  final String? reference;
  final String? notes;
  final DateTime paidAt;

  SubscriptionPayment({
    required this.id,
    required this.amount,
    required this.periodStart,
    required this.periodEnd,
    required this.method,
    this.reference,
    this.notes,
    required this.paidAt,
  });

  factory SubscriptionPayment.fromJson(Map<String, dynamic> json) {
    return SubscriptionPayment(
      id: json['id'] as String,
      amount: Decimal.parse(json['amount'] as String),
      periodStart: DateTime.parse(json['period_start'] as String),
      periodEnd: DateTime.parse(json['period_end'] as String),
      method: json['method'] as String,
      reference: json['reference'] as String?,
      notes: json['notes'] as String?,
      paidAt: DateTime.parse(json['paid_at'] as String),
    );
  }
}

class RecordSubscriptionPaymentResult {
  final String paymentId;
  final bool duplicate;

  RecordSubscriptionPaymentResult({required this.paymentId, required this.duplicate});

  factory RecordSubscriptionPaymentResult.fromJson(Map<String, dynamic> json) {
    return RecordSubscriptionPaymentResult(
      paymentId: json['payment_id'] as String,
      duplicate: json['duplicate'] as bool? ?? false,
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

  Future<({List<PlatformAuditLogEntry> entries, int total})> listAuditLogs({
    int limit = 50,
    int offset = 0,
    String? actionCode,
    String? entityType,
    String? tenantId,
    DateTime? from,
    DateTime? to,
    String? q,
  }) async {
    final path = _query('/api/v1/platform/audit-logs', {
      'limit': '$limit',
      'offset': '$offset',
      if (actionCode != null && actionCode.isNotEmpty) 'action_code': actionCode,
      if (entityType != null && entityType.isNotEmpty) 'entity_type': entityType,
      if (tenantId != null && tenantId.isNotEmpty) 'tenant_id': tenantId,
      if (from != null) 'from': from.toUtc().toIso8601String(),
      if (to != null) 'to': to.toUtc().toIso8601String(),
      if (q != null && q.isNotEmpty) 'q': q,
    });
    final response = await client.getAuthed(path);
    final entries = (response['entries'] as List<dynamic>).map((e) => PlatformAuditLogEntry.fromJson(e as Map<String, dynamic>)).toList();
    return (entries: entries, total: response['total'] as int);
  }

  Future<({List<PlatformErrorLogEntry> entries, int total})> listErrorLogs({
    int limit = 50,
    int offset = 0,
    int? statusCode,
    String? code,
    String? method,
    DateTime? from,
    DateTime? to,
    String? q,
  }) async {
    final path = _query('/api/v1/platform/error-logs', {
      'limit': '$limit',
      'offset': '$offset',
      if (statusCode != null) 'status_code': '$statusCode',
      if (code != null && code.isNotEmpty) 'code': code,
      if (method != null && method.isNotEmpty) 'method': method,
      if (from != null) 'from': from.toUtc().toIso8601String(),
      if (to != null) 'to': to.toUtc().toIso8601String(),
      if (q != null && q.isNotEmpty) 'q': q,
    });
    final response = await client.getAuthed(path);
    final entries = (response['entries'] as List<dynamic>).map((e) => PlatformErrorLogEntry.fromJson(e as Map<String, dynamic>)).toList();
    return (entries: entries, total: response['total'] as int);
  }

  /// Builds `basePath?k=v&...` from only the non-null/non-empty params,
  /// percent-encoding each value — the straightforward way to build an
  /// optional-filter query string since no existing method in this file
  /// had more than one or two always-present params to interpolate.
  String _query(String basePath, Map<String, String> params) {
    if (params.isEmpty) return basePath;
    final queryString = params.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
    return '$basePath?$queryString';
  }

  Future<PlatformSettings> getPlatformSettings() async {
    final response = await client.getAuthed('/api/v1/platform/settings');
    return PlatformSettings.fromJson(response);
  }

  Future<void> updatePlatformSettings({
    required String appName,
    required String appTagline,
    String? logoUrl,
    String? primaryColor,
  }) async {
    await client.putAuthed('/api/v1/platform/settings', {
      'app_name': appName,
      'app_tagline': appTagline,
      if (logoUrl != null) 'logo_url': logoUrl,
      if (primaryColor != null) 'primary_color': primaryColor,
    });
  }

  /// Full tenant profile edit — legal/trade name, tax registrations,
  /// address, and contact details. This is the fix for the owner having to
  /// hand-write SQL to correct a tenant's GSTIN or address: everything a
  /// tenant's own Owner can't touch about their own registration record.
  Future<void> updateTenant(
    String id, {
    required String legalName,
    String? tradeName,
    String? gstin,
    String? fssaiLicenseNo,
    required String addressLine1,
    String? addressLine2,
    required String city,
    String? district,
    required String stateCode,
    String? postalCode,
    String? phone,
    String? email,
  }) async {
    await client.putAuthed('/api/v1/platform/tenants/$id', {
      'legal_name': legalName,
      if (tradeName != null) 'trade_name': tradeName,
      if (gstin != null) 'gstin': gstin,
      if (fssaiLicenseNo != null) 'fssai_license_no': fssaiLicenseNo,
      'address_line1': addressLine1,
      if (addressLine2 != null) 'address_line2': addressLine2,
      'city': city,
      if (district != null) 'district': district,
      'state_code': stateCode,
      if (postalCode != null) 'postal_code': postalCode,
      if (phone != null) 'phone': phone,
      if (email != null) 'email': email,
    });
  }

  /// Lists a tenant's own staff accounts — the first step in the owner
  /// lockout fix: a platform admin can now see who exists before resetting
  /// a password or flipping a status, instead of guessing at the DB.
  Future<({List<PlatformTenantUser> users, int total})> listTenantUsers(
    String id, {
    String query = '',
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await client.getAuthed(
      '/api/v1/platform/tenants/$id/users?q=${Uri.encodeQueryComponent(query)}&limit=$limit&offset=$offset',
    );
    final users = (response['users'] as List<dynamic>).map((u) => PlatformTenantUser.fromJson(u as Map<String, dynamic>)).toList();
    return (users: users, total: response['total'] as int);
  }

  Future<String> createTenantUser(
    String id, {
    required String username,
    required String password,
    required String displayName,
    String? phone,
    String? email,
    List<String> roleIds = const [],
  }) async {
    final response = await client.postAuthed('/api/v1/platform/tenants/$id/users', {
      'username': username,
      'password': password,
      'display_name': displayName,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (email != null && email.isNotEmpty) 'email': email,
      if (roleIds.isNotEmpty) 'role_ids': roleIds,
    });
    return response['id'] as String;
  }

  Future<PlatformTenantUserDetail> getTenantUser(String id, String userId) async {
    final response = await client.getAuthed('/api/v1/platform/tenants/$id/users/$userId');
    return PlatformTenantUserDetail.fromJson(response);
  }

  Future<void> updateTenantUser(String id, String userId, {required String displayName, String? phone, String? email}) async {
    await client.putAuthed('/api/v1/platform/tenants/$id/users/$userId', {
      'display_name': displayName,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (email != null && email.isNotEmpty) 'email': email,
    });
  }

  Future<void> setTenantUserStatus(String id, String userId, bool active) async {
    await client.postAuthed('/api/v1/platform/tenants/$id/users/$userId/status', {'active': active});
  }

  /// Server-generates a brand-new password and returns it exactly once —
  /// this is the direct replacement for the owner SSHing in and
  /// hand-writing a password-reset SQL statement. The caller must show it
  /// to the admin immediately; it's never retrievable again afterwards.
  Future<String> resetTenantUserPassword(String id, String userId) async {
    final response = await client.postAuthed('/api/v1/platform/tenants/$id/users/$userId/reset-password', {});
    return response['new_password'] as String;
  }

  Future<List<PlatformRole>> listTenantRoles(String id) async {
    final response = await client.getAuthed('/api/v1/platform/tenants/$id/roles');
    return (response['roles'] as List<dynamic>).map((r) => PlatformRole.fromJson(r as Map<String, dynamic>)).toList();
  }

  Future<void> setTenantUserRoles(String id, String userId, List<String> roleIds) async {
    await client.putAuthed('/api/v1/platform/tenants/$id/users/$userId/roles', {'role_ids': roleIds});
  }

  /// Lists a tenant's registered devices — the other half of the owner
  /// lockout fix: a platform admin can see devices to revoke a lost one or
  /// generate a pairing code on the owner's behalf.
  Future<({List<PlatformDevice> devices, int total})> listTenantDevices(
    String id, {
    String query = '',
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await client.getAuthed(
      '/api/v1/platform/tenants/$id/devices?q=${Uri.encodeQueryComponent(query)}&limit=$limit&offset=$offset',
    );
    final devices = (response['devices'] as List<dynamic>).map((d) => PlatformDevice.fromJson(d as Map<String, dynamic>)).toList();
    return (devices: devices, total: response['total'] as int);
  }

  Future<void> revokeTenantDevice(String id, String deviceId, {String? reason}) async {
    await client.postAuthed('/api/v1/platform/tenants/$id/devices/$deviceId/revoke', {
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    });
  }

  /// Generates a device-pairing code on behalf of a tenant that forgot to
  /// generate their own — the whole reason this feature exists: the owner
  /// reads this code over the phone to whoever is setting up the device.
  Future<PairingCodeResult> generateTenantPairingCode(String id) async {
    final response = await client.postAuthed('/api/v1/platform/tenants/$id/devices/pairing-codes', {});
    return PairingCodeResult.fromJson(response);
  }

  /// The subscription-plan catalogue, in the order the server returns it.
  Future<List<SubscriptionPlan>> listPlans() async {
    final response = await client.getAuthed('/api/v1/platform/plans');
    return (response['plans'] as List<dynamic>).map((p) => SubscriptionPlan.fromJson(p as Map<String, dynamic>)).toList();
  }

  Future<String> createPlan({
    required String code,
    required String name,
    required Decimal price,
    required int gracePeriodDays,
  }) async {
    final response = await client.postAuthed('/api/v1/platform/plans', {
      'code': code,
      'name': name,
      'price': price.toString(),
      'grace_period_days': gracePeriodDays,
    });
    return response['id'] as String;
  }

  /// Code is immutable once a plan is created (UpdatePlan's request has no
  /// code field server-side), so this never sends one.
  Future<void> updatePlan(
    String id, {
    required String name,
    required Decimal price,
    required int gracePeriodDays,
    required bool active,
  }) async {
    await client.putAuthed('/api/v1/platform/plans/$id', {
      'name': name,
      'price': price.toString(),
      'grace_period_days': gracePeriodDays,
      'active': active,
    });
  }

  /// Returns null — not an error — when the tenant has no subscription
  /// assigned yet. That's the normal state for any tenant that existed
  /// before this feature or hasn't had a plan assigned, so callers show an
  /// empty/setup state rather than an error for a 404 here.
  Future<TenantSubscription?> getTenantSubscription(String id) async {
    try {
      final response = await client.getAuthed('/api/v1/platform/tenants/$id/subscription');
      return TenantSubscription.fromJson(response);
    } on ApiError catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Assigns or changes a tenant's plan — used both for first-time
  /// assignment and for switching plans later. Omitting [periodStart]
  /// means "starting today".
  Future<void> setTenantSubscriptionPlan(String id, String planId, {DateTime? periodStart}) async {
    await client.putAuthed('/api/v1/platform/tenants/$id/subscription/plan', {
      'plan_id': planId,
      if (periodStart != null) 'period_start': _dateOnly(periodStart),
    });
  }

  /// Records a payment collected out of band (UPI/bank/cash) against a
  /// tenant's subscription — auto-reactivates a suspended tenant
  /// server-side. Requires an assigned plan (404 otherwise).
  Future<RecordSubscriptionPaymentResult> recordSubscriptionPayment(
    String id, {
    required Decimal amount,
    required String method,
    String? reference,
    String? notes,
  }) async {
    final response = await client.postAuthed('/api/v1/platform/tenants/$id/subscription/payments', {
      'amount': amount.toString(),
      'method': method,
      if (reference != null && reference.isNotEmpty) 'reference': reference,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      // A fresh idempotency key per submission, same pattern as the
      // tenant-side manual receipt dialog (features/customers/receipt_api.dart)
      // — guards against a lost response being retried, not a deliberate
      // double-tap.
      'idempotency_key': const Uuid().v4(),
    });
    return RecordSubscriptionPaymentResult.fromJson(response);
  }

  Future<({List<SubscriptionPayment> payments, int total})> listBillingHistory(
    String id, {
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await client.getAuthed('/api/v1/platform/tenants/$id/subscription/payments?limit=$limit&offset=$offset');
    final payments = (response['payments'] as List<dynamic>).map((p) => SubscriptionPayment.fromJson(p as Map<String, dynamic>)).toList();
    return (payments: payments, total: response['total'] as int);
  }

  String _dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// The platform-wide default branding — the single source of truth every
/// tenant's own app name/tagline/logo/color falls back to when they haven't
/// set their own override (see TenantDetail.appDisplayName etc.). Editing
/// this is what used to require changing a hardcoded string in the Flutter
/// source and shipping a new build.
class PlatformSettings {
  final String appName;
  final String appTagline;
  final String? logoUrl;
  final String? primaryColor;

  PlatformSettings({required this.appName, required this.appTagline, this.logoUrl, this.primaryColor});

  factory PlatformSettings.fromJson(Map<String, dynamic> json) {
    return PlatformSettings(
      appName: json['app_name'] as String,
      appTagline: json['app_tagline'] as String,
      logoUrl: json['logo_url'] as String?,
      primaryColor: json['primary_color'] as String?,
    );
  }
}
