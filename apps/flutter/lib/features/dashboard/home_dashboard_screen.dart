import 'dart:async';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/auth_session.dart';
import '../../core/local_db.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import '../auditlog/audit_log_screen.dart';
import '../auth/generate_pairing_code_screen.dart';
import '../auth/login_screen.dart';
import '../auth/device_management_screen.dart';
import 'analytics_dashboard_screen.dart';
import '../contra/contra_screen.dart';
import '../docseries/doc_series_screen.dart';
import '../eod/eod_api.dart';
import '../eod/eod_screen.dart';
import '../customers/customer_list_screen.dart';
import '../pos/invoice_history_screen.dart';
import '../procurement/grn_history_screen.dart';
import '../procurement/grn_screen.dart';
import '../products/master_data_screen.dart';
import '../products/product_list_screen.dart';
import '../products/tax_profile_screen.dart';
import '../products/location_screen.dart';
import '../reports/reports_api.dart';
import '../reports/reports_screen.dart';
import '../reports/stock_management_screen.dart';
import '../settings/store_settings_screen.dart';
import '../returns/return_screen.dart';
import '../staff/staff_list_screen.dart';
import '../stockcount/stock_count_history_screen.dart';
import '../supplier/supplier_list_screen.dart';
import '../sync/outbox_screen.dart';
import '../../core/number_format.dart';

/// Executive Cockpit & Store Home Dashboard for FeedMate.
/// Benchmarked against modern retail POS cockpits (Shopify POS, Square, Khatabook).
class HomeDashboardScreen extends StatefulWidget {
  final VoidCallback onOpenPos;

  /// Switches AppShell to the persistent Reports tab in place, the same
  /// way [onOpenPos] switches to Counter — never a [Navigator.push] to a
  /// second, non-persistent instance of the screen that would hide the
  /// bottom nav and diverge from the "Reports" tab a user could tap
  /// instead. Null only when the session lacks report.view, in which case
  /// the "Analytics & Reports" tile below is not shown at all.
  final VoidCallback? onOpenReports;

  const HomeDashboardScreen({super.key, required this.onOpenPos, this.onOpenReports});

  @override
  State<HomeDashboardScreen> createState() => _HomeDashboardScreenState();
}

class _HomeDashboardScreenState extends State<HomeDashboardScreen> {
  int _pendingSyncCount = 0;

  // Live KPI values
  SalesSummary? _todaySales;
  Decimal? _totalCustomerOutstanding;
  int _overdueCustomerCount = 0;
  int _expiringBatchCount = 0;
  int _lowStockCount = 0;
  int _outOfStockCount = 0;
  EodSession? _eodSession;
  bool _eodNotOpened = false;

  static final _dateFormatter = DateFormat('EEEE, dd MMMM yyyy');

  @override
  void initState() {
    super.initState();
    _loadDashboardData();
  }

  Future<void> _loadDashboardData() async {
    final client = context.read<ApiClient>();
    final session = context.read<AuthSession>();

    // 1. Pending sync count from local SQLite
    try {
      final localDb = context.read<LocalDatabase>();
      final count = await localDb.pendingInvoiceCount();
      if (mounted) setState(() => _pendingSyncCount = count);
    } catch (_) {}

    // 2. Fetch sales summary if user has report.view permission
    if (session.hasPermission('report.view')) {
      try {
        final reportsApi = ReportsApi(client);
        final today = DateTime.now();
        final startOfDay = DateTime(today.year, today.month, today.day);
        final summary = await reportsApi.salesSummary(dateFrom: startOfDay, dateTo: startOfDay);
        if (mounted) setState(() => _todaySales = summary);
      } catch (_) {}

      // 3. Fetch customer ledger balances
      try {
        final reportsApi = ReportsApi(client);
        final balances = await reportsApi.customerBalances();
        Decimal total = Decimal.zero;
        int overdue = 0;
        for (final b in balances) {
          total += b.balance;
          if (b.balance > b.creditLimit) overdue++;
        }
        if (mounted) {
          setState(() {
            _totalCustomerOutstanding = total;
            _overdueCustomerCount = overdue;
          });
        }
      } catch (_) {}

      // 4. Fetch Stock on hand & expiry warnings
      try {
        final reportsApi = ReportsApi(client);
        final stock = await reportsApi.stockOnHand();
        int expiring = 0;
        for (final s in stock) {
          if (s.expiringWithin30Days) expiring += s.batchCount;
        }
        if (mounted) setState(() => _expiringBatchCount = expiring);
      } catch (_) {}
    }

    // 4b. Live stock/reorder status — not gated on report.view: any staff
    // role that can browse the catalog should see what's running low, the
    // same way /products has no extra permission gate server-side.
    try {
      final reportsApi = ReportsApi(client);
      final stockSummary = await reportsApi.stockSummary();
      if (mounted) {
        setState(() {
          _lowStockCount = stockSummary.lowStockCount;
          _outOfStockCount = stockSummary.outOfStockCount;
        });
      }
    } catch (_) {}

    // 5. Fetch EOD Session
    if (session.hasPermission('cash.eod_close')) {
      try {
        final eodApi = EodApi(client);
        final eod = await eodApi.getSession();
        if (mounted) {
          setState(() {
            _eodSession = eod;
            _eodNotOpened = false;
          });
        }
      } on ApiError catch (e) {
        if (e.code == 'NOT_FOUND' && mounted) {
          setState(() {
            _eodSession = null;
            _eodNotOpened = true;
          });
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AuthSession>();
    final todayStr = _dateFormatter.format(DateTime.now());

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.storefront, color: AppColors.primary, size: 20),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('FeedMate', style: AppTypography.headline),
                Text('Andipatti Animal Feed System', style: AppTypography.caption),
              ],
            ),
          ],
        ),
        actions: [
          // Pending Sync Badge Button
          IconButton(
            tooltip: 'Offline Sync Console',
            icon: Badge(
              label: Text('$_pendingSyncCount'),
              isLabelVisible: _pendingSyncCount > 0,
              backgroundColor: AppColors.warning,
              child: const Icon(Icons.sync_rounded),
            ),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const OutboxScreen()),
              );
              _loadDashboardData();
            },
          ),
          // Logout
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout_rounded),
            onPressed: () async {
              await session.logout();
              if (!context.mounted) return;
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
              );
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadDashboardData,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            // 1. Welcome & Shift Banner
            _buildWelcomeBanner(session, todayStr),
            const SizedBox(height: 16),

            // 2. Urgent Alerts (if any)
            if (_pendingSyncCount > 0 || _expiringBatchCount > 0 || _lowStockCount > 0 || _outOfStockCount > 0 || _eodNotOpened) ...[
              _buildUrgentAlertsCard(),
              const SizedBox(height: 16),
            ],

            // 3. Live Store KPI Carousel
            Text('STORE PERFORMANCE TODAY', style: AppTypography.caption.copyWith(fontWeight: FontWeight.bold, letterSpacing: 0.8)),
            const SizedBox(height: 10),
            _buildKpiMetricsRow(),
            const SizedBox(height: 24),

            // 4. Bento Action Launchers
            Text('QUICK OPERATIONS', style: AppTypography.caption.copyWith(fontWeight: FontWeight.bold, letterSpacing: 0.8)),
            const SizedBox(height: 12),
            _buildQuickActionGrid(session),
            const SizedBox(height: 24),

            // 5. Manage — everything else, so it's reachable from Home and
            // not only from the Counter tab's overflow menu.
            Text('MANAGE', style: AppTypography.caption.copyWith(fontWeight: FontWeight.bold, letterSpacing: 0.8)),
            const SizedBox(height: 12),
            _buildManageGrid(session),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildWelcomeBanner(AuthSession session, String todayStr) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: AppColors.gradientHeroMesh,
        borderRadius: AppDecorations.borderRadiusLg,
        boxShadow: AppDecorations.emeraldGlow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Good day, ${session.displayName ?? "Operator"} 👋',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'FeedMate POS • Andipatti Terminal',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFF34D399),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Color(0xFF34D399),
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'STORE ACTIVE',
                      style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.calendar_today_rounded, color: Colors.white70, size: 14),
                const SizedBox(width: 8),
                Text(
                  todayStr,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUrgentAlertsCard() {
    return Column(
      children: [
        if (_pendingSyncCount > 0)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.warningContainer,
              borderRadius: AppDecorations.borderRadiusSm,
              border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                const Icon(Icons.cloud_off_rounded, color: AppColors.warning, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$_pendingSyncCount offline sale(s) waiting for server sync.',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.onWarningContainer),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const OutboxScreen()),
                  ),
                  child: const Text('Sync Now', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ],
            ),
          ),
        if (_expiringBatchCount > 0)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.dangerContainer,
              borderRadius: AppDecorations.borderRadiusSm,
              border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: AppColors.danger, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$_expiringBatchCount inventory batch(es) expiring within 30 days.',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.onDangerContainer),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ReportsScreen()),
                  ),
                  child: const Text('View Batches', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ],
            ),
          ),
        if (_outOfStockCount > 0 || _lowStockCount > 0)
          Container(
            key: const Key('low_stock_alert_banner'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _outOfStockCount > 0 ? AppColors.dangerContainer : AppColors.warningContainer,
              borderRadius: AppDecorations.borderRadiusSm,
              border: Border.all(color: (_outOfStockCount > 0 ? AppColors.danger : AppColors.warning).withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.inventory_2_rounded,
                  color: _outOfStockCount > 0 ? AppColors.danger : AppColors.warning,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    [
                      if (_outOfStockCount > 0) '$_outOfStockCount product(s) out of stock',
                      if (_lowStockCount > 0) '$_lowStockCount running low',
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _outOfStockCount > 0 ? AppColors.onDangerContainer : AppColors.onWarningContainer,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const StockManagementScreen()),
                  ),
                  child: const Text('Manage Stock', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildKpiMetricsRow() {
    final sales = _todaySales;
    final customerOutstanding = _totalCustomerOutstanding;
    final eod = _eodSession;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 600;

        final cards = [
          _buildKpiCard(
            title: "Today's Gross Sales",
            value: sales != null ? money(sales.grossSales) : '—',
            subtitle: sales != null ? '${sales.invoiceCount} invoices finalized' : 'No sales yet',
            icon: Icons.payments_rounded,
            iconColor: Colors.white,
            iconBg: AppColors.primary,
            cardGradient: AppColors.gradientEmerald,
          ),
          _buildKpiCard(
            title: "Customer Receivables",
            value: customerOutstanding != null ? money(customerOutstanding) : '—',
            subtitle: _overdueCustomerCount > 0 ? '$_overdueCustomerCount over credit limit' : 'All accounts healthy',
            icon: Icons.account_balance_wallet_rounded,
            iconColor: Colors.white,
            iconBg: _overdueCustomerCount > 0 ? AppColors.danger : AppColors.secondary,
            cardGradient: _overdueCustomerCount > 0 ? AppColors.gradientRose : AppColors.gradientIndigo,
            isAlert: _overdueCustomerCount > 0,
          ),
          _buildKpiCard(
            title: "Cash Session (EOD)",
            value: eod != null ? '${money(eod.openingCash)} Float' : (_eodNotOpened ? 'Not Opened' : '—'),
            subtitle: eod != null ? 'Status: ${eod.status}' : 'Open morning till',
            icon: Icons.point_of_sale_rounded,
            iconColor: Colors.white,
            iconBg: AppColors.warning,
            cardGradient: AppColors.gradientAmber,
          ),
        ];

        if (isWide) {
          return Row(
            children: cards.map((c) => Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: c))).toList(),
          );
        }

        return SizedBox(
          height: 136,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: cards.map((c) => Container(width: 270, margin: const EdgeInsets.only(right: 12), child: c)).toList(),
          ),
        );
      },
    );
  }

  Widget _buildKpiCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    LinearGradient? cardGradient,
    bool isAlert = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppDecorations.borderRadiusMd,
        border: Border.all(
          color: isAlert ? AppColors.danger.withValues(alpha: 0.5) : AppColors.border,
          width: isAlert ? 1.5 : 1,
        ),
        boxShadow: AppDecorations.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: AppTypography.caption.copyWith(fontWeight: FontWeight.w700, color: AppColors.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: cardGradient,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: iconBg.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Icon(icon, color: iconColor, size: 16),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: AppTypography.headline.copyWith(
              color: isAlert ? AppColors.danger : AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (isAlert) ...[
                const Icon(Icons.error_outline_rounded, size: 12, color: AppColors.danger),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  subtitle,
                  style: AppTypography.caption.copyWith(
                    color: isAlert ? AppColors.danger : AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: isAlert ? FontWeight.bold : FontWeight.normal,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActionGrid(AuthSession session) {
    final actions = [
      _ActionItem(
        title: 'New Bill / POS',
        subtitle: 'Search, scan & checkout',
        icon: Icons.add_shopping_cart_rounded,
        gradient: AppColors.gradientEmerald,
        onTap: widget.onOpenPos,
      ),
      _ActionItem(
        title: 'Customer Ledger',
        subtitle: 'Customers & receipts',
        icon: Icons.people_alt_rounded,
        gradient: AppColors.gradientIndigo,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const CustomerListScreen()),
        ),
      ),
      _ActionItem(
        title: 'Stock Management',
        subtitle: _outOfStockCount + _lowStockCount > 0
            ? '${_outOfStockCount + _lowStockCount} need attention'
            : 'Real-time stock & reorder',
        icon: Icons.inventory_2_rounded,
        gradient: const LinearGradient(colors: [Color(0xFF0D9488), Color(0xFF0F766E)]),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const StockManagementScreen()),
        ),
      ),
      if (session.hasPermission('grn.post'))
        _ActionItem(
          title: 'Receive Stock',
          subtitle: 'GRN & tare inward',
          icon: Icons.move_to_inbox_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF0284C7), Color(0xFF0EA5E9)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const GrnScreen()),
          ),
        ),
      if (session.hasPermission('supplier.manage'))
        _ActionItem(
          title: 'Suppliers',
          subtitle: 'Payables & invoices',
          icon: Icons.local_shipping_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SupplierListScreen()),
          ),
        ),
      if (session.hasPermission('cash.eod_close'))
        _ActionItem(
          title: 'Cash Drawer EOD',
          subtitle: 'Reconciliation & float',
          icon: Icons.lock_clock_rounded,
          gradient: AppColors.gradientAmber,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const EodScreen()),
          ),
        ),
      if (session.hasPermission('report.view'))
        _ActionItem(
          title: 'Analytics & Reports',
          subtitle: 'Sales, stock & balances',
          icon: Icons.analytics_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF9333EA), Color(0xFFA855F7)]),
          onTap: widget.onOpenReports ?? () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ReportsScreen()),
              ),
        ),
      if (session.hasPermission('report.view'))
        _ActionItem(
          title: 'Business Insights',
          subtitle: 'Trends, top sellers & more',
          icon: Icons.insights_rounded,
          gradient: AppColors.gradientSunset,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AnalyticsDashboardScreen()),
          ),
        ),
      _ActionItem(
        title: 'Offline Outbox',
        subtitle: '$_pendingSyncCount pending sync',
        icon: Icons.cloud_sync_rounded,
        gradient: const LinearGradient(colors: [Color(0xFF475569), Color(0xFF64748B)]),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const OutboxScreen()),
        ),
      ),
      if (session.hasPermission('device.manage'))
        _ActionItem(
          title: 'Pair New Device',
          subtitle: 'Generate pairing code',
          icon: Icons.qr_code_2_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF0D9488), Color(0xFF14B8A6)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const GeneratePairingCodeScreen()),
          ),
        ),
    ];

    return _buildActionGrid(actions);
  }

  /// Everything else this app can do, grouped so it's reachable from Home
  /// and not only from the Counter tab's overflow menu — each item gated
  /// on the same permission the menu item itself requires.
  Widget _buildManageGrid(AuthSession session) {
    final actions = [
      if (session.hasPermission('product.manage'))
        _ActionItem(
          title: 'Products',
          subtitle: 'Catalog & pricing',
          icon: Icons.inventory_2_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF0F766E), Color(0xFF14B8A6)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ProductListScreen()),
          ),
        ),
      if (session.hasPermission('product.manage'))
        _ActionItem(
          title: 'Categories & Brands',
          subtitle: 'Product lookups',
          icon: Icons.category_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF7C3AED), Color(0xFFA78BFA)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const MasterDataScreen()),
          ),
        ),
      if (session.hasPermission('product.manage'))
        _ActionItem(
          title: 'Locations',
          subtitle: 'Shops, godowns & warehouses',
          icon: Icons.warehouse_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF0D9488), Color(0xFF5EEAD4)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const LocationScreen()),
          ),
        ),
      if (session.hasPermission('product.manage'))
        _ActionItem(
          title: 'Tax Profiles',
          subtitle: 'GST rates & inclusive pricing',
          icon: Icons.receipt_long_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF0891B2), Color(0xFF67E8F9)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TaxProfileScreen()),
          ),
        ),
      if (session.hasPermission('stock.count'))
        _ActionItem(
          title: 'Stock Counts',
          subtitle: 'Physical audit',
          icon: Icons.playlist_add_check_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF0369A1), Color(0xFF0EA5E9)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const StockCountHistoryScreen()),
          ),
        ),
      if (session.hasPermission('pos.sell'))
        _ActionItem(
          title: 'Invoice History',
          subtitle: 'Past sales & reprint',
          icon: Icons.receipt_long_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF059669), Color(0xFF34D399)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const InvoiceHistoryScreen()),
          ),
        ),
      if (session.hasPermission('grn.post'))
        _ActionItem(
          title: 'GRN History',
          subtitle: 'Past goods receipts',
          icon: Icons.history_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF0284C7), Color(0xFF38BDF8)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const GrnHistoryScreen()),
          ),
        ),
      if (session.hasPermission('return.create'))
        _ActionItem(
          title: 'Sales Return',
          subtitle: 'Look up & refund',
          icon: Icons.assignment_return_rounded,
          gradient: const LinearGradient(colors: [Color(0xFFB45309), Color(0xFFF59E0B)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ReturnScreen()),
          ),
        ),
      if (session.hasPermission('contra.approve'))
        _ActionItem(
          title: 'Contra / Buy-Back',
          subtitle: 'Farmer barter credit',
          icon: Icons.undo_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF7C3AED), Color(0xFFC084FC)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ContraScreen()),
          ),
        ),
      if (session.hasPermission('user.manage'))
        _ActionItem(
          title: 'Staff',
          subtitle: 'Accounts & roles',
          icon: Icons.badge_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF4338CA), Color(0xFF818CF8)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const StaffListScreen()),
          ),
        ),
      if (session.hasPermission('device.manage'))
        _ActionItem(
          title: 'Manage Devices',
          subtitle: 'Terminals & revoke',
          icon: Icons.devices_other_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF334155), Color(0xFF64748B)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const DeviceManagementScreen()),
          ),
        ),
      if (session.hasPermission('tenant.admin'))
        _ActionItem(
          title: 'Financial Years',
          subtitle: 'Document numbering',
          icon: Icons.calendar_month_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF9A3412), Color(0xFFF97316)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const DocSeriesScreen()),
          ),
        ),
      if (session.hasPermission('tenant.admin'))
        _ActionItem(
          title: 'Audit Log',
          subtitle: 'Overrides & history',
          icon: Icons.fact_check_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF475569), Color(0xFF94A3B8)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AuditLogScreen()),
          ),
        ),
      if (session.hasPermission('tenant.admin'))
        _ActionItem(
          title: 'Store Settings',
          subtitle: 'Profile & receipt text',
          icon: Icons.storefront_rounded,
          gradient: const LinearGradient(colors: [Color(0xFF7C2D12), Color(0xFFEA580C)]),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const StoreSettingsScreen()),
          ),
        ),
    ];

    return _buildActionGrid(actions);
  }

  Widget _buildActionGrid(List<_ActionItem> actions) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width >= 720 ? 4 : 2;
        final double childAspectRatio = width >= 720 ? 1.35 : 1.15;

        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: actions.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: childAspectRatio,
          ),
          itemBuilder: (context, index) {
            final a = actions[index];
            // The tile's solid background lives on Material itself, not on
            // an opaque child Container: InkWell paints its splash as one
            // of the ancestor Material's own ink features, which render
            // before (i.e. below) the widget subtree — so an opaque
            // Container child painted on top of that layer would hide the
            // ripple almost entirely. Border/shadow stay on the Container
            // since Material doesn't offer an easy equivalent for those.
            return Container(
              decoration: BoxDecoration(
                borderRadius: AppDecorations.borderRadiusMd,
                border: Border.all(color: AppColors.border),
                boxShadow: AppDecorations.cardShadow,
              ),
              child: Material(
                color: AppColors.surface,
                borderRadius: AppDecorations.borderRadiusMd,
                child: InkWell(
                  onTap: a.onTap,
                  borderRadius: AppDecorations.borderRadiusMd,
                  hoverColor: AppColors.surfaceHover,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            gradient: a.gradient,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: (a.gradient is LinearGradient
                                        ? (a.gradient as LinearGradient).colors.first
                                        : AppColors.primary)
                                    .withValues(alpha: 0.3),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Icon(a.icon, color: Colors.white, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                a.title,
                                style: AppTypography.title.copyWith(fontSize: 13.5, fontWeight: FontWeight.bold),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                a.subtitle,
                                style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.textTertiary),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ActionItem {
  final String title;
  final String subtitle;
  final IconData icon;
  final Gradient gradient;
  final VoidCallback onTap;

  _ActionItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.gradient,
    required this.onTap,
  });
}
