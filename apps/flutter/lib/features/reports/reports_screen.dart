import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/csv_export.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'reports_api.dart';
import '../../core/number_format.dart';

/// Reports/dashboard — a real Flutter view on top of the four reporting
/// endpoints. All computation happens server-side; every number rendered
/// is exactly what the server returned.
class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: const Text('Reports & Analytics', style: AppTypography.headline),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.surfaceSecondary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: Colors.white,
                unselectedLabelColor: AppColors.textSecondary,
                indicatorSize: TabBarIndicatorSize.tab,
                indicator: BoxDecoration(
                  gradient: AppColors.gradientRose,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.danger.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                dividerColor: Colors.transparent,
                labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                tabs: const [
                  Tab(
                    key: Key('tab_sales'),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.trending_up_rounded, size: 16),
                        SizedBox(width: 6),
                        Text('Sales'),
                      ],
                    ),
                  ),
                  Tab(
                    key: Key('tab_stock'),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.inventory_2_rounded, size: 16),
                        SizedBox(width: 6),
                        Text('Stock'),
                      ],
                    ),
                  ),
                  Tab(
                    key: Key('tab_balances'),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.account_balance_wallet_rounded, size: 16),
                        SizedBox(width: 6),
                        Text('Balances'),
                      ],
                    ),
                  ),
                  Tab(
                    key: Key('tab_eod'),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.point_of_sale_rounded, size: 16),
                        SizedBox(width: 6),
                        Text('EOD History'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
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
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 96),
        children: [
          // Hero Header Banner
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              gradient: AppColors.gradientRose,
              borderRadius: AppDecorations.borderRadiusLg,
              boxShadow: AppDecorations.roseGlow,
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                  ),
                  child: const Icon(Icons.analytics_rounded, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Sales & Revenue Intelligence',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Total turnover, tax collections and tender breakdown',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Date Filter Pill Button & Export Row
          Row(
            children: [
              Expanded(
                child: InkWell(
                  key: const Key('sales_date_range_tile'),
                  onTap: _pickDateRange,
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.border),
                      boxShadow: AppDecorations.cardShadow,
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.primaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.date_range_rounded, color: AppColors.primary, size: 18),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Period Range', style: TextStyle(color: AppColors.textSecondary, fontSize: 10, fontWeight: FontWeight.bold)),
                              Text(
                                '${_dateFormat.format(_dateFrom)} – ${_dateFormat.format(_dateTo)}',
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.textPrimary),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.edit_calendar_rounded, size: 16, color: AppColors.primary),
                      ],
                    ),
                  ),
                ),
              ),
              if (summary != null) ...[
                const SizedBox(width: 10),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.border),
                    boxShadow: AppDecorations.cardShadow,
                  ),
                  child: IconButton(
                    key: const Key('sales_export_csv_button'),
                    tooltip: 'Export CSV',
                    icon: const Icon(Icons.ios_share_rounded, size: 20, color: AppColors.primary),
                    onPressed: _export,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),

          if (_loading) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),

          if (_error != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.dangerContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer)),
            ),

          if (summary != null) ...[
            // Summary Breakdown Card
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
                boxShadow: AppDecorations.cardShadow,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          gradient: AppColors.gradientEmerald,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.receipt_long_rounded, color: Colors.white, size: 18),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        'Financial Breakdown',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.textPrimary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _statRow('Invoices', summary.invoiceCount.toString(), key: 'sales_invoice_count', icon: Icons.description_outlined),
                  _statRow('Gross Sales', money(summary.grossSales), icon: Icons.add_circle_outline_rounded),
                  _statRow('Discounts', money(summary.discountTotal), icon: Icons.discount_outlined),
                  _statRow('Tax', money(summary.taxTotal), icon: Icons.percent_rounded),
                  const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Divider(height: 1, color: AppColors.border)),
                  _statRow('Net Sales', money(summary.netSales), bold: true, icon: Icons.verified_rounded),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // By Tender Card
            if (summary.byTender.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                  boxShadow: AppDecorations.cardShadow,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            gradient: AppColors.gradientIndigo,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.account_balance_wallet_rounded, color: Colors.white, size: 18),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'Payment Tenders Received',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.textPrimary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ...summary.byTender.map((t) => _tenderRow(t)),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _statRow(String label, String value, {String? key, bool bold = false, IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: bold ? AppColors.primary : AppColors.textSecondary),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: TextStyle(
                  color: bold ? AppColors.textPrimary : AppColors.textSecondary,
                  fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
                  fontSize: bold ? 15 : 13,
                ),
              ),
            ],
          ),
          Text(
            value,
            key: key != null ? Key(key) : null,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w900 : FontWeight.w700,
              fontSize: bold ? 16 : 14,
              color: bold ? AppColors.primary : AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tenderRow(TenderTotal t) {
    final isCash = t.method.toUpperCase() == 'CASH';
    final isCredit = t.method.toUpperCase() == 'CREDIT';
    final badgeColor = isCash ? AppColors.primary : (isCredit ? AppColors.secondary : AppColors.accent);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isCash ? Icons.money_rounded : (isCredit ? Icons.credit_score_rounded : Icons.credit_card_rounded),
                  size: 16,
                  color: badgeColor,
                ),
              ),
              const SizedBox(width: 10),
              Text(t.method, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            ],
          ),
          Text(
            money(t.total),
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: badgeColor),
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

  LinearGradient _avatarGrad(String name) {
    final colors = [
      AppColors.gradientCyan,
      AppColors.gradientEmerald,
      AppColors.gradientIndigo,
      AppColors.gradientAmber,
      AppColors.gradientPurple,
    ];
    final idx = name.codeUnits.fold(0, (a, b) => a + b) % colors.length;
    return colors[idx];
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: _lines.isEmpty
          ? ListView(children: const [
              Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No stock on hand', style: AppTypography.bodySecondary))),
            ])
          : ListView.builder(
              key: const Key('stock_list'),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: _lines.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceSecondary,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Text(
                            '${_lines.length} items in stock',
                            style: AppTypography.caption.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                        TextButton.icon(
                          key: const Key('stock_export_csv_button'),
                          onPressed: _export,
                          icon: const Icon(Icons.ios_share_rounded, size: 16),
                          label: const Text('Export CSV'),
                        ),
                      ],
                    ),
                  );
                }
                index -= 1;
                final l = _lines[index];
                return Container(
                  key: Key('stock_${l.productId}'),
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: l.expiringWithin30Days ? AppColors.warning.withValues(alpha: 0.4) : AppColors.border),
                    boxShadow: AppDecorations.cardShadow,
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        gradient: _avatarGrad(l.name),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Center(
                        child: Icon(Icons.inventory_2_rounded, color: Colors.white, size: 20),
                      ),
                    ),
                    title: Text(l.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceSecondary,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(l.sku, style: AppTypography.caption.copyWith(fontWeight: FontWeight.w600)),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceSecondary,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('${l.batchCount} batch(es)', style: AppTypography.caption),
                          ),
                          if (l.nearestExpiry != null)
                            Text(
                              'nearest expiry ${DateFormat('dd MMM yyyy').format(l.nearestExpiry!)}',
                              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                            ),
                        ],
                      ),
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          l.totalAvailable.toString(),
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: AppColors.primary),
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

  LinearGradient _avatarGrad(String name) {
    final colors = [
      AppColors.gradientIndigo,
      AppColors.gradientCyan,
      AppColors.gradientEmerald,
      AppColors.gradientPurple,
      AppColors.gradientAmber,
    ];
    final idx = name.codeUnits.fold(0, (a, b) => a + b) % colors.length;
    return colors[idx];
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: _balances.isEmpty
          ? ListView(children: const [
              Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No outstanding balances', style: AppTypography.bodySecondary))),
            ])
          : ListView.builder(
              key: const Key('balances_list'),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: _balances.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceSecondary,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Text(
                            '${_balances.length} receivables accounts',
                            style: AppTypography.caption.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                        TextButton.icon(
                          key: const Key('balances_export_csv_button'),
                          onPressed: _export,
                          icon: const Icon(Icons.ios_share_rounded, size: 16),
                          label: const Text('Export CSV'),
                        ),
                      ],
                    ),
                  );
                }
                index -= 1;
                final b = _balances[index];
                final overLimit = b.balance > b.creditLimit;
                return Container(
                  key: Key('balance_${b.customerId}'),
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: overLimit ? AppColors.danger.withValues(alpha: 0.4) : AppColors.border),
                    boxShadow: AppDecorations.cardShadow,
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        gradient: _avatarGrad(b.name),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: Text(
                          b.name.isNotEmpty ? b.name[0].toUpperCase() : 'C',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17),
                        ),
                      ),
                    ),
                    title: Text(b.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    subtitle: Text('Limit: ${money(b.creditLimit)}', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    trailing: Text(
                      money(b.balance),
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
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: _sessions.isEmpty
          ? ListView(children: const [
              Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No EOD sessions in this range', style: AppTypography.bodySecondary))),
            ])
          : ListView.builder(
              key: const Key('eod_history_list'),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: _sessions.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceSecondary,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Text(
                            '${_sessions.length} recorded cash sessions',
                            style: AppTypography.caption.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                        TextButton.icon(
                          key: const Key('eod_export_csv_button'),
                          onPressed: _export,
                          icon: const Icon(Icons.ios_share_rounded, size: 16),
                          label: const Text('Export CSV'),
                        ),
                      ],
                    ),
                  );
                }
                index -= 1;
                final s = _sessions[index];
                return Container(
                  key: Key('eod_history_${_dateFormat.format(s.businessDate)}'),
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.border),
                    boxShadow: AppDecorations.cardShadow,
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    leading: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        gradient: AppColors.gradientPurple,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.point_of_sale_rounded, color: Colors.white, size: 20),
                    ),
                    title: Text(_dateFormat.format(s.businessDate), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    subtitle: Text('${s.status} · Expected ${money(s.expectedCash)}', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    trailing: s.variance != null
                        ? Text(
                            money(s.variance!),
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
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
