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
    final limit = detail.creditLimit > Decimal.zero ? detail.creditLimit : Decimal.one;
    final ratio = (detail.outstandingBalance / limit).toDouble().clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        decoration: BoxDecoration(
          gradient: overLimit
              ? const LinearGradient(colors: [Color(0xFF881337), Color(0xFFE11D48)])
              : const LinearGradient(colors: [Color(0xFF0F766E), Color(0xFF065F46)]),
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(color: Color(0x200F172A), blurRadius: 20, offset: Offset(0, 6)),
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
                    '${detail.customerCode} · ${detail.customerType}',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                if (detail.phone != null)
                  Row(
                    children: [
                      const Icon(Icons.phone_outlined, size: 14, color: Colors.white70),
                      const SizedBox(width: 4),
                      Text(detail.phone!, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _summaryStat('Outstanding', detail.outstandingBalance,
                    key: 'khata_outstanding_balance',
                    color: Colors.white),
                _summaryStat('Credit Limit', detail.creditLimit,
                    key: 'khata_credit_limit',
                    color: Colors.white70),
                _summaryStat('Available', detail.availableCredit,
                    key: 'khata_available_credit',
                    color: Colors.white70),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 6,
                backgroundColor: Colors.white.withOpacity(0.25),
                valueColor: AlwaysStoppedAnimation<Color>(
                  overLimit ? const Color(0xFFFDE047) : const Color(0xFF6EE7B7),
                ),
              ),
            ),
            if (overLimit)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.yellowAccent.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'Over credit limit',
                    style: TextStyle(color: Color(0xFFFEF08A), fontSize: 12, fontWeight: FontWeight.bold),
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
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.w500)),
        const SizedBox(height: 2),
        Text(
          '₹${value.toStringAsFixed(2)}',
          key: Key(key),
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: color ?? Colors.white),
        ),
      ],
    );
  }

  Widget _buildLedgerTile(LedgerEntry e) {
    final isDebit = e.debit > Decimal.zero;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: ListTile(
        key: Key('khata_ledger_entry_${e.id}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: isDebit ? const Color(0xFFFFE4E6) : const Color(0xFFD1FAE5),
            shape: BoxShape.circle,
          ),
          child: Icon(
            isDebit ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            color: isDebit ? const Color(0xFFE11D48) : const Color(0xFF059669),
            size: 20,
          ),
        ),
        title: Text(e.description ?? e.documentType, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        subtitle: Text(
          '${e.documentType} · ${_dateFormat.format(e.entryDate.toLocal())}',
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
        ),
        trailing: Text(
          isDebit ? '+₹${e.debit.toStringAsFixed(2)}' : '-₹${e.credit.toStringAsFixed(2)}',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 15,
            color: isDebit ? const Color(0xFFE11D48) : const Color(0xFF059669),
          ),
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
