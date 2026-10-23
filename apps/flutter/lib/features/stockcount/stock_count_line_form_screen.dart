import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import '../pos/product.dart';
import 'stock_count_api.dart';

class StockCountLineResult {
  final String batchId;
  final Decimal countedQty;
  final String? reason;

  StockCountLineResult({required this.batchId, required this.countedQty, this.reason});
}

/// Collects one physical count for a chosen product: which batch, and how
/// much was actually found on the shelf.
class StockCountLineFormScreen extends StatefulWidget {
  final String stockCountId;
  final Product product;

  const StockCountLineFormScreen({super.key, required this.stockCountId, required this.product});

  @override
  State<StockCountLineFormScreen> createState() => _StockCountLineFormScreenState();
}

class _StockCountLineFormScreenState extends State<StockCountLineFormScreen> {
  final _qtyController = TextEditingController();
  final _reasonController = TextEditingController();
  List<BatchOption> _batches = [];
  String? _selectedBatchId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBatches();
  }

  Future<void> _loadBatches() async {
    try {
      final api = StockCountApi(context.read<ApiClient>());
      final batches = await api.listBatchesForProduct(widget.stockCountId, widget.product.id);
      if (!mounted) return;
      setState(() {
        _batches = batches;
        _selectedBatchId = batches.isNotEmpty ? batches.first.id : null;
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

  @override
  void dispose() {
    _qtyController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _save() {
    if (_selectedBatchId == null) {
      setState(() => _error = 'No batch available for this product at this location');
      return;
    }
    final qty = Decimal.tryParse(_qtyController.text.trim());
    if (qty == null || qty < Decimal.zero) {
      setState(() => _error = 'Enter a valid, non-negative counted quantity');
      return;
    }
    Navigator.of(context).pop(StockCountLineResult(
      batchId: _selectedBatchId!,
      countedQty: qty,
      reason: _reasonController.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(widget.product.name, style: AppTypography.headline),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 14),
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
                      if (_batches.isEmpty)
                        const Text('No active batches for this product at this location.', style: TextStyle(color: AppColors.textSecondary))
                      else
                        DropdownButtonFormField<String>(
                          key: const Key('stock_count_line_batch_dropdown'),
                          initialValue: _selectedBatchId,
                          decoration: const InputDecoration(
                            labelText: 'Batch',
                            prefixIcon: Icon(Icons.qr_code_2_rounded, size: 20),
                          ),
                          items: _batches
                              .map((b) => DropdownMenuItem(
                                    value: b.id,
                                    child: Text('${b.batchCode} (on hand: ${b.availableQty.toString()})'),
                                  ))
                              .toList(),
                          onChanged: (v) => setState(() => _selectedBatchId = v),
                        ),
                      const SizedBox(height: 14),
                      TextField(
                        key: const Key('stock_count_line_qty_field'),
                        controller: _qtyController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Counted quantity',
                          prefixIcon: Icon(Icons.scale_rounded, size: 20),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        key: const Key('stock_count_line_reason_field'),
                        controller: _reasonController,
                        decoration: const InputDecoration(
                          labelText: 'Reason for variance (optional)',
                          prefixIcon: Icon(Icons.note_alt_outlined, size: 20),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('stock_count_line_save_button'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _batches.isEmpty ? null : _save,
                  child: const Text('Save Count', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
    );
  }
}
