import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth_session.dart';
import '../../core/theme/app_colors.dart';
import '../dashboard/home_dashboard_screen.dart';
import '../khata/khata_customer_list_screen.dart';
import '../pos/product_search_screen.dart';
import '../reports/reports_screen.dart';
import '../supplier/supplier_list_screen.dart';

/// Adaptive App Navigation Shell for FeedMate.
/// Implements a modern Bottom Navigation Bar on handhelds and a Navigation Rail on tablets.
class AppShell extends StatefulWidget {
  final int initialIndex;
  const AppShell({super.key, this.initialIndex = 0});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
  }

  void _onTabSelected(int index) {
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AuthSession>();

    // Home, Counter, and Khata are available to everyone; Suppliers and
    // Reports only appear at all when the session actually holds the
    // permission — mirroring the overflow menu's convention elsewhere in the
    // app (hide what a user can't use, rather than showing a tab that leads
    // nowhere useful).
    final hasSuppliersTab = session.hasPermission('supplier.manage');
    final hasReportsTab = session.hasPermission('report.view');
    // Fixed positions: Home=0, Counter=1, Khata=2, then Suppliers (if
    // present), then Reports — computed directly rather than searching the
    // list built below, since Home's callback needs this before that list
    // exists.
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
      ),
      const _ShellTab(
        screen: ProductSearchScreen(),
        icon: Icons.point_of_sale_outlined,
        selectedIcon: Icons.point_of_sale_rounded,
        label: 'Counter',
      ),
      const _ShellTab(
        screen: KhataCustomerListScreen(),
        icon: Icons.account_balance_wallet_outlined,
        selectedIcon: Icons.account_balance_wallet_rounded,
        label: 'Khata',
      ),
      if (hasSuppliersTab)
        const _ShellTab(
          screen: SupplierListScreen(),
          icon: Icons.local_shipping_outlined,
          selectedIcon: Icons.local_shipping_rounded,
          label: 'Suppliers',
        ),
      if (hasReportsTab)
        const _ShellTab(
          screen: ReportsScreen(),
          icon: Icons.analytics_outlined,
          selectedIcon: Icons.analytics_rounded,
          label: 'Reports',
        ),
    ];
    // A permission change (rare, but possible across a session refresh)
    // could leave the previously-selected index out of range now that the
    // tab list has shrunk — fall back to Home rather than crashing.
    final currentIndex = _currentIndex < tabs.length ? _currentIndex : 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isTablet = constraints.maxWidth >= 768;

        if (isTablet) {
          // Tablet / Desktop Navigation Rail
          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: currentIndex,
                  onDestinationSelected: _onTabSelected,
                  backgroundColor: AppColors.surface,
                  indicatorColor: AppColors.primaryContainer,
                  labelType: NavigationRailLabelType.all,
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        gradient: AppColors.gradientEmerald,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.storefront_rounded, color: Colors.white, size: 24),
                    ),
                  ),
                  destinations: [
                    for (final tab in tabs)
                      NavigationRailDestination(
                        icon: Icon(tab.icon),
                        selectedIcon: Icon(tab.selectedIcon, color: AppColors.primary),
                        label: Text(tab.label),
                      ),
                  ],
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

        // Mobile Bottom Navigation Bar
        return Scaffold(
          body: IndexedStack(
            index: currentIndex,
            children: [for (final tab in tabs) tab.screen],
          ),
          bottomNavigationBar: Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.border, width: 1)),
            ),
            child: NavigationBar(
              selectedIndex: currentIndex,
              onDestinationSelected: _onTabSelected,
              backgroundColor: AppColors.surface,
              indicatorColor: AppColors.primaryContainer,
              elevation: 0,
              height: 64,
              destinations: [
                for (final tab in tabs)
                  NavigationDestination(
                    icon: Icon(tab.icon),
                    selectedIcon: Icon(tab.selectedIcon, color: AppColors.primary),
                    label: tab.label,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ShellTab {
  final Widget screen;
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  const _ShellTab({required this.screen, required this.icon, required this.selectedIcon, required this.label});
}
