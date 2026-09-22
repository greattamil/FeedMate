import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/branding_provider.dart';
import '../../core/responsive.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'platform_api_client.dart';
import 'platform_audit_log_screen.dart';
import 'platform_error_log_screen.dart';
import 'platform_login_screen.dart';
import 'platform_settings_screen.dart';
import 'tenant_list_screen.dart';

class _PlatformTab {
  final Widget screen;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final Color color;
  final Gradient gradient;

  const _PlatformTab({
    required this.screen,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.color,
    required this.gradient,
  });
}

/// The super-admin shell — mirrors the tenant app's [AppShell] responsive
/// pattern (permanent sidebar on desktop/wide web, bottom nav on handheld)
/// instead of a bespoke one-off dark layout, so this looks and behaves like
/// the rest of the product rather than a disconnected internal tool.
class PlatformShell extends StatefulWidget {
  const PlatformShell({super.key});

  @override
  State<PlatformShell> createState() => _PlatformShellState();
}

class _PlatformShellState extends State<PlatformShell> {
  int _index = 0;

  static const _tabs = [
    _PlatformTab(
      screen: TenantListScreen(),
      icon: Icons.storefront_outlined,
      selectedIcon: Icons.storefront_rounded,
      label: 'Tenants',
      color: AppColors.primary,
      gradient: AppColors.gradientEmerald,
    ),
    _PlatformTab(
      screen: PlatformAuditLogScreen(),
      icon: Icons.history_outlined,
      selectedIcon: Icons.history_rounded,
      label: 'Audit Log',
      color: AppColors.secondary,
      gradient: AppColors.gradientIndigo,
    ),
    _PlatformTab(
      screen: PlatformErrorLogScreen(),
      icon: Icons.bug_report_outlined,
      selectedIcon: Icons.bug_report_rounded,
      label: 'Error Log',
      color: AppColors.danger,
      gradient: AppColors.gradientRose,
    ),
    _PlatformTab(
      screen: PlatformSettingsScreen(),
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      label: 'Settings',
      color: AppColors.accent,
      gradient: AppColors.gradientCyan,
    ),
  ];

  Future<void> _logout() async {
    await context.read<PlatformApiClient>().logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const PlatformLoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayName = context.watch<PlatformApiClient>().displayName ?? 'Admin';

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= ResponsiveBreakpoints.desktopMin;

        if (isDesktop) {
          return Scaffold(
            backgroundColor: AppColors.background,
            body: Row(
              children: [
                _buildSidebar(context, displayName),
                const VerticalDivider(thickness: 1, width: 1, color: AppColors.border),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildTopBar(context),
                      Expanded(
                        child: IndexedStack(index: _index, children: [for (final t in _tabs) t.screen]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        final activeTab = _tabs[_index];
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            foregroundColor: AppColors.textPrimary,
            elevation: 0,
            title: Text(activeTab.label, style: AppTypography.headline),
            actions: [
              IconButton(
                key: const Key('platform_logout_button'),
                onPressed: _logout,
                icon: const Icon(Icons.logout_rounded),
                tooltip: 'Log out',
              ),
            ],
          ),
          body: IndexedStack(index: _index, children: [for (final t in _tabs) t.screen]),
          bottomNavigationBar: Container(
            decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(top: BorderSide(color: AppColors.border, width: 1)),
              boxShadow: [BoxShadow(color: Color(0x080F172A), blurRadius: 16, offset: Offset(0, -4))],
            ),
            child: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              backgroundColor: AppColors.surface,
              indicatorColor: activeTab.color.withValues(alpha: 0.16),
              elevation: 0,
              height: 64,
              destinations: [
                for (final t in _tabs)
                  NavigationDestination(icon: Icon(t.icon), selectedIcon: Icon(t.selectedIcon, color: t.color), label: t.label),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final branding = context.watch<BrandingProvider>();
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Text(_tabs[_index].label, style: AppTypography.displayMedium.copyWith(fontSize: 19)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: AppColors.secondaryContainer, borderRadius: AppDecorations.borderRadiusFull),
            child: Text(
              '${branding.appName} — Super Admin',
              style: AppTypography.caption.copyWith(color: AppColors.onSecondaryContainer, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar(BuildContext context, String displayName) {
    return Container(
      width: 260,
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: AppColors.gradientIndigo,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: AppDecorations.cardShadow,
                  ),
                  child: const Icon(Icons.admin_panel_settings_rounded, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Platform Admin', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: AppColors.textPrimary)),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
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
                    backgroundColor: AppColors.secondary,
                    child: Text(
                      displayName.isNotEmpty ? displayName[0].toUpperCase() : 'A',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(displayName, style: AppTypography.title.copyWith(fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  IconButton(
                    key: const Key('platform_logout_button'),
                    onPressed: _logout,
                    icon: const Icon(Icons.logout_rounded, size: 18, color: AppColors.textSecondary),
                    tooltip: 'Log out',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _tabs.length,
              separatorBuilder: (context, index) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final tab = _tabs[index];
                final isSelected = index == _index;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  decoration: BoxDecoration(
                    gradient: isSelected ? tab.gradient : null,
                    borderRadius: AppDecorations.borderRadiusMd,
                    boxShadow: isSelected
                        ? [BoxShadow(color: tab.color.withValues(alpha: 0.35), blurRadius: 14, offset: const Offset(0, 4))]
                        : null,
                  ),
                  child: isSelected
                      // The gradient fill alone communicates selection.
                      // Layering any Material ink widget on top of it here
                      // (InkWell/Material, even with every overlay color set
                      // to transparent) reliably repaints solid black the
                      // instant the pointer that just clicked this item is
                      // still resting over it in a web build — a genuine
                      // engine-level interaction with an animated gradient
                      // decoration, not something fixable by tuning ink
                      // state colors. A plain GestureDetector sidesteps the
                      // entire Material ink pipeline for the selected item.
                      ? GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _index = index),
                          child: _sidebarItemContent(tab, isSelected),
                        )
                      : Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: AppDecorations.borderRadiusMd,
                            onTap: () => setState(() => _index = index),
                            hoverColor: AppColors.surfaceHover,
                            child: _sidebarItemContent(tab, isSelected),
                          ),
                        ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _sidebarItemContent(_PlatformTab tab, bool isSelected) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: isSelected ? Colors.white.withValues(alpha: 0.2) : tab.color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(isSelected ? tab.selectedIcon : tab.icon, size: 18, color: isSelected ? Colors.white : tab.color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              tab.label,
              style: AppTypography.title.copyWith(fontSize: 14, color: isSelected ? Colors.white : AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
