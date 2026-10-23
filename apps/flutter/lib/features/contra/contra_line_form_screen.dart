import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import '../pos/product.dart';
import 'contra_api.dart';

/// Full-screen form for one contra (buy-back) line: batch/expiry, quantity,
/// the price the shop is crediting the customer at, and quality status.
class ContraLineFormScreen extends StatefulWidget {
  final Product product;
  final ContraLineDraft? existing;

  const ContraLineFormScreen({super.key, required this.product, this.existing});

  @override
  State<ContraLineFormScreen> createState() => _ContraLineFormScreenState();
}

class _ContraLineFormScreenState extends State<ContraLineFormScreen> {
  static final _dateFormat = DateFormat('dd MMM yyyy');

  late final TextEditingController _batchController;
  late final TextEditingController _qtyController;
  late final TextEditingController _priceController;

  DateTime? _manufactureDate;
  DateTime? _expiryDate;
  String _qualityStatus = 'ACCEPTED';
  String? _error;

  static const _qualityOptions = ['ACCEPTED', 'REJECTED', 'DAMAGED', 'QUARANTINE'];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _batchController = TextEditingController(text: e?.batchCode ?? '');
    _qtyController = TextEditingController(text: e != null ? e.quantity.toString() : '');
    _priceController = TextEditingController(text: e != null ? e.valuationUnitPrice.toStringAsFixed(2) : '');
    _manufactureDate = e?.manufactureDate;
    _expiryDate = e?.expiryDate;
    _qualityStatus = e?.qualityStatus ?? 'ACCEPTED';
  }

  @override
  void dispose() {
    _batchController.dispose();
    _qtyController.dispose();
    _priceController.dispose();
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
    if (qty == null || qty <= Decimal.zero) {
      setState(() => _error = 'Enter a quantity greater than zero');
      return;
    }
    final price = Decimal.tryParse(_priceController.text.trim());
    if (price == null || price < Decimal.zero) {
      setState(() => _error = 'Enter a valid, non-negative unit price');
      return;
    }
    if (widget.product.batchRequired && _batchController.text.trim().isEmpty) {
      setState(() => _error = 'This product requires a batch code');
      return;
    }
    Navigator.of(context).pop(ContraLineDraft(
      product: widget.product,
      batchCode: _batchController.text.trim(),
      manufactureDate: _manufactureDate,
      expiryDate: _expiryDate,
      quantity: qty,
      valuationUnitPrice: price,
      qualityStatus: _qualityStatus,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(widget.product.name, style: AppTypography.headline),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
              boxShadow: AppDecorations.cardShadow,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const Key('contra_line_batch_field'),
                  controller: _batchController,
                  decoration: InputDecoration(
                    labelText: widget.product.batchRequired ? 'Batch code (required)' : 'Batch code (optional)',
                    prefixIcon: const Icon(Icons.qr_code_2_rounded, size: 20),
                  ),
                ),
                const SizedBox(height: 14),
                ListTile(
                  key: const Key('contra_line_manufacture_date_tile'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Manufacture date (optional)', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    _manufactureDate == null ? 'Not set' : _dateFormat.format(_manufactureDate!),
                    style: TextStyle(color: _manufactureDate == null ? AppColors.textSecondary : AppColors.textPrimary),
                  ),
                  trailing: const Icon(Icons.calendar_today_rounded, size: 18, color: AppColors.primary),
                  onTap: () => _pickDate(isExpiry: false),
                ),
                const Divider(height: 1),
                ListTile(
                  key: const Key('contra_line_expiry_date_tile'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Expiry date (optional)', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    _expiryDate == null ? 'Not set' : _dateFormat.format(_expiryDate!),
                    style: TextStyle(color: _expiryDate == null ? AppColors.textSecondary : AppColors.textPrimary),
                  ),
                  trailing: const Icon(Icons.calendar_today_rounded, size: 18, color: AppColors.primary),
                  onTap: () => _pickDate(isExpiry: true),
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const Key('contra_line_qty_field'),
                  controller: _qtyController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Quantity taken back',
                    prefixIcon: Icon(Icons.scale_rounded, size: 20),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const Key('contra_line_price_field'),
                  controller: _priceController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Credit price per unit (₹)',
                    prefixIcon: Icon(Icons.currency_rupee_rounded, size: 20),
                  ),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  key: const Key('contra_line_quality_dropdown'),
                  initialValue: _qualityStatus,
                  decoration: const InputDecoration(
                    labelText: 'Quality status',
                    prefixIcon: Icon(Icons.verified_outlined, size: 20),
                  ),
                  items: _qualityOptions.map((q) => DropdownMenuItem(value: q, child: Text(q))).toList(),
                  onChanged: (v) => setState(() => _qualityStatus = v ?? 'ACCEPTED'),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.dangerContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('contra_line_save_button'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _save,
            child: const Text('Save Line', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
