import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/theme/app_typography.dart';
import 'staff_api.dart';

/// The fields the create-staff form collects. Password is only present on
/// create — editing an existing account's password isn't wired up in this
/// pass (self-service password reset covers the normal case; an admin
/// resetting someone else's password is not yet a supported flow).
class StaffFormResult {
  final String username;
  final String? password;
  final String displayName;
  final String? phone;
  final String? email;
  final List<String> roleIds;

  StaffFormResult({
    required this.username,
    this.password,
    required this.displayName,
    this.phone,
    this.email,
    required this.roleIds,
  });
}

/// Create-staff dialog: username/password/display name plus optional
/// contact info and role assignment. All validation (password strength,
/// username uniqueness) is authoritative server-side — this only checks
/// required fields are present before submitting.
class StaffFormDialog extends StatefulWidget {
  const StaffFormDialog({super.key});

  @override
  State<StaffFormDialog> createState() => _StaffFormDialogState();
}

class _StaffFormDialogState extends State<StaffFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();

  List<Role> _roles = [];
  final Set<String> _selectedRoleIds = {};
  bool _loadingRoles = true;
  String? _rolesError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadRoles());
  }

  Future<void> _loadRoles() async {
    try {
      final api = StaffApi(context.read<ApiClient>());
      final roles = await api.listRoles();
      if (!mounted) return;
      setState(() {
        _roles = roles;
        _loadingRoles = false;
      });
    } catch (e) {
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
    Navigator.of(context).pop(StaffFormResult(
      username: _usernameController.text.trim(),
      password: _passwordController.text,
      displayName: _displayNameController.text.trim(),
      phone: _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim(),
      email: _emailController.text.trim().isEmpty ? null : _emailController.text.trim(),
      roleIds: _selectedRoleIds.toList(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Staff', style: AppTypography.headline),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('staff_username_field'),
                controller: _usernameController,
                decoration: const InputDecoration(labelText: 'Username'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('staff_password_field'),
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
                validator: (v) => (v == null || v.length < 8) ? 'At least 8 characters' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('staff_display_name_field'),
                controller: _displayNameController,
                decoration: const InputDecoration(labelText: 'Display Name'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('staff_phone_field'),
                controller: _phoneController,
                decoration: const InputDecoration(labelText: 'Phone (optional)'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('staff_email_field'),
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Email (optional)'),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              Align(alignment: Alignment.centerLeft, child: Text('Roles', style: Theme.of(context).textTheme.titleSmall)),
              if (_loadingRoles) const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())
              else if (_rolesError != null)
                Text(_rolesError!, style: const TextStyle(color: Colors.red))
              else
                Wrap(
                  spacing: 8,
                  children: _roles.map((role) {
                    final selected = _selectedRoleIds.contains(role.id);
                    return FilterChip(
                      key: Key('staff_role_chip_${role.id}'),
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
          key: const Key('staff_form_submit'),
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
