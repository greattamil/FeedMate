import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../pos/pos_api.dart';
import 'returns_api.dart';

class _LineState {
  final InvoiceLineForReturn original;
  final TextEditingController qtyController = TextEditingController();
  String conditionStatus = 'SELLABLE';
  String? restockLocationId;

  _LineState(this.original);

  void dispose() => qtyController.dispose();
}

/// Post a sales return against a past invoice (PRD 9.7): look the invoice up
/// by its printed number, pick which lines (and how much of each) to
/// return, mark the condition of what's coming back (sellable goods restock
/// the original batch; anything else is quarantined at a chosen location),
/// and choose how the refund is issued. The server re-derives every
/// eligible quantity and re-validates from scratch — this screen only
/// collects what the cashier observed.
class ReturnScreen extends StatefulWidget {
  const ReturnScreen({super.key});

  @override
  State<ReturnScreen> createState() => _ReturnScreenState();
}

class _ReturnScreenState extends State<ReturnScreen> {
  static const _conditionOptions = ['SELLABLE', 'DAMAGED', 'EXPIRED', 'QUARANTINE', 'OTHER'];
  static const _refundMethods = ['CASH', 'UPI', 'CREDIT_NOTE'];

  final _invoiceNumberController = TextEditingController();
  final _reasonController = TextEditingController();
  InvoiceForReturn? _invoice;
  List<_LineState> _lineStates = [];
  List<LocationInfo> _locations = [];
  String _refundMethod = 'CASH';
  bool _lookingUp = false;
  bool _posting = false;
  String? _error;

  @override
  void dispose() {
    _invoiceNumberController.dispose();
    _reasonController.dispose();
    for (final l in _lineStates) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _lookUp() async {
    final number = _invoiceNumberController.text.trim();
    if (number.isEmpty) return;
    setState(() {
      _lookingUp = true;
      _error = null;
      _invoice = null;
    });
    try {
      final api = ReturnsApi(context.read<ApiClient>());
      final invoice = await api.lookupInvoice(number);
      final locations = await PosApi(context.read<ApiClient>()).listLocations();
      if (!mounted) return;
      for (final l in _lineStates) {
        l.dispose();
      }
      setState(() {
        _invoice = invoice;
        _locations = locations;
        _lineStates = invoice.lines
            .where((l) => l.remainingEligible > Decimal.zero)
            .map((l) => _LineState(l))
            .toList();
        _lookingUp = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _lookingUp = false;
      });
    }
  }

  bool get _canPost =>
      _invoice != null &&
      !_posting &&
      _lineStates.any((l) {
        final qty = Decimal.tryParse(l.qtyController.text.trim());
        return qty != null && qty > Decimal.zero;
      });

  Future<void> _post() async {
    final drafts = <ReturnLineDraft>[];
    for (final l in _lineStates) {
      final qty = Decimal.tryParse(l.qtyController.text.trim());
      if (qty == null || qty <= Decimal.zero) continue;
      if (qty > l.original.remainingEligible) {
        setState(() => _error =
            '${l.original.productName}: cannot return more than ${l.original.remainingEligible.toStringAsFixed(3)}');
        return;
      }
      if (l.conditionStatus != 'SELLABLE' && l.restockLocationId == null) {
        setState(() => _error = '${l.original.productName}: pick a quarantine location for a non-sellable return');
        return;
      }
      drafts.add(ReturnLineDraft(
        original: l.original,
        quantity: qty,
        conditionStatus: l.conditionStatus,
        restockLocationId: l.restockLocationId,
      ));
    }
    if (drafts.isEmpty) return;

    setState(() {
      _posting = true;
      _error = null;
    });
    try {
      final api = ReturnsApi(context.read<ApiClient>());
      final result = await api.postReturn(
        originalInvoiceId: _invoice!.id,
        reason: _reasonController.text.trim(),
        lines: drafts,
        refundMethod: _refundMethod,
      );
      if (!mounted) return;
      setState(() => _posting = false);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Return Posted'),
          content: Text(
              'Return ${result.returnNumber} was posted. Refund: ₹${result.totalRefund.toStringAsFixed(2)}'),
          actions: [
            TextButton(
              key: const Key('return_posted_ok_button'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      for (final l in _lineStates) {
        l.dispose();
      }
      setState(() {
        _invoice = null;
        _lineStates = [];
        _invoiceNumberController.clear();
        _reasonController.clear();
        _refundMethod = 'CASH';
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _posting = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sales Return')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('return_invoice_number_field'),
                  controller: _invoiceNumberController,
                  decoration: const InputDecoration(labelText: 'Invoice number'),
                  onSubmitted: (_) => _lookUp(),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                key: const Key('return_lookup_button'),
                onPressed: _lookingUp ? null : _lookUp,
                child: _lookingUp ? const CircularProgressIndicator() : const Text('Look Up'),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
          if (_invoice != null) ...[
            const Divider(height: 32),
            Text(
              'Invoice ${_invoice!.invoiceNumber} · ₹${_invoice!.grandTotal.toStringAsFixed(2)}',
              key: const Key('return_invoice_summary'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            if (_lineStates.isEmpty)
              const Text('Nothing left on this invoice is eligible to return.')
            else
              ..._lineStates.map(_buildLineCard),
            const Divider(height: 32),
            TextField(
              key: const Key('return_reason_field'),
              controller: _reasonController,
              decoration: const InputDecoration(labelText: 'Reason (optional)'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('return_refund_method_dropdown'),
              initialValue: _refundMethod,
              decoration: const InputDecoration(labelText: 'Refund method'),
              items: _refundMethods.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
              onChanged: (v) => setState(() => _refundMethod = v ?? 'CASH'),
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('return_post_button'),
              onPressed: _canPost ? _post : null,
              child: _posting ? const CircularProgressIndicator() : const Text('Post Return'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLineCard(_LineState l) {
    return Card(
      key: Key('return_line_card_${l.original.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.original.productName, style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(
                '${l.original.sku} · Sold ${l.original.quantity.toStringAsFixed(3)} · Already returned ${l.original.alreadyReturned.toStringAsFixed(3)} · Eligible ${l.original.remainingEligible.toStringAsFixed(3)}'),
            const SizedBox(height: 8),
            TextField(
              key: Key('return_qty_field_${l.original.id}'),
              controller: l.qtyController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Quantity to return'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: Key('return_condition_dropdown_${l.original.id}'),
              initialValue: l.conditionStatus,
              decoration: const InputDecoration(labelText: 'Condition'),
              items: _conditionOptions.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
              onChanged: (v) => setState(() => l.conditionStatus = v ?? 'SELLABLE'),
            ),
            if (l.conditionStatus != 'SELLABLE') ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: Key('return_restock_location_dropdown_${l.original.id}'),
                initialValue: l.restockLocationId,
                decoration: const InputDecoration(labelText: 'Quarantine location'),
                items: _locations.map((loc) => DropdownMenuItem(value: loc.id, child: Text(loc.name))).toList(),
                onChanged: (v) => setState(() => l.restockLocationId = v),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
