import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../pos/product.dart';
import 'procurement_api.dart';

/// Full-screen form for one GRN line: batch/expiry, received quantity and
/// cost, quality status, and optional weight/tare capture (PRD A7 — tare
/// must always be an explicit method, never assumed). Pops with a completed
/// GRNLineDraft, or null if cancelled.
class GrnLineFormScreen extends StatefulWidget {
  final Product product;
  final GRNLineDraft? existing;

  const GrnLineFormScreen({super.key, required this.product, this.existing});

  @override
  State<GrnLineFormScreen> createState() => _GrnLineFormScreenState();
}

class _GrnLineFormScreenState extends State<GrnLineFormScreen> {
  static final _dateFormat = DateFormat('dd MMM yyyy');

  late final TextEditingController _batchController;
  late final TextEditingController _qtyController;
  late final TextEditingController _costController;
  late final TextEditingController _grossWeightController;
  late final TextEditingController _measuredTareController;
  late final TextEditingController _bagCountController;
  late final TextEditingController _standardTareController;

  DateTime? _manufactureDate;
  DateTime? _expiryDate;
  String _qualityStatus = 'ACCEPTED';
  bool _captureWeight = false;
  String _tareMethod = 'MEASURED';
  String? _error;

  static const _qualityOptions = ['ACCEPTED', 'REJECTED', 'DAMAGED', 'QUARANTINE'];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _batchController = TextEditingController(text: e?.batchCode ?? '');
    _qtyController = TextEditingController(text: e != null ? e.receivedQty.toStringAsFixed(2) : '');
    _costController = TextEditingController(text: e != null ? e.unitCost.toStringAsFixed(2) : '');
    _grossWeightController = TextEditingController(text: e?.grossWeightKg?.toStringAsFixed(2) ?? '');
    _measuredTareController = TextEditingController(text: e?.measuredTareKg?.toStringAsFixed(2) ?? '');
    _bagCountController = TextEditingController(text: e?.bagCount?.toString() ?? '');
    _standardTareController = TextEditingController(text: e?.standardTarePerBagKg?.toStringAsFixed(2) ?? '');
    _manufactureDate = e?.manufactureDate;
    _expiryDate = e?.expiryDate;
    _qualityStatus = e?.qualityStatus ?? 'ACCEPTED';
    _captureWeight = e?.captureWeight ?? false;
    _tareMethod = e?.tareMethod ?? 'MEASURED';
  }

  @override
  void dispose() {
    _batchController.dispose();
    _qtyController.dispose();
    _costController.dispose();
    _grossWeightController.dispose();
    _measuredTareController.dispose();
    _bagCountController.dispose();
    _standardTareController.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool isExpiry}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (isExpiry ? _expiryDate : _manufactureDate) ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 15),
    );
    if (picked == null) return;
    setState(() {
      if (isExpiry) {
        _expiryDate = picked;
      } else {
        _manufactureDate = picked;
      }
    });
  }

  void _save() {
    final qty = Decimal.tryParse(_qtyController.text.trim());
    final cost = Decimal.tryParse(_costController.text.trim());
    if (_batchController.text.trim().isEmpty) {
      setState(() => _error = 'Batch code is required');
      return;
    }
    if (qty == null || qty <= Decimal.zero) {
      setState(() => _error = 'Enter a valid received quantity greater than zero');
      return;
    }
    if (cost == null || cost < Decimal.zero) {
      setState(() => _error = 'Enter a valid unit cost');
      return;
    }

    Decimal? grossWeight;
    Decimal? measuredTare;
    int? bagCount;
    Decimal? standardTare;
    if (_captureWeight) {
      grossWeight = Decimal.tryParse(_grossWeightController.text.trim());
      if (grossWeight == null || grossWeight <= Decimal.zero) {
        setState(() => _error = 'Enter a valid gross weight (kg)');
        return;
      }
      if (_tareMethod == 'MEASURED') {
        measuredTare = Decimal.tryParse(_measuredTareController.text.trim());
        if (measuredTare == null || measuredTare < Decimal.zero) {
          setState(() => _error = 'Enter a valid measured tare (kg)');
          return;
        }
      } else {
        bagCount = int.tryParse(_bagCountController.text.trim());
        standardTare = Decimal.tryParse(_standardTareController.text.trim());
        if (bagCount == null || bagCount <= 0) {
          setState(() => _error = 'Enter a valid bag count');
          return;
        }
        if (standardTare == null || standardTare < Decimal.zero) {
          setState(() => _error = 'Enter a valid standard tare per bag (kg)');
          return;
        }
      }
    }

    Navigator.of(context).pop(GRNLineDraft(
      product: widget.product,
      batchCode: _batchController.text.trim(),
      manufactureDate: _manufactureDate,
      expiryDate: _expiryDate,
      receivedQty: qty,
      unitCost: cost,
      qualityStatus: _qualityStatus,
      captureWeight: _captureWeight,
      grossWeightKg: grossWeight,
      tareMethod: _tareMethod,
      measuredTareKg: measuredTare,
      bagCount: bagCount,
      standardTarePerBagKg: standardTare,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text(widget.product.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFE4E6),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(_error!, style: const TextStyle(color: Color(0xFFE11D48), fontSize: 13)),
            ),
          ],
          // Card 1: Batch & Dates
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('BATCH & VALIDITY', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 0.6)),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('grn_line_batch_code_field'),
                  controller: _batchController,
                  decoration: const InputDecoration(labelText: 'Batch code / lot no.', prefixIcon: Icon(Icons.tag_rounded, size: 18)),
                ),
                const SizedBox(height: 12),
                ListTile(
                  key: const Key('grn_line_mfg_date_tile'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today_rounded, color: Color(0xFF0F766E), size: 20),
                  title: const Text('Manufacture Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  subtitle: Text(_manufactureDate == null ? 'Tap to set' : _dateFormat.format(_manufactureDate!), style: const TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: Color(0xFF64748B)),
                  onTap: () => _pickDate(isExpiry: false),
                ),
                const Divider(height: 1),
                ListTile(
                  key: const Key('grn_line_expiry_date_tile'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_busy_rounded, color: Color(0xFFE11D48), size: 20),
                  title: const Text('Expiry Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  subtitle: Text(_expiryDate == null ? 'Tap to set' : _dateFormat.format(_expiryDate!), style: const TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: Color(0xFF64748B)),
                  onTap: () => _pickDate(isExpiry: true),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // Card 2: Quantity & Cost
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('QUANTITY & PRICING', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B), letterSpacing: 0.6)),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('grn_line_qty_field'),
                  controller: _qtyController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Received quantity (bags/units)', prefixIcon: Icon(Icons.numbers_rounded, size: 18)),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('grn_line_unit_cost_field'),
                  controller: _costController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Unit purchase cost (₹)', prefixIcon: Icon(Icons.currency_rupee_rounded, size: 18)),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('grn_line_quality_dropdown'),
                  initialValue: _qualityStatus,
                  decoration: const InputDecoration(labelText: 'Quality status', prefixIcon: Icon(Icons.verified_outlined, size: 18)),
                  items: _qualityOptions.map((q) => DropdownMenuItem(value: q, child: Text(q))).toList(),
                  onChanged: (v) => setState(() => _qualityStatus = v ?? 'ACCEPTED'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // Card 3: Tare & Weighing
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  key: const Key('grn_line_capture_weight_switch'),
                  contentPadding: EdgeInsets.zero,
                  activeColor: const Color(0xFF0F766E),
                  title: const Text('Capture Tare & Net Weight', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  subtitle: const Text('For loose or weighed bagged animal feed', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                  value: _captureWeight,
                  onChanged: (v) => setState(() => _captureWeight = v),
                ),
                if (_captureWeight) ...[
                  const Divider(height: 20),
                  TextField(
                    key: const Key('grn_line_gross_weight_field'),
                    controller: _grossWeightController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Gross weight (kg)', prefixIcon: Icon(Icons.scale_rounded, size: 18)),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const Key('grn_line_tare_method_dropdown'),
                    initialValue: _tareMethod,
                    decoration: const InputDecoration(labelText: 'Tare method', prefixIcon: Icon(Icons.tune_rounded, size: 18)),
                    items: const [
                      DropdownMenuItem(value: 'MEASURED', child: Text('Measured (weighed empty)')),
                      DropdownMenuItem(value: 'STANDARD_PER_BAG', child: Text('Standard per bag')),
                    ],
                    onChanged: (v) => setState(() => _tareMethod = v ?? 'MEASURED'),
                  ),
                  const SizedBox(height: 12),
                  if (_tareMethod == 'MEASURED')
                    TextField(
                      key: const Key('grn_line_measured_tare_field'),
                      controller: _measuredTareController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Measured tare weight (kg)'),
                    )
                  else ...[
                    TextField(
                      key: const Key('grn_line_bag_count_field'),
                      controller: _bagCountController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Bag count'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('grn_line_standard_tare_field'),
                      controller: _standardTareController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Standard tare per bag (kg)'),
                    ),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('grn_line_save_button'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF0F766E),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _save,
            child: const Text('Save Line to GRN', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
