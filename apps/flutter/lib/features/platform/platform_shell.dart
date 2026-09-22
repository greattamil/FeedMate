import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import 'platform_api_client.dart';
import 'platform_audit_log_screen.dart';
import 'platform_error_log_screen.dart';
import 'platform_login_screen.dart';
import 'tenant_list_screen.dart';

/// The super-admin shell: a bottom-nav switcher between Tenants, Audit Log,
/// and Error Log, plus a logout action — the platform-admin equivalent of
/// the tenant app's AppShell, but with none of the tenant-scoped tabs.
class PlatformShell extends StatefulWidget {
  const PlatformShell({super.key});

  @override
  State<PlatformShell> createState() => _PlatformShellState();
}

class _PlatformShellState extends State<PlatformShell> {
  int _index = 0;

  static const _screens = [
    TenantListScreen(),
    PlatformAuditLogScreen(),
    PlatformErrorLogScreen(),
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
    final displayName = context.watch<PlatformApiClient>().displayName;
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: Text(
          displayName != null ? 'Platform Admin — $displayName' : 'Platform Admin',
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            key: const Key('platform_logout_button'),
            onPressed: _logout,
            icon: const Icon(Icons.logout_rounded, color: Colors.white),
            tooltip: 'Log out',
          ),
        ],
      ),
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: const Color(0xFF1E293B),
        indicatorColor: AppColors.primary.withValues(alpha: 0.3),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.storefront_rounded, color: Color(0xFF94A3B8)), selectedIcon: Icon(Icons.storefront_rounded, color: Colors.white), label: 'Tenants'),
          NavigationDestination(icon: Icon(Icons.history_rounded, color: Color(0xFF94A3B8)), selectedIcon: Icon(Icons.history_rounded, color: Colors.white), label: 'Audit Log'),
          NavigationDestination(icon: Icon(Icons.bug_report_rounded, color: Color(0xFF94A3B8)), selectedIcon: Icon(Icons.bug_report_rounded, color: Colors.white), label: 'Error Log'),
        ],
      ),
    );
  }
}
