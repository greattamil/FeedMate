import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'platform_api.dart';
import 'platform_api_client.dart';

/// The Devices tab of [TenantDetailScreen]: browse a tenant's registered
/// devices, revoke a lost/stolen one, and — the whole reason this tab
/// exists — generate a pairing code on the tenant's behalf when they
/// forgot to generate their own, instead of the platform owner
/// hand-writing a pairing-code row in production.
class TenantDevicesTab extends StatefulWidget {
  final String tenantId;
  const TenantDevicesTab({super.key, required this.tenantId});

  @override
  State<TenantDevicesTab> createState() => _TenantDevicesTabState();
}

class _TenantDevicesTabState extends State<TenantDevicesTab> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  List<PlatformDevice> _devices = [];
  bool _loading = false;
  String? _error;

  static final _dateFormat = DateFormat('dd MMM yyyy, h:mm a');

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(query));
  }

  Future<void> _search(String query) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      final result = await api.listTenantDevices(widget.tenantId, query: query);
      if (!mounted) return;
      setState(() {
        _devices = result.devices;
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

  Future<void> _revoke(PlatformDevice device) async {
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke Device?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${device.displayName} will be signed out immediately and can never use its current session again.'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('platform_revoke_reason_field'),
              controller: reasonController,
              decoration: const InputDecoration(labelText: 'Reason (optional)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('platform_revoke_confirm_button'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      await api.revokeTenantDevice(widget.tenantId, device.id, reason: reasonController.text.trim());
      if (!mounted) return;
      await _search(_searchController.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${device.displayName} has been revoked')));
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _generatePairingCode() async {
    await showDialog<void>(
      context: context,
      builder: (context) => _PairingCodeDialog(tenantId: widget.tenantId),
    );
    // Revoking/generating doesn't change the device list itself (a new
    // pairing code isn't a device row until someone redeems it), but a
    // refresh is cheap and keeps the list honest if the dialog's close
    // happened to race a redemption.
    await _search(_searchController.text);
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'ACTIVE':
        return AppColors.success;
      case 'REVOKED':
        return AppColors.danger;
      default:
        return AppColors.warning;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        key: const Key('platform_generate_pairing_code_fab'),
        onPressed: _generatePairingCode,
        icon: const Icon(Icons.add_link_rounded),
        label: const Text('Generate Pairing Code'),
        backgroundColor: AppColors.secondary,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              key: const Key('platform_device_search_field'),
              controller: _searchController,
              decoration: InputDecoration(
                labelText: 'Search by device name',
                prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          _onQueryChanged('');
                        },
                      )
                    : null,
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          if (_loading) const LinearProgressIndicator(color: AppColors.primary, minHeight: 2),
          if (_error != null)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppColors.dangerContainer, borderRadius: AppDecorations.borderRadiusSm),
              child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer)),
            ),
          Expanded(
            child: _devices.isEmpty && !_loading
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.devices_other_outlined, size: 56, color: Color(0xFF94A3B8)),
                        SizedBox(height: 12),
                        Text('No devices found', style: AppTypography.bodySecondary),
                      ],
                    ),
                  )
                : ListView.builder(
                    key: const Key('platform_device_results_list'),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                    itemCount: _devices.length,
                    itemBuilder: (context, index) {
                      final d = _devices[index];
                      final canRevoke = d.status == 'ACTIVE' || d.status == 'PENDING';
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: AppDecorations.card(color: AppColors.surface),
                        child: ListTile(
                          key: Key('platform_device_item_${d.id}'),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          leading: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: AppColors.surfaceSecondary,
                              borderRadius: AppDecorations.borderRadiusMd,
                              border: Border.all(color: AppColors.border.withValues(alpha: 0.5)),
                            ),
                            child: const Center(child: Icon(Icons.smartphone_rounded, color: AppColors.primary, size: 22)),
                          ),
                          title: Row(
                            children: [
                              Expanded(child: Text(d.displayName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _statusColor(d.status).withValues(alpha: 0.12),
                                  borderRadius: AppDecorations.borderRadiusSm,
                                ),
                                child: Text(
                                  d.status,
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _statusColor(d.status)),
                                ),
                              ),
                            ],
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              [
                                d.platform,
                                if (d.lastSeenAt != null) 'Last seen ${_dateFormat.format(d.lastSeenAt!.toLocal())}',
                              ].join(' · '),
                              style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
                            ),
                          ),
                          trailing: canRevoke
                              ? IconButton(
                                  key: Key('platform_revoke_device_${d.id}'),
                                  icon: const Icon(Icons.block_rounded, color: AppColors.danger),
                                  tooltip: 'Revoke',
                                  onPressed: () => _revoke(d),
                                )
                              : null,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Generates and displays a tenant pairing code: large monospace text, a
/// live countdown to its exact 10-minute expiry, and a copy button — the
/// platform admin reads this over the phone to the tenant.
class _PairingCodeDialog extends StatefulWidget {
  final String tenantId;
  const _PairingCodeDialog({required this.tenantId});

  @override
  State<_PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends State<_PairingCodeDialog> {
  String? _code;
  DateTime? _expiresAt;
  Duration _remaining = Duration.zero;
  Timer? _ticker;
  bool _generating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _generate());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      final result = await api.generateTenantPairingCode(widget.tenantId);
      if (!mounted) return;
      setState(() {
        _code = result.code;
        _expiresAt = result.expiresAt;
        _generating = false;
      });
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      _tick();
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _generating = false;
      });
    }
  }

  void _tick() {
    final expiresAt = _expiresAt;
    if (expiresAt == null) return;
    final remaining = expiresAt.difference(DateTime.now());
    if (!mounted) return;
    setState(() => _remaining = remaining.isNegative ? Duration.zero : remaining);
    if (remaining.isNegative) {
      _ticker?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final expired = _expiresAt != null && _remaining == Duration.zero;
    return AlertDialog(
      key: const Key('platform_pairing_code_dialog'),
      title: const Text('Device Pairing Code'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Read this code to the tenant so they can register a new device.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 20),
            if (_generating)
              const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator(color: AppColors.primary)),
            if (_error != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppColors.dangerContainer, borderRadius: AppDecorations.borderRadiusSm),
                child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer)),
              ),
            if (_code != null) ...[
              InkWell(
                key: const Key('platform_pairing_code_copy'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _code!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Code copied to clipboard'), duration: Duration(seconds: 1)),
                  );
                },
                borderRadius: AppDecorations.borderRadiusMd,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  decoration: BoxDecoration(
                    color: expired ? AppColors.dangerContainer : AppColors.successContainer,
                    border: Border.all(color: expired ? AppColors.dangerLight : AppColors.success, width: 1.5),
                    borderRadius: AppDecorations.borderRadiusMd,
                  ),
                  child: Column(
                    children: [
                      Text(
                        _code!,
                        key: const Key('platform_pairing_code_text'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 6,
                          fontFamily: 'monospace',
                          color: expired ? AppColors.danger : AppColors.success,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Tap to copy',
                        style: TextStyle(fontSize: 11, color: (expired ? AppColors.danger : AppColors.success).withValues(alpha: 0.7)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                key: const Key('platform_pairing_code_expiry'),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: expired ? AppColors.dangerContainer : AppColors.surfaceSecondary,
                  borderRadius: AppDecorations.borderRadiusFull,
                ),
                child: Text(
                  expired
                      ? 'Expired — generate a new code'
                      : 'Expires in ${_remaining.inMinutes}:${(_remaining.inSeconds % 60).toString().padLeft(2, '0')} '
                          '(at ${_expiresAt!.toLocal().hour.toString().padLeft(2, '0')}:${_expiresAt!.toLocal().minute.toString().padLeft(2, '0')})',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: expired ? AppColors.danger : AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (expired)
          TextButton(
            key: const Key('platform_pairing_code_regenerate'),
            onPressed: _generating ? null : _generate,
            child: const Text('Generate New Code'),
          ),
        FilledButton(
          key: const Key('platform_pairing_code_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
