import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import 'staff_api.dart';

/// A staff member's profile, status, and role assignment. Deactivation is a
/// status flip, never a hard delete (see identity.Service.SetUserStatus's
/// doc comment) — a deactivated user's historical invoices/GRNs/audit
/// entries stay intact and attributable. Self-deactivation is rejected
/// server-side.
class StaffDetailScreen extends StatefulWidget {
  final String userId;
  const StaffDetailScreen({super.key, required this.userId});

  @override
  State<StaffDetailScreen> createState() => _StaffDetailScreenState();
}

class _StaffDetailScreenState extends State<StaffDetailScreen> {
  StaffDetail? _detail;
  List<Role> _roles = [];
  bool _loading = true;
  String? _error;

  static final _dateFormat = DateFormat('dd MMM yyyy, h:mm a');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = StaffApi(context.read<ApiClient>());
      final detail = await api.getDetail(widget.userId);
      final roles = await api.listRoles();
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _roles = roles;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _toggleActive() async {
    final detail = _detail;
    if (detail == null) return;
    final makeActive = detail.status != 'ACTIVE';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(makeActive ? 'Reactivate Staff?' : 'Deactivate Staff?'),
        content: Text(makeActive
            ? '${detail.displayName} will be able to log in again.'
            : '${detail.displayName} will be signed out and can never log in again until reactivated.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('staff_toggle_active_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(makeActive ? 'Reactivate' : 'Deactivate'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final api = StaffApi(context.read<ApiClient>());
      await api.setActive(widget.userId, makeActive);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(makeActive ? 'Staff reactivated' : 'Staff deactivated')),
      );
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _toggleRole(String roleId, bool selected) async {
    final detail = _detail;
    if (detail == null) return;
    final newRoleIds = Set<String>.from(detail.roleIds);
    if (selected) {
      newRoleIds.add(roleId);
    } else {
      newRoleIds.remove(roleId);
    }
    try {
      final api = StaffApi(context.read<ApiClient>());
      await api.setRoles(widget.userId, newRoleIds.toList());
      if (!mounted) return;
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(
        title: Text(detail?.displayName ?? 'Staff'),
        actions: [
          if (detail != null)
            IconButton(
              key: const Key('toggle_staff_active_button'),
              onPressed: _toggleActive,
              icon: Icon(detail.status == 'ACTIVE' ? Icons.block_rounded : Icons.check_circle_outline_rounded),
              tooltip: detail.status == 'ACTIVE' ? 'Deactivate' : 'Reactivate',
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: Colors.red))))
              : detail == null
                  ? const SizedBox.shrink()
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(detail.displayName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                              Text('@${detail.username}', style: const TextStyle(color: Color(0xFF64748B), fontSize: 13)),
                              const SizedBox(height: 8),
                              Text(
                                'Status: ${detail.status}',
                                key: const Key('staff_status_text'),
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: detail.status == 'ACTIVE' ? const Color(0xFF059669) : const Color(0xFFE11D48)),
                              ),
                              if (detail.phone != null) Text('Phone: ${detail.phone}', style: const TextStyle(fontSize: 13)),
                              if (detail.email != null) Text('Email: ${detail.email}', style: const TextStyle(fontSize: 13)),
                              if (detail.lastLoginAt != null)
                                Text('Last login: ${_dateFormat.format(detail.lastLoginAt!.toLocal())}', style: const TextStyle(fontSize: 13)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text('Roles', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: _roles.map((role) {
                            final selected = detail.roleIds.contains(role.id);
                            return FilterChip(
                              key: Key('staff_detail_role_chip_${role.id}'),
                              label: Text(role.name),
                              selected: selected,
                              onSelected: (v) => _toggleRole(role.id, v),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
    );
  }
}
