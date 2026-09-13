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
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('Checkout & Cart', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      ),
      body: Column(
        children: [
          if (_offline)
            Container(
              key: const Key('offline_checkout_banner'),
              width: double.infinity,
              color: const Color(0xFFFEF3C7),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: const [
                  Icon(Icons.wifi_off_rounded, color: Color(0xFFD97706), size: 18),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Offline — sale will be queued and priced when back online',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF92400E)),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: cart.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.shopping_cart_outlined, size: 56, color: Color(0xFF94A3B8)),
                        SizedBox(height: 12),
                        Text('Cart is empty', style: TextStyle(color: Color(0xFF64748B), fontSize: 16, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: cart.lines.length,
                    itemBuilder: (context, index) {
                      final line = cart.lines[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                          boxShadow: const [
                            BoxShadow(color: Color(0x060F172A), blurRadius: 10, offset: Offset(0, 2)),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: const Color(0xFFE6F4EA),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Center(
                                child: Icon(Icons.grain_rounded, color: Color(0xFF0F766E), size: 20),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(line.product.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                  const SizedBox(height: 2),
                                  Text(line.product.sku, style: const TextStyle(color: Color(0xFF64748B), fontSize: 12)),
                                  if (line.product.sellingPrice != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      '₹${line.product.sellingPrice!.toStringAsFixed(2)} each',
                                      style: const TextStyle(color: Color(0xFF0F766E), fontWeight: FontWeight.w600, fontSize: 12),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            // Stepper Controls
                            Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(30),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.remove_circle_outline, size: 20),
                                    padding: const EdgeInsets.all(6),
                                    constraints: const BoxConstraints(),
                                    color: const Color(0xFF0F766E),
                                    onPressed: () {
                                      cart.updateQuantity(line.product.id, line.quantity - Decimal.one);
                                      _onCartChanged();
                                    },
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    child: Text(
                                      line.quantity.toString(),
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.add_circle_outline, size: 20),
                                    padding: const EdgeInsets.all(6),
                                    constraints: const BoxConstraints(),
                                    color: const Color(0xFF0F766E),
                                    onPressed: () {
                                      cart.updateQuantity(line.product.id, line.quantity + Decimal.one);
                                      _onCartChanged();
                                    },
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20, color: Color(0xFFE11D48)),
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
          // Location & Tender Controls Container
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
              boxShadow: [
                BoxShadow(color: Color(0x0A0F172A), blurRadius: 16, offset: Offset(0, -4)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_locations.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: DropdownButtonFormField<String>(
                      initialValue: _selectedLocationId,
                      decoration: const InputDecoration(
                        labelText: 'Fulfillment Location',
                        prefixIcon: Icon(Icons.store_rounded, size: 18),
                        isDense: true,
                      ),
                      items: _locations
                          .map((l) => DropdownMenuItem(value: l.id, child: Text(l.name)))
                          .toList(),
                      onChanged: (value) => setState(() => _selectedLocationId = value),
                    ),
                  ),
                // Tender Toggle
                Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<String>(
                        key: const Key('tender_method_toggle'),
                        segments: const [
                          ButtonSegment(
                            value: 'CASH',
                            icon: Icon(Icons.payments_rounded, size: 16),
                            label: Text('Cash'),
                          ),
                          ButtonSegment(
                            value: 'CREDIT',
                            icon: Icon(Icons.account_balance_wallet_rounded, size: 16),
                            label: Text('Credit (Khata)'),
                            enabled: true,
                          ),
                        ],
                        selected: {_tenderMethod},
                        onSelectionChanged: _offline
                            ? null
                            : (selection) => setState(() => _tenderMethod = selection.first),
                      ),
                    ),
                  ],
                ),
                if (_tenderMethod == 'CREDIT' && !_offline) ...[
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: ListTile(
                      key: const Key('customer_picker_tile'),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEEF2FF),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.person_rounded, color: Color(0xFF4F46E5), size: 20),
                      ),
                      title: Text(_selectedCustomer?.name ?? 'Select customer', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      subtitle: _selectedCustomer != null
                          ? Text('${_selectedCustomer!.customerCode} · ${_selectedCustomer!.phone ?? ""}')
                          : const Text('Required for Khata credit billing', style: TextStyle(fontSize: 12)),
                      trailing: const Icon(Icons.chevron_right_rounded, color: Color(0xFF64748B)),
                      onTap: _pickCustomer,
                    ),
                  ),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!, style: const TextStyle(color: Color(0xFFE11D48), fontSize: 13)),
                  ),
                const SizedBox(height: 12),
                // Total and Checkout Action Button
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _quoting
                                ? 'Calculating…'
                                : _quote != null
                                    ? 'Total: ₹${_quote!.grandTotal.toStringAsFixed(2)}'
                                    : (estimate != null
                                        ? 'Estimated: ₹${estimate.toStringAsFixed(2)}'
                                        : 'Total: —'),
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF0F766E)),
                            key: const Key('cart_total'),
                          ),
                          if (_quote != null && _quote!.taxTotal > Decimal.zero)
                            Text(
                              'Includes ₹${_quote!.taxTotal.toStringAsFixed(2)} GST tax',
                              style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                            ),
                        ],
                      ),
                    ),
                    FilledButton(
                      key: const Key('checkout_button'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF0F766E),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: canCheckout ? () => _checkout() : null,
                      child: _checkingOut
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Text(
                              _offline
                                  ? 'Queue Sale (Offline)'
                                  : (_tenderMethod == 'CREDIT' ? 'Charge to Khata' : 'Charge Cash'),
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
