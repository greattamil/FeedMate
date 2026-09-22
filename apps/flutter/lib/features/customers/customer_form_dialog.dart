import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../pos/customer_api.dart';

/// The fields a customer create/edit form collects. customer_code is
/// server-generated and never part of this result — see the dialog's
/// read-only display on edit for where it's shown instead.
class CustomerFormResult {
  final String name;
  final String? localName;
  final String? phone;
  final String? email;
  final String? gstin;
  final String customerType;
  final Decimal? creditLimit;

  CustomerFormResult({
    required this.name,
    this.localName,
    this.phone,
    this.email,
    this.gstin,
    required this.customerType,
    this.creditLimit,
  });
}

/// Shared create/edit dialog for customer master data.
class CustomerFormDialog extends StatefulWidget {
  final CustomerDetail? existing;
  const CustomerFormDialog({super.key, this.existing});

  @override
  State<CustomerFormDialog> createState() => _CustomerFormDialogState();
}

class _CustomerFormDialogState extends State<CustomerFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _codeController;
  late final TextEditingController _nameController;
  late final TextEditingController _localNameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;
  late final TextEditingController _gstinController;
  late final TextEditingController _creditLimitController;
  late String _customerType;

  bool get _isEdit => widget.existing != null;

  static const _customerTypeLabels = {
    'FARMER': 'Farmer',
    'WHOLESALE_DEALER': 'Wholesale Dealer',
    'AAVIN_SUBCONTRACTOR': 'AAVIN Subcontractor',
    'OTHER': 'Other',
  };

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _codeController = TextEditingController(text: e?.customerCode ?? '');
    _nameController = TextEditingController(text: e?.name ?? '');
    _localNameController = TextEditingController(text: e?.localName ?? '');
    _phoneController = TextEditingController(text: e?.phone ?? '');
    _emailController = TextEditingController(text: e?.email ?? '');
    _gstinController = TextEditingController(text: e?.gstin ?? '');
    _creditLimitController = TextEditingController();
    _customerType = _customerTypeLabels.containsKey(e?.customerType) ? e!.customerType : 'FARMER';
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _localNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _gstinController.dispose();
    _creditLimitController.dispose();
    super.dispose();
  }

  InputDecoration _inputDeco(String label, {IconData? prefixIcon}) {
    return InputDecoration(
      labelText: label,
      prefixIcon: prefixIcon != null ? Icon(prefixIcon, size: 18, color: AppColors.primary) : null,
      filled: true,
      fillColor: AppColors.surfaceSecondary,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.border.withValues(alpha: 0.5)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    );
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(CustomerFormResult(
      name: _nameController.text.trim(),
      localName: _localNameController.text.trim().isEmpty ? null : _localNameController.text.trim(),
      phone: _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim(),
      email: _emailController.text.trim().isEmpty ? null : _emailController.text.trim(),
      gstin: _gstinController.text.trim().isEmpty ? null : _gstinController.text.trim(),
      customerType: _customerType,
      creditLimit: (!_isEdit && _creditLimitController.text.trim().isNotEmpty)
          ? Decimal.parse(_creditLimitController.text.trim())
          : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: _isEdit ? AppColors.gradientIndigo : AppColors.gradientEmerald,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _isEdit ? Icons.edit_rounded : Icons.person_add_alt_1_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Text(_isEdit ? 'Edit Customer' : 'Add Customer', style: AppTypography.headline.copyWith(fontSize: 18)),
        ],
      ),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isEdit) ...[
                TextFormField(
                  key: const Key('customer_code_field_readonly'),
                  controller: _codeController,
                  enabled: false,
                  decoration: _inputDeco('Customer Code (immutable)', prefixIcon: Icons.lock_outline_rounded),
                ),
                const SizedBox(height: 12),
              ] else
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.auto_awesome_rounded, size: 14, color: AppColors.textSecondary),
                      const SizedBox(width: 6),
                      Text('Customer code is generated automatically', style: AppTypography.caption),
                    ],
                  ),
                ),
              TextFormField(
                key: const Key('customer_name_field'),
                controller: _nameController,
                decoration: _inputDeco('Full Name *', prefixIcon: Icons.person_rounded),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('customer_local_name_field'),
                controller: _localNameController,
                decoration: _inputDeco('Local Name (Tamil, optional)', prefixIcon: Icons.translate_rounded),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('customer_phone_field'),
                controller: _phoneController,
                decoration: _inputDeco('Phone Number', prefixIcon: Icons.phone_rounded),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('customer_email_field'),
                controller: _emailController,
                decoration: _inputDeco('Email Address', prefixIcon: Icons.email_rounded),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('customer_gstin_field'),
                controller: _gstinController,
                decoration: _inputDeco('GSTIN (optional)', prefixIcon: Icons.receipt_rounded),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('customer_type_field'),
                initialValue: _customerType,
                decoration: _inputDeco('Customer Classification', prefixIcon: Icons.category_rounded),
                items: _customerTypeLabels.entries
                    .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => setState(() => _customerType = v ?? 'FARMER'),
              ),
              if (!_isEdit) ...[
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('customer_credit_limit_field'),
                  controller: _creditLimitController,
                  decoration: _inputDeco('Initial Credit Limit (₹)', prefixIcon: Icons.currency_rupee_rounded),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    try {
                      Decimal.parse(v.trim());
                      return null;
                    } catch (_) {
                      return 'Invalid amount';
                    }
                  },
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('customer_form_submit'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: _submit,
          child: Text(_isEdit ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}
