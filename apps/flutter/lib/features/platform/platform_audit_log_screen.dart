import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: Colors.white));
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.white)));
    if (_entries.isEmpty) return const Center(child: Text('No audit entries yet', style: TextStyle(color: Color(0xFF94A3B8))));

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _entries.length,
        itemBuilder: (context, index) {
          final e = _entries[index];
          return Container(
            key: Key('platform_audit_entry_${e.id}'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(12)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text(e.actionCode, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13))),
                    Text(_dateFormat.format(e.createdAt.toLocal()), style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${e.tenantName ?? 'Platform'} · ${e.entityType}${e.actorName != null ? ' · by ${e.actorName}' : ''}',
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                ),
                if (e.reason != null) ...[
                  const SizedBox(height: 4),
                  Text(e.reason!, style: const TextStyle(color: Colors.white70, fontSize: 12, fontStyle: FontStyle.italic)),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
