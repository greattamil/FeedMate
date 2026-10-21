import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'platform_api.dart';
import 'platform_api_client.dart';

/// The Users tab of [TenantDetailScreen]: browse a tenant's own staff
/// accounts, create new ones, edit profiles/roles, flip status, and —
/// the whole reason this screen exists — reset a locked-out owner's
/// password without the platform owner having to SSH into production.
class TenantUsersTab extends StatefulWidget {
  final String tenantId;
  const TenantUsersTab({super.key, required this.tenantId});

  @override
  State<TenantUsersTab> createState() => _TenantUsersTabState();
}

class _TenantUsersTabState extends State<TenantUsersTab> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  List<PlatformTenantUser> _users = [];
  bool _loading = false;
  String? _error;

  static final _dateFormat = DateFormat('dd MMM yyyy, h:mm a');

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(query));
  }

  Future<void> _search(String query) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      final result = await api.listTenantUsers(widget.tenantId, query: query);
      if (!mounted) return;
      setState(() {
        _users = result.users;
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

  Future<void> _addUser() async {
    final draft = await showDialog<_UserFormResult>(
      context: context,
      builder: (context) => _UserFormDialog(tenantId: widget.tenantId),
    );
    if (draft == null) return;

    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      await api.createTenantUser(
        widget.tenantId,
        username: draft.username,
        password: draft.password!,
        displayName: draft.displayName,
        phone: draft.phone,
        email: draft.email,
        roleIds: draft.roleIds,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${draft.displayName} added')));
      await _search(_searchController.text);
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _editUser(PlatformTenantUser user) async {
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      final detail = await api.getTenantUser(widget.tenantId, user.id);
      if (!mounted) return;
      final draft = await showDialog<_UserFormResult>(
        context: context,
        builder: (context) => _UserFormDialog(tenantId: widget.tenantId, existing: detail),
      );
      if (draft == null) return;
      await api.updateTenantUser(widget.tenantId, user.id, displayName: draft.displayName, phone: draft.phone, email: draft.email);
      if (!mounted) return;
      await api.setTenantUserRoles(widget.tenantId, user.id, draft.roleIds);
      if (!mounted) return;
      await _search(_searchController.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('User updated')));
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _toggleStatus(PlatformTenantUser user) async {
    final makeActive = user.status != 'ACTIVE';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: makeActive ? AppColors.successContainer : AppColors.dangerContainer,
                borderRadius: AppDecorations.borderRadiusSm,
              ),
              child: Icon(
                makeActive ? Icons.check_circle_outline_rounded : Icons.block_rounded,
                color: makeActive ? AppColors.success : AppColors.danger,
              ),
            ),
            const SizedBox(width: 12),
            Text(makeActive ? 'Activate User?' : 'Deactivate User?'),
          ],
        ),
        content: Text(
          makeActive
              ? '${user.displayName} will be able to log in again.'
              : '${user.displayName} will be signed out and unable to log in until reactivated.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('platform_user_status_confirm'),
            style: FilledButton.styleFrom(backgroundColor: makeActive ? AppColors.success : AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(makeActive ? 'Activate' : 'Deactivate'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      await api.setTenantUserStatus(widget.tenantId, user.id, makeActive);
      if (!mounted) return;
      await _search(_searchController.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(makeActive ? 'User activated' : 'User deactivated')),
      );
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _resetPassword(PlatformTenantUser user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Password?'),
        content: Text(
          'A brand-new password will be generated for ${user.displayName}. '
          'Their current password stops working immediately.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('platform_reset_password_confirm'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.warning),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset Password'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      final newPassword = await api.resetTenantUserPassword(widget.tenantId, user.id);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _NewPasswordDialog(password: newPassword),
      );
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        key: const Key('platform_add_user_fab'),
        onPressed: _addUser,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Add User'),
        backgroundColor: AppColors.primary,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              key: const Key('platform_user_search_field'),
              controller: _searchController,
              decoration: InputDecoration(
                labelText: 'Search by username or name',
                prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          _onQueryChanged('');
                        },
                      )
                    : null,
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          if (_loading) const LinearProgressIndicator(color: AppColors.primary, minHeight: 2),
          if (_error != null)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppColors.dangerContainer, borderRadius: AppDecorations.borderRadiusSm),
              child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer)),
            ),
          Expanded(
            child: _users.isEmpty && !_loading
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.badge_outlined, size: 56, color: Color(0xFF94A3B8)),
                        SizedBox(height: 12),
                        Text('No users found', style: AppTypography.bodySecondary),
                      ],
                    ),
                  )
                : ListView.builder(
                    key: const Key('platform_user_results_list'),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                    itemCount: _users.length,
                    itemBuilder: (context, index) {
                      final u = _users[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: AppDecorations.card(color: AppColors.surface),
                        child: ListTile(
                          key: Key('platform_user_item_${u.id}'),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          leading: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(gradient: AppColors.gradientIndigo, borderRadius: AppDecorations.borderRadiusMd),
                            child: Center(
                              child: Text(
                                u.displayName.isNotEmpty ? u.displayName.substring(0, 1).toUpperCase() : '?',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                              ),
                            ),
                          ),
                          title: Text(u.displayName, style: AppTypography.title),
                          subtitle: Text(
                            [
                              '@${u.username}',
                              u.status,
                              if (u.lastLoginAt != null) 'Last login ${_dateFormat.format(u.lastLoginAt!.toLocal())}',
                            ].join(' · '),
                            style: AppTypography.caption.copyWith(
                              color: u.status == 'ACTIVE' ? AppColors.textSecondary : AppColors.danger,
                            ),
                          ),
                          trailing: PopupMenuButton<String>(
                            key: Key('platform_user_menu_${u.id}'),
                            icon: const Icon(Icons.more_vert_rounded, color: AppColors.textSecondary),
                            onSelected: (action) {
                              switch (action) {
                                case 'edit':
                                  _editUser(u);
                                  break;
                                case 'status':
                                  _toggleStatus(u);
                                  break;
                                case 'reset_password':
                                  _resetPassword(u);
                                  break;
                              }
                            },
                            itemBuilder: (context) => [
                              const PopupMenuItem(value: 'edit', child: Text('Edit')),
                              PopupMenuItem(value: 'status', child: Text(u.status == 'ACTIVE' ? 'Deactivate' : 'Activate')),
                              const PopupMenuItem(value: 'reset_password', child: Text('Reset Password')),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _UserFormResult {
  final String username;
  final String? password;
  final String displayName;
  final String? phone;
  final String? email;
  final List<String> roleIds;

  _UserFormResult({
    required this.username,
    this.password,
    required this.displayName,
    this.phone,
    this.email,
    required this.roleIds,
  });
}

/// Create/edit dialog: username+password only present on create (editing
/// an existing account's credentials goes through the dedicated password
/// reset flow instead — see [_NewPasswordDialog]).
class _UserFormDialog extends StatefulWidget {
  final String tenantId;
  final PlatformTenantUserDetail? existing;
  const _UserFormDialog({required this.tenantId, this.existing});

  @override
  State<_UserFormDialog> createState() => _UserFormDialogState();
}

class _UserFormDialogState extends State<_UserFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _usernameController;
  final _passwordController = TextEditingController();
  late final TextEditingController _displayNameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;

  List<PlatformRole> _roles = [];
  late final Set<String> _selectedRoleIds;
  bool _loadingRoles = true;
  String? _rolesError;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _usernameController = TextEditingController(text: existing?.username ?? '');
    _displayNameController = TextEditingController(text: existing?.displayName ?? '');
    _phoneController = TextEditingController(text: existing?.phone ?? '');
    _emailController = TextEditingController(text: existing?.email ?? '');
    _selectedRoleIds = Set<String>.from(existing?.roleIds ?? const <String>[]);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadRoles());
  }

  Future<void> _loadRoles() async {
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      final roles = await api.listTenantRoles(widget.tenantId);
      if (!mounted) return;
      setState(() {
        _roles = roles;
        _loadingRoles = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _rolesError = 'Failed to load roles';
        _loadingRoles = false;
      });
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _displayNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(_UserFormResult(
      username: _usernameController.text.trim(),
      password: _isEdit ? null : _passwordController.text,
      displayName: _displayNameController.text.trim(),
      phone: _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim(),
      email: _emailController.text.trim().isEmpty ? null : _emailController.text.trim(),
      roleIds: _selectedRoleIds.toList(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit User' : 'Add User', style: AppTypography.headline),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('platform_user_username_field'),
                controller: _usernameController,
                enabled: !_isEdit,
                decoration: const InputDecoration(labelText: 'Username'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              if (!_isEdit) ...[
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('platform_user_password_field'),
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                  validator: (v) => (v == null || v.length < 8) ? 'At least 8 characters' : null,
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('platform_user_display_name_field'),
                controller: _displayNameController,
                decoration: const InputDecoration(labelText: 'Display Name'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('platform_user_phone_field'),
                controller: _phoneController,
                decoration: const InputDecoration(labelText: 'Phone (optional)'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('platform_user_email_field'),
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Email (optional)'),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              Align(alignment: Alignment.centerLeft, child: Text('Roles', style: Theme.of(context).textTheme.titleSmall)),
              if (_loadingRoles)
                const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())
              else if (_rolesError != null)
                Text(_rolesError!, style: const TextStyle(color: AppColors.danger))
              else
                Wrap(
                  spacing: 8,
                  children: _roles.map((role) {
                    final selected = _selectedRoleIds.contains(role.id);
                    return FilterChip(
                      key: Key('platform_user_role_chip_${role.id}'),
                      label: Text(role.name),
                      selected: selected,
                      onSelected: (v) => setState(() {
                        if (v) {
                          _selectedRoleIds.add(role.id);
                        } else {
                          _selectedRoleIds.remove(role.id);
                        }
                      }),
                    );
                  }).toList(),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('platform_user_form_submit'),
          onPressed: _submit,
          child: Text(_isEdit ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

/// Shows a server-generated password exactly once. There is no way to
/// retrieve it again after this dialog closes, so dismissing it requires
/// an explicit acknowledgement rather than a tap-outside/back-button
/// dismiss — the whole point of this flow is the admin actually copies it
/// before closing.
class _NewPasswordDialog extends StatelessWidget {
  final String password;
  const _NewPasswordDialog({required this.password});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        key: const Key('platform_reset_password_dialog'),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: AppColors.warningContainer, borderRadius: AppDecorations.borderRadiusSm),
              child: const Icon(Icons.key_rounded, color: AppColors.warning),
            ),
            const SizedBox(width: 12),
            const Expanded(child: Text('New Password Generated')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: AppColors.dangerContainer, borderRadius: AppDecorations.borderRadiusSm),
              child: const Text(
                'This password will not be shown again. Copy it now and hand it to the tenant out of band.',
                style: TextStyle(color: AppColors.onDangerContainer, fontSize: 13, fontWeight: FontWeight.w600, height: 1.4),
              ),
            ),
            const SizedBox(height: 16),
            InkWell(
              key: const Key('platform_new_password_copy'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: password));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Password copied to clipboard'), duration: Duration(seconds: 1)),
                );
              },
              borderRadius: AppDecorations.borderRadiusSm,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceSecondary,
                  border: Border.all(color: AppColors.border),
                  borderRadius: AppDecorations.borderRadiusSm,
                ),
                child: Column(
                  children: [
                    Text(
                      password,
                      key: const Key('platform_new_password_text'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1.5, fontFamily: 'monospace'),
                    ),
                    const SizedBox(height: 6),
                    const Text('Tap to copy', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          FilledButton(
            key: const Key('platform_new_password_acknowledge'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("I've copied the password"),
          ),
        ],
      ),
    );
  }
}
