import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import 'supplier_api.dart';
import 'supplier_detail_screen.dart';

/// Entry point for the supplier payable feature — mirrors
/// khata_customer_list_screen.dart on the payable side: search/browse
/// suppliers, tap one to see their statement.
class SupplierListScreen extends StatefulWidget {
  const SupplierListScreen({super.key});

  @override
  State<SupplierListScreen> createState() => _SupplierListScreenState();
}

class _SupplierListScreenState extends State<SupplierListScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<SupplierSummary> _results = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(query));
  }

  Future<void> _search(String query) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = SupplierApi(context.read<ApiClient>());
      final results = await api.search(query);
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
      appBar: AppBar(title: const Text('Suppliers')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              key: const Key('supplier_search_field'),
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'Search by name, code, phone, or GSTIN',
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
                ? const Center(child: Text('No suppliers found'))
                : ListView.builder(
                    key: const Key('supplier_results_list'),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final s = _results[index];
                      return ListTile(
                        key: Key('supplier_${s.id}'),
                        leading: const Icon(Icons.local_shipping_outlined),
                        title: Text(s.name),
                        subtitle: Text('${s.supplierCode}${s.phone != null ? ' · ${s.phone}' : ''}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => SupplierDetailScreen(supplierId: s.id)),
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
