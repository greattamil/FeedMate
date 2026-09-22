import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
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
        title: Text(status == 'ACTIVE' ? 'Reactivate Tenant?' : 'Suspend Tenant?'),
        content: Text(
          status == 'ACTIVE'
              ? 'This tenant will be able to log in and use the app again immediately.'
              : 'This tenant will be signed out of new logins immediately — existing sessions stop working on their next refresh.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('tenant_status_confirm'),
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

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: Text(detail?.legalName ?? 'Tenant', style: const TextStyle(color: Colors.white)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white)))
              : detail == null
                  ? const SizedBox.shrink()
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _card(
                          title: 'Status',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Current: ${detail.status}', key: const Key('tenant_detail_status'), style: const TextStyle(color: Colors.white)),
                              const SizedBox(height: 10),
                              Row(children: [
                                if (detail.status != 'ACTIVE')
                                  FilledButton(
                                    key: const Key('tenant_reactivate_button'),
                                    onPressed: () => _changeStatus('ACTIVE'),
                                    child: const Text('Reactivate'),
                                  ),
                                if (detail.status == 'ACTIVE')
                                  FilledButton(
                                    key: const Key('tenant_suspend_button'),
                                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFFF59E0B)),
                                    onPressed: () => _changeStatus('SUSPENDED'),
                                    child: const Text('Suspend'),
                                  ),
                              ]),
                            ],
                          ),
                        ),
                        _card(
                          title: 'Plan & Billing',
                          trailing: IconButton(key: const Key('tenant_edit_plan_button'), onPressed: _editPlan, icon: const Icon(Icons.edit_outlined, color: Colors.white70)),
                          child: Text(
                            'Plan: ${detail.planCode}${detail.planExpiresAt != null ? ' · Expires ${detail.planExpiresAt!.toLocal().toString().split(' ').first}' : ''}',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        _card(
                          title: 'Whitelabel Branding',
                          trailing: IconButton(key: const Key('tenant_edit_branding_button'), onPressed: _editBranding, icon: const Icon(Icons.edit_outlined, color: Colors.white70)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('App name: ${detail.appDisplayName ?? '(default)'}', style: const TextStyle(color: Colors.white)),
                              Text('Logo URL: ${detail.logoUrl ?? '(none)'}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                              Text('Primary color: ${detail.primaryColor ?? '(default)'}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                            ],
                          ),
                        ),
                        _card(
                          title: 'Feature Flags & Modules',
                          child: Column(
                            children: _knownFeatureCodes.map((code) {
                              final enabled = detail.features[code] ?? false;
                              return SwitchListTile(
                                key: Key('tenant_feature_switch_$code'),
                                contentPadding: EdgeInsets.zero,
                                title: Text(code, style: const TextStyle(color: Colors.white, fontSize: 13)),
                                value: enabled,
                                onChanged: (v) => _toggleFeature(code, v),
                              );
                            }).toList(),
                          ),
                        ),
                        _card(
                          title: 'Usage',
                          child: Text('${detail.userCount} staff user${detail.userCount == 1 ? '' : 's'}', style: const TextStyle(color: Colors.white)),
                        ),
                      ],
                    ),
    );
  }

  Widget _card({required String title, required Widget child, Widget? trailing}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 10),
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
