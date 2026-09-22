import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/number_format.dart';
import '../../core/responsive.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'create_tenant_screen.dart';
import 'platform_api.dart';
import 'platform_api_client.dart';
import 'tenant_detail_screen.dart';

/// Every tenant on this deployment — the platform admin's home screen.
/// Never a per-tenant view: this is the one place "all clients" is a valid
/// thing to see at once.
class TenantListScreen extends StatefulWidget {
  const TenantListScreen({super.key});

  @override
  State<TenantListScreen> createState() => _TenantListScreenState();
}

class _TenantListScreenState extends State<TenantListScreen> {
  List<TenantSummary> _tenants = [];
  bool _loading = true;
  String? _error;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
    _searchController.addListener(() => setState(() => _query = _searchController.text.trim().toLowerCase()));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      final tenants = await api.listTenants();
      if (!mounted) return;
      setState(() {
        _tenants = tenants;
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

  Future<void> _openCreate() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CreateTenantScreen()),
    );
    if (created == true) await _load();
  }

  Future<void> _openDetail(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TenantDetailScreen(tenantId: id)),
    );
    await _load();
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'ACTIVE':
        return AppColors.success;
      case 'SUSPENDED':
        return AppColors.warning;
      default:
        return AppColors.danger;
    }
  }

  List<TenantSummary> get _filtered {
    if (_query.isEmpty) return _tenants;
    return _tenants.where((t) {
      return t.legalName.toLowerCase().contains(_query) ||
          (t.tradeName?.toLowerCase().contains(_query) ?? false) ||
          t.city.toLowerCase().contains(_query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 48, color: AppColors.danger),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center, style: AppTypography.body),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final activeCount = _tenants.where((t) => t.status == 'ACTIVE').length;
    final suspendedCount = _tenants.where((t) => t.status == 'SUSPENDED').length;
    final totalUsers = _tenants.fold<int>(0, (sum, t) => sum + t.userCount);
    final filtered = _filtered;

    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.all(context.responsive(mobile: 16.0, desktop: 24.0)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ResponsiveBreakpoints.maxContentWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Stat summary row
              LayoutBuilder(
                builder: (context, constraints) {
                  final cards = [
                    _statCard('Total Tenants', intGrouped(_tenants.length), Icons.storefront_rounded, AppColors.primary),
                    _statCard('Active', intGrouped(activeCount), Icons.check_circle_rounded, AppColors.success),
                    _statCard('Suspended', intGrouped(suspendedCount), Icons.pause_circle_rounded, AppColors.warning),
                    _statCard('Total Users', intGrouped(totalUsers), Icons.people_alt_rounded, AppColors.secondary),
                  ];
                  if (context.isMobile) {
                    return SizedBox(
                      height: 96,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: cards.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                        itemBuilder: (context, i) => SizedBox(width: 160, child: cards[i]),
                      ),
                    );
                  }
                  return Row(
                    children: [
                      for (int i = 0; i < cards.length; i++) ...[
                        if (i > 0) const SizedBox(width: 14),
                        Expanded(child: cards[i]),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),

              // Search + Add
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('tenant_search_field'),
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search tenants by name or city…',
                        prefixIcon: const Icon(Icons.search_rounded, color: AppColors.textSecondary),
                        filled: true,
                        fillColor: AppColors.surface,
                        border: OutlineInputBorder(borderRadius: AppDecorations.borderRadiusMd, borderSide: const BorderSide(color: AppColors.border)),
                        enabledBorder: OutlineInputBorder(borderRadius: AppDecorations.borderRadiusMd, borderSide: const BorderSide(color: AppColors.border)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    key: const Key('add_tenant_fab'),
                    onPressed: _openCreate,
                    style: FilledButton.styleFrom(backgroundColor: AppColors.primary, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16)),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('New Tenant'),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              if (filtered.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 48),
                  child: Center(
                    child: Column(
                      children: [
                        const Icon(Icons.storefront_outlined, size: 48, color: AppColors.textTertiary),
                        const SizedBox(height: 12),
                        Text(_tenants.isEmpty ? 'No tenants yet — create the first one.' : 'No tenants match your search.', style: AppTypography.bodySecondary),
                      ],
                    ),
                  ),
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = context.responsive(mobile: 1, tablet: 2, desktop: 3);
                    if (columns == 1) {
                      return Column(
                        children: [for (final t in filtered) Padding(padding: const EdgeInsets.only(bottom: 12), child: _tenantCard(t))],
                      );
                    }
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: filtered.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 14,
                        childAspectRatio: 2.6,
                      ),
                      itemBuilder: (context, i) => _tenantCard(filtered[i]),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppDecorations.card(),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: AppDecorations.borderRadiusMd),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(value, style: AppTypography.displayMedium.copyWith(fontSize: 20)),
                Text(label, style: AppTypography.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tenantCard(TenantSummary t) {
    final statusColor = _statusColor(t.status);
    return Container(
      key: Key('tenant_item_${t.id}'),
      decoration: AppDecorations.card(),
      child: Material(
        color: Colors.transparent,
        borderRadius: AppDecorations.borderRadiusMd,
        child: InkWell(
          borderRadius: AppDecorations.borderRadiusMd,
          onTap: () => _openDetail(t.id),
          hoverColor: AppColors.surfaceHover,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(gradient: AppColors.gradientEmerald, borderRadius: AppDecorations.borderRadiusMd),
                  child: Center(
                    child: Text(
                      t.legalName.isNotEmpty ? t.legalName[0].toUpperCase() : '?',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(t.legalName, style: AppTypography.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(
                        '${t.city} · ${t.planCode} · ${intGrouped(t.userCount)} user${t.userCount == 1 ? '' : 's'}',
                        style: AppTypography.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.12), borderRadius: AppDecorations.borderRadiusFull),
                  child: Text(t.status, style: AppTypography.caption.copyWith(color: statusColor, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
