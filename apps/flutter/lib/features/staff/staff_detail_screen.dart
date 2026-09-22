import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'staff_api.dart';

/// A staff member's profile, status, and role assignment.
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
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: makeActive ? AppColors.successContainer : AppColors.dangerContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                makeActive ? Icons.check_circle_outline_rounded : Icons.block_rounded,
                color: makeActive ? AppColors.success : AppColors.danger,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Text(makeActive ? 'Reactivate Staff?' : 'Deactivate Staff?'),
          ],
        ),
        content: Text(
          makeActive
              ? '${detail.displayName} will be able to log in again.'
              : '${detail.displayName} will be signed out and can never log in again until reactivated.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('staff_toggle_active_confirm'),
            style: FilledButton.styleFrom(backgroundColor: makeActive ? AppColors.success : AppColors.danger),
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

  Future<void> _editProfile() async {
    final detail = _detail;
    if (detail == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _StaffEditDialog(detail: detail),
    );
    if (saved == true) await _load();
  }

  Future<void> _resetPassword() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _ResetPasswordDialog(userId: widget.userId),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password reset — share the new password with the staff member')),
      );
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
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(detail?.displayName ?? 'Staff Details', style: AppTypography.headline),
        actions: [
          if (detail != null) ...[
            IconButton(
              key: const Key('edit_staff_button'),
              onPressed: _editProfile,
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit Profile',
            ),
            IconButton(
              key: const Key('reset_staff_password_button'),
              onPressed: _resetPassword,
              icon: const Icon(Icons.key_rounded),
              tooltip: 'Reset Password',
            ),
            IconButton(
              key: const Key('toggle_staff_active_button'),
              onPressed: _toggleActive,
              icon: Icon(detail.status == 'ACTIVE' ? Icons.block_rounded : Icons.check_circle_outline_rounded),
              tooltip: detail.status == 'ACTIVE' ? 'Deactivate' : 'Reactivate',
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _error != null
              ? Center(
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.dangerContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer)),
                  ),
                )
              : detail == null
                  ? const SizedBox.shrink()
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: AppColors.border),
                            boxShadow: AppDecorations.cardShadow,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 48,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      gradient: AppColors.gradientIndigo,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Center(
                                      child: Text(
                                        detail.displayName.isNotEmpty ? detail.displayName.substring(0, 1).toUpperCase() : '?',
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(detail.displayName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                                        Text('@${detail.username}', style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: detail.status == 'ACTIVE' ? AppColors.successContainer : AppColors.dangerContainer,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      'Status: ${detail.status}',
                                      key: const Key('staff_status_text'),
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: detail.status == 'ACTIVE' ? AppColors.success : AppColors.danger,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const Divider(height: 24),
                              if (detail.phone != null) ...[
                                Row(
                                  children: [
                                    const Icon(Icons.phone_outlined, size: 16, color: AppColors.textSecondary),
                                    const SizedBox(width: 8),
                                    Text('Phone: ${detail.phone}', style: const TextStyle(fontSize: 13)),
                                  ],
                                ),
                                const SizedBox(height: 6),
                              ],
                              if (detail.email != null) ...[
                                Row(
                                  children: [
                                    const Icon(Icons.email_outlined, size: 16, color: AppColors.textSecondary),
                                    const SizedBox(width: 8),
                                    Text('Email: ${detail.email}', style: const TextStyle(fontSize: 13)),
                                  ],
                                ),
                                const SizedBox(height: 6),
                              ],
                              if (detail.lastLoginAt != null) ...[
                                Row(
                                  children: [
                                    const Icon(Icons.login_rounded, size: 16, color: AppColors.textSecondary),
                                    const SizedBox(width: 8),
                                    Text('Last login: ${_dateFormat.format(detail.lastLoginAt!.toLocal())}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            const Icon(Icons.security_rounded, size: 18, color: AppColors.primary),
                            const SizedBox(width: 8),
                            const Text('Assigned Roles & Permissions', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.textPrimary)),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: AppColors.border),
                            boxShadow: AppDecorations.cardShadow,
                          ),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: _roles.map((role) {
                              final selected = detail.roleIds.contains(role.id);
                              return FilterChip(
                                key: Key('staff_detail_role_chip_${role.id}'),
                                label: Text(role.name),
                                selected: selected,
                                selectedColor: AppColors.primaryLight.withAlpha(50),
                                checkmarkColor: AppColors.primary,
                                onSelected: (v) => _toggleRole(role.id, v),
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
    );
  }
}

/// Edits a staff member's display name/phone/email — never their username
/// or password (see [_ResetPasswordDialog] for the latter).
class _StaffEditDialog extends StatefulWidget {
  final StaffDetail detail;
  const _StaffEditDialog({required this.detail});

  @override
  State<_StaffEditDialog> createState() => _StaffEditDialogState();
}

class _StaffEditDialogState extends State<_StaffEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _displayNameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _displayNameController = TextEditingController(text: widget.detail.displayName);
    _phoneController = TextEditingController(text: widget.detail.phone ?? '');
    _emailController = TextEditingController(text: widget.detail.email ?? '');
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final api = StaffApi(context.read<ApiClient>());
      await api.update(
        widget.detail.id,
        displayName: _displayNameController.text.trim(),
        phone: _phoneController.text.trim(),
        email: _emailController.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Staff Profile', style: AppTypography.headline),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('staff_edit_display_name_field'),
                controller: _displayNameController,
                decoration: const InputDecoration(labelText: 'Display Name'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('staff_edit_phone_field'),
                controller: _phoneController,
                decoration: const InputDecoration(labelText: 'Phone (optional)'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('staff_edit_email_field'),
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Email (optional)'),
                keyboardType: TextInputType.emailAddress,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          key: const Key('staff_edit_submit'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}

/// Admin-initiated password reset — there is no email/SMS self-service
/// flow in this app, so a manager sets a new password directly here and
/// hands it to the staff member out of band.
class _ResetPasswordDialog extends StatefulWidget {
  final String userId;
  const _ResetPasswordDialog({required this.userId});

  @override
  State<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<_ResetPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final api = StaffApi(context.read<ApiClient>());
      await api.resetPassword(widget.userId, _passwordController.text);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reset Password', style: AppTypography.headline),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('reset_password_field'),
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'New Password'),
                validator: (v) => (v == null || v.length < 8) ? 'At least 8 characters' : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          key: const Key('reset_password_submit'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Reset Password'),
        ),
      ],
    );
  }
}
