import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'reports_api.dart';

/// A single, real-time view of every product's stock status — the "portal"
/// for stock management the shop owner asked for. Every number here comes
/// straight from GET /api/v1/reports/stock-summary
/// (services/api/internal/httpapi/reports_handlers.go), which itself reads
/// batches.available_qty — the one column POS sales, GRN receiving, sales
/// returns, and stock-count adjustments all write through
/// inventory.PostStockMovement. There is no cached or hardcoded quantity
/// anywhere in this screen; "Low Stock" / "Out of Stock" are the server's
/// own comparison of that live quantity against the product's reorder
/// level, not a client-side guess.
class StockManagementScreen extends StatefulWidget {
  const StockManagementScreen({super.key});

  @override
  State<StockManagementScreen> createState() => _StockManagementScreenState();
}

enum _StockFilter { all, lowStock, outOfStock }

class _StockManagementScreenState extends State<StockManagementScreen> {
  final _searchController = TextEditingController();
  StockSummary? _summary;
  bool _loading = true;
  String? _error;
  _StockFilter _filter = _StockFilter.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ReportsApi(context.read<ApiClient>());
      final summary = await api.stockSummary();
      if (!mounted) return;
      setState(() {
        _summary = summary;
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

  List<StockSummaryLine> _visibleLines() {
    final summary = _summary;
    if (summary == null) return [];
    final query = _searchController.text.trim().toLowerCase();
    return summary.lines.where((l) {
      if (_filter == _StockFilter.lowStock && !l.isLowStock) return false;
      if (_filter == _StockFilter.outOfStock && !l.isOutOfStock) return false;
      if (query.isEmpty) return true;
      return l.name.toLowerCase().contains(query) || l.sku.toLowerCase().contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    final lines = _visibleLines();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Stock Management', style: AppTypography.headline),
        actions: [
          IconButton(
            key: const Key('stock_management_refresh_button'),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: AppColors.surface,
            child: Column(
              children: [
                TextField(
                  key: const Key('stock_search_field'),
                  controller: _searchController,
                  decoration: InputDecoration(
                    labelText: 'Search product by name or SKU',
                    prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 18),
                            onPressed: () => setState(_searchController.clear),
                          )
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                if (summary != null)
                  Row(
                    children: [
                      Expanded(
                        child: _filterChip(
                          key: const Key('stock_filter_all'),
                          label: 'All (${summary.lines.length})',
                          selected: _filter == _StockFilter.all,
                          onTap: () => setState(() => _filter = _StockFilter.all),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _filterChip(
                          key: const Key('stock_filter_low'),
                          label: 'Low Stock (${summary.lowStockCount})',
                          selected: _filter == _StockFilter.lowStock,
                          color: AppColors.warning,
                          onTap: () => setState(() => _filter = _StockFilter.lowStock),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _filterChip(
                          key: const Key('stock_filter_out'),
                          label: 'Out of Stock (${summary.outOfStockCount})',
                          selected: _filter == _StockFilter.outOfStock,
                          color: AppColors.danger,
                          onTap: () => setState(() => _filter = _StockFilter.outOfStock),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(color: AppColors.primary, minHeight: 2),
          if (_error != null)
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.dangerContainer,
                borderRadius: AppDecorations.borderRadiusSm,
              ),
              child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer)),
            ),
          Expanded(
            child: !_loading && lines.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.inventory_2_outlined, size: 56, color: Color(0xFF94A3B8)),
                        SizedBox(height: 12),
                        Text('No products found', style: AppTypography.bodySecondary),
                      ],
                    ),
                  )
                : ListView.builder(
                    key: const Key('stock_management_list'),
                    padding: const EdgeInsets.all(12),
                    itemCount: lines.length,
                    itemBuilder: (context, index) => _stockCard(lines[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip({required Key key, required String label, required bool selected, required VoidCallback onTap, Color? color}) {
    final accent = color ?? AppColors.primary;
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: AppDecorations.borderRadiusSm,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.15) : AppColors.surfaceSecondary,
          borderRadius: AppDecorations.borderRadiusSm,
          border: Border.all(color: selected ? accent : AppColors.border),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: AppTypography.caption.copyWith(
            fontWeight: FontWeight.bold,
            color: selected ? accent : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _stockCard(StockSummaryLine l) {
    final Color badgeBg;
    final Color badgeFg;
    final String badgeLabel;
    switch (l.status) {
      case 'OUT_OF_STOCK':
        badgeBg = AppColors.dangerContainer;
        badgeFg = AppColors.onDangerContainer;
        badgeLabel = 'Out of Stock';
        break;
      case 'LOW_STOCK':
        badgeBg = AppColors.warningContainer;
        badgeFg = AppColors.onWarningContainer;
        badgeLabel = 'Low Stock';
        break;
      default:
        badgeBg = AppColors.successContainer;
        badgeFg = AppColors.onSuccessContainer;
        badgeLabel = 'In Stock';
    }

    return Container(
      key: Key('stock_line_${l.productId}'),
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
                Text(l.name, style: AppTypography.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Flexible(
                      child: Text(l.sku, style: AppTypography.caption, overflow: TextOverflow.ellipsis),
                    ),
                    if (l.reorderLevel != null) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Reorder at ${l.reorderLevel!.toStringAsFixed(0)} ${l.uomCode}',
                          style: AppTypography.caption,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${l.onHandQty.toString()} ${l.uomCode}',
                style: AppTypography.title.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: badgeBg, borderRadius: BorderRadius.circular(AppDecorations.radiusFull)),
                child: Text(
                  badgeLabel,
                  style: AppTypography.caption.copyWith(fontWeight: FontWeight.bold, color: badgeFg),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
