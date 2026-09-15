import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/auth_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import '../pos/customer_api.dart';
import 'khata_detail_screen.dart';

/// Modernized Customer Directory for Khata Ledger.
class KhataCustomerListScreen extends StatefulWidget {
  const KhataCustomerListScreen({super.key});

  @override
  State<KhataCustomerListScreen> createState() => _KhataCustomerListScreenState();
}

class _KhataCustomerListScreenState extends State<KhataCustomerListScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<CustomerSummary> _results = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search('');
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
      final api = CustomerApi(context.read<ApiClient>());
      final results = await api.search(query);
      if (!mounted) return;
      setState(() {
        _results = results;
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

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _addCustomer() async {
    final draft = await showDialog<_CustomerFormResult>(
      context: context,
      builder: (context) => const _CustomerFormDialog(),
    );
    if (draft == null) return;

    try {
      final api = CustomerApi(context.read<ApiClient>());
      await api.create(
        customerCode: draft.customerCode,
        name: draft.name,
        phone: draft.phone,
        customerType: draft.customerType,
        creditLimit: draft.creditLimit,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${draft.name} added to Khata directory')),
      );
      await _search(_controller.text);
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AuthSession>();
    final canManage = session.hasPermission('credit.configure');
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Customer Khata Directory', style: AppTypography.headline),
      ),
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              key: const Key('add_customer_fab'),
              onPressed: _addCustomer,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('Add Customer'),
              backgroundColor: AppColors.primary,
            )
          : null,
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: AppColors.surface,
            child: TextField(
              key: const Key('khata_search_field'),
              controller: _controller,
              decoration: InputDecoration(
                labelText: 'Search farmer by name, code, or phone',
                prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () {
                          _controller.clear();
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
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.dangerContainer,
                borderRadius: AppDecorations.borderRadiusSm,
              ),
              child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer)),
            ),
          Expanded(
            child: _results.isEmpty && !_loading
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.people_outline_rounded, size: 56, color: Color(0xFF94A3B8)),
                        SizedBox(height: 12),
                        Text('No customers found', style: AppTypography.bodySecondary),
                      ],
                    ),
                  )
                : ListView.builder(
                    key: const Key('khata_results_list'),
                    padding: const EdgeInsets.all(12),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final c = _results[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: AppDecorations.borderRadiusMd,
                          border: Border.all(color: AppColors.border),
                          boxShadow: AppDecorations.cardShadow,
                        ),
                        child: ListTile(
                          key: Key('khata_customer_${c.id}'),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          leading: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              gradient: AppColors.gradientIndigo,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Center(
                              child: Text(
                                c.name.isNotEmpty ? c.name.substring(0, 1).toUpperCase() : 'K',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                              ),
                            ),
                          ),
                          title: Text(c.name, style: AppTypography.title),
                          subtitle: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceSecondary,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(c.customerCode, style: AppTypography.caption),
                              ),
                              if (c.phone != null) ...[
                                const SizedBox(width: 8),
                                const Icon(Icons.phone_outlined, size: 12, color: AppColors.textSecondary),
                                const SizedBox(width: 4),
                                // Flexible + ellipsis: the trailing balance
                                // badge (e.g. "₹103000.00 Due") can be wide
                                // enough to squeeze this row below the
                                // phone number's natural width, which would
                                // otherwise overflow the tile on the right
                                // (caught live on the emulator).
                                Flexible(
                                  child: Text(c.phone!, style: AppTypography.caption, overflow: TextOverflow.ellipsis),
                                ),
                              ],
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _balanceBadge(c.balance),
                              const SizedBox(width: 4),
                              const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.textSecondary),
                            ],
                          ),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => KhataDetailScreen(customerId: c.id)),
                            );
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// A shopkeeper browsing this directory wants to see who owes money
  /// without opening each customer individually — a red "Due" pill for an
  /// outstanding balance, a neutral "Clear" pill otherwise. Never a
  /// client-side computation: c.balance already came straight from the
  /// server's ledger aggregate (see customer.List's SQL).
  Widget _balanceBadge(Decimal balance) {
    final isDue = balance > Decimal.zero;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isDue ? AppColors.dangerContainer : AppColors.successContainer,
        borderRadius: BorderRadius.circular(AppDecorations.radiusFull),
      ),
      child: Text(
        isDue ? '₹${balance.toStringAsFixed(2)} Due' : 'Clear',
        style: AppTypography.caption.copyWith(
          fontWeight: FontWeight.bold,
          color: isDue ? AppColors.onDangerContainer : AppColors.onSuccessContainer,
        ),
      ),
    );
  }
}

class _CustomerFormResult {
  final String customerCode;
  final String name;
  final String? phone;
  final String customerType;
  final Decimal? creditLimit;

  _CustomerFormResult({
    required this.customerCode,
    required this.name,
    this.phone,
    required this.customerType,
    this.creditLimit,
  });
}

class _CustomerFormDialog extends StatefulWidget {
  const _CustomerFormDialog();

  @override
  State<_CustomerFormDialog> createState() => _CustomerFormDialogState();
}

class _CustomerFormDialogState extends State<_CustomerFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _creditLimitController = TextEditingController();
  String _customerType = 'RETAIL';

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _creditLimitController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      _CustomerFormResult(
        customerCode: _codeController.text.trim(),
        name: _nameController.text.trim(),
        phone: _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim(),
        customerType: _customerType,
        creditLimit: _creditLimitController.text.trim().isEmpty
            ? null
            : Decimal.parse(_creditLimitController.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Customer', style: AppTypography.headline),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('customer_code_field'),
                controller: _codeController,
                decoration: const InputDecoration(labelText: 'Customer Code'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
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
                key: const Key('customer_phone_field'),
                controller: _phoneController,
                decoration: const InputDecoration(labelText: 'Phone (optional)'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('customer_type_field'),
                initialValue: _customerType,
                decoration: const InputDecoration(labelText: 'Customer Type'),
                items: const [
                  DropdownMenuItem(value: 'RETAIL', child: Text('Retail')),
                  DropdownMenuItem(value: 'WHOLESALE', child: Text('Wholesale')),
                  DropdownMenuItem(value: 'FARMER', child: Text('Farmer')),
                ],
                onChanged: (v) => setState(() => _customerType = v ?? 'RETAIL'),
              ),
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
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('customer_form_submit'),
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
