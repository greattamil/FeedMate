import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../pos/pos_api.dart';
import 'returns_api.dart';
import '../../core/number_format.dart';

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
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.successContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 24),
              ),
              const SizedBox(width: 12),
              const Text('Return Posted'),
            ],
          ),
          content: Text(
            'Return ${result.returnNumber} was posted.\nRefund: ${money(result.totalRefund)} via $_refundMethod',
            style: const TextStyle(height: 1.4),
          ),
          actions: [
            FilledButton(
              key: const Key('return_posted_ok_button'),
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
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
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Sales Return & Refund'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Search Invoice Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: AppDecorations.card(color: AppColors.surface),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.dangerContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.assignment_return_rounded, color: AppColors.danger, size: 20),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Lookup Past Invoice',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          Text(
                            'Enter bill / invoice number printed on the customer receipt',
                            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('return_invoice_number_field'),
                        controller: _invoiceNumberController,
                        decoration: const InputDecoration(
                          hintText: 'e.g. INV-2026-0014',
                          labelText: 'Invoice number',
                          prefixIcon: Icon(Icons.receipt_long_rounded, size: 20),
                        ),
                        onSubmitted: (_) => _lookUp(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      key: const Key('return_lookup_button'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      ),
                      onPressed: _lookingUp ? null : _lookUp,
                      icon: _lookingUp
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.search_rounded, size: 18),
                      label: Text(_lookingUp ? 'Searching...' : 'Look Up'),
                    ),
                  ],
                ),
              ],
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.dangerContainer,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.dangerLight),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],

          if (_invoice != null) ...[
            const SizedBox(height: 20),
            // Invoice Summary Hero Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: AppColors.gradientDark,
                borderRadius: BorderRadius.circular(16),
                boxShadow: AppDecorations.cardShadow,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.receipt_rounded, color: Colors.white70, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            'Invoice ${_invoice!.invoiceNumber}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.primaryLight.withAlpha(50),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: AppColors.primaryLight.withAlpha(100)),
                        ),
                        child: Text(
                          money(_invoice!.grandTotal),
                          key: const Key('return_invoice_summary'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_invoice!.lines.length} original item(s) · Select lines to return below',
                    style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 13),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 18),
            Row(
              children: [
                const Icon(Icons.inventory_2_rounded, size: 18, color: AppColors.primary),
                const SizedBox(width: 8),
                const Text(
                  'Select Items to Return',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                ),
                const Spacer(),
                Text(
                  '${_lineStates.length} eligible',
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (_lineStates.isEmpty)
              Container(
                padding: const EdgeInsets.all(24),
                decoration: AppDecorations.card(color: AppColors.surface),
                child: const Center(
                  child: Text(
                    'Nothing left on this invoice is eligible to return.',
                    style: TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                  ),
                ),
              )
            else
              ..._lineStates.map(_buildLineCard),

            const SizedBox(height: 20),
            // Refund Details Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: AppDecorations.card(color: AppColors.surface),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Refund & Reason',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    key: const Key('return_reason_field'),
                    controller: _reasonController,
                    decoration: const InputDecoration(
                      labelText: 'Reason (optional)',
                      hintText: 'e.g. Damaged bag, wrong feed purchased',
                      prefixIcon: Icon(Icons.notes_rounded, size: 20),
                    ),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    key: const Key('return_refund_method_dropdown'),
                    initialValue: _refundMethod,
                    decoration: const InputDecoration(
                      labelText: 'Refund method',
                      prefixIcon: Icon(Icons.payments_rounded, size: 20),
                    ),
                    items: _refundMethods
                        .map((m) => DropdownMenuItem(
                              value: m,
                              child: Row(
                                children: [
                                  Icon(
                                    m == 'CASH'
                                        ? Icons.money_rounded
                                        : m == 'UPI'
                                            ? Icons.qr_code_rounded
                                            : Icons.receipt_long_rounded,
                                    size: 18,
                                    color: AppColors.textSecondary,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(m, style: const TextStyle(fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _refundMethod = v ?? 'CASH'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),
            FilledButton.icon(
              key: const Key('return_post_button'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.danger,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _canPost ? _post : null,
              icon: _posting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.check_circle_outline_rounded, size: 20),
              label: Text(
                _posting ? 'Posting Return...' : 'Post Return',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }

  Widget _buildLineCard(_LineState l) {
    return Container(
      key: Key('return_line_card_${l.original.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: AppDecorations.card(color: AppColors.surface),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.inventory_rounded, color: AppColors.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.original.productName,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    Text(
                      '${l.original.sku} · Sold ${l.original.quantity.toStringAsFixed(3)} · Already returned ${l.original.alreadyReturned.toStringAsFixed(3)} · Eligible ${l.original.remainingEligible.toStringAsFixed(3)}',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Progress & counts pill bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surfaceSecondary,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _statMini('Sold', l.original.quantity.toStringAsFixed(3), AppColors.textPrimary),
                _statMini('Returned', l.original.alreadyReturned.toStringAsFixed(3), AppColors.danger),
                _statMini('Eligible', l.original.remainingEligible.toStringAsFixed(3), AppColors.success),
              ],
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            key: Key('return_qty_field_${l.original.id}'),
            controller: l.qtyController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Quantity to return',
              hintText: 'Max: ${l.original.remainingEligible.toStringAsFixed(3)}',
              prefixIcon: const Icon(Icons.calculate_rounded, size: 20),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: Key('return_condition_dropdown_${l.original.id}'),
            initialValue: l.conditionStatus,
            decoration: const InputDecoration(
              labelText: 'Condition',
              prefixIcon: Icon(Icons.health_and_safety_rounded, size: 20),
            ),
            items: _conditionOptions
                .map((c) => DropdownMenuItem(
                      value: c,
                      child: Text(c, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ))
                .toList(),
            onChanged: (v) => setState(() => l.conditionStatus = v ?? 'SELLABLE'),
          ),
          if (l.conditionStatus != 'SELLABLE') ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: Key('return_restock_location_dropdown_${l.original.id}'),
              initialValue: l.restockLocationId,
              decoration: const InputDecoration(
                labelText: 'Quarantine location',
                prefixIcon: Icon(Icons.warehouse_rounded, size: 20, color: AppColors.warning),
              ),
              items: _locations.map((loc) => DropdownMenuItem(value: loc.id, child: Text(loc.name))).toList(),
              onChanged: (v) => setState(() => l.restockLocationId = v),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statMini(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
        Text(
          value,
          style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13),
        ),
      ],
    );
  }
}

