import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/auth_session.dart';
import '../../core/local_db.dart';
import '../../core/sync_service.dart';
import '../auth/generate_pairing_code_screen.dart';
import '../auth/login_screen.dart';
import '../khata/khata_customer_list_screen.dart';
import 'cart_model.dart';
import 'cart_screen.dart';
import 'product.dart';
import 'product_repository.dart';

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

  Future<void> _syncNow() async {
    final syncService = context.read<SyncService>();
    final result = await syncService.syncPendingInvoices();
    if (!mounted) return;
    await _refreshPendingSyncCount();
    final message = result.synced == 0 && result.failed == 0
        ? (result.remaining > 0 ? 'Still offline — nothing synced' : 'Nothing to sync')
        : 'Synced ${result.synced} sale(s)'
            '${result.failed > 0 ? ', ${result.failed} need review' : ''}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
            tooltip: 'Sync pending sales',
            icon: Badge(
              key: const Key('pending_sync_badge'),
              label: Text('$_pendingSyncCount'),
              isLabelVisible: _pendingSyncCount > 0,
              child: const Icon(Icons.sync),
            ),
            onPressed: _syncNow,
          ),
          IconButton(
            key: const Key('khata_button'),
            icon: const Icon(Icons.account_balance_wallet_outlined),
            tooltip: 'Khata (customer credit ledger)',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const KhataCustomerListScreen()),
              );
            },
          ),
          if (session.hasPermission('device.manage'))
            IconButton(
              key: const Key('pair_device_button'),
              icon: const Icon(Icons.qr_code_2),
              tooltip: 'Pair a new device',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const GeneratePairingCodeScreen()),
                );
              },
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
