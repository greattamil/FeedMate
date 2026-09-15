import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_typography.dart';
import '../pos/customer_api.dart';

/// The fields a customer create/edit form collects. customer_code is only
/// present (and shown, read-only) when editing — see CustomerDetail server
/// contract, where the business key is immutable once assigned.
class CustomerFormResult {
  final String? customerCode;
  final String name;
  final String? localName;
  final String? phone;
  final String? email;
  final String? gstin;
  final String customerType;
  final Decimal? creditLimit;

  CustomerFormResult({
    this.customerCode,
    required this.name,
    this.localName,
    this.phone,
    this.email,
    this.gstin,
    required this.customerType,
    this.creditLimit,
  });
}

/// Shared create/edit dialog for customer master data. When [existing] is
/// null this collects a customer_code (returned on CustomerFormResult) and
/// an optional initial credit limit; when non-null the code is shown
/// read-only and credit limit is omitted (it's revised separately via the
/// dedicated "Edit Credit Limit" action on the ledger screen, the same
/// trust-sensitive action either way — see customer.Service.SetCreditLimit).
///
/// customerType must be one of the values the customers_customer_type_check
/// DB constraint actually allows (FARMER, WHOLESALE_DEALER,
/// AAVIN_SUBCONTRACTOR, OTHER — see customer.validCustomerTypes
/// server-side). An earlier version of this dialog offered "Retail" and
/// "Wholesale", neither of which the database accepts, which is why every
/// customer creation with the (then-)default selection failed with an
/// opaque internal error — fixed here by only ever offering values the
/// server will actually accept.
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

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(CustomerFormResult(
      customerCode: _isEdit ? null : _codeController.text.trim(),
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
      title: Text(_isEdit ? 'Edit Customer' : 'Add Customer', style: AppTypography.headline),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_isEdit)
                TextFormField(
                  key: const Key('customer_code_field'),
                  controller: _codeController,
                  decoration: const InputDecoration(labelText: 'Customer Code'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                )
              else
                TextFormField(
                  key: const Key('customer_code_field_readonly'),
                  controller: _codeController,
                  enabled: false,
                  decoration: const InputDecoration(labelText: 'Customer Code (cannot be changed)'),
                ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('customer_name_field'),
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('customer_local_name_field'),
                controller: _localNameController,
                decoration: const InputDecoration(labelText: 'Local Name (optional)'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('customer_phone_field'),
                controller: _phoneController,
                decoration: const InputDecoration(labelText: 'Phone (optional)'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('customer_email_field'),
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Email (optional)'),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('customer_gstin_field'),
                controller: _gstinController,
                decoration: const InputDecoration(labelText: 'GSTIN (optional)'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('customer_type_field'),
                initialValue: _customerType,
                decoration: const InputDecoration(labelText: 'Customer Type'),
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
                  decoration: const InputDecoration(labelText: 'Initial Credit Limit (optional)'),
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
          onPressed: _submit,
          child: Text(_isEdit ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}
