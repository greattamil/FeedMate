import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import 'cart_model.dart';
import 'pos_api.dart';

/// Cart/checkout screen: shows the cart, fetches a live server-computed
/// quote whenever it changes (never computes tax/totals itself — see
/// pos_api.dart), and finalizes a real invoice via the API on checkout.
///
/// Scope note: this only supports a single CASH tender for the full amount.
/// Split tenders (cash+UPI+credit) and a customer picker for Khata sales are
/// not yet wired into the UI, though the backend already supports both (see
/// docs/IMPLEMENTATION_STATUS.md).
class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  QuoteResult? _quote;
  bool _quoting = false;
  bool _checkingOut = false;
  String? _error;
  List<LocationInfo> _locations = [];
  String? _selectedLocationId;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadLocations();
    _refreshQuote();
  }

  Future<void> _loadLocations() async {
    try {
      final api = PosApi(context.read<ApiClient>());
      final locations = await api.listLocations();
      if (!mounted) return;
      setState(() {
        _locations = locations;
        if (locations.length == 1) {
          _selectedLocationId = locations.first.id;
        }
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed to load locations: ${e.message}');
    }
  }

  void _onCartChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _refreshQuote);
  }

  Future<void> _refreshQuote() async {
    final cart = context.read<CartModel>();
    if (cart.isEmpty) {
      setState(() {
        _quote = null;
        _error = null;
      });
      return;
    }
    setState(() {
      _quoting = true;
      _error = null;
    });
    try {
      final api = PosApi(context.read<ApiClient>());
      final quote = await api.quote(cart.lines);
      if (!mounted) return;
      setState(() {
        _quote = quote;
        _quoting = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _quoting = false;
      });
    }
  }

  Future<void> _checkout() async {
    final cart = context.read<CartModel>();
    final quote = _quote;
    if (quote == null || cart.isEmpty) return;
    if (_selectedLocationId == null) {
      setState(() => _error = 'Select a location before checkout');
      return;
    }

    setState(() {
      _checkingOut = true;
      _error = null;
    });
    try {
      final api = PosApi(context.read<ApiClient>());
      final result = await api.finalizeCashSale(
        lines: cart.lines,
        locationId: _selectedLocationId!,
        amount: quote.grandTotal,
      );
      if (!mounted) return;
      cart.clear();
      setState(() {
        _quote = null;
        _checkingOut = false;
      });
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Sale Complete'),
          content: Text('Invoice ${result.invoiceNumber}\nTotal: ₹${result.grandTotal.toStringAsFixed(2)}'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
          ],
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _checkingOut = false;
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartModel>();

    return Scaffold(
      appBar: AppBar(title: const Text('Cart')),
      body: Column(
        children: [
          Expanded(
            child: cart.isEmpty
                ? const Center(child: Text('Cart is empty'))
                : ListView.builder(
                    itemCount: cart.lines.length,
                    itemBuilder: (context, index) {
                      final line = cart.lines[index];
                      return ListTile(
                        title: Text(line.product.name),
                        subtitle: Text(line.product.sku),
                        leading: IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () {
                            cart.updateQuantity(line.product.id, line.quantity - Decimal.one);
                            _onCartChanged();
                          },
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(line.quantity.toString()),
                            IconButton(
                              icon: const Icon(Icons.add_circle_outline),
                              onPressed: () {
                                cart.updateQuantity(line.product.id, line.quantity + Decimal.one);
                                _onCartChanged();
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () {
                                cart.removeLine(line.product.id);
                                _onCartChanged();
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          if (_locations.length > 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<String>(
                initialValue: _selectedLocationId,
                decoration: const InputDecoration(labelText: 'Location'),
                items: _locations
                    .map((l) => DropdownMenuItem(value: l.id, child: Text(l.name)))
                    .toList(),
                onChanged: (value) => setState(() => _selectedLocationId = value),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _quoting
                        ? 'Calculating…'
                        : _quote != null
                            ? 'Total: ₹${_quote!.grandTotal.toStringAsFixed(2)}'
                            : 'Total: —',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    key: const Key('cart_total'),
                  ),
                ),
                FilledButton(
                  key: const Key('checkout_button'),
                  onPressed: (_quote != null && !_checkingOut) ? _checkout : null,
                  child: _checkingOut
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Charge Cash'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
