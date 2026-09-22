import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/responsive.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'platform_api.dart';
import 'platform_api_client.dart';

/// Every audit entry across every tenant, newest first — the platform
/// admin's cross-tenant view of platformadmin.Service.ListAuditLogsAllTenants.
/// A per-tenant Owner's own audit log screen shows only their own rows
/// (RLS-scoped); this is the one screen that can legitimately see all of
/// them at once.
class PlatformAuditLogScreen extends StatefulWidget {
  const PlatformAuditLogScreen({super.key});

  @override
  State<PlatformAuditLogScreen> createState() => _PlatformAuditLogScreenState();
}

class _PlatformAuditLogScreenState extends State<PlatformAuditLogScreen> {
  List<PlatformAuditLogEntry> _entries = [];
  bool _loading = true;
  String? _error;

  static final _dateFormat = DateFormat('dd MMM yyyy, h:mm a');

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
      final entries = await api.listAuditLogs(limit: 100);
      if (!mounted) return;
      setState(() {
        _entries = entries;
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

  IconData _actionIcon(String actionCode) {
    final code = actionCode.toUpperCase();
    if (code.contains('SUSPEND')) return Icons.pause_circle_outline_rounded;
    if (code.contains('CREATE') || code.contains('REGISTER')) return Icons.add_circle_outline_rounded;
    if (code.contains('DELETE') || code.contains('REVOKE')) return Icons.remove_circle_outline_rounded;
    if (code.contains('DEVICE')) return Icons.smartphone_rounded;
    if (code.contains('UPDATE') || code.contains('EDIT')) return Icons.edit_outlined;
    return Icons.circle_notifications_outlined;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: AppTypography.body),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ResponsiveBreakpoints.maxContentWidth),
          child: _entries.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    SizedBox(height: 96),
                    Icon(Icons.history_rounded, size: 48, color: AppColors.textTertiary),
                    SizedBox(height: 12),
                    Center(child: Text('No audit entries yet', style: AppTypography.bodySecondary)),
                  ],
                )
              : ListView.builder(
                  padding: EdgeInsets.all(context.responsive(mobile: 16.0, desktop: 24.0)),
                  itemCount: _entries.length,
                  itemBuilder: (context, index) {
                    final e = _entries[index];
                    return Container(
                      key: Key('platform_audit_entry_${e.id}'),
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(16),
                      decoration: AppDecorations.card(),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(color: AppColors.secondaryContainer, borderRadius: AppDecorations.borderRadiusSm),
                            child: Icon(_actionIcon(e.actionCode), color: AppColors.secondary, size: 18),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(child: Text(e.actionCode, style: AppTypography.title.copyWith(fontSize: 14))),
                                    Text(_dateFormat.format(e.createdAt.toLocal()), style: AppTypography.caption),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${e.tenantName ?? 'Platform'} · ${e.entityType}${e.actorName != null ? ' · by ${e.actorName}' : ''}',
                                  style: AppTypography.bodySecondary,
                                ),
                                if (e.reason != null) ...[
                                  const SizedBox(height: 4),
                                  Text(e.reason!, style: AppTypography.bodySecondary.copyWith(fontStyle: FontStyle.italic)),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
