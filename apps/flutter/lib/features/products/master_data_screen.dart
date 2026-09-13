import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'product_admin_api.dart';

/// Manage the two product lookup tables a shop owner routinely extends
/// while onboarding new product lines: categories and brands. UOMs and tax
/// profiles stay out of scope here — UOMs are a largely-fixed global seed
/// and tax profiles carry GST-compliance implications that deserve a
/// dedicated flow (see masterdata.go's package doc comment server-side).
class MasterDataScreen extends StatefulWidget {
  const MasterDataScreen({super.key});

  @override
  State<MasterDataScreen> createState() => _MasterDataScreenState();
}

class _MasterDataScreenState extends State<MasterDataScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  List<MasterDataOption> _categories = [];
  List<MasterDataOption> _brands = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      final categories = await api.listCategories();
      final brands = await api.listBrands();
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _brands = brands;
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

  Future<void> _addCategory() async {
    final name = await _promptForName('Add Category', 'category_name_field');
    if (name == null) return;
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      await api.createCategory(name: name);
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _addBrand() async {
    final name = await _promptForName('Add Brand', 'brand_name_field');
    if (name == null) return;
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      await api.createBrand(name: name);
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<String?> _promptForName(String title, String fieldKey) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          key: Key(fieldKey),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            key: Key('${fieldKey}_submit'),
            onPressed: () => Navigator.of(context).pop(controller.text.trim().isEmpty ? null : controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _deactivateCategory(MasterDataOption category) async {
    final confirmed = await _confirmDeactivate(category.label);
    if (confirmed != true) return;
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      await api.setCategoryActive(category.id, false);
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _deactivateBrand(MasterDataOption brand) async {
    final confirmed = await _confirmDeactivate(brand.label);
    if (confirmed != true) return;
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      await api.setBrandActive(brand.id, false);
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<bool?> _confirmDeactivate(String name) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Deactivate?'),
        content: Text('$name will no longer appear when creating or editing products.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('master_data_deactivate_confirm'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Deactivate'),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<MasterDataOption> items, void Function(MasterDataOption) onDeactivate, String emptyLabel) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) {
      return Center(child: Text(emptyLabel, style: AppTypography.bodySecondary));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppDecorations.borderRadiusMd,
            border: Border.all(color: AppColors.border),
          ),
          child: ListTile(
            key: Key('master_data_item_${item.id}'),
            title: Text(item.label),
            trailing: IconButton(
              key: Key('master_data_deactivate_${item.id}'),
              icon: const Icon(Icons.delete_outline, color: AppColors.danger),
              onPressed: () => onDeactivate(item),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Categories & Brands', style: AppTypography.headline),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Categories'),
            Tab(text: 'Brands'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('master_data_add_fab'),
        backgroundColor: AppColors.primary,
        onPressed: _tabController.index == 0 ? _addCategory : _addBrand,
        child: const Icon(Icons.add),
      ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: Colors.red))))
          : TabBarView(
              controller: _tabController,
              children: [
                _buildList(_categories, _deactivateCategory, 'No categories yet'),
                _buildList(_brands, _deactivateBrand, 'No brands yet'),
              ],
            ),
    );
  }
}
