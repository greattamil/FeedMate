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
import 'supplier_api.dart';
import 'supplier_form_dialog.dart';
import '../../core/number_format.dart';

/// A supplier's payable statement — the mirror image of CustomerLedgerScreen:
/// a credit here increases what the shop owes the supplier (e.g. a GRN), a
/// debit decreases it (e.g. a payment). The balance shown always comes from
/// a fresh server computation, never a client-side running total.
class SupplierDetailScreen extends StatefulWidget {
  final String supplierId;
  const SupplierDetailScreen({super.key, required this.supplierId});

  @override
  State<SupplierDetailScreen> createState() => _SupplierDetailScreenState();
}

class _SupplierDetailScreenState extends State<SupplierDetailScreen> {
  SupplierDetail? _detail;
  List<SupplierLedgerEntry> _entries = [];
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
      final api = SupplierApi(context.read<ApiClient>());
      final detail = await api.getDetail(widget.supplierId);
      final entries = await api.getLedger(widget.supplierId);
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

  Future<void> _recordPayment() async {
    final result = await showDialog<_PaymentFormResult>(
      context: context,
      builder: (context) => const _RecordPaymentDialog(),
    );
    if (result == null) return;

    try {
      final api = SupplierApi(context.read<ApiClient>());
      final paymentResult = await api.recordPayment(
        supplierId: widget.supplierId,
        amount: result.amount,
        method: result.method,
        reference: result.reference,
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(paymentResult.duplicate
            ? 'This payment was already recorded'
            : 'Payment of ${money(result.amount)} recorded'),
      ));
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _editSupplier() async {
    final detail = _detail;
    if (detail == null) return;
    final result = await showDialog<SupplierFormResult>(
      context: context,
      builder: (context) => SupplierFormDialog(existing: detail),
    );
    if (result == null) return;

    try {
      final api = SupplierApi(context.read<ApiClient>());
      await api.update(
        supplierId: widget.supplierId,
        name: result.name,
        tradeName: result.tradeName,
        gstin: result.gstin,
        phone: result.phone,
        email: result.email,
        paymentTermsDays: result.paymentTermsDays,
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Supplier updated')));
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
        title: Text(makeActive ? 'Reactivate Supplier?' : 'Deactivate Supplier?'),
        content: Text(makeActive
            ? '${detail.name} will be available again for new purchases.'
            : '${detail.name} will be hidden from supplier pickers. Existing GRNs and payments are unaffected.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('supplier_toggle_active_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(makeActive ? 'Reactivate' : 'Deactivate'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final api = SupplierApi(context.read<ApiClient>());
      await api.setActive(widget.supplierId, makeActive);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(makeActive ? 'Supplier reactivated' : 'Supplier deactivated')),
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
    final canManage = session.hasPermission('supplier.manage');
    return Scaffold(
      appBar: AppBar(
        title: Text(detail?.name ?? 'Supplier'),
        actions: [
          if (detail != null && canManage) ...[
            IconButton(
              key: const Key('edit_supplier_button'),
              onPressed: _editSupplier,
              icon: const Icon(Icons.edit_note_rounded),
              tooltip: 'Edit Supplier',
            ),
            IconButton(
              key: const Key('toggle_supplier_active_button'),
              onPressed: _toggleActive,
              icon: Icon(detail.active ? Icons.block_rounded : Icons.check_circle_outline_rounded),
              tooltip: detail.active ? 'Deactivate Supplier' : 'Reactivate Supplier',
            ),
          ],
        ],
      ),
      floatingActionButton: detail == null
          ? null
          : Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: AppDecorations.amberGlow,
              ),
              child: FloatingActionButton.extended(
                heroTag: null,
                key: const Key('record_payment_fab'),
                onPressed: _recordPayment,
                icon: const Icon(Icons.add_card_rounded),
                label: const Text('Record Payment', style: TextStyle(fontWeight: FontWeight.w700)),
                backgroundColor: AppColors.warning,
                foregroundColor: Colors.white,
              ),
            ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? ListView(children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error!, style: const TextStyle(color: Colors.red)),
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
                            const Icon(Icons.receipt_long_rounded, size: 18, color: AppColors.textSecondary),
                            const SizedBox(width: 8),
                            Text('Ledger Statement', style: AppTypography.title.copyWith(fontSize: 15, fontWeight: FontWeight.w700)),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceSecondary,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AppColors.border),
                              ),
                              child: Text('${_entries.length} entries', style: AppTypography.caption.copyWith(fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                      ),
                      if (_entries.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: Text('No ledger entries yet', style: AppTypography.bodySecondary)),
                        )
                      else
                        ..._entries.map(_buildLedgerTile),
                    ],
                  ),
      ),
    );
  }

  Widget _buildSummaryCard(SupplierDetail detail) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          gradient: AppColors.gradientAmber,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: AppColors.warning.withOpacity(0.3),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white.withOpacity(0.25)),
                  ),
                  child: Text(
                    detail.supplierCode,
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
                if (detail.gstin != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'GSTIN: ${detail.gstin}',
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
            if (detail.phone != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.phone_rounded, size: 14, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(detail.phone!, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                ],
              ),
            ],
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Outstanding Payable',
                      style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.85), fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      money(detail.outstandingPayable),
                      key: const Key('supplier_outstanding_payable'),
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 24, color: Colors.white, letterSpacing: -0.5),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'Payment Terms',
                      style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.85), fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${detail.paymentTermsDays} days',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLedgerTile(SupplierLedgerEntry e) {
    // A credit increases the payable (e.g. a GRN); a debit decreases it (a
    // payment) — the opposite convention from a customer ledger entry.
    final isCredit = e.credit > Decimal.zero;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        boxShadow: AppDecorations.cardShadow,
      ),
      child: ListTile(
        key: Key('supplier_ledger_entry_${e.id}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isCredit ? const Color(0xFFFFE4E6) : const Color(0xFFD1FAE5),
            shape: BoxShape.circle,
          ),
          child: Icon(
            isCredit ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            color: isCredit ? const Color(0xFFE11D48) : const Color(0xFF059669),
            size: 20,
          ),
        ),
        title: Text(e.description ?? e.documentType, style: AppTypography.title.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: Row(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.surfaceSecondary,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(e.documentType, style: AppTypography.caption.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            Text(
              _dateFormat.format(e.entryDate.toLocal()),
              style: AppTypography.caption,
            ),
          ],
        ),
        trailing: Text(
          isCredit ? '+${money(e.credit)}' : '-${money(e.debit)}',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 15,
            color: isCredit ? const Color(0xFFE11D48) : const Color(0xFF059669),
          ),
        ),
      ),
    );
  }
}

class _PaymentFormResult {
  final Decimal amount;
  final String method;
  final String? reference;

  _PaymentFormResult({required this.amount, required this.method, this.reference});
}

class _RecordPaymentDialog extends StatefulWidget {
  const _RecordPaymentDialog();

  @override
  State<_RecordPaymentDialog> createState() => _RecordPaymentDialogState();
}

class _RecordPaymentDialogState extends State<_RecordPaymentDialog> {
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
    Navigator.of(context).pop(_PaymentFormResult(
      amount: amount,
      method: _method,
      reference: _referenceController.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: AppDecorations.borderRadiusLg),
      backgroundColor: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: AppColors.gradientAmber,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.payments_rounded, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Text(
                    'Record Payment',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            TextField(
              key: const Key('payment_amount_field'),
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Amount paid',
                prefixIcon: const Icon(Icons.currency_rupee_rounded, size: 18, color: AppColors.warning),
                border: OutlineInputBorder(borderRadius: AppDecorations.borderRadiusMd),
                enabledBorder: OutlineInputBorder(
                  borderRadius: AppDecorations.borderRadiusMd,
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: AppDecorations.borderRadiusMd,
                  borderSide: const BorderSide(color: AppColors.warning, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              key: const Key('payment_method_dropdown'),
              initialValue: _method,
              decoration: InputDecoration(
                labelText: 'Method',
                prefixIcon: const Icon(Icons.account_balance_wallet_rounded, size: 18, color: AppColors.warning),
                border: OutlineInputBorder(borderRadius: AppDecorations.borderRadiusMd),
                enabledBorder: OutlineInputBorder(
                  borderRadius: AppDecorations.borderRadiusMd,
                  borderSide: const BorderSide(color: AppColors.border),
                ),
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
              key: const Key('payment_reference_field'),
              controller: _referenceController,
              decoration: InputDecoration(
                labelText: 'Reference / note (optional)',
                prefixIcon: const Icon(Icons.notes_rounded, size: 18, color: AppColors.textSecondary),
                border: OutlineInputBorder(borderRadius: AppDecorations.borderRadiusMd),
                enabledBorder: OutlineInputBorder(
                  borderRadius: AppDecorations.borderRadiusMd,
                  borderSide: const BorderSide(color: AppColors.border),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('payment_submit_button'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.warning,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _submit,
                  child: const Text('Record', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
