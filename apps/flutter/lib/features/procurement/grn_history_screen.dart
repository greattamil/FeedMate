import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'grn_history_api.dart';
import 'grn_detail_screen.dart';

/// Browse past goods receipts (PRD 7.6). Read-only — a posted GRN is never
/// edited or deleted from here.
class GrnHistoryScreen extends StatefulWidget {
  const GrnHistoryScreen({super.key});

  @override
  State<GrnHistoryScreen> createState() => _GrnHistoryScreenState();
}

class _GrnHistoryScreenState extends State<GrnHistoryScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<GRNSummary> _results = [];
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
      final api = GRNHistoryApi(context.read<ApiClient>());
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('GRN History', style: AppTypography.headline),
      ),
      body: Column(
        children: [
          // Teal Hero Banner
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              gradient: AppColors.gradientTealCyan,
              borderRadius: AppDecorations.borderRadiusLg,
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withOpacity(0.25),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withOpacity(0.3)),
                  ),
                  child: const Icon(Icons.history_rounded, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'GRN Intake Register',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Chronological goods receipt history & receiving logs',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.9),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.2)),
                  ),
                  child: Text(
                    '${_results.length} logged',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Search Field
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(
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
                        Icon(Icons.move_to_inbox_outlined, size: 56, color: Color(0xFF94A3B8)),
                        SizedBox(height: 12),
                        Text('No GRNs found', style: AppTypography.bodySecondary),
                      ],
                    ),
                  )
                : ListView.builder(
                    key: const Key('grn_history_results_list'),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                          title: Text(g.grnNumber, style: AppTypography.title.copyWith(fontSize: 15, fontWeight: FontWeight.w700)),
                          subtitle: Text(
                            [
                              g.supplierName,
                              if (g.postedAt != null) _dateFormat.format(g.postedAt!.toLocal()),
                            ].join(' · '),
                            style: AppTypography.caption,
                          ),
                          trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: AppColors.textSecondary),
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
        ],
      ),
    );
  }
}
