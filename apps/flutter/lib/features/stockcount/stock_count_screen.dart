import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/csv_export.dart';
import '../procurement/product_picker_screen.dart';
import 'stock_count_api.dart';
import 'stock_count_line_form_screen.dart';

/// One stock count, in progress or already resolved. While IN_PROGRESS this
/// screen lets a cashier add/rescan product counts and then post (or
/// cancel) the count; for any other status it is a read-only review of what
/// was counted and, once posted, exactly how much each line adjusted
/// inventory by.
class StockCountScreen extends StatefulWidget {
  final String stockCountId;
  const StockCountScreen({super.key, required this.stockCountId});

  @override
  State<StockCountScreen> createState() => _StockCountScreenState();
}

class _StockCountScreenState extends State<StockCountScreen> {
  StockCountDetail? _detail;
  bool _loading = true;
  bool _busy = false;
  String? _error;

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
      final api = StockCountApi(context.read<ApiClient>());
      final detail = await api.getDetail(widget.stockCountId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
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

  Future<void> _addProduct() async {
    final product = await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ProductPickerScreen()),
    );
    if (product == null || !mounted) return;
    final result = await Navigator.of(context).push<StockCountLineResult>(
      MaterialPageRoute(builder: (_) => StockCountLineFormScreen(stockCountId: widget.stockCountId, product: product)),
    );
    if (result == null) return;

    try {
      final api = StockCountApi(context.read<ApiClient>());
      await api.recordCount(
        stockCountId: widget.stockCountId,
        productId: product.id,
        batchId: result.batchId,
        countedQty: result.countedQty,
        reason: result.reason,
      );
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _postCount() async {
    final detail = _detail;
    if (detail == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Post Stock Count?'),
        content: Text(
          'Every line with a variance will adjust inventory to match what was counted. '
          'This cannot be undone — a mistake must be corrected with a fresh count.\n\n'
          '${detail.lines.where((l) => l.varianceQty != Decimal.zero).length} of ${detail.lines.length} lines have a variance.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('stock_count_post_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Post'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      final api = StockCountApi(context.read<ApiClient>());
      final result = await api.postCount(widget.stockCountId);
      if (!mounted) return;
      setState(() => _busy = false);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Stock Count Posted'),
          content: Text(
            '${result.linesAdjusted} line(s) adjusted.\n'
            'Net inventory value change: ₹${result.netValueDelta.toStringAsFixed(2)}',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
          ],
        ),
      );
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _cancelCount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Stock Count?'),
        content: const Text('Nothing counted so far will be applied to inventory.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('No')),
          FilledButton(
            key: const Key('stock_count_cancel_confirm'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel Count'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final api = StockCountApi(context.read<ApiClient>());
      await api.cancelCount(widget.stockCountId);
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _export() async {
    final detail = _detail;
    if (detail == null) return;
    await shareCsv(
      fileName: 'stock-count-${detail.id}.csv',
      headers: const ['SKU', 'Product', 'Batch', 'Expected Qty', 'Counted Qty', 'Variance', 'Reason'],
      rows: [
        for (final l in detail.lines)
          [l.sku, l.productName, l.batchCode, l.expectedQty.toString(), l.countedQty.toString(), l.varianceQty.toString(), l.reason ?? ''],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final isOpen = detail?.status == 'IN_PROGRESS';
    return Scaffold(
      appBar: AppBar(
        title: Text('Stock Count · ${detail?.countMode ?? ''}'),
        actions: [
          if (detail != null && detail.lines.isNotEmpty)
            IconButton(
              key: const Key('stock_count_export_csv_button'),
              onPressed: _export,
              icon: const Icon(Icons.ios_share_rounded),
              tooltip: 'Export CSV',
            ),
        ],
      ),
      floatingActionButton: isOpen
          ? FloatingActionButton.extended(
              key: const Key('stock_count_add_item_fab'),
              onPressed: _addProduct,
              icon: const Icon(Icons.add),
              label: const Text('Add Item'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: Colors.red))))
              : detail == null
                  ? const SizedBox.shrink()
                  : Column(
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          color: const Color(0xFFF8FAFC),
                          child: Text(
                            'Status: ${detail.status}',
                            key: const Key('stock_count_status_text'),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Expanded(
                          child: detail.lines.isEmpty
                              ? const Center(child: Text('No items counted yet'))
                              : ListView.builder(
                                  key: const Key('stock_count_lines_list'),
                                  padding: const EdgeInsets.all(12),
                                  itemCount: detail.lines.length,
                                  itemBuilder: (context, index) {
                                    final l = detail.lines[index];
                                    final hasVariance = l.varianceQty != Decimal.zero;
                                    return Container(
                                      key: Key('stock_count_line_${l.id}'),
                                      margin: const EdgeInsets.only(bottom: 8),
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: const Color(0xFFE2E8F0)),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(l.productName, style: const TextStyle(fontWeight: FontWeight.w600)),
                                                Text(
                                                  'Batch ${l.batchCode} · Expected ${l.expectedQty.toString()} · Counted ${l.countedQty.toString()}',
                                                  style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Text(
                                            '${l.varianceQty > Decimal.zero ? '+' : ''}${l.varianceQty.toString()}',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: hasVariance ? Colors.red : Colors.green,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                        ),
                        if (isOpen)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    key: const Key('stock_count_cancel_button'),
                                    onPressed: _busy ? null : _cancelCount,
                                    child: const Text('Cancel Count'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: FilledButton(
                                    key: const Key('stock_count_post_button'),
                                    onPressed: (_busy || detail.lines.isEmpty) ? null : _postCount,
                                    child: _busy
                                        ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                        : const Text('Post Count'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
    );
  }
}
