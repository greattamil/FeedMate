import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import '../pos/pos_api.dart';
import 'stock_count_api.dart';
import 'stock_count_screen.dart';

/// Browse past and in-progress stock counts, and start a new one. Starting
/// a count only opens the header — items are added one at a time on the
/// count screen itself, as they're physically found on the shelf.
class StockCountHistoryScreen extends StatefulWidget {
  const StockCountHistoryScreen({super.key});

  @override
  State<StockCountHistoryScreen> createState() => _StockCountHistoryScreenState();
}

class _StockCountHistoryScreenState extends State<StockCountHistoryScreen> {
  List<StockCountSummary> _results = [];
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
      final api = StockCountApi(context.read<ApiClient>());
      final results = await api.list();
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

  Future<void> _startCount() async {
    final draft = await showDialog<_StartCountResult>(
      context: context,
      builder: (context) => const _StartCountDialog(),
    );
    if (draft == null) return;

    try {
      final api = StockCountApi(context.read<ApiClient>());
      final id = await api.startCount(locationId: draft.locationId, countMode: draft.countMode);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => StockCountScreen(stockCountId: id)),
      );
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'IN_PROGRESS':
        return AppColors.warning;
      case 'POSTED':
        return AppColors.success;
      case 'CANCELLED':
        return AppColors.danger;
      default:
        return AppColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Stock Counts', style: AppTypography.headline),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('start_stock_count_fab'),
        onPressed: _startCount,
        icon: const Icon(Icons.playlist_add_check_rounded),
        label: const Text('Start Count'),
        backgroundColor: AppColors.primary,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: Colors.red))))
              : _results.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.fact_check_outlined, size: 56, color: Color(0xFF94A3B8)),
                          SizedBox(height: 12),
                          Text('No stock counts yet', style: AppTypography.bodySecondary),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        key: const Key('stock_count_history_list'),
                        padding: const EdgeInsets.all(12),
                        itemCount: _results.length,
                        itemBuilder: (context, index) {
                          final c = _results[index];
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: AppDecorations.borderRadiusMd,
                              border: Border.all(color: AppColors.border),
                              boxShadow: AppDecorations.cardShadow,
                            ),
                            child: ListTile(
                              key: Key('stock_count_history_item_${c.id}'),
                              title: Text(c.locationName, style: AppTypography.title),
                              subtitle: Text(
                                '${c.countMode} · ${_dateFormat.format(c.startedAt.toLocal())}',
                                style: AppTypography.caption,
                              ),
                              trailing: Text(
                                c.status,
                                style: TextStyle(fontWeight: FontWeight.bold, color: _statusColor(c.status)),
                              ),
                              onTap: () async {
                                await Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => StockCountScreen(stockCountId: c.id)),
                                );
                                await _load();
                              },
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}

class _StartCountResult {
  final String locationId;
  final String countMode;

  _StartCountResult({required this.locationId, required this.countMode});
}

class _StartCountDialog extends StatefulWidget {
  const _StartCountDialog();

  @override
  State<_StartCountDialog> createState() => _StartCountDialogState();
}

class _StartCountDialogState extends State<_StartCountDialog> {
  List<LocationInfo> _locations = [];
  String? _selectedLocationId;
  String _countMode = 'CYCLE';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadLocations();
  }

  Future<void> _loadLocations() async {
    try {
      final api = PosApi(context.read<ApiClient>());
      final locations = await api.listLocations();
      if (!mounted) return;
      setState(() {
        _locations = locations;
        if (locations.length == 1) _selectedLocationId = locations.first.id;
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
    return AlertDialog(
      title: const Text('Start Stock Count'),
      content: _loading
          ? const SizedBox(height: 60, child: Center(child: CircularProgressIndicator()))
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
                DropdownButtonFormField<String>(
                  key: const Key('stock_count_location_dropdown'),
                  initialValue: _selectedLocationId,
                  decoration: const InputDecoration(labelText: 'Location'),
                  items: _locations.map((l) => DropdownMenuItem(value: l.id, child: Text(l.name))).toList(),
                  onChanged: (v) => setState(() => _selectedLocationId = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('stock_count_mode_dropdown'),
                  initialValue: _countMode,
                  decoration: const InputDecoration(labelText: 'Count Mode'),
                  items: const [
                    DropdownMenuItem(value: 'CYCLE', child: Text('Cycle (subset of products)')),
                    DropdownMenuItem(value: 'FULL', child: Text('Full (every product)')),
                  ],
                  onChanged: (v) => setState(() => _countMode = v ?? 'CYCLE'),
                ),
              ],
            ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('stock_count_start_submit'),
          onPressed: _selectedLocationId == null
              ? null
              : () => Navigator.of(context).pop(_StartCountResult(locationId: _selectedLocationId!, countMode: _countMode)),
          child: const Text('Start'),
        ),
      ],
    );
  }
}
