import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/auth_session.dart';
import '../auth/login_screen.dart';
import 'cart_model.dart';
import 'cart_screen.dart';
import 'product.dart';

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
  String? _error;

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
      final client = context.read<ApiClient>();
      final encoded = Uri.encodeQueryComponent(query);
      final response = await client.getAuthed('/api/v1/products/search?q=$encoded');
      final results = (response['results'] as List<dynamic>? ?? [])
          .map((e) => Product.fromSearchResult(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _results = results;
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
            key: const Key('cart_button'),
            icon: Badge(
              label: Text('${cart.itemCount}'),
              isLabelVisible: !cart.isEmpty,
              child: const Icon(Icons.shopping_cart),
            ),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CartScreen()),
              );
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
