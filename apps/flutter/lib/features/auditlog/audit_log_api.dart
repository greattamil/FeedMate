import '../../core/api_client.dart';

/// One entry of the append-only audit trail — every explicit-reasoned
/// override (credit limit, tare threshold), EOD close/reopen, and other
/// sensitive action across the system writes here. Read-only: there is no
/// endpoint anywhere to create, edit, or delete an entry.
class AuditLogEntry {
  final String id;
  final String? actorName;
  final String actionCode;
  final String entityType;
  final String? entityId;
  final String? reason;
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;
  final DateTime createdAt;

  AuditLogEntry({
    required this.id,
    required this.actorName,
    required this.actionCode,
    required this.entityType,
    required this.entityId,
    required this.reason,
    required this.before,
    required this.after,
    required this.createdAt,
  });

  factory AuditLogEntry.fromJson(Map<String, dynamic> json) {
    return AuditLogEntry(
      id: json['id'] as String,
      actorName: json['actor_name'] as String?,
      actionCode: json['action_code'] as String,
      entityType: json['entity_type'] as String,
      entityId: json['entity_id'] as String?,
      reason: json['reason'] as String?,
      before: json['before'] as Map<String, dynamic>?,
      after: json['after'] as Map<String, dynamic>?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

/// Wraps GET /api/v1/audit-logs. See
/// services/api/internal/httpapi/auditlog_handlers.go.
class AuditLogApi {
  final ApiClient client;

  AuditLogApi(this.client);

  Future<List<AuditLogEntry>> list({String query = '', int limit = 50, int offset = 0}) async {
    final params = {
      if (query.isNotEmpty) 'q': query,
      'limit': limit.toString(),
      'offset': offset.toString(),
    };
    final qs = params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
    final response = await client.getAuthed('/api/v1/audit-logs?$qs');
    return (response['entries'] as List<dynamic>)
        .map((e) => AuditLogEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
