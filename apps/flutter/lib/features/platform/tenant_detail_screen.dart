import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/responsive.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'platform_api.dart';
import 'platform_api_client.dart';

/// The platform admin's full control surface for one tenant: suspend/
/// reactivate, plan tier + expiry, whitelabel branding, and feature-flag
/// toggles — everything a shop's own Owner has no access to change about
/// their own account.
class TenantDetailScreen extends StatefulWidget {
  final String tenantId;
  const TenantDetailScreen({super.key, required this.tenantId});

  @override
  State<TenantDetailScreen> createState() => _TenantDetailScreenState();
}

// A small starter catalogue of feature codes a platform admin can toggle.
// tenant_features is free-form (no catalogue table server-side), so this
// list is just a convenience — SetTenantFeature accepts any code.
const _knownFeatureCodes = ['advanced_reports', 'multi_location', 'sms_reminders', 'whatsapp_invoices'];

class _TenantDetailScreenState extends State<TenantDetailScreen> {
  TenantDetail? _detail;
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
      final api = PlatformApi(context.read<PlatformApiClient>());
      final detail = await api.getTenant(widget.tenantId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
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

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _changeStatus(String status) async {
    final api = PlatformApi(context.read<PlatformApiClient>());
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: status == 'ACTIVE' ? AppColors.successContainer : AppColors.warningContainer,
                borderRadius: AppDecorations.borderRadiusSm,
              ),
              child: Icon(
                status == 'ACTIVE' ? Icons.check_circle_outline_rounded : Icons.pause_circle_outline_rounded,
                color: status == 'ACTIVE' ? AppColors.success : AppColors.warning,
              ),
            ),
            const SizedBox(width: 12),
            Text(status == 'ACTIVE' ? 'Reactivate Tenant?' : 'Suspend Tenant?'),
          ],
        ),
        content: Text(
          status == 'ACTIVE'
              ? 'This tenant will be able to log in and use the app again immediately.'
              : 'This tenant will be signed out of new logins immediately — existing sessions stop working on their next refresh.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('tenant_status_confirm'),
            style: FilledButton.styleFrom(backgroundColor: status == 'ACTIVE' ? AppColors.success : AppColors.warning),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(status == 'ACTIVE' ? 'Reactivate' : 'Suspend'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() => api.setTenantStatus(widget.tenantId, status));
  }

  Future<void> _editPlan() async {
    final detail = _detail;
    if (detail == null) return;
    final result = await showDialog<(String, DateTime?)>(
      context: context,
      builder: (context) => _PlanDialog(currentPlan: detail.planCode, currentExpiry: detail.planExpiresAt),
    );
    if (result == null) return;
    final api = PlatformApi(context.read<PlatformApiClient>());
    await _run(() => api.setTenantPlan(widget.tenantId, result.$1, result.$2));
  }

  Future<void> _editBranding() async {
    final detail = _detail;
    if (detail == null) return;
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => _BrandingDialog(detail: detail),
    );
    if (result == null) return;
    final api = PlatformApi(context.read<PlatformApiClient>());
    await _run(() => api.setTenantBranding(
          widget.tenantId,
          appDisplayName: result['app_display_name'],
          logoUrl: result['logo_url'],
          primaryColor: result['primary_color'],
        ));
  }

  Future<void> _toggleFeature(String code, bool enabled) async {
    final api = PlatformApi(context.read<PlatformApiClient>());
    await _run(() => api.setTenantFeature(widget.tenantId, code, enabled));
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

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        title: Text(detail?.legalName ?? 'Tenant', style: AppTypography.headline),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!, style: const TextStyle(color: AppColors.danger)),
                  ),
                )
              : detail == null
                  ? const SizedBox.shrink()
                  : SingleChildScrollView(
                      padding: EdgeInsets.all(context.responsive(mobile: 16.0, desktop: 24.0)),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: ResponsiveBreakpoints.maxContentWidth),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _headerCard(detail),
                              const SizedBox(height: 16),
                              context.isDesktop
                                  ? IntrinsicHeight(
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Expanded(child: _sideColumn(detail)),
                                          const SizedBox(width: 16),
                                          Expanded(flex: 2, child: _mainColumn(detail)),
                                        ],
                                      ),
                                    )
                                  // Mobile: the actionable "control panel" (status/
                                  // plan/usage) comes first — a platform admin's
                                  // most common reason to open this screen (suspend
                                  // a tenant, check their plan) must not require
                                  // scrolling past branding/feature-flag cards first.
                                  : Column(children: [_sideColumn(detail), const SizedBox(height: 16), _mainColumn(detail)]),
                            ],
                          ),
                        ),
                      ),
                    ),
    );
  }

  Widget _mainColumn(TenantDetail detail) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(
          title: 'Whitelabel Branding',
          icon: Icons.palette_outlined,
          iconColor: AppColors.secondary,
          trailing: IconButton(key: const Key('tenant_edit_branding_button'), onPressed: _editBranding, icon: const Icon(Icons.edit_outlined, size: 20)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv('App name', detail.appDisplayName ?? '(using platform default)'),
              _kv('Logo URL', detail.logoUrl ?? '(none)'),
              _kv('Primary color', detail.primaryColor ?? '(using platform default)'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          title: 'Feature Flags & Modules',
          icon: Icons.extension_outlined,
          iconColor: AppColors.accent,
          child: Column(
            children: _knownFeatureCodes.map((code) {
              final enabled = detail.features[code] ?? false;
              return SwitchListTile(
                key: Key('tenant_feature_switch_$code'),
                contentPadding: EdgeInsets.zero,
                title: Text(code, style: AppTypography.body),
                value: enabled,
                activeThumbColor: AppColors.primary,
                onChanged: (v) => _toggleFeature(code, v),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _sideColumn(TenantDetail detail) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(
          title: 'Status',
          icon: Icons.toggle_on_outlined,
          iconColor: _statusColor(detail.status),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                key: const Key('tenant_detail_status'),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: _statusColor(detail.status).withValues(alpha: 0.12), borderRadius: AppDecorations.borderRadiusFull),
                child: Text('Current: ${detail.status}', style: AppTypography.caption.copyWith(color: _statusColor(detail.status), fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 14),
              if (detail.status != 'ACTIVE')
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('tenant_reactivate_button'),
                    style: FilledButton.styleFrom(backgroundColor: AppColors.success),
                    onPressed: () => _changeStatus('ACTIVE'),
                    child: const Text('Reactivate'),
                  ),
                ),
              if (detail.status == 'ACTIVE')
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('tenant_suspend_button'),
                    style: FilledButton.styleFrom(backgroundColor: AppColors.warning),
                    onPressed: () => _changeStatus('SUSPENDED'),
                    child: const Text('Suspend'),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          title: 'Plan & Billing',
          icon: Icons.workspace_premium_outlined,
          iconColor: AppColors.warning,
          trailing: IconButton(key: const Key('tenant_edit_plan_button'), onPressed: _editPlan, icon: const Icon(Icons.edit_outlined, size: 20)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv('Plan', detail.planCode),
              _kv('Expires', detail.planExpiresAt != null ? detail.planExpiresAt!.toLocal().toString().split(' ').first : 'No expiry set'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          title: 'Usage',
          icon: Icons.people_alt_outlined,
          iconColor: AppColors.primary,
          child: _kv('Staff users', '${detail.userCount}'),
        ),
      ],
    );
  }

  Widget _headerCard(TenantDetail detail) {
    final statusColor = _statusColor(detail.status);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: AppDecorations.card(gradient: AppColors.gradientHeroMesh, shadows: AppDecorations.emeraldGlow),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: AppDecorations.borderRadiusMd),
            child: Center(
              child: Text(
                detail.legalName.isNotEmpty ? detail.legalName[0].toUpperCase() : '?',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 24),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(detail.legalName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20)),
                const SizedBox(height: 4),
                Text('${detail.addressLine1}, ${detail.city}, ${detail.stateCode}', style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: AppDecorations.borderRadiusFull, border: Border.all(color: statusColor.withValues(alpha: 0.6))),
            child: Text(detail.status, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 90, child: Text(label, style: AppTypography.caption)),
          Expanded(child: Text(value, style: AppTypography.body)),
        ],
      ),
    );
  }

  Widget _card({required String title, required IconData icon, required Color iconColor, required Widget child, Widget? trailing}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppDecorations.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.12), borderRadius: AppDecorations.borderRadiusSm),
                child: Icon(icon, color: iconColor, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: AppTypography.title)),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _PlanDialog extends StatefulWidget {
  final String currentPlan;
  final DateTime? currentExpiry;
  const _PlanDialog({required this.currentPlan, this.currentExpiry});

  @override
  State<_PlanDialog> createState() => _PlanDialogState();
}

class _PlanDialogState extends State<_PlanDialog> {
  late String _plan;
  DateTime? _expiry;
  static const _plans = ['TRIAL', 'BASIC', 'PRO'];

  @override
  void initState() {
    super.initState();
    _plan = widget.currentPlan;
    _expiry = widget.currentExpiry;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Plan'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            key: const Key('plan_dialog_code_field'),
            initialValue: _plan,
            items: _plans.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
            onChanged: (v) => setState(() => _plan = v ?? _plan),
          ),
          const SizedBox(height: 12),
          ListTile(
            key: const Key('plan_dialog_expiry_field'),
            contentPadding: EdgeInsets.zero,
            title: Text(_expiry == null ? 'No expiry set' : 'Expires ${_expiry!.toLocal().toString().split(' ').first}'),
            trailing: const Icon(Icons.calendar_today_rounded, size: 18),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _expiry ?? DateTime.now().add(const Duration(days: 30)),
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 3650)),
              );
              if (picked != null) setState(() => _expiry = picked);
            },
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('plan_dialog_submit'),
          onPressed: () => Navigator.of(context).pop((_plan, _expiry)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _BrandingDialog extends StatefulWidget {
  final TenantDetail detail;
  const _BrandingDialog({required this.detail});

  @override
  State<_BrandingDialog> createState() => _BrandingDialogState();
}

class _BrandingDialogState extends State<_BrandingDialog> {
  late final TextEditingController _appNameController;
  late final TextEditingController _logoController;
  late final TextEditingController _colorController;

  @override
  void initState() {
    super.initState();
    _appNameController = TextEditingController(text: widget.detail.appDisplayName ?? '');
    _logoController = TextEditingController(text: widget.detail.logoUrl ?? '');
    _colorController = TextEditingController(text: widget.detail.primaryColor ?? '');
  }

  @override
  void dispose() {
    _appNameController.dispose();
    _logoController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Whitelabel Branding'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(key: const Key('branding_app_name_field'), controller: _appNameController, decoration: const InputDecoration(labelText: 'App Display Name')),
            const SizedBox(height: 12),
            TextField(key: const Key('branding_logo_url_field'), controller: _logoController, decoration: const InputDecoration(labelText: 'Logo URL')),
            const SizedBox(height: 12),
            TextField(key: const Key('branding_color_field'), controller: _colorController, decoration: const InputDecoration(labelText: 'Primary Color (#RRGGBB)')),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('branding_dialog_submit'),
          onPressed: () => Navigator.of(context).pop({
            'app_display_name': _appNameController.text.trim(),
            'logo_url': _logoController.text.trim(),
            'primary_color': _colorController.text.trim(),
          }),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
