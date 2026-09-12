import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import 'supplier_api.dart';

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

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(title: Text(detail?.name ?? 'Supplier')),
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
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(detail.supplierCode, style: const TextStyle(color: Colors.grey)),
              if (detail.phone != null) Text(detail.phone!),
              if (detail.gstin != null) Text('GSTIN: ${detail.gstin}'),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Outstanding Payable', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      Text(
                        '₹${detail.outstandingPayable.toStringAsFixed(2)}',
                        key: const Key('supplier_outstanding_payable'),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Payment Terms', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      Text('${detail.paymentTermsDays} days',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLedgerTile(SupplierLedgerEntry e) {
    // A credit increases the payable (e.g. a GRN); a debit decreases it (a
    // payment) — the opposite convention from a customer ledger entry.
    final isCredit = e.credit > Decimal.zero;
    return ListTile(
      key: Key('supplier_ledger_entry_${e.id}'),
      leading: Icon(
        isCredit ? Icons.arrow_upward : Icons.arrow_downward,
        color: isCredit ? Colors.red : Colors.green,
      ),
      title: Text(e.description ?? e.documentType),
      subtitle: Text('${e.documentType} · ${_dateFormat.format(e.entryDate.toLocal())}'),
      trailing: Text(
        isCredit ? '+₹${e.credit.toStringAsFixed(2)}' : '-₹${e.debit.toStringAsFixed(2)}',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: isCredit ? Colors.red : Colors.green,
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
