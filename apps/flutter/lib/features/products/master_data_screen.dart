import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'product_admin_api.dart';

/// Manage the two product lookup tables a shop owner routinely extends
/// while onboarding new product lines: categories and brands. Full CRUD —
/// add, rename, and activate/deactivate — since a typo previously meant
/// deactivate-and-recreate, losing the id every existing product pointed
/// to. UOMs and tax profiles stay out of scope here — UOMs are a
/// largely-fixed global seed and tax profiles have their own dedicated
/// screen (see tax_profile_screen.dart).
class MasterDataScreen extends StatefulWidget {
  const MasterDataScreen({super.key});

  @override
  State<MasterDataScreen> createState() => _MasterDataScreenState();
}

class _MasterDataScreenState extends State<MasterDataScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  List<CategoryDetail> _categories = [];
  List<BrandDetail> _brands = [];
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
      final categories = await api.listAllCategories();
      final brands = await api.listAllBrands();
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
    final result = await _promptForNameAndLocal(title: 'Add Category', fieldKey: 'category_name_field');
    if (result == null) return;
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      await api.createCategory(name: result.$1, localName: result.$2);
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _editCategory(CategoryDetail category) async {
    final result = await _promptForNameAndLocal(
      title: 'Edit Category',
      fieldKey: 'category_edit_name_field',
      initialName: category.name,
      initialLocalName: category.localName,
    );
    if (result == null) return;
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      await api.updateCategory(category.id, name: result.$1, localName: result.$2);
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _addBrand() async {
    final result = await _promptForNameAndLocal(title: 'Add Brand', fieldKey: 'brand_name_field');
    if (result == null) return;
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      await api.createBrand(name: result.$1, localName: result.$2);
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _editBrand(BrandDetail brand) async {
    final result = await _promptForNameAndLocal(
      title: 'Edit Brand',
      fieldKey: 'brand_edit_name_field',
      initialName: brand.name,
      initialLocalName: brand.localName,
    );
    if (result == null) return;
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      await api.updateBrand(brand.id, name: result.$1, localName: result.$2);
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Shared add/edit dialog collecting a name and optional local-language
  /// name. Returns (name, localName) or null if cancelled.
  Future<(String, String?)?> _promptForNameAndLocal({
    required String title,
    required String fieldKey,
    String? initialName,
    String? initialLocalName,
  }) async {
    final nameController = TextEditingController(text: initialName ?? '');
    final localController = TextEditingController(text: initialLocalName ?? '');
    final isEdit = initialName != null;
    return showDialog<(String, String?)>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isEdit ? AppColors.infoContainer : AppColors.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                isEdit ? Icons.edit_rounded : Icons.add_circle_outline_rounded,
                color: isEdit ? AppColors.onInfoContainer : AppColors.primary,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Text(title),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: Key(fieldKey),
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'Enter name'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: Key('${fieldKey}_local'),
              controller: localController,
              decoration: const InputDecoration(labelText: 'Local name (Tamil, optional)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            key: Key('${fieldKey}_submit'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isEmpty) return;
              final local = localController.text.trim();
              Navigator.of(context).pop((name, local.isEmpty ? null : local));
            },
            child: Text(isEdit ? 'Save' : 'Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleCategoryActive(CategoryDetail category) async {
    if (category.active) {
      final confirmed = await _confirmDeactivate(category.name);
      if (confirmed != true) return;
    }
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      await api.setCategoryActive(category.id, !category.active);
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _toggleBrandActive(BrandDetail brand) async {
    if (brand.active) {
      final confirmed = await _confirmDeactivate(brand.name);
      if (confirmed != true) return;
    }
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      await api.setBrandActive(brand.id, !brand.active);
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
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.dangerContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.warning_amber_rounded, color: AppColors.danger, size: 22),
            ),
            const SizedBox(width: 12),
            const Text('Deactivate?'),
          ],
        ),
        content: Text('$name will no longer appear when creating or editing products.', style: const TextStyle(height: 1.4)),
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

  Widget _buildCategoryList() {
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    if (_categories.isEmpty) return _emptyState('No categories yet');
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _categories.length,
      itemBuilder: (context, index) {
        final item = _categories[index];
        return _row(
          id: item.id,
          title: item.name,
          subtitle: item.localName,
          active: item.active,
          onEdit: () => _editCategory(item),
          onToggleActive: () => _toggleCategoryActive(item),
        );
      },
    );
  }

  Widget _buildBrandList() {
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    if (_brands.isEmpty) return _emptyState('No brands yet');
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _brands.length,
      itemBuilder: (context, index) {
        final item = _brands[index];
        return _row(
          id: item.id,
          title: item.name,
          subtitle: item.localName,
          active: item.active,
          onEdit: () => _editBrand(item),
          onToggleActive: () => _toggleBrandActive(item),
        );
      },
    );
  }

  Widget _emptyState(String label) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.category_outlined, size: 48, color: Color(0xFF94A3B8)),
          const SizedBox(height: 10),
          Text(label, style: AppTypography.bodySecondary),
        ],
      ),
    );
  }

  Widget _row({
    required String id,
    required String title,
    required String? subtitle,
    required bool active,
    required VoidCallback onEdit,
    required VoidCallback onToggleActive,
  }) {
    return Opacity(
      opacity: active ? 1 : 0.55,
      child: Container(
        key: Key('master_data_item_$id'),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppDecorations.borderRadiusMd,
          border: Border.all(color: AppColors.border),
          boxShadow: AppDecorations.cardShadow,
        ),
        child: ListTile(
          onTap: onEdit,
          leading: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.surfaceSecondary,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.label_outline_rounded, color: AppColors.primary, size: 18),
          ),
          title: Text(title, style: AppTypography.title),
          subtitle: Text(subtitle == null ? (active ? '' : 'Inactive') : (active ? subtitle : '$subtitle · Inactive')),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: Key('master_data_edit_$id'),
                icon: const Icon(Icons.edit_outlined, color: AppColors.textSecondary),
                tooltip: 'Edit',
                onPressed: onEdit,
              ),
              IconButton(
                key: Key('master_data_toggle_active_$id'),
                icon: Icon(
                  active ? Icons.delete_outline_rounded : Icons.restore_rounded,
                  color: active ? AppColors.danger : AppColors.success,
                ),
                tooltip: active ? 'Deactivate' : 'Reactivate',
                onPressed: onToggleActive,
              ),
            ],
          ),
        ),
      ),
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
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primary,
          tabs: const [
            Tab(text: 'Categories', icon: Icon(Icons.category_rounded, size: 18)),
            Tab(text: 'Brands', icon: Icon(Icons.business_rounded, size: 18)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: null,
        key: const Key('master_data_add_fab'),
        backgroundColor: AppColors.primary,
        onPressed: _tabController.index == 0 ? _addCategory : _addBrand,
        child: const Icon(Icons.add_rounded),
      ),
      body: _error != null
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
          : TabBarView(
              controller: _tabController,
              children: [
                _buildCategoryList(),
                _buildBrandList(),
              ],
            ),
    );
  }
}
