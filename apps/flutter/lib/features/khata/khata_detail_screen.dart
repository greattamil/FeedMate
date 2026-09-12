import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../pos/customer_api.dart';
import 'receipt_api.dart';

/// A customer's Khata statement: current credit position plus the itemized
/// ledger behind it. The balance shown is always what the server just
/// computed from the ledger (never a locally-summed number) — see PRD 10.1:
/// the receivable balance is derived, not a separately maintained field.
class KhataDetailScreen extends StatefulWidget {
  final String customerId;
  const KhataDetailScreen({super.key, required this.customerId});

  @override
  State<KhataDetailScreen> createState() => _KhataDetailScreenState();
}

class _KhataDetailScreenState extends State<KhataDetailScreen> {
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
            : 'Receipt of ₹${result.amount.toStringAsFixed(2)} recorded'),
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
      appBar: AppBar(title: Text(detail?.name ?? 'Khata')),
      floatingActionButton: detail == null
          ? null
          : FloatingActionButton.extended(
              key: const Key('record_receipt_fab'),
              onPressed: _recordReceipt,
              icon: const Icon(Icons.add),
              label: const Text('Record Receipt'),
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

  Widget _buildSummaryCard(CustomerDetail detail) {
    final overLimit = detail.outstandingBalance > detail.creditLimit;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${detail.customerCode} · ${detail.customerType}',
                  style: const TextStyle(color: Colors.grey)),
              if (detail.phone != null) Text(detail.phone!),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _summaryStat('Outstanding', detail.outstandingBalance,
                      key: 'khata_outstanding_balance',
                      color: overLimit ? Colors.red : null),
                  _summaryStat('Credit Limit', detail.creditLimit, key: 'khata_credit_limit'),
                  _summaryStat('Available', detail.availableCredit, key: 'khata_available_credit'),
                ],
              ),
              if (overLimit)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Over credit limit', style: TextStyle(color: Colors.red, fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summaryStat(String label, Decimal value, {required String key, Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        Text(
          '₹${value.toStringAsFixed(2)}',
          key: Key(key),
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color),
        ),
      ],
    );
  }

  Widget _buildLedgerTile(LedgerEntry e) {
    final isDebit = e.debit > Decimal.zero;
    return ListTile(
      key: Key('khata_ledger_entry_${e.id}'),
      leading: Icon(
        isDebit ? Icons.arrow_upward : Icons.arrow_downward,
        color: isDebit ? Colors.red : Colors.green,
      ),
      title: Text(e.description ?? e.documentType),
      subtitle: Text('${e.documentType} · ${_dateFormat.format(e.entryDate.toLocal())}'),
      trailing: Text(
        isDebit ? '+₹${e.debit.toStringAsFixed(2)}' : '-₹${e.credit.toStringAsFixed(2)}',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: isDebit ? Colors.red : Colors.green,
        ),
      ),
    );
  }
}

class _ReceiptFormResult {
  final Decimal amount;
  final String method;
  final String? reference;

  _ReceiptFormResult({required this.amount, required this.method, this.reference});
}

/// Collects the details for a receipt collected in person. This dialog only
/// gathers input — the server is what actually decides whether the amount
/// is valid and posts the ledger/journal entries (see ReceiptApi).
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
      title: const Text('Record Receipt'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('receipt_amount_field'),
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount received'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const Key('receipt_method_dropdown'),
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
            key: const Key('receipt_reference_field'),
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
          key: const Key('receipt_submit_button'),
          onPressed: _submit,
          child: const Text('Record'),
        ),
      ],
    );
  }
}
