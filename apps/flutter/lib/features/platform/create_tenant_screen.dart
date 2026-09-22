import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
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

  InputDecoration _dec(String label) => InputDecoration(labelText: label, labelStyle: const TextStyle(color: Color(0xFF94A3B8)));

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(color: Colors.white);
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(backgroundColor: const Color(0xFF1E293B), title: const Text('New Tenant', style: TextStyle(color: Colors.white))),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Business Details', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('tenant_legal_name_field'),
              controller: _legalNameController, style: textStyle, decoration: _dec('Legal Name'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(key: const Key('tenant_trade_name_field'), controller: _tradeNameController, style: textStyle, decoration: _dec('Trade Name (optional)')),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('tenant_address_field'),
              controller: _addressController, style: textStyle, decoration: _dec('Address'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextFormField(
                  key: const Key('tenant_city_field'),
                  controller: _cityController, style: textStyle, decoration: _dec('City'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  key: const Key('tenant_state_code_field'),
                  controller: _stateCodeController, style: textStyle, decoration: _dec('State Code'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
              ),
            ]),
            const SizedBox(height: 12),
            TextFormField(key: const Key('tenant_phone_field'), controller: _phoneController, style: textStyle, decoration: _dec('Phone (optional)'), keyboardType: TextInputType.phone),
            const SizedBox(height: 12),
            TextFormField(key: const Key('tenant_email_field'), controller: _emailController, style: textStyle, decoration: _dec('Email (optional)'), keyboardType: TextInputType.emailAddress),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('tenant_plan_field'),
              initialValue: _planCode, style: textStyle, dropdownColor: const Color(0xFF1E293B), decoration: _dec('Plan'),
              items: _planCodes.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
              onChanged: (v) => setState(() => _planCode = v ?? _planCode),
            ),
            const SizedBox(height: 24),
            const Text('First Owner Login', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('tenant_owner_name_field'),
              controller: _ownerNameController, style: textStyle, decoration: _dec('Owner Display Name'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('tenant_owner_username_field'),
              controller: _ownerUsernameController, style: textStyle, decoration: _dec('Owner Username'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('tenant_owner_password_field'),
              controller: _ownerPasswordController, style: textStyle, obscureText: true, decoration: _dec('Owner Password'),
              validator: (v) => (v == null || v.length < 8) ? 'At least 8 characters' : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: const Color(0xFF7F1D1D), borderRadius: BorderRadius.circular(10)),
                child: Text(_error!, style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('create_tenant_submit'),
              onPressed: _saving ? null : _submit,
              child: Text(_saving ? 'Creating…' : 'Create Tenant'),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
