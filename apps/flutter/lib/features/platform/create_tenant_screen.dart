import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/responsive.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'platform_api.dart';
import 'platform_api_client.dart';

/// Provisions a brand-new client end-to-end: the tenant, its Owner role
/// (with every permission), a financial year, default document series, and
/// the first Owner login — all in the one call to
/// platformadmin.Service.CreateTenant, so nothing is left for a developer
/// to patch in later by hand (see that method's doc comment).
class CreateTenantScreen extends StatefulWidget {
  const CreateTenantScreen({super.key});

  @override
  State<CreateTenantScreen> createState() => _CreateTenantScreenState();
}

class _CreateTenantScreenState extends State<CreateTenantScreen> {
  final _formKey = GlobalKey<FormState>();
  final _legalNameController = TextEditingController();
  final _tradeNameController = TextEditingController();
  final _addressController = TextEditingController();
  final _cityController = TextEditingController();
  final _stateCodeController = TextEditingController(text: 'TN');
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _ownerUsernameController = TextEditingController();
  final _ownerPasswordController = TextEditingController();
  final _ownerNameController = TextEditingController();
  String _planCode = 'TRIAL';
  bool _saving = false;
  String? _error;

  static const _planCodes = ['TRIAL', 'BASIC', 'PRO'];

  @override
  void dispose() {
    for (final c in [
      _legalNameController, _tradeNameController, _addressController, _cityController, _stateCodeController,
      _phoneController, _emailController, _ownerUsernameController, _ownerPasswordController, _ownerNameController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      await api.createTenant(
        legalName: _legalNameController.text.trim(),
        tradeName: _tradeNameController.text.trim(),
        addressLine1: _addressController.text.trim(),
        city: _cityController.text.trim(),
        stateCode: _stateCodeController.text.trim(),
        phone: _phoneController.text.trim(),
        email: _emailController.text.trim(),
        planCode: _planCode,
        ownerUsername: _ownerUsernameController.text.trim(),
        ownerPassword: _ownerPasswordController.text,
        ownerName: _ownerNameController.text.trim(),
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
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        title: const Text('New Tenant', style: AppTypography.headline),
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: EdgeInsets.all(context.responsive(mobile: 16.0, desktop: 24.0)),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: ResponsiveBreakpoints.maxFormWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _sectionCard(
                    icon: Icons.storefront_rounded,
                    iconColor: AppColors.primary,
                    title: 'Business Details',
                    subtitle: 'Legal identity and address for this client.',
                    children: [
                      TextFormField(
                        key: const Key('tenant_legal_name_field'),
                        controller: _legalNameController,
                        decoration: const InputDecoration(labelText: 'Legal Name'),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        key: const Key('tenant_trade_name_field'),
                        controller: _tradeNameController,
                        decoration: const InputDecoration(labelText: 'Trade Name (optional)'),
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        key: const Key('tenant_address_field'),
                        controller: _addressController,
                        decoration: const InputDecoration(labelText: 'Address'),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 14),
                      Row(children: [
                        Expanded(
                          child: TextFormField(
                            key: const Key('tenant_city_field'),
                            controller: _cityController,
                            decoration: const InputDecoration(labelText: 'City'),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            key: const Key('tenant_state_code_field'),
                            controller: _stateCodeController,
                            decoration: const InputDecoration(labelText: 'State Code'),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                          ),
                        ),
                      ]),
                      const SizedBox(height: 14),
                      Row(children: [
                        Expanded(
                          child: TextFormField(
                            key: const Key('tenant_phone_field'),
                            controller: _phoneController,
                            decoration: const InputDecoration(labelText: 'Phone (optional)'),
                            keyboardType: TextInputType.phone,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            key: const Key('tenant_email_field'),
                            controller: _emailController,
                            decoration: const InputDecoration(labelText: 'Email (optional)'),
                            keyboardType: TextInputType.emailAddress,
                          ),
                        ),
                      ]),
                      const SizedBox(height: 14),
                      DropdownButtonFormField<String>(
                        key: const Key('tenant_plan_field'),
                        initialValue: _planCode,
                        decoration: const InputDecoration(labelText: 'Plan'),
                        items: _planCodes.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                        onChanged: (v) => setState(() => _planCode = v ?? _planCode),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _sectionCard(
                    icon: Icons.person_add_alt_1_rounded,
                    iconColor: AppColors.secondary,
                    title: 'First Owner Login',
                    subtitle: 'This account gets every permission — the client’s first user.',
                    children: [
                      TextFormField(
                        key: const Key('tenant_owner_name_field'),
                        controller: _ownerNameController,
                        decoration: const InputDecoration(labelText: 'Owner Display Name'),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        key: const Key('tenant_owner_username_field'),
                        controller: _ownerUsernameController,
                        decoration: const InputDecoration(labelText: 'Owner Username'),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        key: const Key('tenant_owner_password_field'),
                        controller: _ownerPasswordController,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: 'Owner Password'),
                        validator: (v) => (v == null || v.length < 8) ? 'At least 8 characters' : null,
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: AppColors.dangerContainer, borderRadius: AppDecorations.borderRadiusMd),
                      child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer, fontSize: 13)),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const Key('create_tenant_submit'),
                    onPressed: _saving ? null : _submit,
                    style: FilledButton.styleFrom(backgroundColor: AppColors.primary, padding: const EdgeInsets.symmetric(vertical: 16)),
                    child: _saving
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Create Tenant', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: AppDecorations.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.12), borderRadius: AppDecorations.borderRadiusSm),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: AppTypography.title),
                    Text(subtitle, style: AppTypography.caption),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          ...children,
        ],
      ),
    );
  }
}
