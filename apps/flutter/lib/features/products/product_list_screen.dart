import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import '../reports/reports_api.dart';
import 'product_admin_api.dart';
import 'product_detail_screen.dart';
import 'product_form_screen.dart';

/// The product master-data browse screen: search, filter by active/inactive,
/// and jump into a product's detail (which itself links to edit/deactivate)
/// or create a brand-new one. Distinct from the POS product search screen —
/// this is master-data management, not point-of-sale lookup.
class ProductListScreen extends StatefulWidget {
  const ProductListScreen({super.key});

  @override
  State<ProductListScreen> createState() => _ProductListScreenState();
}

class _ProductListScreenState extends State<ProductListScreen> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  List<ProductListItem> _products = [];
  int _total = 0;
  bool _loading = true;
  bool _showInactive = false;
  String? _error;
  Map<String, StockSummaryLine> _stockByProduct = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = context.read<ApiClient>();
      final api = ProductAdminApi(client);
      final page = await api.list(query: _searchController.text.trim(), activeOnly: !_showInactive);
      if (!mounted) return;
      setState(() {
        _products = page.products;
        _total = page.total;
        _loading = false;
      });
      // Real, live stock — never a hardcoded/placeholder number. Best-effort:
      // if this fails, the list still renders (just without stock badges)
      // rather than blocking the whole product list on a secondary call.
      try {
        final stock = await ReportsApi(client).stockSummary();
        if (mounted) {
          setState(() => _stockByProduct = {for (final l in stock.lines) l.productId: l});
        }
      } catch (_) {}
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _load);
  }

  Future<void> _openCreate() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const ProductFormScreen()),
    );
    if (created == true) await _load();
  }

  Future<void> _openDetail(ProductListItem item) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ProductDetailScreen(productId: item.id)),
    );
    if (changed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Products', style: AppTypography.headline)),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('product_add_fab'),
        onPressed: _openCreate,
        icon: const Icon(Icons.add),
        label: const Text('Add Product'),
        backgroundColor: AppColors.primary,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextField(
              key: const Key('product_search_field'),
              controller: _searchController,
              decoration: const InputDecoration(
                labelText: 'Search by name or SKU',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text('$_total product${_total == 1 ? '' : 's'}', style: AppTypography.bodySecondary),
                const Spacer(),
                const Text('Show inactive', style: AppTypography.bodySecondary),
                Switch(
                  key: const Key('product_show_inactive_switch'),
                  value: _showInactive,
                  onChanged: (v) {
                    setState(() => _showInactive = v);
                    _load();
                  },
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(color: AppColors.primary, minHeight: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_error!, style: const TextStyle(color: AppColors.danger)),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _products.isEmpty && !_loading
                  ? ListView(
                      children: const [
                        SizedBox(height: 120),
                        Center(child: Text('No products found', style: AppTypography.bodySecondary)),
                      ],
                    )
                  : ListView.builder(
                      key: const Key('product_list'),
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                      itemCount: _products.length,
                      itemBuilder: (context, index) {
                        final p = _products[index];
                        final stock = _stockByProduct[p.id];
                        return Container(
                          key: Key('product_row_${p.id}'),
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: AppDecorations.card(),
                          child: ListTile(
                            title: Text(p.name, style: AppTypography.title),
                            subtitle: Row(
                              children: [
                                Flexible(child: Text(p.sku, style: AppTypography.bodySecondary, overflow: TextOverflow.ellipsis)),
                                if (stock != null) ...[
                                  const SizedBox(width: 8),
                                  _stockBadge(stock),
                                ],
                              ],
                            ),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  p.sellingPrice != null ? '₹${p.sellingPrice!.toStringAsFixed(2)}' : '—',
                                  style: AppTypography.currencySmall,
                                ),
                                if (!p.active)
                                  const Padding(
                                    padding: EdgeInsets.only(top: 2),
                                    child: Text('INACTIVE', style: TextStyle(fontSize: 10, color: AppColors.danger, fontWeight: FontWeight.bold)),
                                  ),
                              ],
                            ),
                            onTap: () => _openDetail(p),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// Real on-hand quantity + reorder status, straight from
  /// GET /api/v1/reports/stock-summary — never a hardcoded value.
  Widget _stockBadge(StockSummaryLine stock) {
    final Color bg;
    final Color fg;
    switch (stock.status) {
      case 'OUT_OF_STOCK':
        bg = AppColors.dangerContainer;
        fg = AppColors.onDangerContainer;
        break;
      case 'LOW_STOCK':
        bg = AppColors.warningContainer;
        fg = AppColors.onWarningContainer;
        break;
      default:
        bg = AppColors.successContainer;
        fg = AppColors.onSuccessContainer;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(AppDecorations.radiusFull)),
      child: Text(
        '${stock.onHandQty.toString()} ${stock.uomCode}',
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: fg),
      ),
    );
  }
}
