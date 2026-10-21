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
import 'platform_log_common.dart';

/// Every audit entry across every tenant, newest first — the platform
/// admin's cross-tenant view of platformadmin.Service.ListAuditLogsAllTenants.
/// A per-tenant Owner's own audit log screen shows only their own rows
/// (RLS-scoped); this is the one screen that can legitimately see all of
/// them at once. Filterable by action code, entity type, tenant, date
/// range and free text, paginated, with a full before/after detail view
/// per entry.
class PlatformAuditLogScreen extends StatefulWidget {
  const PlatformAuditLogScreen({super.key});

  @override
  State<PlatformAuditLogScreen> createState() => _PlatformAuditLogScreenState();
}

class _PlatformAuditLogScreenState extends State<PlatformAuditLogScreen> {
  static const _pageSize = 20;

  List<PlatformAuditLogEntry> _entries = [];
  int _total = 0;
  int _offset = 0;
  bool _loading = true;
  String? _error;

  final _actionCodeController = TextEditingController();
  final _entityTypeController = TextEditingController();
  final _tenantController = TextEditingController();
  final _searchController = TextEditingController();
  DateTime? _from;
  DateTime? _to;

  static final _dateFormat = DateFormat('dd MMM yyyy, h:mm a');
  static final _dateOnlyFormat = DateFormat('dd MMM yyyy');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _actionCodeController.dispose();
    _entityTypeController.dispose();
    _tenantController.dispose();
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
      final result = await api.listAuditLogs(
        limit: _pageSize,
        offset: _offset,
        actionCode: _actionCodeController.text.trim().isEmpty ? null : _actionCodeController.text.trim(),
        entityType: _entityTypeController.text.trim().isEmpty ? null : _entityTypeController.text.trim(),
        tenantId: _looksLikeUuid(_tenantController.text.trim()) ? _tenantController.text.trim() : null,
        from: _from,
        to: _to,
        q: _combinedSearch(),
      );
      if (!mounted) return;
      setState(() {
        _entries = result.entries;
        _total = result.total;
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

  // `tenant` free text that isn't a UUID is treated as a tenant-name
  // search term, folded into `q` (which the server also matches against
  // tenant name) rather than sent as `tenant_id`.
  String? _combinedSearch() {
    final parts = <String>[];
    if (_searchController.text.trim().isNotEmpty) parts.add(_searchController.text.trim());
    final tenantText = _tenantController.text.trim();
    if (tenantText.isNotEmpty && !_looksLikeUuid(tenantText)) parts.add(tenantText);
    if (parts.isEmpty) return null;
    return parts.join(' ');
  }

  bool _looksLikeUuid(String s) => RegExp(r'^[0-9a-fA-F-]{32,36}$').hasMatch(s);

  Future<void> _applyFilters() async {
    _offset = 0;
    await _load();
  }

  Future<void> _clearFilters() async {
    _actionCodeController.clear();
    _entityTypeController.clear();
    _tenantController.clear();
    _searchController.clear();
    setState(() {
      _from = null;
      _to = null;
      _offset = 0;
    });
    await _load();
  }

  Future<void> _changePage(int newOffset) async {
    setState(() => _offset = newOffset);
    await _load();
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (isFrom ? _from : _to) ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365 * 3)),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _from = picked;
      } else {
        _to = DateTime(picked.year, picked.month, picked.day, 23, 59, 59);
      }
    });
  }

  void _openDetail(PlatformAuditLogEntry entry) {
    Navigator.of(context).push(MaterialPageRoute(builder: (context) => _AuditLogDetailScreen(entry: entry)));
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: ResponsiveBreakpoints.maxContentWidth),
        child: Column(
          children: [
            _filterBar(),
            if (_loading) const LinearProgressIndicator(color: AppColors.primary, minHeight: 2),
            Expanded(child: _body()),
            if (_total > 0) _paginationBar(),
          ],
        ),
      ),
    );
  }

  Widget _filterBar() {
    return Padding(
      padding: EdgeInsets.all(context.responsive(mobile: 12.0, desktop: 16.0)),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: AppDecorations.card(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                SizedBox(
                  width: 180,
                  child: TextField(
                    key: const Key('audit_log_filter_action_code'),
                    controller: _actionCodeController,
                    decoration: const InputDecoration(labelText: 'Action code', isDense: true),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: TextField(
                    key: const Key('audit_log_filter_entity_type'),
                    controller: _entityTypeController,
                    decoration: const InputDecoration(labelText: 'Entity type', isDense: true),
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: TextField(
                    key: const Key('audit_log_filter_tenant'),
                    controller: _tenantController,
                    decoration: const InputDecoration(labelText: 'Tenant (ID or name)', isDense: true),
                  ),
                ),
                SizedBox(
                  width: 200,
                  child: TextField(
                    key: const Key('audit_log_filter_search'),
                    controller: _searchController,
                    decoration: const InputDecoration(labelText: 'Search reason/actor', isDense: true),
                  ),
                ),
                InkWell(
                  key: const Key('audit_log_filter_from_date'),
                  onTap: () => _pickDate(isFrom: true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: AppDecorations.borderRadiusSm),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.calendar_today_rounded, size: 14, color: AppColors.textTertiary),
                      const SizedBox(width: 6),
                      Text(_from == null ? 'From' : _dateOnlyFormat.format(_from!), style: AppTypography.bodySecondary),
                    ]),
                  ),
                ),
                InkWell(
                  key: const Key('audit_log_filter_to_date'),
                  onTap: () => _pickDate(isFrom: false),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: AppDecorations.borderRadiusSm),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.calendar_today_rounded, size: 14, color: AppColors.textTertiary),
                      const SizedBox(width: 6),
                      Text(_to == null ? 'To' : _dateOnlyFormat.format(_to!), style: AppTypography.bodySecondary),
                    ]),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(key: const Key('audit_log_clear_filters'), onPressed: _clearFilters, child: const Text('Clear')),
                const SizedBox(width: 8),
                FilledButton(key: const Key('audit_log_apply_filters'), onPressed: _applyFilters, child: const Text('Apply Filters')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
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
    if (_entries.isEmpty && !_loading) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 64),
          Icon(Icons.history_rounded, size: 48, color: AppColors.textTertiary),
          SizedBox(height: 12),
          Center(child: Text('No audit entries match these filters', style: AppTypography.bodySecondary)),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        key: const Key('audit_log_list'),
        padding: EdgeInsets.all(context.responsive(mobile: 16.0, desktop: 24.0)),
        itemCount: _entries.length,
        itemBuilder: (context, index) {
          final e = _entries[index];
          final actionColor = PlatformLogCommon.actionColor(e.actionCode);
          return InkWell(
            key: Key('platform_audit_entry_${e.id}'),
            onTap: () => _openDetail(e),
            borderRadius: AppDecorations.borderRadiusMd,
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(16),
              decoration: AppDecorations.card(),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                    decoration: BoxDecoration(color: actionColor.withValues(alpha: 0.12), borderRadius: AppDecorations.borderRadiusSm),
                    child: Text(
                      PlatformLogCommon.formatActionCode(e.actionCode),
                      style: AppTypography.caption.copyWith(color: actionColor, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(child: Text(e.entityType, style: AppTypography.title.copyWith(fontSize: 14))),
                            Text(_dateFormat.format(e.createdAt.toLocal()), style: AppTypography.caption),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${e.tenantName ?? 'Platform-level'} · by ${e.displayActor}',
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
            ),
          );
        },
      ),
    );
  }

  Widget _paginationBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text('${_offset + 1}-${(_offset + _entries.length).clamp(0, _total)} of $_total', style: AppTypography.caption),
          IconButton(
            key: const Key('audit_log_page_prev'),
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: _offset > 0 ? () => _changePage((_offset - _pageSize).clamp(0, _total)) : null,
          ),
          IconButton(
            key: const Key('audit_log_page_next'),
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: _offset + _pageSize < _total ? () => _changePage(_offset + _pageSize) : null,
          ),
        ],
      ),
    );
  }
}

/// Full-screen detail view for a single audit-log entry: actor identity
/// (tenant user + device, or platform admin), request provenance, reason,
/// and before/after state shown as two sequential pretty-printed JSON
/// blocks (not a diff) — "Before" is omitted entirely when absent, which is
/// the common case since most actions are creates.
class _AuditLogDetailScreen extends StatelessWidget {
  final PlatformAuditLogEntry entry;
  const _AuditLogDetailScreen({required this.entry});

  static final _dateFormat = DateFormat('dd MMM yyyy, h:mm:ss a');

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final actionColor = PlatformLogCommon.actionColor(e.actionCode);
    return Scaffold(
      key: const Key('audit_log_detail_screen'),
      appBar: AppBar(title: Text(PlatformLogCommon.formatActionCode(e.actionCode))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: actionColor.withValues(alpha: 0.12), borderRadius: AppDecorations.borderRadiusFull),
                  child: Text(e.actionCode, style: AppTypography.caption.copyWith(color: actionColor, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(_dateFormat.format(e.createdAt.toLocal()), style: AppTypography.bodySecondary)),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: AppDecorations.card(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PlatformLogCommon.kv('Entity type', e.entityType),
                  if (e.entityId != null) PlatformLogCommon.kvCopyable(context, 'Entity ID', e.entityId!, key: const Key('audit_log_detail_copy_entity_id')),
                  PlatformLogCommon.kv('Tenant', e.tenantName ?? 'Platform-level'),
                  PlatformLogCommon.kv('Actor', e.displayActor),
                  if (e.actorDeviceId != null) PlatformLogCommon.kv('Actor device ID', e.actorDeviceId!),
                  if (e.reason != null) PlatformLogCommon.kv('Reason', e.reason!),
                  if (e.requestId != null)
                    PlatformLogCommon.kvCopyable(context, 'Request ID', e.requestId!, key: const Key('audit_log_detail_copy_request_id')),
                  if (e.ipAddress != null) PlatformLogCommon.kv('IP address', e.ipAddress!),
                  if (e.userAgent != null) PlatformLogCommon.kv('User agent', e.userAgent!),
                ],
              ),
            ),
            if (e.beforeJson != null) ...[
              const SizedBox(height: 16),
              PlatformLogCommon.monoBlock(
                key: const Key('audit_log_detail_before_json'),
                label: 'Before',
                text: PlatformLogCommon.prettyJson(e.beforeJson!),
              ),
            ],
            if (e.afterJson != null) ...[
              const SizedBox(height: 16),
              PlatformLogCommon.monoBlock(
                key: const Key('audit_log_detail_after_json'),
                label: 'After',
                text: PlatformLogCommon.prettyJson(e.afterJson!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
