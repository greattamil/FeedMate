import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/auth_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'product_admin_api.dart';
import 'product_form_screen.dart';

/// Read-only master-data view of one product, with Edit and
/// Activate/Deactivate actions (both gated on product.manage). Pops `true`
/// if anything changed, so the list screen behind it knows to refresh.
class ProductDetailScreen extends StatefulWidget {
  final String productId;

  const ProductDetailScreen({super.key, required this.productId});

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  ProductDetail? _product;
  bool _loading = true;
  bool _updatingStatus = false;
  bool _changed = false;
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
      final api = ProductAdminApi(context.read<ApiClient>());
      final detail = await api.getDetail(widget.productId);
      if (!mounted) return;
      setState(() {
        _product = detail;
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

  Future<void> _edit() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ProductFormScreen(existing: _product)),
    );
    if (saved == true) {
      _changed = true;
      await _load();
    }
  }

  Future<void> _toggleActive() async {
    final product = _product;
    if (product == null) return;
    final newActive = !product.active;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(newActive ? 'Activate Product' : 'Deactivate Product'),
        content: Text(newActive
            ? 'This product will become available again for sale, purchase, and receiving.'
            : 'This product will no longer appear in search, sale, or receiving screens. Its history is kept intact.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('product_detail_confirm_status_button'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(newActive ? 'Activate' : 'Deactivate'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _updatingStatus = true);
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      await api.setActive(product.id, newActive);
      _changed = true;
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _updatingStatus = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AuthSession>();
    final canManage = session.hasPermission('product.manage');
    final p = _product;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text(p?.name ?? 'Product', style: AppTypography.headline),
          actions: [
            if (canManage && p != null)
              IconButton(
                key: const Key('product_detail_edit_button'),
                icon: const Icon(Icons.edit_outlined),
                onPressed: _edit,
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
            : _error != null
                ? Center(child: Text(_error!, style: const TextStyle(color: AppColors.danger)))
                : p == null
                    ? const SizedBox.shrink()
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: AppDecorations.card(),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Text(p.name, style: AppTypography.displayMedium),
                                      ),
                                      Container(
                                        key: const Key('product_detail_status_badge'),
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        decoration: AppDecorations.pill(
                                          color: p.active ? AppColors.successContainer : AppColors.dangerContainer,
                                        ),
                                        child: Text(
                                          p.active ? 'ACTIVE' : 'INACTIVE',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: p.active ? AppColors.onSuccessContainer : AppColors.onDangerContainer,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (p.localNameTa != null) Text(p.localNameTa!, style: AppTypography.bodySecondary),
                                  const SizedBox(height: 4),
                                  Text('SKU: ${p.sku}', style: AppTypography.body),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                            _sectionCard('Pricing', [
                              _row('MRP', p.mrp != null ? '₹${p.mrp!.toStringAsFixed(2)}' : '—'),
                              _row('Selling price', p.sellingPrice != null ? '₹${p.sellingPrice!.toStringAsFixed(2)}' : '—'),
                              _row('Minimum price floor', p.minPriceFloor != null ? '₹${p.minPriceFloor!.toStringAsFixed(2)}' : '—'),
                            ]),
                            const SizedBox(height: 12),
                            _sectionCard('Inventory & reorder', [
                              _row('Pack size', p.packSize?.toString() ?? '—'),
                              _row('Standard weight (kg)', p.standardWeightKg?.toString() ?? '—'),
                              _row('Reorder level', p.reorderLevel?.toString() ?? '—'),
                              _row('Reorder target', p.reorderTarget?.toString() ?? '—'),
                            ]),
                            const SizedBox(height: 12),
                            _sectionCard('Tax', [
                              _row('HSN code', p.hsnCode ?? '—'),
                              _row('Tax profile', p.taxProfileId != null ? 'Configured' : 'Not set'),
                            ]),
                            const SizedBox(height: 12),
                            _sectionCard('Handling', [
                              _flagRow('Batch tracking required', p.batchRequired),
                              _flagRow('Expiry date required', p.expiryRequired),
                              _flagRow('Loose sale allowed', p.looseSaleAllowed),
                              _flagRow('Weighing scale required', p.scaleRequired),
                              _row('Product type', p.productType),
                            ]),
                            if (p.barcodes.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              _sectionCard(
                                'Barcodes',
                                [Wrap(spacing: 8, runSpacing: 4, children: p.barcodes.map((b) => Chip(label: Text(b))).toList())],
                              ),
                            ],
                            if (p.aliases.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              _sectionCard(
                                'Aliases',
                                [Wrap(spacing: 8, runSpacing: 4, children: p.aliases.map((a) => Chip(label: Text(a))).toList())],
                              ),
                            ],
                            if (canManage) ...[
                              const SizedBox(height: 24),
                              OutlinedButton.icon(
                                key: const Key('product_detail_toggle_status_button'),
                                onPressed: _updatingStatus ? null : _toggleActive,
                                icon: Icon(p.active ? Icons.block : Icons.check_circle_outline,
                                    color: p.active ? AppColors.danger : AppColors.success),
                                label: Text(
                                  p.active ? 'Deactivate Product' : 'Activate Product',
                                  style: TextStyle(color: p.active ? AppColors.danger : AppColors.success),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: p.active ? AppColors.danger : AppColors.success),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
      ),
    );
  }

  Widget _sectionCard(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppDecorations.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTypography.title),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTypography.bodySecondary),
          Text(value, style: AppTypography.body),
        ],
      ),
    );
  }

  Widget _flagRow(String label, bool value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTypography.bodySecondary),
          Icon(value ? Icons.check_circle : Icons.cancel, size: 18, color: value ? AppColors.success : AppColors.textTertiary),
        ],
      ),
    );
  }
}
