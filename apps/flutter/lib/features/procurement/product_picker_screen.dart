import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import '../products/product_admin_api.dart';
import '../pos/product.dart';
import '../pos/product_repository.dart';

/// Product picker for GRN Inward — browses the full catalog immediately
/// (matching POS's CatalogPanel) with category filter chips, rather than
/// requiring the user to already know what to type before seeing anything.
class ProductPickerScreen extends StatefulWidget {
  const ProductPickerScreen({super.key});

  @override
  State<ProductPickerScreen> createState() => _ProductPickerScreenState();
}

class _ProductPickerScreenState extends State<ProductPickerScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<Product> _results = [];
  bool _loading = false;
  String? _error;

  List<MasterDataOption> _categories = [];
  String? _selectedCategoryId;
  bool _loadingCategories = true;

  @override
  void initState() {
    super.initState();
    _loadCategories();
    // Show the full catalog immediately — a shop owner receiving stock
    // needs to browse and pick, not already know the exact name to type.
    _search('');
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
    _search(_controller.text);
  }

  Future<void> _search(String query) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = context.read<ProductRepository>();
      final result = await repo.search(query, categoryId: _selectedCategoryId);
      if (!mounted) return;
      setState(() {
        _results = result.products;
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
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('Select Product to Receive', style: AppTypography.headline)),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            color: AppColors.surface,
            child: Column(
              children: [
                TextField(
                  key: const Key('product_picker_search_field'),
                  controller: _controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Search by feed name, Tamil, or SKU',
                    prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary),
                    suffixIcon: _controller.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 18),
                            onPressed: () {
                              _controller.clear();
                              _onQueryChanged('');
                            },
                          )
                        : null,
                  ),
                  onChanged: _onQueryChanged,
                ),
                if (!_loadingCategories && _categories.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 32,
                    child: ListView.builder(
                      key: const Key('product_picker_category_chip_list'),
                      scrollDirection: Axis.horizontal,
                      itemCount: _categories.length + 1,
                      itemBuilder: (context, index) {
                        final categoryId = index == 0 ? null : _categories[index - 1].id;
                        final label = index == 0 ? 'All' : _categories[index - 1].label;
                        final isSelected = categoryId == _selectedCategoryId;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            key: index == 0 ? const Key('product_picker_category_chip_all') : Key('product_picker_category_chip_$categoryId'),
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
                              side: BorderSide(color: isSelected ? AppColors.primary : AppColors.border),
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
            child: _results.isEmpty && !_loading
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
                    padding: const EdgeInsets.all(12),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final p = _results[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: AppDecorations.borderRadiusMd,
                          border: Border.all(color: AppColors.border),
                          boxShadow: AppDecorations.cardShadow,
                        ),
                        child: ListTile(
                          key: Key('product_picker_result_${p.id}'),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          leading: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              gradient: AppColors.gradientEmerald,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Center(
                              child: Text(
                                p.name.isNotEmpty ? p.name.substring(0, 1).toUpperCase() : 'P',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17),
                              ),
                            ),
                          ),
                          title: Text(p.name, style: AppTypography.title),
                          subtitle: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceSecondary,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(p.sku, style: AppTypography.caption),
                              ),
                              if (p.localNameTa != null) ...[
                                const SizedBox(width: 6),
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
                              ],
                            ],
                          ),
                          trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.textSecondary),
                          onTap: () => Navigator.of(context).pop(p),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
