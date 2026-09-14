import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/auth_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import '../auth/login_screen.dart';
import '../products/product_admin_api.dart';
import 'cart_model.dart';
import 'product.dart';
import 'product_repository.dart';

/// The product catalog: search bar, category filter chips, and a
/// tap-to-add results list — backed by ranked search (barcode > SKU > exact
/// name > alias > fuzzy). Tapping a result adds it to the cart immediately;
/// there is no intermediate "confirm" step, matching how a real POS counter
/// terminal works. Shared between [ProductSearchScreen] (a standalone page)
/// and [PosScreen] (the single-screen POS, where this sits directly next to
/// the cart so the cashier never navigates away to see what they just
/// added).
class CatalogPanel extends StatefulWidget {
  const CatalogPanel({super.key});

  @override
  State<CatalogPanel> createState() => _CatalogPanelState();
}

class _CatalogPanelState extends State<CatalogPanel> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  List<Product> _results = [];
  bool _loading = false;
  bool _fromCache = false;
  String? _error;

  // The category filter chips must reflect the real categories a shop
  // owner has actually set up (Categories & Brands admin, Phase 38) — not
  // a static guess — so a product filed under a category that doesn't
  // exist here can never be invisible in the POS, and a chip can never
  // claim to filter by a category that doesn't actually exist.
  List<MasterDataOption> _categories = [];
  String? _selectedCategoryId;
  bool _loadingCategories = true;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      final categories = await api.listCategories();
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _loadingCategories = false;
      });
    } on ApiError catch (_) {
      // Categories are a nice-to-have filter, not required to search/sell —
      // fail quietly and leave only the "All" chip rather than blocking the
      // counter on a category-list fetch.
      if (!mounted) return;
      setState(() => _loadingCategories = false);
    }
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(query));
  }

  void _onCategorySelected(String? categoryId) {
    setState(() => _selectedCategoryId = categoryId);
    _search(_searchController.text);
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty && _selectedCategoryId == null) {
      setState(() {
        _results = [];
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repository = context.read<ProductRepository>();
      final result = await repository.search(query, categoryId: _selectedCategoryId);
      if (!mounted) return;
      setState(() {
        _results = result.products;
        _fromCache = result.fromCache;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
      if (e.code == 'UNAUTHENTICATED') {
        await context.read<AuthSession>().logout();
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Search & Scanner Header Bar
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          color: AppColors.surface,
          child: Column(
            children: [
              TextField(
                key: const Key('search_field'),
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Scan barcode or search (English / Tamil / SKU)',
                  prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_searchController.text.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            _onQueryChanged('');
                          },
                        ),
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: Icon(Icons.qr_code_scanner_rounded, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                onChanged: _onQueryChanged,
              ),
              if (!_loadingCategories && _categories.isNotEmpty) ...[
                const SizedBox(height: 10),
                // Horizontal category pill selector — populated from the
                // real categories a shop owner has configured (Categories &
                // Brands admin), never a fixed guess unrelated to the
                // actual catalog.
                SizedBox(
                  height: 32,
                  child: ListView.builder(
                    key: const Key('category_chip_list'),
                    scrollDirection: Axis.horizontal,
                    itemCount: _categories.length + 1,
                    itemBuilder: (context, index) {
                      final categoryId = index == 0 ? null : _categories[index - 1].id;
                      final label = index == 0 ? 'All' : _categories[index - 1].label;
                      final isSelected = categoryId == _selectedCategoryId;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          key: index == 0 ? const Key('category_chip_all') : Key('category_chip_$categoryId'),
                          selected: isSelected,
                          showCheckmark: false,
                          label: Text(label),
                          labelStyle: TextStyle(
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                            color: isSelected ? Colors.white : AppColors.textSecondary,
                          ),
                          backgroundColor: AppColors.surfaceSecondary,
                          selectedColor: AppColors.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppDecorations.radiusFull),
                            side: BorderSide(
                              color: isSelected ? AppColors.primary : AppColors.border,
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          onSelected: (selected) => _onCategorySelected(categoryId),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(color: AppColors.primary, minHeight: 2),
        if (_fromCache)
          Container(
            key: const Key('offline_cache_banner'),
            width: double.infinity,
            color: AppColors.warningContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: const [
                Icon(Icons.wifi_off_rounded, color: AppColors.warning, size: 16),
                SizedBox(width: 8),
                Text(
                  'Offline — showing cached products',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.onWarningContainer),
                ),
              ],
            ),
          ),
        if (_error != null)
          Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.dangerContainer,
              borderRadius: AppDecorations.borderRadiusSm,
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer, fontSize: 13))),
              ],
            ),
          ),
        // Product Search Results List
        Expanded(
          child: _results.isEmpty && !_loading
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inventory_2_outlined, size: 48, color: AppColors.textTertiary),
                      const SizedBox(height: 12),
                      Text(
                        _searchController.text.isEmpty && _selectedCategoryId == null
                            ? 'Scan barcode or enter product name/SKU'
                            : 'No products matched your search',
                        style: AppTypography.bodySecondary,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  key: const Key('results_list'),
                  padding: const EdgeInsets.all(12),
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final p = _results[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: AppDecorations.borderRadiusMd,
                        border: Border.all(color: AppColors.border),
                        boxShadow: AppDecorations.cardShadow,
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: AppDecorations.borderRadiusMd,
                          onTap: () {
                            context.read<CartModel>().addProduct(p);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Row(
                                  children: [
                                    const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                                    const SizedBox(width: 8),
                                    Text('Added ${p.name} to cart'),
                                  ],
                                ),
                                duration: const Duration(seconds: 1),
                                backgroundColor: AppColors.primaryDark,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                // Product Initial Avatar
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    gradient: AppColors.gradientEmerald,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Center(
                                    child: Text(
                                      p.name.isNotEmpty ? p.name.substring(0, 1).toUpperCase() : 'P',
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // Product Title, Tamil name & SKU
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(p.name, style: AppTypography.title.copyWith(fontSize: 15)),
                                      const SizedBox(height: 3),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: AppColors.surfaceSecondary,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(p.sku, style: AppTypography.caption),
                                          ),
                                          if (p.localNameTa != null)
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: AppColors.primaryContainer,
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                p.localNameTa!,
                                                style: AppTypography.caption.copyWith(color: AppColors.primaryDark),
                                              ),
                                            ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: AppColors.secondaryContainer,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              p.matchType,
                                              style: AppTypography.caption.copyWith(color: AppColors.secondary),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Price Tag & Add Action
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      p.sellingPrice != null ? '₹${p.sellingPrice!.toStringAsFixed(2)}' : '—',
                                      style: AppTypography.currencyMedium.copyWith(color: AppColors.primary),
                                    ),
                                    const SizedBox(height: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: AppColors.primaryContainer,
                                        borderRadius: BorderRadius.circular(AppDecorations.radiusFull),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: const [
                                          Icon(Icons.add_rounded, size: 14, color: AppColors.primary),
                                          SizedBox(width: 2),
                                          Text(
                                            'Add',
                                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.primary),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
