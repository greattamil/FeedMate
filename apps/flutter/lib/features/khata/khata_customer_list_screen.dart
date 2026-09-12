import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../pos/customer_api.dart';
import 'khata_detail_screen.dart';

/// Entry point for the Khata (credit ledger) feature: search/browse
/// customers, tap one to see their statement. See customer_picker_screen.dart
/// for the near-identical search UI used during checkout — kept as a
/// separate screen because that one *selects* a customer for a sale, while
/// this one *navigates* into their ledger, a different enough interaction to
/// not share a widget.
class KhataCustomerListScreen extends StatefulWidget {
  const KhataCustomerListScreen({super.key});

  @override
  State<KhataCustomerListScreen> createState() => _KhataCustomerListScreenState();
}

class _KhataCustomerListScreenState extends State<KhataCustomerListScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<CustomerSummary> _results = [];
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
      final api = CustomerApi(context.read<ApiClient>());
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
      appBar: AppBar(title: const Text('Khata — Customers')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              key: const Key('khata_search_field'),
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'Search by name, code, or phone',
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
                ? const Center(child: Text('No customers found'))
                : ListView.builder(
                    key: const Key('khata_results_list'),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final c = _results[index];
                      return ListTile(
                        key: Key('khata_customer_${c.id}'),
                        leading: const Icon(Icons.account_balance_wallet_outlined),
                        title: Text(c.name),
                        subtitle: Text('${c.customerCode}${c.phone != null ? ' · ${c.phone}' : ''}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => KhataDetailScreen(customerId: c.id)),
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
