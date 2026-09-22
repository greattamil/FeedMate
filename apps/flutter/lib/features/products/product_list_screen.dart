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
import '../../core/number_format.dart';

/// The product master-data browse screen: search, filter by active/inactive,
/// and jump into a product's detail (which itself links to edit/deactivate)
/// or create a brand-new one.
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
      // Real, live stock from GET /api/v1/reports/stock-summary
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

  LinearGradient _avatarGradient(String name) {
    final colors = [
      AppColors.gradientEmerald,
      AppColors.gradientIndigo,
      AppColors.gradientAmber,
      AppColors.gradientPurple,
      AppColors.gradientCyan,
    ];
    final idx = name.codeUnits.fold(0, (a, b) => a + b) % colors.length;
    return colors[idx];
  }

  String _getInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return 'P';
    if (parts.length == 1) return parts[0].substring(0, parts[0].length >= 2 ? 2 : 1).toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Products Master', style: AppTypography.headline),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _load,
          ),
        ],
      ),
      floatingActionButton: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: AppDecorations.emeraldGlow,
        ),
        child: FloatingActionButton.extended(
          heroTag: null,
          key: const Key('product_add_fab'),
          onPressed: _openCreate,
          icon: const Icon(Icons.add_rounded, color: Colors.white),
          label: const Text('Add Product', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          backgroundColor: AppColors.primary,
        ),
      ),
      body: Column(
        children: [
          // Hero Header Banner
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              gradient: AppColors.gradientHeroMesh,
              borderRadius: AppDecorations.borderRadiusLg,
              boxShadow: AppDecorations.cardShadow,
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                  ),
                  child: const Icon(Icons.inventory_2_rounded, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Products & Inventory Master',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Manage SKU specs, prices, stock rules & barcodes',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Search Field
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
                boxShadow: AppDecorations.cardShadow,
              ),
              child: TextField(
                key: const Key('product_search_field'),
                controller: _searchController,
                decoration: InputDecoration(
                  labelText: 'Search by name or SKU',
                  prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            _load();
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.transparent,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                onChanged: _onQueryChanged,
              ),
            ),
          ),

          // Filter bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceSecondary,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.apps_rounded, size: 14, color: AppColors.primary),
                      const SizedBox(width: 6),
                      Text('$_total product${_total == 1 ? '' : 's'}', style: AppTypography.bodySecondary.copyWith(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                const Spacer(),
                const Text('Show inactive', style: AppTypography.bodySecondary),
                const SizedBox(width: 6),
                Switch(
                  key: const Key('product_show_inactive_switch'),
                  value: _showInactive,
                  activeColor: AppColors.primary,
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.dangerContainer,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!, style: const TextStyle(color: AppColors.danger))),
                  ],
                ),
              ),
            ),

          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _products.isEmpty && !_loading
                  ? ListView(
                      children: const [
                        SizedBox(height: 100),
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.inventory_2_outlined, size: 48, color: AppColors.textTertiary),
                              SizedBox(height: 12),
                              Text('No products found', style: AppTypography.bodySecondary),
                            ],
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      key: const Key('product_list'),
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                      itemCount: _products.length,
                      itemBuilder: (context, index) {
                        final p = _products[index];
                        final stock = _stockByProduct[p.id];
                        final avatarGrad = _avatarGradient(p.name);
                        final initials = _getInitials(p.name);

                        return Container(
                          key: Key('product_row_${p.id}'),
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: AppColors.border),
                            boxShadow: AppDecorations.cardShadow,
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => _openDetail(p),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Row(
                                children: [
                                  // Product Chromatic Avatar
                                  Container(
                                    width: 46,
                                    height: 46,
                                    decoration: BoxDecoration(
                                      gradient: avatarGrad,
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(
                                          color: avatarGrad.colors.first.withValues(alpha: 0.25),
                                          blurRadius: 8,
                                          offset: const Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: Center(
                                      child: Text(
                                        initials,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 14),

                                  // Product Info
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          p.name,
                                          style: AppTypography.title.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: AppColors.surfaceSecondary,
                                                borderRadius: BorderRadius.circular(6),
                                                border: Border.all(color: AppColors.border),
                                              ),
                                              child: Text(
                                                p.sku,
                                                style: AppTypography.caption.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                  color: AppColors.textSecondary,
                                                ),
                                              ),
                                            ),
                                            if (stock != null) ...[
                                              const SizedBox(width: 8),
                                              _stockBadge(stock),
                                            ],
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),

                                  // Price & Status
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        p.sellingPrice != null ? money(p.sellingPrice!) : '—',
                                        style: AppTypography.currencySmall.copyWith(
                                          color: AppColors.primary,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      if (!p.active)
                                        Container(
                                          margin: const EdgeInsets.only(top: 4),
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: AppColors.dangerContainer,
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: const Text(
                                            'INACTIVE',
                                            style: TextStyle(
                                              fontSize: 9,
                                              color: AppColors.danger,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(width: 6),
                                  const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary, size: 20),
                                ],
                              ),
                            ),
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

  /// Real on-hand quantity + reorder status, straight from GET /api/v1/reports/stock-summary
  Widget _stockBadge(StockSummaryLine stock) {
    final Color bg;
    final Color fg;
    final IconData icon;
    switch (stock.status) {
      case 'OUT_OF_STOCK':
        bg = AppColors.dangerContainer;
        fg = AppColors.onDangerContainer;
        icon = Icons.cancel_rounded;
        break;
      case 'LOW_STOCK':
        bg = AppColors.warningContainer;
        fg = AppColors.onWarningContainer;
        icon = Icons.warning_amber_rounded;
        break;
      default:
        bg = AppColors.successContainer;
        fg = AppColors.onSuccessContainer;
        icon = Icons.check_circle_rounded;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppDecorations.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: fg),
          const SizedBox(width: 4),
          Text(
            '${stock.onHandQty.toString()} ${stock.uomCode}',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: fg),
          ),
        ],
      ),
    );
  }
}
