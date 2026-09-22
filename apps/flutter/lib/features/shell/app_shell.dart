import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth_session.dart';
import '../../core/branding_provider.dart';
import '../../core/local_db.dart';
import '../../core/responsive.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import '../auth/login_screen.dart';
import '../dashboard/home_dashboard_screen.dart';
import '../customers/customer_list_screen.dart';
import '../pos/product_search_screen.dart';
import '../reports/reports_screen.dart';
import '../supplier/supplier_list_screen.dart';
import '../sync/outbox_screen.dart';

/// Adaptive Multi-Platform Navigation Shell for FeedMate.
/// Adapts dynamically between:
/// - Desktop Sidebar (Windows & Web >= 1100px)
/// - Navigation Rail (Tablets 768px - 1099px)
/// - Modern Bottom Navigation Bar (Handhelds < 768px)
class AppShell extends StatefulWidget {
  final int initialIndex;
  const AppShell({super.key, this.initialIndex = 0});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _currentIndex;
  int _pendingSyncCount = 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _refreshSyncCount();
  }

  Future<void> _refreshSyncCount() async {
    try {
      final localDb = context.read<LocalDatabase>();
      final count = await localDb.pendingInvoiceCount();
      if (mounted) setState(() => _pendingSyncCount = count);
    } catch (_) {}
  }

  void _onTabSelected(int index) {
    setState(() => _currentIndex = index);
    _refreshSyncCount();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AuthSession>();
    final branding = context.watch<BrandingProvider>();

    final hasSuppliersTab = session.hasPermission('supplier.manage');
    final hasReportsTab = session.hasPermission('report.view');
    final reportsIndex = hasReportsTab ? (3 + (hasSuppliersTab ? 1 : 0)) : null;

    final tabs = <_ShellTab>[
      _ShellTab(
        screen: HomeDashboardScreen(
          onOpenPos: () => _onTabSelected(1),
          onOpenReports: reportsIndex != null ? () => _onTabSelected(reportsIndex) : null,
        ),
        icon: Icons.dashboard_outlined,
        selectedIcon: Icons.dashboard_rounded,
        label: 'Home',
        color: AppColors.primary,
        gradient: AppColors.gradientEmerald,
      ),
      const _ShellTab(
        screen: ProductSearchScreen(),
        icon: Icons.point_of_sale_outlined,
        selectedIcon: Icons.point_of_sale_rounded,
        label: 'Counter',
        color: AppColors.secondary,
        gradient: AppColors.gradientIndigo,
      ),
      const _ShellTab(
        screen: CustomerListScreen(),
        icon: Icons.account_balance_wallet_outlined,
        selectedIcon: Icons.account_balance_wallet_rounded,
        label: 'Customers',
        color: AppColors.accent,
        gradient: AppColors.gradientCyan,
      ),
      if (hasSuppliersTab)
        const _ShellTab(
          screen: SupplierListScreen(),
          icon: Icons.local_shipping_outlined,
          selectedIcon: Icons.local_shipping_rounded,
          label: 'Suppliers',
          color: AppColors.warning,
          gradient: AppColors.gradientAmber,
        ),
      if (hasReportsTab)
        const _ShellTab(
          screen: ReportsScreen(),
          icon: Icons.analytics_outlined,
          selectedIcon: Icons.analytics_rounded,
          label: 'Reports',
          color: AppColors.danger,
          gradient: AppColors.gradientRose,
        ),
    ];

    final currentIndex = _currentIndex < tabs.length ? _currentIndex : 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= ResponsiveBreakpoints.desktopMin;
        final isTablet = constraints.maxWidth >= ResponsiveBreakpoints.tabletMin && !isDesktop;

        // 1. Desktop Mode (Windows & Web)
        if (isDesktop) {
          return Scaffold(
            body: Row(
              children: [
                _buildDesktopSidebar(context, session, branding, tabs, currentIndex),
                const VerticalDivider(thickness: 1, width: 1, color: AppColors.border),
                Expanded(
                  child: IndexedStack(
                    index: currentIndex,
                    children: [for (final tab in tabs) tab.screen],
                  ),
                ),
              ],
            ),
          );
        }

        // 2. Tablet Mode (Compact Navigation Rail)
        if (isTablet) {
          return Scaffold(
            body: Row(
              children: [
                LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: constraints.maxHeight),
                      child: IntrinsicHeight(
                        child: NavigationRail(
                          selectedIndex: currentIndex,
                          onDestinationSelected: _onTabSelected,
                          backgroundColor: AppColors.surface,
                          indicatorColor: AppColors.primaryContainer,
                          labelType: NavigationRailLabelType.all,
                          leading: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                gradient: AppColors.gradientEmerald,
                                borderRadius: BorderRadius.circular(10),
                                boxShadow: AppDecorations.cardShadow,
                              ),
                              child: const Icon(Icons.storefront_rounded, color: Colors.white, size: 20),
                            ),
                          ),
                          destinations: [
                            for (final tab in tabs)
                              NavigationRailDestination(
                                icon: Icon(tab.icon),
                                selectedIcon: Icon(tab.selectedIcon, color: tab.color),
                                label: Text(tab.label, style: const TextStyle(fontSize: 11)),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const VerticalDivider(thickness: 1, width: 1, color: AppColors.border),
                Expanded(
                  child: IndexedStack(
                    index: currentIndex,
                    children: [for (final tab in tabs) tab.screen],
                  ),
                ),
              ],
            ),
          );
        }

        // 3. Mobile Mode (Elevated Bottom Navigation Bar)
        final activeTab = tabs[currentIndex];
        return Scaffold(
          body: IndexedStack(
            index: currentIndex,
            children: [for (final tab in tabs) tab.screen],
          ),
          bottomNavigationBar: Container(
            decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(top: BorderSide(color: AppColors.border, width: 1)),
              boxShadow: [
                BoxShadow(
                  color: Color(0x080F172A),
                  blurRadius: 16,
                  offset: Offset(0, -4),
                ),
              ],
            ),
            child: NavigationBar(
              selectedIndex: currentIndex,
              onDestinationSelected: _onTabSelected,
              backgroundColor: AppColors.surface,
              indicatorColor: activeTab.color.withValues(alpha: 0.16),
              elevation: 0,
              height: 64,
              destinations: [
                for (final tab in tabs)
                  NavigationDestination(
                    icon: Icon(tab.icon),
                    selectedIcon: Icon(tab.selectedIcon, color: tab.color),
                    label: tab.label,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDesktopSidebar(
    BuildContext context,
    AuthSession session,
    BrandingProvider branding,
    List<_ShellTab> tabs,
    int currentIndex,
  ) {
    final displayName = session.displayName ?? 'Staff';
    final roleName = session.hasPermission('tenant.admin')
        ? 'ADMIN'
        : (session.hasPermission('pos.sell') ? 'CASHIER' : 'ACTIVE');

    return Container(
      width: 260,
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: Brand & Store Name
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: AppColors.gradientEmerald,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: AppDecorations.cardShadow,
                  ),
                  child: const Icon(Icons.storefront_rounded, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        branding.appName,
                        style: AppTypography.displayMedium.copyWith(fontSize: 19, letterSpacing: -0.5),
                      ),
                      Text(
                        branding.appTagline,
                        style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1, color: AppColors.border),

          // User Profile Card
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surfaceSecondary,
                borderRadius: AppDecorations.borderRadiusMd,
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: AppColors.primary,
                    child: Text(
                      displayName.isNotEmpty ? displayName[0].toUpperCase() : 'U',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayName,
                          style: AppTypography.title.copyWith(fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          roleName,
                          style: AppTypography.caption.copyWith(fontSize: 10, color: AppColors.primary, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 8),

          // Navigation Links
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: tabs.length,
              separatorBuilder: (context, index) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final tab = tabs[index];
                final isSelected = index == currentIndex;

                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  decoration: BoxDecoration(
                    gradient: isSelected ? tab.gradient : null,
                    color: isSelected ? null : Colors.transparent,
                    borderRadius: AppDecorations.borderRadiusMd,
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color: tab.color.withValues(alpha: 0.35),
                              blurRadius: 14,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null,
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: AppDecorations.borderRadiusMd,
                      onTap: () => _onTabSelected(index),
                      hoverColor: isSelected ? null : AppColors.surfaceHover,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? Colors.white.withValues(alpha: 0.2)
                                    : tab.color.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                isSelected ? tab.selectedIcon : tab.icon,
                                size: 18,
                                color: isSelected ? Colors.white : tab.color,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                tab.label,
                                style: AppTypography.title.copyWith(
                                  fontSize: 14,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                  color: isSelected ? Colors.white : AppColors.textPrimary,
                                ),
                              ),
                            ),
                            if (isSelected)
                              Container(
                                width: 7,
                                height: 7,
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          const Divider(height: 1, color: AppColors.border),

          // Footer: Sync Status & Logout
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                ListTile(
                  dense: true,
                  shape: RoundedRectangleBorder(borderRadius: AppDecorations.borderRadiusSm),
                  leading: Badge(
                    label: Text('$_pendingSyncCount'),
                    isLabelVisible: _pendingSyncCount > 0,
                    backgroundColor: AppColors.warning,
                    child: const Icon(Icons.sync_rounded, size: 20, color: AppColors.textSecondary),
                  ),
                  title: const Text('Offline Outbox', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                  trailing: _pendingSyncCount > 0
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: AppColors.warningContainer, borderRadius: BorderRadius.circular(4)),
                          child: Text('$_pendingSyncCount pending', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppColors.onWarningContainer)),
                        )
                      : const Icon(Icons.check_circle_outline_rounded, color: AppColors.success, size: 16),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OutboxScreen()));
                    _refreshSyncCount();
                  },
                ),
                ListTile(
                  dense: true,
                  shape: RoundedRectangleBorder(borderRadius: AppDecorations.borderRadiusSm),
                  leading: const Icon(Icons.logout_rounded, size: 20, color: AppColors.danger),
                  title: const Text('Logout', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.danger)),
                  onTap: () async {
                    await session.logout();
                    if (!context.mounted) return;
                    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShellTab {
  final Widget screen;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final Color color;
  final LinearGradient gradient;

  const _ShellTab({
    required this.screen,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.color,
    required this.gradient,
  });
}
