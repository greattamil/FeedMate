import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/auth_session.dart';
import '../../core/local_db.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import '../auditlog/audit_log_screen.dart';
import '../auth/device_management_screen.dart';
import '../auth/generate_pairing_code_screen.dart';
import '../auth/login_screen.dart';
import '../contra/contra_screen.dart';
import '../eod/eod_screen.dart';
import '../khata/khata_customer_list_screen.dart';
import '../procurement/grn_history_screen.dart';
import '../procurement/grn_screen.dart';
import '../products/product_list_screen.dart';
import '../reports/reports_screen.dart';
import '../returns/return_screen.dart';
import '../staff/staff_list_screen.dart';
import '../supplier/supplier_list_screen.dart';
import '../sync/outbox_screen.dart';
import 'cart_model.dart';
import 'cart_screen.dart';
import 'invoice_history_screen.dart';
import 'product.dart';
import 'product_repository.dart';

enum _MenuAction { khata, suppliers, grn, grnHistory, returnSale, contra, products, invoiceHistory, reports, eod, pairDevice, manageDevices, auditLog, staff }

/// Modernized POS Counter & Product Catalog for FeedMate.
/// Backed by ranked search (barcode > SKU > exact name > alias > fuzzy).
class ProductSearchScreen extends StatefulWidget {
  const ProductSearchScreen({super.key});

  @override
  State<ProductSearchScreen> createState() => _ProductSearchScreenState();
}

class _ProductSearchScreenState extends State<ProductSearchScreen> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  List<Product> _results = [];
  bool _loading = false;
  bool _fromCache = false;
  String? _error;
  int _pendingSyncCount = 0;
  String _selectedCategory = 'All';

  static const _categories = [
    'All',
    'Cattle Feed',
    'Poultry Feed',
    'Mineral Mix',
    'Concentrate',
    'Grains & Raw',
  ];

  @override
  void initState() {
    super.initState();
    _refreshPendingSyncCount();
  }

  Future<void> _refreshPendingSyncCount() async {
    final localDb = context.read<LocalDatabase>();
    final count = await localDb.pendingInvoiceCount();
    if (!mounted) return;
    setState(() => _pendingSyncCount = count);
  }

  Future<void> _openOutbox() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const OutboxScreen()),
    );
    await _refreshPendingSyncCount();
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(query));
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
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
      final result = await repository.search(query);
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
    final session = context.watch<AuthSession>();
    final cart = context.watch<CartModel>();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(session.displayName ?? 'Product Search', style: AppTypography.headline),
        actions: [
          IconButton(
            key: const Key('sync_button'),
            tooltip: 'Offline sales outbox',
            icon: Badge(
              key: const Key('pending_sync_badge'),
              label: Text('$_pendingSyncCount'),
              isLabelVisible: _pendingSyncCount > 0,
              backgroundColor: AppColors.warning,
              child: const Icon(Icons.sync_rounded),
            ),
            onPressed: _openOutbox,
          ),
          PopupMenuButton<_MenuAction>(
            key: const Key('more_menu_button'),
            tooltip: 'More',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (action) {
              switch (action) {
                case _MenuAction.khata:
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const KhataCustomerListScreen()),
                  );
                  break;
                case _MenuAction.suppliers:
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SupplierListScreen()),
                  );
                  break;
                case _MenuAction.grn:
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const GrnScreen()),
                  );
                  break;
                case _MenuAction.grnHistory:
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const GrnHistoryScreen()),
                  );
                  break;
                case _MenuAction.returnSale:
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ReturnScreen()),
                  );
                  break;
                case _MenuAction.contra:
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ContraScreen()),
                  );
                  break;
                case _MenuAction.products:
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ProductListScreen()),
                  );
                  break;
                case _MenuAction.invoiceHistory:
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const InvoiceHistoryScreen()),
                  );
                  break;
                case _MenuAction.eod:
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const EodScreen()),
                  );
                  break;
                case _MenuAction.reports:
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ReportsScreen()),
                  );
                  break;
                case _MenuAction.pairDevice:
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const GeneratePairingCodeScreen()),
                  );
                  break;
                case _MenuAction.manageDevices:
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DeviceManagementScreen()),
                  );
                  break;
                case _MenuAction.auditLog:
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AuditLogScreen()),
                  );
                  break;
                case _MenuAction.staff:
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const StaffListScreen()),
                  );
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                key: Key('menu_item_khata'),
                value: _MenuAction.khata,
                child: ListTile(
                  leading: Icon(Icons.account_balance_wallet_outlined),
                  title: Text('Khata'),
                ),
              ),
              if (session.hasPermission('supplier.manage'))
                const PopupMenuItem(
                  key: Key('menu_item_suppliers'),
                  value: _MenuAction.suppliers,
                  child: ListTile(
                    leading: Icon(Icons.local_shipping_outlined),
                    title: Text('Suppliers'),
                  ),
                ),
              if (session.hasPermission('grn.post'))
                const PopupMenuItem(
                  key: Key('menu_item_grn'),
                  value: _MenuAction.grn,
                  child: ListTile(
                    leading: Icon(Icons.move_to_inbox_outlined),
                    title: Text('Receive Stock (GRN)'),
                  ),
                ),
              if (session.hasPermission('grn.post'))
                const PopupMenuItem(
                  key: Key('menu_item_grn_history'),
                  value: _MenuAction.grnHistory,
                  child: ListTile(
                    leading: Icon(Icons.history_rounded),
                    title: Text('GRN History'),
                  ),
                ),
              if (session.hasPermission('return.create'))
                const PopupMenuItem(
                  key: Key('menu_item_return'),
                  value: _MenuAction.returnSale,
                  child: ListTile(
                    leading: Icon(Icons.assignment_return_outlined),
                    title: Text('Sales Return'),
                  ),
                ),
              if (session.hasPermission('contra.approve'))
                const PopupMenuItem(
                  key: Key('menu_item_contra'),
                  value: _MenuAction.contra,
                  child: ListTile(
                    leading: Icon(Icons.undo_rounded),
                    title: Text('Contra / Buy-Back'),
                  ),
                ),
              if (session.hasPermission('product.manage'))
                const PopupMenuItem(
                  key: Key('menu_item_products'),
                  value: _MenuAction.products,
                  child: ListTile(
                    leading: Icon(Icons.inventory_2_outlined),
                    title: Text('Products'),
                  ),
                ),
              if (session.hasPermission('pos.sell'))
                const PopupMenuItem(
                  key: Key('menu_item_invoice_history'),
                  value: _MenuAction.invoiceHistory,
                  child: ListTile(
                    leading: Icon(Icons.receipt_long_outlined),
                    title: Text('Invoice History'),
                  ),
                ),
              if (session.hasPermission('report.view'))
                const PopupMenuItem(
                  key: Key('menu_item_reports'),
                  value: _MenuAction.reports,
                  child: ListTile(
                    leading: Icon(Icons.bar_chart_outlined),
                    title: Text('Reports'),
                  ),
                ),
              if (session.hasPermission('cash.eod_close'))
                const PopupMenuItem(
                  key: Key('menu_item_eod'),
                  value: _MenuAction.eod,
                  child: ListTile(
                    leading: Icon(Icons.point_of_sale_outlined),
                    title: Text('End of Day'),
                  ),
                ),
              if (session.hasPermission('device.manage'))
                const PopupMenuItem(
                  key: Key('menu_item_pair_device'),
                  value: _MenuAction.pairDevice,
                  child: ListTile(
                    leading: Icon(Icons.qr_code_2),
                    title: Text('Pair a new device'),
                  ),
                ),
              if (session.hasPermission('user.manage'))
                const PopupMenuItem(
                  key: Key('menu_item_staff'),
                  value: _MenuAction.staff,
                  child: ListTile(
                    leading: Icon(Icons.badge_outlined),
                    title: Text('Staff'),
                  ),
                ),
              if (session.hasPermission('device.manage'))
                const PopupMenuItem(
                  key: Key('menu_item_manage_devices'),
                  value: _MenuAction.manageDevices,
                  child: ListTile(
                    leading: Icon(Icons.devices_other_outlined),
                    title: Text('Manage Devices'),
                  ),
                ),
              if (session.hasPermission('tenant.admin'))
                const PopupMenuItem(
                  key: Key('menu_item_audit_log'),
                  value: _MenuAction.auditLog,
                  child: ListTile(
                    leading: Icon(Icons.fact_check_outlined),
                    title: Text('Audit Log'),
                  ),
                ),
            ],
          ),
          IconButton(
            key: const Key('cart_button'),
            tooltip: 'View Cart',
            icon: Badge(
              label: Text('${cart.itemCount}'),
              isLabelVisible: !cart.isEmpty,
              backgroundColor: AppColors.primary,
              child: const Icon(Icons.shopping_cart_rounded),
            ),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CartScreen()),
              );
              await _refreshPendingSyncCount();
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Logout',
            onPressed: () async {
              await session.logout();
              if (!context.mounted) return;
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
              );
            },
          ),
        ],
      ),
      body: Column(
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
                const SizedBox(height: 10),
                // Horizontal category pill selector
                SizedBox(
                  height: 32,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _categories.length,
                    itemBuilder: (context, index) {
                      final cat = _categories[index];
                      final isSelected = cat == _selectedCategory;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          selected: isSelected,
                          showCheckmark: false,
                          label: Text(cat),
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
                          onSelected: (selected) {
                            setState(() => _selectedCategory = cat);
                            if (cat != 'All') {
                              _searchController.text = cat;
                              _search(cat);
                            }
                          },
                        ),
                      );
                    },
                  ),
                ),
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
                          _searchController.text.isEmpty
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
      ),
    );
  }
}
