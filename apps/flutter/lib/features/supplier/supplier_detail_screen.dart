import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/auth_session.dart';
import 'supplier_api.dart';
import 'supplier_form_dialog.dart';

/// A supplier's payable statement — the mirror image of KhataDetailScreen:
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
            : 'Payment of ₹${result.amount.toStringAsFixed(2)} recorded'),
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
          : FloatingActionButton.extended(
              key: const Key('record_payment_fab'),
              onPressed: _recordPayment,
              icon: const Icon(Icons.add),
              label: const Text('Record Payment'),
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
                    // Bottom padding reserves room for the extended
                    // "Record Payment" FAB, which otherwise floats over
                    // the last ledger row and makes it hard to read.
                    padding: const EdgeInsets.only(bottom: 96),
                    children: [
                      if (detail != null) _buildSummaryCard(detail),
                      const Divider(height: 1),
                      if (_entries.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: Text('No ledger entries yet')),
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
      padding: const EdgeInsets.all(16),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF0369A1), Color(0xFF0284C7)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(color: Color(0x180F172A), blurRadius: 20, offset: Offset(0, 6)),
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    detail.supplierCode,
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                if (detail.gstin != null)
                  Text(
                    'GSTIN: ${detail.gstin}',
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
              ],
            ),
            if (detail.phone != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.phone_outlined, size: 14, color: Colors.white70),
                  const SizedBox(width: 4),
                  Text(detail.phone!, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Outstanding Payable', style: TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(
                      '₹${detail.outstandingPayable.toStringAsFixed(2)}',
                      key: const Key('supplier_outstanding_payable'),
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20, color: Colors.white),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('Payment Terms', style: TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(
                      '${detail.paymentTermsDays} days',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Colors.white),
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
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: ListTile(
        key: Key('supplier_ledger_entry_${e.id}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Container(
          width: 38,
          height: 38,
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
        title: Text(e.description ?? e.documentType, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        subtitle: Text(
          '${e.documentType} · ${_dateFormat.format(e.entryDate.toLocal())}',
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
        ),
        trailing: Text(
          isCredit ? '+₹${e.credit.toStringAsFixed(2)}' : '-₹${e.debit.toStringAsFixed(2)}',
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
    return AlertDialog(
      title: const Text('Record Payment'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('payment_amount_field'),
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount paid'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const Key('payment_method_dropdown'),
            initialValue: _method,
            decoration: const InputDecoration(labelText: 'Method'),
            items: const [
              DropdownMenuItem(value: 'CASH', child: Text('Cash')),
              DropdownMenuItem(value: 'BANK', child: Text('Bank Transfer')),
              DropdownMenuItem(value: 'OTHER', child: Text('Other')),
            ],
            onChanged: (value) => setState(() => _method = value ?? 'CASH'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('payment_reference_field'),
            controller: _referenceController,
            decoration: const InputDecoration(labelText: 'Reference / note (optional)'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('payment_submit_button'),
          onPressed: _submit,
          child: const Text('Record'),
        ),
      ],
    );
  }
}
