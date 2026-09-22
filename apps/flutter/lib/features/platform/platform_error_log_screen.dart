import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/responsive.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'platform_api.dart';
import 'platform_api_client.dart';

/// Every 5xx the API has returned, newest first — the durable record
/// httpapi.SetErrorSink now persists on every CodeInternal response,
/// replacing "grep docker logs" with something a non-developer can browse
/// (see error_logs migration's doc comment).
class PlatformErrorLogScreen extends StatefulWidget {
  const PlatformErrorLogScreen({super.key});

  @override
  State<PlatformErrorLogScreen> createState() => _PlatformErrorLogScreenState();
}

class _PlatformErrorLogScreenState extends State<PlatformErrorLogScreen> {
  List<PlatformErrorLogEntry> _entries = [];
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
      final entries = await api.listErrorLogs(limit: 100);
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
                    Icon(Icons.verified_outlined, size: 48, color: AppColors.success),
                    SizedBox(height: 12),
                    Center(child: Text('No errors recorded — good sign', style: AppTypography.bodySecondary)),
                  ],
                )
              : ListView.builder(
                  padding: EdgeInsets.all(context.responsive(mobile: 16.0, desktop: 24.0)),
                  itemCount: _entries.length,
                  itemBuilder: (context, index) {
                    final e = _entries[index];
                    return Container(
                      key: Key('platform_error_entry_${e.id}'),
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(16),
                      decoration: AppDecorations.card(border: Border.all(color: AppColors.dangerContainer)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                decoration: BoxDecoration(color: AppColors.dangerContainer, borderRadius: AppDecorations.borderRadiusFull),
                                child: Text('${e.statusCode}', style: AppTypography.caption.copyWith(color: AppColors.onDangerContainer, fontWeight: FontWeight.bold)),
                              ),
                              Text(_dateFormat.format(e.createdAt.toLocal()), style: AppTypography.caption),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(e.message, style: AppTypography.body),
                          if (e.requestId != null) ...[
                            const SizedBox(height: 8),
                            InkWell(
                              onTap: () {
                                Clipboard.setData(ClipboardData(text: e.requestId!));
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Request ID copied'), duration: Duration(seconds: 1)));
                              },
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.copy_rounded, size: 12, color: AppColors.textTertiary),
                                  const SizedBox(width: 4),
                                  Text('Request: ${e.requestId}', style: AppTypography.caption),
                                ],
                              ),
                            ),
                          ],
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
