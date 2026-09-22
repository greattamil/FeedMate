import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import 'supplier_api.dart';

/// The fields a supplier create/edit form collects. supplier_code is
/// server-generated and never part of this result — see the dialog's
/// read-only display on edit for where it's shown instead.
class SupplierFormResult {
  final String name;
  final String? tradeName;
  final String? gstin;
  final String? phone;
  final String? email;
  final int paymentTermsDays;

  SupplierFormResult({
    required this.name,
    this.tradeName,
    this.gstin,
    this.phone,
    this.email,
    required this.paymentTermsDays,
  });
}

/// Shared create/edit dialog for supplier master data. When [existing] is
/// null this collects a supplier_code (returned on SupplierFormResult);
/// when non-null the code is shown read-only, mirroring ProductFormScreen's
/// SKU-immutability convention for suppliers.
class SupplierFormDialog extends StatefulWidget {
  final SupplierDetail? existing;
  const SupplierFormDialog({super.key, this.existing});

  @override
  State<SupplierFormDialog> createState() => _SupplierFormDialogState();
}

class _SupplierFormDialogState extends State<SupplierFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _codeController;
  late final TextEditingController _nameController;
  late final TextEditingController _tradeNameController;
  late final TextEditingController _gstinController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;
  late final TextEditingController _paymentTermsController;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _codeController = TextEditingController(text: e?.supplierCode ?? '');
    _nameController = TextEditingController(text: e?.name ?? '');
    _tradeNameController = TextEditingController(text: e?.tradeName ?? '');
    _gstinController = TextEditingController(text: e?.gstin ?? '');
    _phoneController = TextEditingController(text: e?.phone ?? '');
    _emailController = TextEditingController(text: e?.email ?? '');
    _paymentTermsController = TextEditingController(text: (e?.paymentTermsDays ?? 0).toString());
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _tradeNameController.dispose();
    _gstinController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _paymentTermsController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(SupplierFormResult(
      name: _nameController.text.trim(),
      tradeName: _tradeNameController.text.trim().isEmpty ? null : _tradeNameController.text.trim(),
      gstin: _gstinController.text.trim().isEmpty ? null : _gstinController.text.trim(),
      phone: _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim(),
      email: _emailController.text.trim().isEmpty ? null : _emailController.text.trim(),
      paymentTermsDays: int.tryParse(_paymentTermsController.text.trim()) ?? 0,
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
              gradient: AppColors.gradientAmber,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _isEdit ? Icons.edit_note_rounded : Icons.add_business_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Text(_isEdit ? 'Edit Supplier' : 'Add Supplier', style: AppTypography.headline.copyWith(fontSize: 18)),
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
                  key: const Key('supplier_code_field_readonly'),
                  controller: _codeController,
                  enabled: false,
                  decoration: const InputDecoration(
                    labelText: 'Supplier Code (cannot be changed)',
                    prefixIcon: Icon(Icons.lock_outline_rounded, size: 18),
                  ),
                ),
                const SizedBox(height: 12),
              ] else
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Icon(Icons.auto_awesome_rounded, size: 14, color: AppColors.textSecondary),
                      SizedBox(width: 6),
                      Text('Supplier code is generated automatically', style: AppTypography.caption),
                    ],
                  ),
                ),
              TextFormField(
                key: const Key('supplier_name_field'),
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Legal Name',
                  prefixIcon: Icon(Icons.business_rounded, size: 18),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('supplier_trade_name_field'),
                controller: _tradeNameController,
                decoration: const InputDecoration(
                  labelText: 'Trade Name (optional)',
                  prefixIcon: Icon(Icons.storefront_rounded, size: 18),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('supplier_gstin_field'),
                controller: _gstinController,
                decoration: const InputDecoration(
                  labelText: 'GSTIN (optional)',
                  prefixIcon: Icon(Icons.verified_user_rounded, size: 18),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('supplier_phone_field'),
                controller: _phoneController,
                decoration: const InputDecoration(
                  labelText: 'Phone (optional)',
                  prefixIcon: Icon(Icons.phone_rounded, size: 18),
                ),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('supplier_email_field'),
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email (optional)',
                  prefixIcon: Icon(Icons.email_rounded, size: 18),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('supplier_payment_terms_field'),
                controller: _paymentTermsController,
                decoration: const InputDecoration(
                  labelText: 'Payment Terms (days)',
                  prefixIcon: Icon(Icons.schedule_rounded, size: 18),
                ),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final n = int.tryParse((v ?? '').trim());
                  if (n == null || n < 0) return 'Enter a non-negative number';
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('supplier_form_submit'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.warning,
            foregroundColor: Colors.white,
          ),
          onPressed: _submit,
          child: Text(_isEdit ? 'Save' : 'Add', style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}
