import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/local_db.dart';
import 'cart_model.dart';
import 'customer_api.dart';
import 'customer_picker_screen.dart';
import 'pos_api.dart';

/// Cart/checkout screen: shows the cart, fetches a live server-computed
/// quote whenever it changes (never computes tax/totals itself — see
/// pos_api.dart), and finalizes a real invoice via the API on checkout.
///
/// Supports a single full-amount tender, either CASH or CREDIT against a
/// selected customer's Khata. Split tenders (cash+UPI+credit in one sale)
/// are not yet wired into the UI, though the backend already supports it.
///
/// Offline: if the live quote call fails on a network error, the screen
/// shows a locally estimated total (from cached selling prices, tax
/// excluded) and switches to CASH-only. Checkout in that state does not call
/// finalize at all — it queues a sale *intent* (lines/location/tender
/// method) to the on-device outbox and lets SyncService materialize the real
/// priced invoice once a connection exists, because only the server can
/// compute the total the tender actually has to match (see sync_service.dart).
/// CREDIT is unavailable offline: a credit sale's limit check needs the
/// customer's live balance, which by definition isn't available offline.
class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  QuoteResult? _quote;
  bool _quoting = false;
  bool _checkingOut = false;
  bool _offline = false;
  String? _error;
  List<LocationInfo> _locations = [];
  String? _selectedLocationId;
  Timer? _debounce;
  String _tenderMethod = 'CASH';
  CustomerSummary? _selectedCustomer;

  @override
  void initState() {
    super.initState();
    _loadLocations();
    _refreshQuote();
  }

  Future<void> _loadLocations() async {
    final localDb = context.read<LocalDatabase>();
    try {
      final api = PosApi(context.read<ApiClient>());
      final locations = await api.listLocations();
      await localDb.setCache(
        'locations',
        jsonEncode(locations.map((l) => {'id': l.id, 'name': l.name}).toList()),
      );
      if (!mounted) return;
      setState(() {
        _locations = locations;
        if (locations.length == 1) {
          _selectedLocationId = locations.first.id;
        }
      });
    } on ApiError catch (e) {
      if (e.code == 'NETWORK_ERROR') {
        final cached = await localDb.getCache('locations');
        if (cached != null) {
          final locations = (jsonDecode(cached) as List<dynamic>)
              .map((l) => LocationInfo(id: l['id'] as String, name: l['name'] as String))
              .toList();
          if (!mounted) return;
          setState(() {
            _locations = locations;
            if (locations.length == 1) _selectedLocationId = locations.first.id;
          });
          return;
        }
      }
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
        _offline = false;
        _quoting = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      final offline = e.code == 'NETWORK_ERROR';
      setState(() {
        _quote = null;
        _offline = offline;
        _error = offline ? null : e.message;
        _quoting = false;
        if (offline) _tenderMethod = 'CASH'; // credit needs a live balance check
      });
    }
  }

  /// A rough, tax-exclusive estimate from cached selling prices — shown only
  /// so the cashier isn't checking out blind while offline. Never sent to
  /// the server: the queued intent carries quantities only, and the real
  /// total is whatever the server computes at sync time.
  Decimal? _estimatedOfflineTotal(CartModel cart) {
    Decimal total = Decimal.zero;
    for (final line in cart.lines) {
      final price = line.product.sellingPrice;
      if (price == null) return null;
      total += price * line.quantity;
    }
    return total;
  }

  Future<void> _pickCustomer() async {
    final selected = await Navigator.of(context).push<CustomerSummary>(
      MaterialPageRoute(builder: (_) => const CustomerPickerScreen()),
    );
    if (selected != null && mounted) {
      setState(() => _selectedCustomer = selected);
    }
  }

  Future<void> _checkout({bool overrideCreditLimit = false, String? overrideReason}) async {
    final cart = context.read<CartModel>();
    if (cart.isEmpty) return;
    if (_selectedLocationId == null) {
      setState(() => _error = 'Select a location before checkout');
      return;
    }
    if (_tenderMethod == 'CREDIT' && _selectedCustomer == null) {
      setState(() => _error = 'Select a customer for a credit sale');
      return;
    }

    if (_offline) {
      await _queueOfflineSale(cart);
      return;
    }

    final quote = _quote;
    if (quote == null) return;

    setState(() {
      _checkingOut = true;
      _error = null;
    });
    try {
      final api = PosApi(context.read<ApiClient>());
      final result = _tenderMethod == 'CREDIT'
          ? await api.finalizeCreditSale(
              lines: cart.lines,
              locationId: _selectedLocationId!,
              amount: quote.grandTotal,
              customerId: _selectedCustomer!.id,
              overrideCreditLimit: overrideCreditLimit,
              overrideReason: overrideReason,
            )
          : await api.finalizeCashSale(
              lines: cart.lines,
              locationId: _selectedLocationId!,
              amount: quote.grandTotal,
            );
      if (!mounted) return;
      cart.clear();
      setState(() {
        _quote = null;
        _checkingOut = false;
        _selectedCustomer = null;
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
      setState(() => _checkingOut = false);
      if (e.code == 'CREDIT_LIMIT_EXCEEDED') {
        await _promptCreditOverride(e.message);
      } else if (e.code == 'NETWORK_ERROR') {
        // Connectivity dropped between the last successful quote and
        // tapping checkout — fall back to queuing rather than losing the
        // sale outright.
        setState(() => _offline = true);
        await _queueOfflineSale(cart);
      } else {
        setState(() => _error = e.message);
      }
    }
  }

  Future<void> _queueOfflineSale(CartModel cart) async {
    setState(() {
      _checkingOut = true;
      _error = null;
    });
    final localDb = context.read<LocalDatabase>();
    final clientTransactionId = const Uuid().v4();
    final intent = {
      'client_transaction_id': clientTransactionId,
      'location_id': _selectedLocationId,
      'tender_method': 'CASH',
      'customer_id': null,
      'lines': cart.lines
          .map((l) => {'product_id': l.product.id, 'quantity': l.quantity.toString()})
          .toList(),
    };
    await localDb.enqueueInvoice(clientTransactionId: clientTransactionId, payloadJson: jsonEncode(intent));
    if (!mounted) return;
    final estimate = _estimatedOfflineTotal(cart);
    cart.clear();
    setState(() {
      _checkingOut = false;
      _quote = null;
    });
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sale Queued (Offline)'),
        content: Text(
          'No connection — this sale will be priced and sent to the server '
          'automatically once online.\n\n'
          '${estimate != null ? "Estimated total: ₹${estimate.toStringAsFixed(2)}\n\n" : ""}'
          'Use the sync button on the search screen to sync manually.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  /// A sale that exceeds the customer's credit limit is rejected by the
  /// server unless the cashier supplies an explicit reason (see
  /// pos.ErrCreditLimitExceeded / pos_handlers.go) — permission to override
  /// is checked server-side; this dialog only collects the required reason.
  Future<void> _promptCreditOverride(String serverMessage) async {
    final reasonController = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Credit Limit Exceeded'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(serverMessage),
            const SizedBox(height: 12),
            TextField(
              key: const Key('override_reason_field'),
              controller: reasonController,
              decoration: const InputDecoration(labelText: 'Reason for override'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(reasonController.text.trim()),
            child: const Text('Override & Charge'),
          ),
        ],
      ),
    );
    if (reason != null && reason.isNotEmpty) {
      await _checkout(overrideCreditLimit: true, overrideReason: reason);
    } else if (mounted) {
      setState(() => _error = 'Credit sale cancelled: limit exceeded');
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
    final estimate = _offline ? _estimatedOfflineTotal(cart) : null;
    final canCheckout = !_checkingOut && !cart.isEmpty && (_quote != null || (_offline && _selectedLocationId != null));

    return Scaffold(
      appBar: AppBar(title: const Text('Cart')),
      body: Column(
        children: [
          if (_offline)
            Container(
              key: const Key('offline_checkout_banner'),
              width: double.infinity,
              color: Colors.amber.shade100,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: const Text(
                'Offline — sale will be queued and priced when back online',
                style: TextStyle(fontSize: 12),
              ),
            ),
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<String>(
                    key: const Key('tender_method_toggle'),
                    segments: const [
                      ButtonSegment(value: 'CASH', label: Text('Cash')),
                      ButtonSegment(value: 'CREDIT', label: Text('Credit (Khata)'), enabled: true),
                    ],
                    selected: {_tenderMethod},
                    onSelectionChanged: _offline
                        ? null
                        : (selection) => setState(() => _tenderMethod = selection.first),
                  ),
                ),
              ],
            ),
          ),
          if (_tenderMethod == 'CREDIT' && !_offline)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: ListTile(
                key: const Key('customer_picker_tile'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: Text(_selectedCustomer?.name ?? 'Select customer'),
                subtitle: _selectedCustomer != null ? Text(_selectedCustomer!.customerCode) : null,
                trailing: const Icon(Icons.chevron_right),
                onTap: _pickCustomer,
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
                            : (estimate != null
                                ? 'Estimated: ₹${estimate.toStringAsFixed(2)}'
                                : 'Total: —'),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    key: const Key('cart_total'),
                  ),
                ),
                FilledButton(
                  key: const Key('checkout_button'),
                  onPressed: canCheckout ? () => _checkout() : null,
                  child: _checkingOut
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_offline
                          ? 'Queue Sale (Offline)'
                          : (_tenderMethod == 'CREDIT' ? 'Charge to Khata' : 'Charge Cash')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
