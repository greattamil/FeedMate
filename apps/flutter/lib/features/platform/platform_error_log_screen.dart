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

/// Every error the API has returned, newest first, now with genuinely
/// complete debug-level detail for EVERY status code (not just 500s) —
/// httpapi.SetErrorSink captures the full request/response context on
/// every error response. Filterable by status code, method, date range and
/// free text, paginated, with a full detail view per entry.
class PlatformErrorLogScreen extends StatefulWidget {
  const PlatformErrorLogScreen({super.key});

  @override
  State<PlatformErrorLogScreen> createState() => _PlatformErrorLogScreenState();
}

class _PlatformErrorLogScreenState extends State<PlatformErrorLogScreen> {
  static const _pageSize = 20;
  static const _methods = ['ANY', 'GET', 'POST', 'PUT', 'PATCH', 'DELETE'];

  List<PlatformErrorLogEntry> _entries = [];
  int _total = 0;
  int _offset = 0;
  bool _loading = true;
  String? _error;

  final _statusCodeController = TextEditingController();
  final _searchController = TextEditingController();
  String _method = 'ANY';
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
    _statusCodeController.dispose();
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
      final result = await api.listErrorLogs(
        limit: _pageSize,
        offset: _offset,
        statusCode: int.tryParse(_statusCodeController.text.trim()),
        method: _method == 'ANY' ? null : _method,
        from: _from,
        to: _to,
        q: _searchController.text.trim().isEmpty ? null : _searchController.text.trim(),
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

  Future<void> _applyFilters() async {
    _offset = 0;
    await _load();
  }

  Future<void> _clearFilters() async {
    _statusCodeController.clear();
    _searchController.clear();
    setState(() {
      _method = 'ANY';
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
        // Include the whole end day.
        _to = DateTime(picked.year, picked.month, picked.day, 23, 59, 59);
      }
    });
  }

  void _openDetail(PlatformErrorLogEntry entry) {
    Navigator.of(context).push(MaterialPageRoute(builder: (context) => _ErrorLogDetailScreen(entry: entry)));
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
                  width: 110,
                  child: TextField(
                    key: const Key('error_log_filter_status_code'),
                    controller: _statusCodeController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Status code', isDense: true),
                  ),
                ),
                SizedBox(
                  width: 140,
                  child: DropdownButtonFormField<String>(
                    key: const Key('error_log_filter_method'),
                    initialValue: _method,
                    decoration: const InputDecoration(labelText: 'Method', isDense: true),
                    items: _methods.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                    onChanged: (v) => setState(() => _method = v ?? 'ANY'),
                  ),
                ),
                SizedBox(
                  width: 200,
                  child: TextField(
                    key: const Key('error_log_filter_search'),
                    controller: _searchController,
                    decoration: const InputDecoration(labelText: 'Search path/message', isDense: true),
                  ),
                ),
                InkWell(
                  key: const Key('error_log_filter_from_date'),
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
                  key: const Key('error_log_filter_to_date'),
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
                TextButton(key: const Key('error_log_clear_filters'), onPressed: _clearFilters, child: const Text('Clear')),
                const SizedBox(width: 8),
                FilledButton(key: const Key('error_log_apply_filters'), onPressed: _applyFilters, child: const Text('Apply Filters')),
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
          Icon(Icons.verified_outlined, size: 48, color: AppColors.success),
          SizedBox(height: 12),
          Center(child: Text('No errors match these filters', style: AppTypography.bodySecondary)),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        key: const Key('error_log_list'),
        padding: EdgeInsets.all(context.responsive(mobile: 16.0, desktop: 24.0)),
        itemCount: _entries.length,
        itemBuilder: (context, index) {
          final e = _entries[index];
          final statusColor = PlatformLogCommon.statusColor(e.statusCode);
          final headline = e.method != null && e.path != null ? '${e.method} ${e.path}' : e.message;
          return InkWell(
            key: Key('platform_error_entry_${e.id}'),
            onTap: () => _openDetail(e),
            borderRadius: AppDecorations.borderRadiusMd,
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(16),
              decoration: AppDecorations.card(border: Border.all(color: statusColor.withValues(alpha: 0.3))),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                            decoration: BoxDecoration(
                              color: PlatformLogCommon.statusContainerColor(e.statusCode),
                              borderRadius: AppDecorations.borderRadiusFull,
                            ),
                            child: Text(
                              '${e.statusCode}',
                              style: AppTypography.caption.copyWith(color: PlatformLogCommon.onStatusContainer(e.statusCode), fontWeight: FontWeight.bold),
                            ),
                          ),
                          if (e.stackTrace != null) ...[
                            const SizedBox(width: 8),
                            Container(
                              key: Key('platform_error_panic_badge_${e.id}'),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(color: AppColors.dangerContainer, borderRadius: AppDecorations.borderRadiusFull),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                const Icon(Icons.warning_amber_rounded, size: 12, color: AppColors.danger),
                                const SizedBox(width: 3),
                                Text('PANIC', style: AppTypography.caption.copyWith(color: AppColors.danger, fontWeight: FontWeight.bold)),
                              ]),
                            ),
                          ],
                        ],
                      ),
                      Text(_dateFormat.format(e.createdAt.toLocal()), style: AppTypography.caption),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(headline, style: AppTypography.body.copyWith(fontWeight: FontWeight.w600)),
                  if (e.method != null && e.path != null) ...[
                    const SizedBox(height: 4),
                    Text(e.message, style: AppTypography.bodySecondary, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                  if (e.code != null) ...[
                    const SizedBox(height: 6),
                    Text(e.code!, style: AppTypography.caption.copyWith(color: AppColors.textTertiary)),
                  ],
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
            key: const Key('error_log_page_prev'),
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: _offset > 0 ? () => _changePage((_offset - _pageSize).clamp(0, _total)) : null,
          ),
          IconButton(
            key: const Key('error_log_page_next'),
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: _offset + _pageSize < _total ? () => _changePage(_offset + _pageSize) : null,
          ),
        ],
      ),
    );
  }
}

/// Full-screen detail view for a single error-log entry — there's enough
/// content here (request body, headers-ish metadata, a potentially long
/// stack trace) that a dialog would be cramped.
class _ErrorLogDetailScreen extends StatelessWidget {
  final PlatformErrorLogEntry entry;
  const _ErrorLogDetailScreen({required this.entry});

  static final _dateFormat = DateFormat('dd MMM yyyy, h:mm:ss a');

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final statusColor = PlatformLogCommon.statusColor(e.statusCode);
    return Scaffold(
      key: const Key('error_log_detail_screen'),
      appBar: AppBar(title: Text('Error · ${e.statusCode}')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: PlatformLogCommon.statusContainerColor(e.statusCode), borderRadius: AppDecorations.borderRadiusFull),
                  child: Text('${e.statusCode}', style: AppTypography.body.copyWith(color: PlatformLogCommon.onStatusContainer(e.statusCode), fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(_dateFormat.format(e.createdAt.toLocal()), style: AppTypography.bodySecondary)),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: AppDecorations.card(border: Border.all(color: statusColor.withValues(alpha: 0.3))),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.message, style: AppTypography.title),
                  const SizedBox(height: 12),
                  if (e.code != null) PlatformLogCommon.kv('Code', e.code!),
                  if (e.method != null) PlatformLogCommon.kv('Method', e.method!),
                  if (e.path != null) PlatformLogCommon.kv('Path', e.path!),
                  if (e.queryParams != null) PlatformLogCommon.kv('Query', e.queryParams!),
                  if (e.requestId != null)
                    PlatformLogCommon.kvCopyable(context, 'Request ID', e.requestId!, key: const Key('error_log_detail_copy_request_id')),
                  if (e.ipAddress != null) PlatformLogCommon.kv('IP address', e.ipAddress!),
                  if (e.userAgent != null) PlatformLogCommon.kv('User agent', e.userAgent!),
                  if (e.tenantId != null) PlatformLogCommon.kv('Tenant ID', e.tenantId!),
                  if (e.actorUserId != null) PlatformLogCommon.kv('Actor (user) ID', e.actorUserId!),
                  if (e.actorPlatformAdminId != null) PlatformLogCommon.kv('Actor (platform admin) ID', e.actorPlatformAdminId!),
                ],
              ),
            ),
            if (e.requestBody != null) ...[
              const SizedBox(height: 16),
              PlatformLogCommon.monoBlock(
                key: const Key('error_log_detail_request_body'),
                label: 'Request body',
                text: PlatformLogCommon.prettyJson(e.requestBody!),
              ),
            ],
            if (e.stackTrace != null) ...[
              const SizedBox(height: 16),
              PlatformLogCommon.monoBlock(
                key: const Key('error_log_detail_stack_trace'),
                label: 'Stack trace',
                text: e.stackTrace!,
                maxLines: 24,
                onCopy: () => PlatformLogCommon.copyToClipboard(context, e.stackTrace!, 'Stack trace'),
                copyButtonKey: const Key('error_log_detail_copy_stack_trace'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
