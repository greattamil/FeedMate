import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../pos/product.dart';
import '../pos/product_repository.dart';

/// Lets someone receiving stock search for and pick a product to add as a
/// GRN line. Pops with the selected Product, or null if cancelled. Mirrors
/// CustomerPickerScreen's search-as-you-type pattern.
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

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(query));
  }

  Future<void> _search(String query) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = context.read<ProductRepository>();
      final result = await repo.search(query);
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
      appBar: AppBar(title: const Text('Select Product')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              key: const Key('product_picker_search_field'),
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Search by name, Tamil, or SKU',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: _results.isEmpty && !_loading
                ? const Center(child: Text('Search for a product to receive'))
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final p = _results[index];
                      return ListTile(
                        key: Key('product_picker_result_${p.id}'),
                        title: Text(p.name),
                        subtitle: Text(p.sku),
                        onTap: () => Navigator.of(context).pop(p),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
