import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/csv_export.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
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
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: const Text('Reports & Analytics'),
          bottom: TabBar(
            isScrollable: true,
            labelColor: AppColors.primary,
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: AppColors.primary,
            indicatorWeight: 3,
            tabs: const [
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
  static final _fileDateFormat = DateFormat('yyyy-MM-dd');

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

  Future<void> _export() async {
    final summary = _summary;
    if (summary == null) return;
    final rows = <List<String>>[
      ['Invoices', summary.invoiceCount.toString()],
      ['Gross Sales', summary.grossSales.toStringAsFixed(2)],
      ['Discounts', summary.discountTotal.toStringAsFixed(2)],
      ['Tax', summary.taxTotal.toStringAsFixed(2)],
      ['Net Sales', summary.netSales.toStringAsFixed(2)],
      for (final t in summary.byTender) ['Tender: ${t.method}', t.total.toStringAsFixed(2)],
    ];
    await shareCsv(
      fileName: 'sales-summary-${_fileDateFormat.format(_dateFrom)}-to-${_fileDateFormat.format(_dateTo)}.csv',
      headers: const ['Metric', 'Amount'],
      rows: rows,
    );
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Date Filter Pill Button
          InkWell(
            key: const Key('sales_date_range_tile'),
            onTap: _pickDateRange,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: AppDecorations.card(color: AppColors.surface),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.date_range_rounded, color: AppColors.primary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Date Range', style: TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                        Text(
                          '${_dateFormat.format(_dateFrom)} – ${_dateFormat.format(_dateTo)}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.textPrimary),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.edit_calendar_rounded, size: 18, color: AppColors.primary),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (summary != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('sales_export_csv_button'),
                onPressed: _export,
                icon: const Icon(Icons.ios_share_rounded, size: 16),
                label: const Text('Export CSV'),
              ),
            ),
          if (_loading) const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.dangerContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer)),
            ),
          if (summary != null) ...[
            // Sales Metrics Detailed Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: AppDecorations.card(color: AppColors.surface),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Summary Breakdown',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 12),
                  _statRow('Invoices', summary.invoiceCount.toString(), key: 'sales_invoice_count'),
                  _statRow('Gross Sales', '₹${summary.grossSales.toStringAsFixed(2)}', key: 'sales_gross'),
                  _statRow('Discounts', '₹${summary.discountTotal.toStringAsFixed(2)}'),
                  _statRow('Tax', '₹${summary.taxTotal.toStringAsFixed(2)}'),
                  const Divider(height: 20),
                  _statRow('Net Sales', '₹${summary.netSales.toStringAsFixed(2)}', key: 'sales_net', bold: true),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (summary.byTender.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: AppDecorations.card(color: AppColors.surface),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('By Tender', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.textPrimary)),
                    const SizedBox(height: 12),
                    ...summary.byTender.map((t) => _statRow(t.method, '₹${t.total.toStringAsFixed(2)}')),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _statRow(String label, String value, {String? key, bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: AppColors.textSecondary, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
          Text(
            value,
            key: key != null ? Key(key) : null,
            style: TextStyle(
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
              fontSize: bold ? 15 : 14,
              color: bold ? AppColors.primary : AppColors.textPrimary,
            ),
          ),
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

  Future<void> _export() async {
    await shareCsv(
      fileName: 'stock-on-hand-${DateFormat('yyyy-MM-dd').format(DateTime.now())}.csv',
      headers: const ['SKU', 'Product', 'Available Qty', 'Batch Count', 'Nearest Expiry'],
      rows: [
        for (final l in _lines)
          [
            l.sku,
            l.name,
            l.totalAvailable.toString(),
            l.batchCount.toString(),
            l.nearestExpiry != null ? DateFormat('yyyy-MM-dd').format(l.nearestExpiry!) : '',
          ],
      ],
    );
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
              padding: const EdgeInsets.all(16),
              itemCount: _lines.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      key: const Key('stock_export_csv_button'),
                      onPressed: _export,
                      icon: const Icon(Icons.ios_share_rounded, size: 16),
                      label: const Text('Export CSV'),
                    ),
                  );
                }
                index -= 1;
                final l = _lines[index];
                return Container(
                  key: Key('stock_${l.productId}'),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: AppDecorations.card(color: AppColors.surface),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: l.expiringWithin30Days ? AppColors.warningContainer : AppColors.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.inventory_2_rounded,
                        color: l.expiringWithin30Days ? AppColors.warning : AppColors.primary,
                        size: 22,
                      ),
                    ),
                    title: Text(l.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${l.sku} · ${l.batchCount} batch(es)'
                        '${l.nearestExpiry != null ? ' · nearest expiry ${DateFormat('dd MMM yyyy').format(l.nearestExpiry!)}' : ''}',
                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          l.totalAvailable.toString(),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.textPrimary),
                        ),
                        if (l.expiringWithin30Days)
                          Container(
                            margin: const EdgeInsets.only(top: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.warningContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text('Expiring soon', style: TextStyle(color: AppColors.onWarningContainer, fontSize: 10, fontWeight: FontWeight.bold)),
                          ),
                      ],
                    ),
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

  Future<void> _export() async {
    await shareCsv(
      fileName: 'customer-balances-${DateFormat('yyyy-MM-dd').format(DateTime.now())}.csv',
      headers: const ['Customer', 'Outstanding Balance', 'Credit Limit'],
      rows: [
        for (final b in _balances) [b.name, b.balance.toStringAsFixed(2), b.creditLimit.toStringAsFixed(2)],
      ],
    );
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
              padding: const EdgeInsets.all(16),
              itemCount: _balances.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      key: const Key('balances_export_csv_button'),
                      onPressed: _export,
                      icon: const Icon(Icons.ios_share_rounded, size: 16),
                      label: const Text('Export CSV'),
                    ),
                  );
                }
                index -= 1;
                final b = _balances[index];
                final overLimit = b.balance > b.creditLimit;
                return Container(
                  key: Key('balance_${b.customerId}'),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: AppDecorations.card(color: AppColors.surface),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: CircleAvatar(
                      backgroundColor: overLimit ? AppColors.dangerContainer : AppColors.secondaryContainer,
                      child: Icon(Icons.person_rounded, color: overLimit ? AppColors.danger : AppColors.secondary, size: 20),
                    ),
                    title: Text(b.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    subtitle: Text('Limit: ₹${b.creditLimit.toStringAsFixed(2)}', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    trailing: Text(
                      '₹${b.balance.toStringAsFixed(2)}',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: overLimit ? Colors.red : AppColors.textPrimary),
                    ),
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

  Future<void> _export() async {
    await shareCsv(
      fileName: 'eod-history-${DateFormat('yyyy-MM-dd').format(DateTime.now())}.csv',
      headers: const ['Business Date', 'Opening Cash', 'Cash Sales', 'Cash Refunds', 'Expected Cash', 'Actual Cash', 'Variance', 'Status'],
      rows: [
        for (final s in _sessions)
          [
            _dateFormat.format(s.businessDate),
            s.openingCash.toStringAsFixed(2),
            s.cashSales.toStringAsFixed(2),
            s.cashRefunds.toStringAsFixed(2),
            s.expectedCash.toStringAsFixed(2),
            s.actualCash?.toStringAsFixed(2) ?? '',
            s.variance?.toStringAsFixed(2) ?? '',
            s.status,
          ],
      ],
    );
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
              padding: const EdgeInsets.all(16),
              itemCount: _sessions.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      key: const Key('eod_export_csv_button'),
                      onPressed: _export,
                      icon: const Icon(Icons.ios_share_rounded, size: 16),
                      label: const Text('Export CSV'),
                    ),
                  );
                }
                index -= 1;
                final s = _sessions[index];
                return Container(
                  key: Key('eod_history_${_dateFormat.format(s.businessDate)}'),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: AppDecorations.card(color: AppColors.surface),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.secondaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.history_rounded, color: AppColors.secondary, size: 22),
                    ),
                    title: Text(_dateFormat.format(s.businessDate), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    subtitle: Text('${s.status} · Expected ₹${s.expectedCash.toStringAsFixed(2)}', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    trailing: s.variance != null
                        ? Text(
                            '₹${s.variance!.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: s.variance == Decimal.zero
                                  ? Colors.green
                                  : (s.variance! < Decimal.zero ? Colors.red : Colors.orange),
                            ),
                          )
                        : null,
                  ),
                );
              },
            ),
    );
  }
}
