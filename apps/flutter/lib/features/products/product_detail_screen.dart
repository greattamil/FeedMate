import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/auth_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import '../reports/reports_api.dart';
import 'product_admin_api.dart';
import 'product_form_screen.dart';
import '../../core/number_format.dart';

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
  StockSummaryLine? _stock;
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
      final client = context.read<ApiClient>();
      final api = ProductAdminApi(client);
      final detail = await api.getDetail(widget.productId);
      if (!mounted) return;
      setState(() {
        _product = detail;
        _loading = false;
      });
      // Real live stock
      try {
        final stock = await ReportsApi(client).stockSummary();
        StockSummaryLine? match;
        for (final l in stock.lines) {
          if (l.productId == widget.productId) {
            match = l;
            break;
          }
        }
        if (mounted) setState(() => _stock = match);
      } catch (_) {}
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
            style: FilledButton.styleFrom(
              backgroundColor: newActive ? AppColors.success : AppColors.danger,
            ),
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

  Widget _sectionCard(
    String title,
    String subtitle,
    IconData icon,
    Color iconColor,
    LinearGradient iconGradient,
    List<Widget> children,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppDecorations.borderRadiusLg,
        border: Border.all(color: AppColors.border),
        boxShadow: AppDecorations.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: iconGradient,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: iconColor.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Icon(icon, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppTypography.title.copyWith(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Divider(height: 1, color: AppColors.border),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: AppColors.textSecondary),
                const SizedBox(width: 8),
              ],
              Text(label, style: AppTypography.bodySecondary),
            ],
          ),
          Text(value, style: AppTypography.body.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _flagRow(String label, bool value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTypography.bodySecondary),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: value ? AppColors.successContainer : AppColors.surfaceSecondary,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: value ? AppColors.success.withValues(alpha: 0.3) : AppColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  value ? Icons.check_circle_rounded : Icons.cancel_outlined,
                  size: 13,
                  color: value ? AppColors.success : AppColors.textSecondary,
                ),
                const SizedBox(width: 4),
                Text(
                  value ? 'Yes' : 'No',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: value ? AppColors.onSuccessContainer : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
          title: Text(p?.name ?? 'Product Detail', style: AppTypography.headline),
          actions: [
            if (canManage && p != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: IconButton(
                  key: const Key('product_detail_edit_button'),
                  tooltip: 'Edit Product',
                  icon: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.edit_rounded, color: AppColors.primary, size: 20),
                  ),
                  onPressed: _edit,
                ),
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
            : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, style: const TextStyle(color: AppColors.danger)),
                        const SizedBox(height: 12),
                        FilledButton(onPressed: _load, child: const Text('Retry')),
                      ],
                    ),
                  )
                : p == null
                    ? const SizedBox.shrink()
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            // Hero Product Card
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: AppDecorations.borderRadiusLg,
                                border: Border.all(color: AppColors.border),
                                boxShadow: AppDecorations.cardShadow,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 52,
                                        height: 52,
                                        decoration: BoxDecoration(
                                          gradient: _avatarGradient(p.name),
                                          borderRadius: BorderRadius.circular(14),
                                          boxShadow: [
                                            BoxShadow(
                                              color: _avatarGradient(p.name).colors.first.withValues(alpha: 0.3),
                                              blurRadius: 10,
                                              offset: const Offset(0, 4),
                                            ),
                                          ],
                                        ),
                                        child: Center(
                                          child: Text(
                                            _getInitials(p.name),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w800,
                                              fontSize: 18,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              p.name,
                                              style: AppTypography.displayMedium.copyWith(fontSize: 18, fontWeight: FontWeight.bold),
                                            ),
                                            if (p.localNameTa != null && p.localNameTa!.isNotEmpty) ...[
                                              const SizedBox(height: 2),
                                              Text(p.localNameTa!, style: AppTypography.bodySecondary),
                                            ],
                                          ],
                                        ),
                                      ),
                                      Container(
                                        key: const Key('product_detail_status_badge'),
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                        decoration: BoxDecoration(
                                          color: p.active ? AppColors.successContainer : AppColors.dangerContainer,
                                          borderRadius: BorderRadius.circular(AppDecorations.radiusFull),
                                          border: Border.all(
                                            color: p.active ? AppColors.success.withValues(alpha: 0.3) : AppColors.danger.withValues(alpha: 0.3),
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Container(
                                              width: 6,
                                              height: 6,
                                              decoration: BoxDecoration(
                                                color: p.active ? AppColors.success : AppColors.danger,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                            const SizedBox(width: 5),
                                            Text(
                                              p.active ? 'ACTIVE' : 'INACTIVE',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w800,
                                                color: p.active ? AppColors.onSuccessContainer : AppColors.onDangerContainer,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: AppColors.surfaceSecondary,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: AppColors.border),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.qr_code_rounded, size: 14, color: AppColors.textSecondary),
                                        const SizedBox(width: 6),
                                        Text('SKU: ${p.sku}', style: AppTypography.body.copyWith(fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),

                            // Real Live Stock Card (when available)
                            if (_stock != null) ...[
                              Container(
                                padding: const EdgeInsets.all(16),
                                margin: const EdgeInsets.only(bottom: 16),
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: AppDecorations.borderRadiusLg,
                                  border: Border.all(color: AppColors.border),
                                  boxShadow: AppDecorations.cardShadow,
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        gradient: AppColors.gradientEmerald,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: const Icon(Icons.warehouse_rounded, color: Colors.white, size: 20),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Text('Current On-Hand Stock', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${_stock!.onHandQty} ${_stock!.uomCode}',
                                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.primary),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: _stock!.status == 'OK' ? AppColors.successContainer : AppColors.warningContainer,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        _stock!.status,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: _stock!.status == 'OK' ? AppColors.onSuccessContainer : AppColors.onWarningContainer,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],

                            // Pricing Section
                            _sectionCard(
                              'Pricing & Valuation',
                              'Standard rates, MRP and minimum floor caps',
                              Icons.payments_rounded,
                              AppColors.secondary,
                              AppColors.gradientIndigo,
                              [
                                _row('MRP', p.mrp != null ? money(p.mrp!) : '—'),
                                _row('Selling price', p.sellingPrice != null ? money(p.sellingPrice!) : '—'),
                                _row('Minimum price floor', p.minPriceFloor != null ? money(p.minPriceFloor!) : '—'),
                              ],
                            ),

                            // Inventory & Reorder
                            _sectionCard(
                              'Inventory & Reorder Planning',
                              'Pack dimensions and replenishment trigger thresholds',
                              Icons.inventory_2_rounded,
                              AppColors.accent,
                              AppColors.gradientCyan,
                              [
                                _row('Pack size', p.packSize?.toString() ?? '—'),
                                _row('Standard weight (kg)', p.standardWeightKg?.toString() ?? '—'),
                                _row('Reorder level', p.reorderLevel?.toString() ?? '—'),
                                _row('Reorder target', p.reorderTarget?.toString() ?? '—'),
                              ],
                            ),

                            // Tax & Statutory
                            _sectionCard(
                              'Tax & Statutory Classification',
                              'HSN tax profile and GST invoicing category',
                              Icons.receipt_long_rounded,
                              AppColors.warning,
                              AppColors.gradientAmber,
                              [
                                _row('HSN code', p.hsnCode ?? '—'),
                                _row('Tax profile', p.taxProfileId != null ? 'Configured' : 'Not set'),
                              ],
                            ),

                            // Handling & Rules
                            _sectionCard(
                              'Handling & Scale Policies',
                              'Batch, expiry, and scale requirements for retail checkout',
                              Icons.tune_rounded,
                              const Color(0xFF7C3AED),
                              AppColors.gradientPurple,
                              [
                                _flagRow('Batch tracking required', p.batchRequired),
                                _flagRow('Expiry date required', p.expiryRequired),
                                _flagRow('Loose sale allowed', p.looseSaleAllowed),
                                _flagRow('Weighing scale required', p.scaleRequired),
                                _row('Product type', p.productType),
                              ],
                            ),

                            // Barcodes
                            if (p.barcodes.isNotEmpty) ...[
                              _sectionCard(
                                'Barcodes',
                                'Registered EAN / UPC scan codes',
                                Icons.qr_code_2_rounded,
                                AppColors.primary,
                                AppColors.gradientEmerald,
                                [
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: p.barcodes.map((b) => Chip(
                                      avatar: const Icon(Icons.qr_code_rounded, size: 16),
                                      label: Text(b, style: const TextStyle(fontWeight: FontWeight.w600)),
                                      backgroundColor: AppColors.surfaceSecondary,
                                      side: const BorderSide(color: AppColors.border),
                                    )).toList(),
                                  ),
                                ],
                              ),
                            ],

                            // Aliases
                            if (p.aliases.isNotEmpty) ...[
                              _sectionCard(
                                'Aliases',
                                'Colloquial & regional search names',
                                Icons.translate_rounded,
                                AppColors.secondary,
                                AppColors.gradientIndigo,
                                [
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: p.aliases.map((a) => Chip(
                                      label: Text(a),
                                      backgroundColor: AppColors.surfaceSecondary,
                                      side: const BorderSide(color: AppColors.border),
                                    )).toList(),
                                  ),
                                ],
                              ),
                            ],

                            // Activate / Deactivate Button
                            if (canManage) ...[
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                key: const Key('product_detail_toggle_status_button'),
                                onPressed: _updatingStatus ? null : _toggleActive,
                                icon: Icon(
                                  p.active ? Icons.block_rounded : Icons.check_circle_rounded,
                                  color: p.active ? AppColors.danger : AppColors.success,
                                  size: 18,
                                ),
                                label: Text(
                                  p.active ? 'Deactivate Product' : 'Activate Product',
                                  style: TextStyle(
                                    color: p.active ? AppColors.danger : AppColors.success,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  side: BorderSide(
                                    color: p.active ? AppColors.danger : AppColors.success,
                                    width: 1.5,
                                  ),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                              const SizedBox(height: 32),
                            ],
                          ],
                        ),
                      ),
      ),
    );
  }
}
