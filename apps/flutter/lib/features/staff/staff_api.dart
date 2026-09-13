import '../../core/api_client.dart';

class StaffSummary {
  final String id;
  final String username;
  final String displayName;
  final String? phone;
  final String? email;
  final String status; // ACTIVE, DISABLED
  final DateTime? lastLoginAt;

  StaffSummary({
    required this.id,
    required this.username,
    required this.displayName,
    required this.phone,
    required this.email,
    required this.status,
    required this.lastLoginAt,
  });

  factory StaffSummary.fromJson(Map<String, dynamic> json) {
    return StaffSummary(
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

class StaffDetail extends StaffSummary {
  final List<String> roleIds;

  StaffDetail({
    required super.id,
    required super.username,
    required super.displayName,
    required super.phone,
    required super.email,
    required super.status,
    required super.lastLoginAt,
    required this.roleIds,
  });

  factory StaffDetail.fromJson(Map<String, dynamic> json) {
    final summary = StaffSummary.fromJson(json);
    return StaffDetail(
      id: summary.id,
      username: summary.username,
      displayName: summary.displayName,
      phone: summary.phone,
      email: summary.email,
      status: summary.status,
      lastLoginAt: summary.lastLoginAt,
      roleIds: (json['role_ids'] as List<dynamic>? ?? []).cast<String>(),
    );
  }
}

class Role {
  final String id;
  final String name;
  final String? description;
  final bool isSystemRole;

  Role({required this.id, required this.name, required this.description, required this.isSystemRole});

  factory Role.fromJson(Map<String, dynamic> json) {
    return Role(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      isSystemRole: json['is_system_role'] as bool? ?? false,
    );
  }
}

/// Wraps the staff/role-management endpoints. See
/// services/api/internal/httpapi/staff_handlers.go. All business rules
/// (never a hard delete, self-deactivation blocked, password strength)
/// live server-side.
class StaffApi {
  final ApiClient client;

  StaffApi(this.client);

  Future<String> create({
    required String username,
    required String password,
    required String displayName,
    String? phone,
    String? email,
    List<String> roleIds = const [],
  }) async {
    final body = {
      'username': username,
      'password': password,
      'display_name': displayName,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (email != null && email.isNotEmpty) 'email': email,
      if (roleIds.isNotEmpty) 'role_ids': roleIds,
    };
    final response = await client.postAuthed('/api/v1/users', body);
    return response['id'] as String;
  }

  Future<List<StaffSummary>> list({String query = ''}) async {
    final path = query.isEmpty ? '/api/v1/users' : '/api/v1/users?q=${Uri.encodeQueryComponent(query)}';
    final response = await client.getAuthed(path);
    return (response['users'] as List<dynamic>).map((u) => StaffSummary.fromJson(u as Map<String, dynamic>)).toList();
  }

  Future<StaffDetail> getDetail(String userId) async {
    final response = await client.getAuthed('/api/v1/users/$userId');
    return StaffDetail.fromJson(response);
  }

  Future<void> setActive(String userId, bool active) async {
    await client.postAuthed('/api/v1/users/$userId/status', {'active': active});
  }

  Future<void> setRoles(String userId, List<String> roleIds) async {
    await client.putAuthed('/api/v1/users/$userId/roles', {'role_ids': roleIds});
  }

  Future<List<Role>> listRoles() async {
    final response = await client.getAuthed('/api/v1/roles');
    return (response['roles'] as List<dynamic>).map((r) => Role.fromJson(r as Map<String, dynamic>)).toList();
  }
}
