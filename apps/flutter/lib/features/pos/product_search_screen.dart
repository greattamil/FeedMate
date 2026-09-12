import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/auth_session.dart';
import '../../core/local_db.dart';
import '../auth/generate_pairing_code_screen.dart';
import '../auth/login_screen.dart';
import '../eod/eod_screen.dart';
import '../khata/khata_customer_list_screen.dart';
import '../reports/reports_screen.dart';
import '../supplier/supplier_list_screen.dart';
import '../sync/outbox_screen.dart';
import 'cart_model.dart';
import 'cart_screen.dart';
import 'product.dart';
import 'product_repository.dart';

enum _MenuAction { khata, suppliers, reports, eod, pairDevice }

/// Product search, backed by the real Go backend's ranked search endpoint
/// (barcode > SKU > exact name > alias > fuzzy — see PRD A4). Tapping a
/// result adds it to the cart; the cart button navigates to checkout.
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
      appBar: AppBar(
        title: Text(session.displayName ?? 'Product Search'),
        actions: [
          IconButton(
            key: const Key('sync_button'),
            tooltip: 'Offline sales outbox',
            icon: Badge(
              key: const Key('pending_sync_badge'),
              label: Text('$_pendingSyncCount'),
              isLabelVisible: _pendingSyncCount > 0,
              child: const Icon(Icons.sync),
            ),
            onPressed: _openOutbox,
          ),
          PopupMenuButton<_MenuAction>(
            key: const Key('more_menu_button'),
            tooltip: 'More',
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
            ],
          ),
          IconButton(
            key: const Key('cart_button'),
            icon: Badge(
              label: Text('${cart.itemCount}'),
              isLabelVisible: !cart.isEmpty,
              child: const Icon(Icons.shopping_cart),
            ),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CartScreen()),
              );
              await _refreshPendingSyncCount();
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
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
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              key: const Key('search_field'),
              controller: _searchController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Scan barcode or search (English / Tamil / SKU)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_fromCache)
            Container(
              key: const Key('offline_cache_banner'),
              width: double.infinity,
              color: Colors.amber.shade100,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: const Text('Offline — showing cached products', style: TextStyle(fontSize: 12)),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: ListView.builder(
              key: const Key('results_list'),
              itemCount: _results.length,
              itemBuilder: (context, index) {
                final p = _results[index];
                return ListTile(
                  title: Text(p.name),
                  subtitle: Text([
                    p.sku,
                    if (p.localNameTa != null) p.localNameTa!,
                    p.matchType,
                  ].join(' · ')),
                  trailing: Text(
                    p.sellingPrice != null ? '₹${p.sellingPrice!.toStringAsFixed(2)}' : '—',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onTap: () {
                    context.read<CartModel>().addProduct(p);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Added ${p.name} to cart'), duration: const Duration(seconds: 1)),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
