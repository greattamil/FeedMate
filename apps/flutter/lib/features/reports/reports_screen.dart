import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import 'reports_api.dart';

/// Reports/dashboard — a real Flutter view on top of the four reporting
/// endpoints that have existed, tested, since Phase 10 but never had a
/// client. All computation (totals, balances, expiry windows) happens
/// server-side; every number here is exactly what the server returned, not
/// a client-side recomputation.
class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Reports'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Sales', key: Key('tab_sales')),
              Tab(text: 'Stock', key: Key('tab_stock')),
              Tab(text: 'Balances', key: Key('tab_balances')),
              Tab(text: 'EOD History', key: Key('tab_eod')),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _SalesSummaryTab(),
            _StockOnHandTab(),
            _CustomerBalancesTab(),
            _EodHistoryTab(),
          ],
        ),
      ),
    );
  }
}

class _SalesSummaryTab extends StatefulWidget {
  const _SalesSummaryTab();

  @override
  State<_SalesSummaryTab> createState() => _SalesSummaryTabState();
}

class _SalesSummaryTabState extends State<_SalesSummaryTab> {
  SalesSummary? _summary;
  bool _loading = true;
  String? _error;
  late DateTime _dateFrom;
  late DateTime _dateTo;

  static final _dateFormat = DateFormat('dd MMM yyyy');

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    _dateFrom = DateTime(today.year, today.month, today.day);
    _dateTo = _dateFrom;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ReportsApi(context.read<ApiClient>());
      final summary = await api.salesSummary(dateFrom: _dateFrom, dateTo: _dateTo);
      if (!mounted) return;
      setState(() {
        _summary = summary;
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

  Future<void> _pickDateRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(start: _dateFrom, end: _dateTo),
    );
    if (range == null) return;
    setState(() {
      _dateFrom = range.start;
      _dateTo = range.end;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            key: const Key('sales_date_range_tile'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.date_range),
            title: Text('${_dateFormat.format(_dateFrom)} – ${_dateFormat.format(_dateTo)}'),
            trailing: const Icon(Icons.edit_calendar_outlined),
            onTap: _pickDateRange,
          ),
          if (_loading) const Center(child: CircularProgressIndicator()),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          if (summary != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _statRow('Invoices', summary.invoiceCount.toString(), key: 'sales_invoice_count'),
                    _statRow('Gross Sales', '₹${summary.grossSales.toStringAsFixed(2)}', key: 'sales_gross'),
                    _statRow('Discounts', '₹${summary.discountTotal.toStringAsFixed(2)}'),
                    _statRow('Tax', '₹${summary.taxTotal.toStringAsFixed(2)}'),
                    const Divider(),
                    _statRow('Net Sales', '₹${summary.netSales.toStringAsFixed(2)}',
                        key: 'sales_net', bold: true),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (summary.byTender.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('By Tender', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      ...summary.byTender.map((t) => _statRow(t.method, '₹${t.total.toStringAsFixed(2)}')),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _statRow(String label, String value, {String? key, bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value,
              key: key != null ? Key(key) : null,
              style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ],
      ),
    );
  }
}

class _StockOnHandTab extends StatefulWidget {
  const _StockOnHandTab();

  @override
  State<_StockOnHandTab> createState() => _StockOnHandTabState();
}

class _StockOnHandTabState extends State<_StockOnHandTab> {
  List<StockOnHandLine> _lines = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ReportsApi(context.read<ApiClient>());
      final lines = await api.stockOnHand();
      if (!mounted) return;
      setState(() {
        _lines = lines;
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
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: _lines.isEmpty
          ? ListView(children: const [
              Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No stock on hand'))),
            ])
          : ListView.builder(
              key: const Key('stock_list'),
              itemCount: _lines.length,
              itemBuilder: (context, index) {
                final l = _lines[index];
                return ListTile(
                  key: Key('stock_${l.productId}'),
                  title: Text(l.name),
                  subtitle: Text(
                    '${l.sku} · ${l.batchCount} batch(es)'
                    '${l.nearestExpiry != null ? ' · nearest expiry ${DateFormat('dd MMM yyyy').format(l.nearestExpiry!)}' : ''}',
                  ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(l.totalAvailable.toString(), style: const TextStyle(fontWeight: FontWeight.bold)),
                      if (l.expiringWithin30Days)
                        const Text('Expiring soon', style: TextStyle(color: Colors.orange, fontSize: 11)),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _CustomerBalancesTab extends StatefulWidget {
  const _CustomerBalancesTab();

  @override
  State<_CustomerBalancesTab> createState() => _CustomerBalancesTabState();
}

class _CustomerBalancesTabState extends State<_CustomerBalancesTab> {
  List<CustomerBalance> _balances = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ReportsApi(context.read<ApiClient>());
      final balances = await api.customerBalances();
      if (!mounted) return;
      setState(() {
        _balances = balances;
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
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: _balances.isEmpty
          ? ListView(children: const [
              Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No outstanding balances'))),
            ])
          : ListView.builder(
              key: const Key('balances_list'),
              itemCount: _balances.length,
              itemBuilder: (context, index) {
                final b = _balances[index];
                final overLimit = b.balance > b.creditLimit;
                return ListTile(
                  key: Key('balance_${b.customerId}'),
                  title: Text(b.name),
                  subtitle: Text('Limit: ₹${b.creditLimit.toStringAsFixed(2)}'),
                  trailing: Text(
                    '₹${b.balance.toStringAsFixed(2)}',
                    style: TextStyle(fontWeight: FontWeight.bold, color: overLimit ? Colors.red : null),
                  ),
                );
              },
            ),
    );
  }
}

class _EodHistoryTab extends StatefulWidget {
  const _EodHistoryTab();

  @override
  State<_EodHistoryTab> createState() => _EodHistoryTabState();
}

class _EodHistoryTabState extends State<_EodHistoryTab> {
  List<EodHistoryEntry> _sessions = [];
  bool _loading = true;
  String? _error;

  static final _dateFormat = DateFormat('dd MMM yyyy');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ReportsApi(context.read<ApiClient>());
      final sessions = await api.eodHistory();
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
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
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: _sessions.isEmpty
          ? ListView(children: const [
              Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No EOD sessions in this range'))),
            ])
          : ListView.builder(
              key: const Key('eod_history_list'),
              itemCount: _sessions.length,
              itemBuilder: (context, index) {
                final s = _sessions[index];
                return ListTile(
                  key: Key('eod_history_${_dateFormat.format(s.businessDate)}'),
                  title: Text(_dateFormat.format(s.businessDate)),
                  subtitle: Text('${s.status} · Expected ₹${s.expectedCash.toStringAsFixed(2)}'),
                  trailing: s.variance != null
                      ? Text(
                          '₹${s.variance!.toStringAsFixed(2)}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: s.variance == Decimal.zero
                                ? Colors.green
                                : (s.variance! < Decimal.zero ? Colors.red : Colors.orange),
                          ),
                        )
                      : null,
                );
              },
            ),
    );
  }
}
