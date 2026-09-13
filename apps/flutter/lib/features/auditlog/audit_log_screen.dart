import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/csv_export.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'audit_log_api.dart';

/// Read-only explorer for the audit trail: explicit-reasoned overrides
/// (credit limit, tare threshold), EOD close/reopen, and other sensitive
/// actions across the system. There is no way to edit or delete an entry
/// from here or anywhere else in the app — that is the entire point of an
/// audit trail.
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key});

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<AuditLogEntry> _results = [];
  bool _loading = false;
  String? _error;

  static final _dateFormat = DateFormat('dd MMM yyyy, h:mm a');

  @override
  void initState() {
    super.initState();
    _search('');
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
      final api = AuditLogApi(context.read<ApiClient>());
      final results = await api.list(query: query);
      if (!mounted) return;
      setState(() {
        _results = results;
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
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    await shareCsv(
      fileName: 'audit-log-${DateFormat('yyyy-MM-dd').format(DateTime.now())}.csv',
      headers: const ['Date/Time', 'Action', 'Entity Type', 'Entity Id', 'Actor', 'Reason'],
      rows: [
        for (final e in _results)
          [
            _dateFormat.format(e.createdAt.toLocal()),
            e.actionCode,
            e.entityType,
            e.entityId ?? '',
            e.actorName ?? '',
            e.reason ?? '',
          ],
      ],
    );
  }

  void _showDetail(AuditLogEntry entry) {
    const encoder = JsonEncoder.withIndent('  ');
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry.actionCode),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Entity: ${entry.entityType}${entry.entityId != null ? " (${entry.entityId})" : ""}'),
              const SizedBox(height: 4),
              Text(_dateFormat.format(entry.createdAt.toLocal())),
              if (entry.actorName != null) ...[
                const SizedBox(height: 4),
                Text('By: ${entry.actorName}'),
              ],
              if (entry.reason != null) ...[
                const SizedBox(height: 8),
                Text('Reason: ${entry.reason}', style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
              if (entry.after != null) ...[
                const SizedBox(height: 12),
                const Text('Details', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                SelectableText(encoder.convert(entry.after), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Audit Log', style: AppTypography.headline),
        actions: [
          if (_results.isNotEmpty)
            IconButton(
              key: const Key('audit_log_export_csv_button'),
              onPressed: _export,
              icon: const Icon(Icons.ios_share_rounded),
              tooltip: 'Export CSV',
            ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            color: AppColors.surface,
            child: TextField(
              key: const Key('audit_log_search_field'),
              controller: _controller,
              decoration: InputDecoration(
                labelText: 'Search by action or entity type',
                prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () {
                          _controller.clear();
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
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.dangerContainer,
                borderRadius: AppDecorations.borderRadiusSm,
              ),
              child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer)),
            ),
          Expanded(
            child: _results.isEmpty && !_loading
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.history_rounded, size: 56, color: Color(0xFF94A3B8)),
                        SizedBox(height: 12),
                        Text('No audit entries found', style: AppTypography.bodySecondary),
                      ],
                    ),
                  )
                : ListView.builder(
                    key: const Key('audit_log_results_list'),
                    padding: const EdgeInsets.all(12),
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final e = _results[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: AppDecorations.borderRadiusMd,
                          border: Border.all(color: AppColors.border),
                          boxShadow: AppDecorations.cardShadow,
                        ),
                        child: ListTile(
                          key: Key('audit_log_item_${e.id}'),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          leading: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: AppColors.surfaceSecondary,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Center(
                              child: Icon(Icons.fact_check_outlined, color: AppColors.primary, size: 20),
                            ),
                          ),
                          title: Text(e.actionCode, style: AppTypography.title),
                          subtitle: Text(
                            [
                              e.entityType,
                              if (e.actorName != null) e.actorName!,
                              _dateFormat.format(e.createdAt.toLocal()),
                            ].join(' · '),
                            style: AppTypography.caption,
                          ),
                          trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.textSecondary),
                          onTap: () => _showDetail(e),
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
