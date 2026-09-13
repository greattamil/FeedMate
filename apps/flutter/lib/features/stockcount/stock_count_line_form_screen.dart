import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../pos/product.dart';
import 'stock_count_api.dart';

class StockCountLineResult {
  final String batchId;
  final Decimal countedQty;
  final String? reason;

  StockCountLineResult({required this.batchId, required this.countedQty, this.reason});
}

/// Collects one physical count for a chosen product: which batch, and how
/// much was actually found on the shelf. Batches are loaded live from the
/// count's own location — there is no typing a batch code here, unlike GRN,
/// since a count can only ever be against stock that already exists.
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
      appBar: AppBar(title: Text(widget.product.name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: const TextStyle(color: Colors.red)),
                  ),
                if (_batches.isEmpty)
                  const Text('No active batches for this product at this location.')
                else
                  DropdownButtonFormField<String>(
                    key: const Key('stock_count_line_batch_dropdown'),
                    initialValue: _selectedBatchId,
                    decoration: const InputDecoration(labelText: 'Batch'),
                    items: _batches
                        .map((b) => DropdownMenuItem(
                              value: b.id,
                              child: Text('${b.batchCode} (on hand: ${b.availableQty.toString()})'),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _selectedBatchId = v),
                  ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('stock_count_line_qty_field'),
                  controller: _qtyController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Counted quantity'),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('stock_count_line_reason_field'),
                  controller: _reasonController,
                  decoration: const InputDecoration(labelText: 'Reason for variance (optional)'),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('stock_count_line_save_button'),
                  onPressed: _batches.isEmpty ? null : _save,
                  child: const Text('Save Count'),
                ),
              ],
            ),
    );
  }
}
