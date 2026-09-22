import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/auth_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import '../pos/customer_api.dart';
import 'customer_form_dialog.dart';
import 'receipt_api.dart';
import '../../core/number_format.dart';

/// A customer's ledger: current credit position plus the itemized history
/// behind it, and the full CRUD actions for their master record (edit,
/// deactivate/reactivate).
class CustomerLedgerScreen extends StatefulWidget {
  final String customerId;
  const CustomerLedgerScreen({super.key, required this.customerId});

  @override
  State<CustomerLedgerScreen> createState() => _CustomerLedgerScreenState();
}

class _CustomerLedgerScreenState extends State<CustomerLedgerScreen> {
  CustomerDetail? _detail;
  List<LedgerEntry> _entries = [];
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
      final api = CustomerApi(context.read<ApiClient>());
      final detail = await api.getDetail(widget.customerId);
      final entries = await api.getLedger(widget.customerId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _entries = entries;
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

  Future<void> _recordReceipt() async {
    final result = await showDialog<_ReceiptFormResult>(
      context: context,
      builder: (context) => const _RecordReceiptDialog(),
    );
    if (result == null) return;

    try {
      final api = ReceiptApi(context.read<ApiClient>());
      final receiptResult = await api.recordReceipt(
        customerId: widget.customerId,
        amount: result.amount,
        method: result.method,
        reference: result.reference,
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(receiptResult.duplicate
            ? 'This receipt was already recorded'
            : 'Receipt of ${money(result.amount)} recorded'),
      ));
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _editCreditLimit() async {
    final detail = _detail;
    if (detail == null) return;
    final newLimit = await showDialog<Decimal>(
      context: context,
      builder: (context) => _EditCreditLimitDialog(currentLimit: detail.creditLimit),
    );
    if (newLimit == null) return;

    try {
      final api = CustomerApi(context.read<ApiClient>());
      await api.setCreditLimit(widget.customerId, newLimit);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Credit limit updated to ${money(newLimit)}'),
      ));
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _editCustomer() async {
    final detail = _detail;
    if (detail == null) return;
    final result = await showDialog<CustomerFormResult>(
      context: context,
      builder: (context) => CustomerFormDialog(existing: detail),
    );
    if (result == null) return;

    try {
      final api = CustomerApi(context.read<ApiClient>());
      await api.update(
        customerId: widget.customerId,
        name: result.name,
        localName: result.localName,
        phone: result.phone,
        email: result.email,
        gstin: result.gstin,
        customerType: result.customerType,
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Customer updated')));
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _toggleActive() async {
    final detail = _detail;
    if (detail == null) return;
    final makeActive = !detail.active;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(makeActive ? 'Reactivate Customer?' : 'Deactivate Customer?', style: AppTypography.headline),
        content: Text(makeActive
            ? '${detail.name} will be available again for new sales and credit.'
            : '${detail.name} will be hidden from customer pickers. Existing invoices and ledger history are unaffected.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('customer_toggle_active_confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: makeActive ? AppColors.success : AppColors.danger,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(makeActive ? 'Reactivate' : 'Deactivate'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final api = CustomerApi(context.read<ApiClient>());
      await api.setActive(widget.customerId, makeActive);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(makeActive ? 'Customer reactivated' : 'Customer deactivated')),
      );
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final session = context.watch<AuthSession>();
    final canManage = session.hasPermission('credit.configure');

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(detail?.name ?? 'Customer Ledger', style: AppTypography.headline),
        actions: [
          if (detail != null && canManage) ...[
            IconButton(
              key: const Key('edit_customer_button'),
              onPressed: _editCustomer,
              icon: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.secondary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.edit_rounded, color: AppColors.secondary, size: 18),
              ),
              tooltip: 'Edit Customer',
            ),
            IconButton(
              key: const Key('edit_credit_limit_button'),
              onPressed: _editCreditLimit,
              icon: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.edit_note_rounded, color: AppColors.primary, size: 18),
              ),
              tooltip: 'Edit Credit Limit',
            ),
            IconButton(
              key: const Key('toggle_customer_active_button'),
              onPressed: _toggleActive,
              icon: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: (detail.active ? AppColors.danger : AppColors.success).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  detail.active ? Icons.block_rounded : Icons.check_circle_outline_rounded,
                  color: detail.active ? AppColors.danger : AppColors.success,
                  size: 18,
                ),
              ),
              tooltip: detail.active ? 'Deactivate Customer' : 'Reactivate Customer',
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
      floatingActionButton: detail == null
          ? null
          : Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: AppDecorations.emeraldGlow,
              ),
              child: FloatingActionButton.extended(
                heroTag: null,
                key: const Key('record_receipt_fab'),
                onPressed: _recordReceipt,
                icon: const Icon(Icons.receipt_long_rounded, color: Colors.white),
                label: const Text('Record Receipt', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                backgroundColor: AppColors.primary,
              ),
            ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
            : _error != null
                ? ListView(children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.dangerContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer)),
                      ),
                    ),
                  ])
                : ListView(
                    padding: const EdgeInsets.only(bottom: 96),
                    children: [
                      if (detail != null) _buildSummaryCard(detail),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Row(
                          children: [
                            const Icon(Icons.history_rounded, size: 16, color: AppColors.textSecondary),
                            const SizedBox(width: 6),
                            Text(
                              'LEDGER TRANSACTIONS (${_entries.length})',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.8,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_entries.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(Icons.receipt_outlined, size: 48, color: AppColors.textTertiary),
                                SizedBox(height: 12),
                                Text('No ledger entries yet', style: AppTypography.bodySecondary),
                              ],
                            ),
                          ),
                        )
                      else
                        ..._entries.map(_buildLedgerTile),
                    ],
                  ),
      ),
    );
  }

  Widget _buildSummaryCard(CustomerDetail detail) {
    final overLimit = detail.outstandingBalance > detail.creditLimit;
    final limit = detail.creditLimit > Decimal.zero ? detail.creditLimit : Decimal.one;
    final ratio = (detail.outstandingBalance / limit).toDouble().clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          gradient: overLimit ? AppColors.gradientRose : AppColors.gradientIndigo,
          borderRadius: BorderRadius.circular(20),
          boxShadow: overLimit ? AppDecorations.roseGlow : AppDecorations.indigoGlow,
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  key: const Key('customer_status_badge'),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
                  ),
                  child: Text(
                    '${detail.customerCode} · ${detail.customerType}${detail.active ? '' : ' · INACTIVE'}',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
                if (detail.phone != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.phone_rounded, size: 12, color: Colors.white),
                        const SizedBox(width: 4),
                        Text(detail.phone!, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _summaryStat('Outstanding', detail.outstandingBalance,
                    key: 'customer_outstanding_balance',
                    color: Colors.white),
                _summaryStat('Credit Limit', detail.creditLimit,
                    key: 'customer_credit_limit',
                    color: Colors.white.withValues(alpha: 0.85)),
                _summaryStat('Available', detail.availableCredit,
                    key: 'customer_available_credit',
                    color: Colors.white.withValues(alpha: 0.85)),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 8,
                backgroundColor: Colors.white.withValues(alpha: 0.25),
                valueColor: AlwaysStoppedAnimation<Color>(
                  overLimit ? const Color(0xFFFDE047) : const Color(0xFF6EE7B7),
                ),
              ),
            ),
            if (overLimit)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.yellowAccent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.yellowAccent.withValues(alpha: 0.3)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xFFFEF08A)),
                      SizedBox(width: 6),
                      Text(
                        'Over credit limit',
                        style: TextStyle(color: Color(0xFFFEF08A), fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _summaryStat(String label, Decimal value, {required String key, Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 10,
            color: Colors.white.withValues(alpha: 0.75),
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          money(value),
          key: Key(key),
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 18,
            color: color ?? Colors.white,
            letterSpacing: -0.2,
          ),
        ),
      ],
    );
  }

  Widget _buildLedgerTile(LedgerEntry e) {
    final isDebit = e.debit > Decimal.zero;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        boxShadow: AppDecorations.cardShadow,
      ),
      child: ListTile(
        key: Key('customer_ledger_entry_${e.id}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: isDebit ? AppColors.dangerContainer : AppColors.successContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            isDebit ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            color: isDebit ? AppColors.danger : AppColors.success,
            size: 20,
          ),
        ),
        title: Text(
          e.description ?? e.documentType,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        subtitle: Row(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.surfaceSecondary,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                e.documentType,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppColors.textSecondary),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _dateFormat.format(e.entryDate.toLocal()),
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
            ),
          ],
        ),
        trailing: Text(
          isDebit ? '+${money(e.debit)}' : '-${money(e.credit)}',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 16,
            color: isDebit ? AppColors.danger : AppColors.success,
          ),
        ),
      ),
    );
  }
}

/// Dialog for revising a customer's credit ceiling
class _EditCreditLimitDialog extends StatefulWidget {
  final Decimal currentLimit;
  const _EditCreditLimitDialog({required this.currentLimit});

  @override
  State<_EditCreditLimitDialog> createState() => _EditCreditLimitDialogState();
}

class _EditCreditLimitDialogState extends State<_EditCreditLimitDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentLimit.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = Decimal.tryParse(_controller.text.trim());
    if (value == null || value < Decimal.zero) {
      setState(() => _error = 'Enter a valid, non-negative amount');
      return;
    }
    Navigator.of(context).pop(value);
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
              gradient: AppColors.gradientIndigo,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.edit_note_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          const Text('Edit Credit Limit', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('credit_limit_field'),
            controller: _controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'New credit limit (₹)',
              prefixIcon: const Icon(Icons.currency_rupee_rounded, size: 18, color: AppColors.primary),
              filled: true,
              fillColor: AppColors.surfaceSecondary,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.primary, width: 1.5)),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('credit_limit_submit_button'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ReceiptFormResult {
  final Decimal amount;
  final String method;
  final String? reference;

  _ReceiptFormResult({required this.amount, required this.method, this.reference});
}

/// Dialog to record an in-person payment receipt
class _RecordReceiptDialog extends StatefulWidget {
  const _RecordReceiptDialog();

  @override
  State<_RecordReceiptDialog> createState() => _RecordReceiptDialogState();
}

class _RecordReceiptDialogState extends State<_RecordReceiptDialog> {
  final _amountController = TextEditingController();
  final _referenceController = TextEditingController();
  String _method = 'CASH';
  String? _error;

  @override
  void dispose() {
    _amountController.dispose();
    _referenceController.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = Decimal.tryParse(_amountController.text.trim());
    if (amount == null || amount <= Decimal.zero) {
      setState(() => _error = 'Enter a valid amount greater than zero');
      return;
    }
    Navigator.of(context).pop(_ReceiptFormResult(
      amount: amount,
      method: _method,
      reference: _referenceController.text.trim(),
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
              gradient: AppColors.gradientEmerald,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.receipt_long_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          const Text('Record Receipt', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('receipt_amount_field'),
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Amount received (₹)',
              prefixIcon: const Icon(Icons.currency_rupee_rounded, size: 18, color: AppColors.primary),
              filled: true,
              fillColor: AppColors.surfaceSecondary,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.primary, width: 1.5)),
            ),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            key: const Key('receipt_method_dropdown'),
            initialValue: _method,
            decoration: InputDecoration(
              labelText: 'Payment Method',
              prefixIcon: const Icon(Icons.payment_rounded, size: 18, color: AppColors.primary),
              filled: true,
              fillColor: AppColors.surfaceSecondary,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.primary, width: 1.5)),
            ),
            items: const [
              DropdownMenuItem(value: 'CASH', child: Text('Cash')),
              DropdownMenuItem(value: 'BANK', child: Text('Bank Transfer')),
              DropdownMenuItem(value: 'OTHER', child: Text('Other')),
            ],
            onChanged: (value) => setState(() => _method = value ?? 'CASH'),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('receipt_reference_field'),
            controller: _referenceController,
            decoration: InputDecoration(
              labelText: 'Reference / note (optional)',
              prefixIcon: const Icon(Icons.notes_rounded, size: 18, color: AppColors.primary),
              filled: true,
              fillColor: AppColors.surfaceSecondary,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.primary, width: 1.5)),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('receipt_submit_button'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: _submit,
          child: const Text('Record'),
        ),
      ],
    );
  }
}
