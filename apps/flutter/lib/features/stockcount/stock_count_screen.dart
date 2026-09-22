import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/csv_export.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import '../procurement/product_picker_screen.dart';
import 'stock_count_api.dart';
import 'stock_count_line_form_screen.dart';
import '../../core/number_format.dart';

/// One stock count, in progress or already resolved.
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
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.check_circle_outline_rounded, color: AppColors.primary, size: 22),
            ),
            const SizedBox(width: 12),
            const Text('Post Stock Count?'),
          ],
        ),
        content: Text(
          'Every line with a variance will adjust inventory to match what was counted. '
          'This cannot be undone — a mistake must be corrected with a fresh count.\n\n'
          '${detail.lines.where((l) => l.varianceQty != Decimal.zero).length} of ${detail.lines.length} lines have a variance.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('stock_count_post_confirm'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
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
              const Text('Stock Count Posted'),
            ],
          ),
          content: Text(
            '${result.linesAdjusted} line(s) adjusted.\n'
            'Net inventory value change: ${money(result.netValueDelta)}',
            style: const TextStyle(height: 1.4),
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
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
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.dangerContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.cancel_outlined, color: AppColors.danger, size: 22),
            ),
            const SizedBox(width: 12),
            const Text('Cancel Stock Count?'),
          ],
        ),
        content: const Text('Nothing counted so far will be applied to inventory.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('No')),
          FilledButton(
            key: const Key('stock_count_cancel_confirm'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
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
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Stock Count · ${detail?.countMode ?? ''}', style: AppTypography.headline),
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
              heroTag: null,
              key: const Key('stock_count_add_item_fab'),
              onPressed: _addProduct,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add Item', style: TextStyle(fontWeight: FontWeight.bold)),
              backgroundColor: AppColors.primary,
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _error != null
              ? Center(
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.dangerContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer)),
                  ),
                )
              : detail == null
                  ? const SizedBox.shrink()
                  : Column(
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            border: Border(bottom: BorderSide(color: AppColors.border)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    isOpen ? Icons.pending_actions_rounded : Icons.check_circle_rounded,
                                    size: 18,
                                    color: isOpen ? AppColors.warning : AppColors.success,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Status: ${detail.status}',
                                    key: const Key('stock_count_status_text'),
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                  ),
                                ],
                              ),
                              Text(
                                '${detail.lines.length} item(s)',
                                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: detail.lines.isEmpty
                              ? Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: const [
                                      Icon(Icons.inventory_2_outlined, size: 52, color: Color(0xFF94A3B8)),
                                      SizedBox(height: 10),
                                      Text('No items counted yet', style: AppTypography.bodySecondary),
                                    ],
                                  ),
                                )
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
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color: AppColors.surface,
                                        borderRadius: AppDecorations.borderRadiusMd,
                                        border: Border.all(color: AppColors.border),
                                        boxShadow: AppDecorations.cardShadow,
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(l.productName, style: AppTypography.title),
                                                const SizedBox(height: 2),
                                                Text(
                                                  'Batch ${l.batchCode} · Expected ${l.expectedQty.toString()} · Counted ${l.countedQty.toString()}',
                                                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: hasVariance ? AppColors.dangerContainer : AppColors.successContainer,
                                              borderRadius: BorderRadius.circular(20),
                                            ),
                                            child: Text(
                                              '${l.varianceQty > Decimal.zero ? '+' : ''}${l.varianceQty.toString()}',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13,
                                                color: hasVariance ? AppColors.danger : AppColors.success,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
      bottomNavigationBar: isOpen && detail != null
          ? Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border(top: BorderSide(color: AppColors.border)),
                boxShadow: AppDecorations.cardShadow,
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const Key('stock_count_cancel_button'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: _busy ? null : _cancelCount,
                        child: const Text('Cancel Count', style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        key: const Key('stock_count_post_button'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: (_busy || detail.lines.isEmpty) ? null : _postCount,
                        child: _busy
                            ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Text('Post Count', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}
