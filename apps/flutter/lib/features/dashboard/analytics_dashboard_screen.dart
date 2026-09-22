import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'dashboard_overview_api.dart';
import '../../core/number_format.dart';

String _money(dynamic value) => money(value);
final _dayLabel = DateFormat('d MMM');
final _dateTimeLabel = DateFormat('d MMM, h:mm a');

/// The detailed, colorful "never miss anything" Analytics Dashboard — a
/// single screen backed by one GET /api/v1/reports/dashboard call
/// (services/api/internal/domain/reports/service.go's DashboardOverview).
/// Every figure here is the same read-side aggregate the rest of the app's
/// reports already trust; this screen adds no client-side math beyond
/// simple ratios/percentages for presentation.
class AnalyticsDashboardScreen extends StatefulWidget {
  const AnalyticsDashboardScreen({super.key});

  @override
  State<AnalyticsDashboardScreen> createState() => _AnalyticsDashboardScreenState();
}

class _AnalyticsDashboardScreenState extends State<AnalyticsDashboardScreen> {
  DashboardOverview? _data;
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
      final api = DashboardOverviewApi(context.read<ApiClient>());
      final data = await api.fetch();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the dashboard: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Analytics Dashboard'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        actions: [
          IconButton(
            key: const Key('dashboard_refresh_button'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _data == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 48),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textSecondary)),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    final data = _data!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _buildKpiGrid(data),
          const SizedBox(height: 20),
          _buildSalesTrendCard(data),
          const SizedBox(height: 20),
          _buildPaymentMixCard(data),
          const SizedBox(height: 20),
          _buildStockHealthCard(data),
          const SizedBox(height: 20),
          _buildTopProductsCard(data),
          const SizedBox(height: 20),
          _buildReceivablesPayablesRow(data),
          const SizedBox(height: 20),
          _buildRecentActivityCard(data),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // KPI row
  // ---------------------------------------------------------------------

  Widget _buildKpiGrid(DashboardOverview data) {
    final growth = data.netSalesGrowthPct;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 700;
        final cards = [
          _KpiCard(
            key: const Key('kpi_today_net_sales'),
            label: "Today's Net Sales",
            value: _money(data.today.netSales),
            gradient: AppColors.gradientEmerald,
            icon: Icons.trending_up_rounded,
            trailing: growth == null
                ? null
                : _GrowthPill(percent: growth),
          ),
          _KpiCard(
            key: const Key('kpi_today_invoices'),
            label: "Today's Invoices",
            value: '${data.today.invoiceCount}',
            gradient: AppColors.gradientIndigo,
            icon: Icons.receipt_long_rounded,
          ),
          _KpiCard(
            key: const Key('kpi_receivables'),
            label: 'Total Receivables',
            value: _money(data.totalReceivables),
            gradient: AppColors.gradientAmber,
            icon: Icons.arrow_downward_rounded,
          ),
          _KpiCard(
            key: const Key('kpi_payables'),
            label: 'Total Payables',
            value: _money(data.totalPayables),
            gradient: AppColors.gradientRose,
            icon: Icons.arrow_upward_rounded,
          ),
          _KpiCard(
            key: const Key('kpi_stock_value'),
            label: 'Stock Value',
            value: _money(data.stockHealth.totalStockValue),
            gradient: AppColors.gradientTealCyan,
            icon: Icons.inventory_2_rounded,
          ),
        ];
        return GridView.count(
          crossAxisCount: isWide ? 3 : 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: isWide ? 2.0 : 1.5,
          children: cards,
        );
      },
    );
  }

  // ---------------------------------------------------------------------
  // Sales trend
  // ---------------------------------------------------------------------

  Widget _buildSalesTrendCard(DashboardOverview data) {
    final points = data.salesTrend;
    final maxY = points.isEmpty
        ? 100.0
        : points.map((p) => p.netSales.toDouble()).fold(0.0, (a, b) => a > b ? a : b) * 1.2 + 1;
    return _SectionCard(
      key: const Key('dashboard_sales_trend_card'),
      title: '14-Day Sales Trend',
      icon: Icons.show_chart_rounded,
      child: SizedBox(
        height: 220,
        child: points.isEmpty
            ? const Center(child: Text('No sales yet', style: TextStyle(color: AppColors.textSecondary)))
            : LineChart(
                LineChartData(
                  minY: 0,
                  maxY: maxY,
                  gridData: FlGridData(show: true, drawVerticalLine: false, horizontalInterval: maxY / 4),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 44,
                        getTitlesWidget: (v, meta) => Text(
                          v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : v.toStringAsFixed(0),
                          style: const TextStyle(fontSize: 10, color: AppColors.textTertiary),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 28,
                        interval: (points.length / 5).ceilToDouble().clamp(1, points.length.toDouble()),
                        getTitlesWidget: (v, meta) {
                          final i = v.toInt();
                          if (i < 0 || i >= points.length) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(_dayLabel.format(points[i].date), style: const TextStyle(fontSize: 10, color: AppColors.textTertiary)),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: [for (var i = 0; i < points.length; i++) FlSpot(i.toDouble(), points[i].netSales.toDouble())],
                      isCurved: true,
                      color: AppColors.primary,
                      barWidth: 3,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        gradient: LinearGradient(
                          colors: [AppColors.primary.withValues(alpha: 0.25), AppColors.primary.withValues(alpha: 0.0)],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                  ],
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (spots) => spots.map((s) {
                        final p = points[s.x.toInt()];
                        return LineTooltipItem(
                          '${_dayLabel.format(p.date)}\n${_money(p.netSales)}\n${p.invoiceCount} bill${p.invoiceCount == 1 ? '' : 's'}',
                          const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Payment mix (last 30 days)
  // ---------------------------------------------------------------------

  Widget _buildPaymentMixCard(DashboardOverview data) {
    final tenders = data.last30Days.byTender.where((t) => t.total.toDouble() > 0).toList();
    final total = tenders.fold<double>(0, (a, t) => a + t.total.toDouble());
    final palette = [
      AppColors.primary,
      AppColors.secondary,
      AppColors.warning,
      AppColors.accent,
      AppColors.danger,
      AppColors.textTertiary,
    ];
    return _SectionCard(
      key: const Key('dashboard_payment_mix_card'),
      title: 'Payment Mix (Last 30 Days)',
      icon: Icons.pie_chart_rounded,
      child: tenders.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('No payments yet', style: TextStyle(color: AppColors.textSecondary))),
            )
          : Row(
              children: [
                SizedBox(
                  height: 160,
                  width: 160,
                  child: PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: 40,
                      sections: [
                        for (var i = 0; i < tenders.length; i++)
                          PieChartSectionData(
                            value: tenders[i].total.toDouble(),
                            color: palette[i % palette.length],
                            title: total == 0 ? '' : '${(tenders[i].total.toDouble() / total * 100).toStringAsFixed(0)}%',
                            radius: 40,
                            titleStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < tenders.length; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Container(width: 10, height: 10, decoration: BoxDecoration(color: palette[i % palette.length], shape: BoxShape.circle)),
                              const SizedBox(width: 8),
                              Expanded(child: Text(tenders[i].method, style: const TextStyle(fontSize: 13, color: AppColors.textPrimary))),
                              Text(_money(tenders[i].total), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  // ---------------------------------------------------------------------
  // Stock health
  // ---------------------------------------------------------------------

  Widget _buildStockHealthCard(DashboardOverview data) {
    final h = data.stockHealth;
    return _SectionCard(
      key: const Key('dashboard_stock_health_card'),
      title: 'Stock Health',
      icon: Icons.health_and_safety_rounded,
      child: Row(
        children: [
          SizedBox(
            height: 140,
            width: 140,
            child: PieChart(
              PieChartData(
                sectionsSpace: 2,
                centerSpaceRadius: 36,
                sections: [
                  if (h.inStock > 0)
                    PieChartSectionData(value: h.inStock.toDouble(), color: AppColors.success, title: '${h.inStock}', radius: 34, titleStyle: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
                  if (h.lowStock > 0)
                    PieChartSectionData(value: h.lowStock.toDouble(), color: AppColors.warning, title: '${h.lowStock}', radius: 34, titleStyle: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
                  if (h.outOfStock > 0)
                    PieChartSectionData(value: h.outOfStock.toDouble(), color: AppColors.danger, title: '${h.outOfStock}', radius: 34, titleStyle: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
                  if (h.totalProducts == 0)
                    PieChartSectionData(value: 1, color: AppColors.surfaceTertiary, title: '', radius: 34),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _legendRow(AppColors.success, 'In Stock', '${h.inStock}'),
                _legendRow(AppColors.warning, 'Low Stock', '${h.lowStock}'),
                _legendRow(AppColors.danger, 'Out of Stock', '${h.outOfStock}'),
                const Divider(height: 16),
                Text('${h.totalProducts} products total', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _legendRow(Color color, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textPrimary))),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Top products
  // ---------------------------------------------------------------------

  Widget _buildTopProductsCard(DashboardOverview data) {
    final products = data.topProducts;
    final maxRevenue = products.isEmpty ? 1.0 : products.map((p) => p.revenue.toDouble()).reduce((a, b) => a > b ? a : b);
    return _SectionCard(
      key: const Key('dashboard_top_products_card'),
      title: 'Best Sellers (Last 30 Days)',
      icon: Icons.emoji_events_rounded,
      child: products.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('No sales yet', style: TextStyle(color: AppColors.textSecondary))),
            )
          : Column(
              children: [
                for (var i = 0; i < products.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 22,
                          child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
                        ),
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(products[i].name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: maxRevenue == 0 ? 0 : products[i].revenue.toDouble() / maxRevenue,
                                  minHeight: 6,
                                  backgroundColor: AppColors.surfaceTertiary,
                                  valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: Text(_money(products[i].revenue), textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  // ---------------------------------------------------------------------
  // Receivables / Payables
  // ---------------------------------------------------------------------

  Widget _buildReceivablesPayablesRow(DashboardOverview data) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 700;
        final receivablesCard = _SectionCard(
          key: const Key('dashboard_receivables_card'),
          title: 'Top Debtors',
          icon: Icons.groups_rounded,
          accentColor: AppColors.warning,
          child: data.receivables.isEmpty
              ? const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('No outstanding receivables', style: TextStyle(color: AppColors.textSecondary)))
              : Column(
                  children: data.receivables.take(5).map((r) => _balanceRow(r.name, r.balance, AppColors.warning)).toList(),
                ),
        );
        final payablesCard = _SectionCard(
          key: const Key('dashboard_payables_card'),
          title: 'Top Creditors',
          icon: Icons.local_shipping_rounded,
          accentColor: AppColors.danger,
          child: data.payables.isEmpty
              ? const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('No outstanding payables', style: TextStyle(color: AppColors.textSecondary)))
              : Column(
                  children: data.payables.take(5).map((p) => _balanceRow(p.name, p.payable, AppColors.danger)).toList(),
                ),
        );
        if (isWide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: receivablesCard),
              const SizedBox(width: 16),
              Expanded(child: payablesCard),
            ],
          );
        }
        return Column(
          children: [
            receivablesCard,
            const SizedBox(height: 20),
            payablesCard,
          ],
        );
      },
    );
  }

  Widget _balanceRow(String name, dynamic balance, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
          Text(_money(balance), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Recent activity
  // ---------------------------------------------------------------------

  Widget _buildRecentActivityCard(DashboardOverview data) {
    return _SectionCard(
      key: const Key('dashboard_recent_activity_card'),
      title: 'Recent Activity',
      icon: Icons.history_rounded,
      child: data.recentInvoices.isEmpty
          ? const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('No invoices yet', style: TextStyle(color: AppColors.textSecondary)))
          : Column(
              children: data.recentInvoices.map((inv) {
                final paid = inv.paymentStatus.toLowerCase() == 'paid';
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: (paid ? AppColors.success : AppColors.warning).withValues(alpha: 0.12), shape: BoxShape.circle),
                        child: Icon(paid ? Icons.check_circle_rounded : Icons.hourglass_bottom_rounded, size: 16, color: paid ? AppColors.success : AppColors.warning),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(inv.customerName ?? 'Walk-in Customer', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                            Text(
                              '${inv.invoiceNumber}${inv.finalizedAt != null ? ' · ${_dateTimeLabel.format(inv.finalizedAt!.toLocal())}' : ''}',
                              style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
                            ),
                          ],
                        ),
                      ),
                      Text(_money(inv.grandTotal), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                    ],
                  ),
                );
              }).toList(),
            ),
    );
  }
}

/// A single colorful gradient KPI tile.
class _KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final Gradient gradient;
  final IconData icon;
  final Widget? trailing;

  const _KpiCard({super.key, required this.label, required this.value, required this.gradient, required this.icon, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(gradient: gradient, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: Colors.white.withValues(alpha: 0.9), size: 22),
              ?trailing,
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11.5, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

class _GrowthPill extends StatelessWidget {
  final double percent;

  const _GrowthPill({required this.percent});

  @override
  Widget build(BuildContext context) {
    final positive = percent >= 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(positive ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 11, color: Colors.white),
          Text('${percent.abs().toStringAsFixed(0)}%', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// A titled white card wrapper shared by every section on this dashboard.
class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final Color? accentColor;

  const _SectionCard({super.key, required this.title, required this.icon, required this.child, this.accentColor});

  @override
  Widget build(BuildContext context) {
    final color = accentColor ?? AppColors.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: AppDecorations.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text(title, style: AppTypography.title.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}
