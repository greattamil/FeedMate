import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/csv_export.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'grn_history_api.dart';
import 'grn_detail_screen.dart';
import '../../core/number_format.dart';

/// Browse past goods receipts (PRD 7.6) — the GRN transaction report.
/// Read-only — a posted GRN is never edited or deleted from here. Filters
/// by date range and GRN no./supplier, shows each receipt's total received
/// value (not just its identity), a running summary banner, and exports to
/// CSV — the same reporting bar every other report in this app (Sales
/// Summary, Stock on Hand, Customer Balances, EOD History) already holds
/// itself to.
class GrnHistoryScreen extends StatefulWidget {
  const GrnHistoryScreen({super.key});

  @override
  State<GrnHistoryScreen> createState() => _GrnHistoryScreenState();
}

class _GrnHistoryScreenState extends State<GrnHistoryScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<GRNSummary> _results = [];
  GRNListSummary? _summary;
  bool _loading = false;
  String? _error;
  DateTime? _dateFrom;
  DateTime? _dateTo;

  static final _dateFormat = DateFormat('dd MMM yyyy, h:mm a');
  static final _dateOnlyFormat = DateFormat('dd MMM yyyy');
  static final _fileDateFormat = DateFormat('yyyy-MM-dd');

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
      final api = GRNHistoryApi(context.read<ApiClient>());
      final page = await api.list(query: query, dateFrom: _dateFrom, dateTo: _dateTo);
      if (!mounted) return;
      setState(() {
        _results = page.grns;
        _summary = page.summary;
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

  Future<void> _pickDateRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: _dateFrom != null && _dateTo != null ? DateTimeRange(start: _dateFrom!, end: _dateTo!) : null,
    );
    if (range == null) return;
    setState(() {
      _dateFrom = range.start;
      _dateTo = range.end;
    });
    await _search(_controller.text);
  }

  void _clearDateRange() {
    setState(() {
      _dateFrom = null;
      _dateTo = null;
    });
    _search(_controller.text);
  }

  Future<void> _export() async {
    await shareCsv(
      fileName: 'grn-history-${_fileDateFormat.format(DateTime.now())}.csv',
      headers: const ['GRN No.', 'Supplier', 'Status', 'Lines', 'Total Value', 'Posted At'],
      rows: [
        for (final g in _results)
          [
            g.grnNumber,
            g.supplierName,
            g.status,
            g.lineCount.toString(),
            g.totalValue.toStringAsFixed(2),
            g.postedAt != null ? _dateFormat.format(g.postedAt!.toLocal()) : '',
          ],
      ],
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('GRN History', style: AppTypography.headline),
        actions: [
          IconButton(
            key: const Key('grn_history_export_button'),
            tooltip: 'Export CSV',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: _results.isEmpty ? null : _export,
          ),
        ],
      ),
      body: Column(
        children: [
          // Teal Hero Banner — now a real summary, not just a count.
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              gradient: AppColors.gradientTealCyan,
              borderRadius: AppDecorations.borderRadiusLg,
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.25),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                      ),
                      child: const Icon(Icons.history_rounded, color: Colors.white, size: 28),
                    ),
                    const SizedBox(width: 16),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'GRN Intake Register',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Chronological goods receipt history & receiving logs',
                            style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _heroStat(
                        key: 'grn_history_count_stat',
                        label: 'Receipts',
                        value: '${summary?.grnCount ?? _results.length}',
                      ),
                    ),
                    Container(width: 1, height: 32, color: Colors.white.withValues(alpha: 0.25)),
                    Expanded(
                      child: _heroStat(
                        key: 'grn_history_value_stat',
                        label: 'Total received value',
                        value: money(summary?.totalValue),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Search Field + Date Range
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                TextField(
                  key: const Key('grn_history_search_field'),
                  controller: _controller,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: AppColors.surface,
                    labelText: 'Search by GRN no. or supplier name',
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
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: AppDecorations.borderRadiusMd,
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: AppDecorations.borderRadiusMd,
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: AppDecorations.borderRadiusMd,
                      borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
                    ),
                  ),
                  onChanged: _onQueryChanged,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        key: const Key('grn_history_date_range_tile'),
                        onTap: _pickDateRange,
                        borderRadius: AppDecorations.borderRadiusMd,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: AppDecorations.borderRadiusMd,
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.date_range_rounded, color: AppColors.primary, size: 18),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _dateFrom != null && _dateTo != null
                                      ? '${_dateOnlyFormat.format(_dateFrom!)} – ${_dateOnlyFormat.format(_dateTo!)}'
                                      : 'All dates',
                                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                ),
                              ),
                              const Icon(Icons.edit_calendar_rounded, size: 16, color: AppColors.primary),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_dateFrom != null) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        key: const Key('grn_history_clear_date_button'),
                        tooltip: 'Clear date filter',
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: _clearDateRange,
                      ),
                    ],
                  ],
                ),
              ],
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
            child: RefreshIndicator(
              onRefresh: () => _search(_controller.text),
              child: _results.isEmpty && !_loading
                  ? LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: constraints.maxHeight),
                          child: const Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.move_to_inbox_outlined, size: 56, color: Color(0xFF94A3B8)),
                                SizedBox(height: 12),
                                Text('No GRNs found', style: AppTypography.bodySecondary),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      key: const Key('grn_history_results_list'),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final g = _results[index];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: AppDecorations.borderRadiusMd,
                            border: Border.all(color: AppColors.border),
                            boxShadow: AppDecorations.cardShadow,
                          ),
                          child: ListTile(
                            key: Key('grn_history_item_${g.id}'),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            leading: Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                gradient: AppColors.gradientTealCyan,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Center(
                                child: Icon(Icons.receipt_long_rounded, color: Colors.white, size: 20),
                              ),
                            ),
                            title: Row(
                              children: [
                                Text(g.grnNumber, style: AppTypography.title.copyWith(fontSize: 15, fontWeight: FontWeight.w700)),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppColors.primaryContainer,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    g.status,
                                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppColors.primary),
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Text(
                              [
                                g.supplierName,
                                '${g.lineCount} item${g.lineCount == 1 ? '' : 's'}',
                                if (g.postedAt != null) _dateFormat.format(g.postedAt!.toLocal()),
                              ].join(' · '),
                              style: AppTypography.caption,
                            ),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  money(g.totalValue),
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: AppColors.primary),
                                ),
                                const Icon(Icons.arrow_forward_ios_rounded, size: 12, color: AppColors.textSecondary),
                              ],
                            ),
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => GrnDetailScreen(grnId: g.id)),
                              );
                            },
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroStat({required String key, required String label, required String value}) {
    return Column(
      key: Key(key),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
