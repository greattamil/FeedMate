import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
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
    if (_loading) return const Center(child: CircularProgressIndicator(color: Colors.white));
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.white)));
    if (_entries.isEmpty) return const Center(child: Text('No errors recorded — good sign', style: TextStyle(color: Color(0xFF94A3B8))));

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _entries.length,
        itemBuilder: (context, index) {
          final e = _entries[index];
          return Container(
            key: Key('platform_error_entry_${e.id}'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFF1E293B), borderRadius: BorderRadius.circular(12)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: const Color(0xFF7F1D1D), borderRadius: BorderRadius.circular(6)),
                      child: Text('${e.statusCode}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                    Text(_dateFormat.format(e.createdAt.toLocal()), style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(e.message, style: const TextStyle(color: Colors.white, fontSize: 13)),
                if (e.requestId != null) ...[
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: e.requestId!));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Request ID copied'), duration: Duration(seconds: 1)));
                    },
                    child: Text('Request: ${e.requestId} (tap to copy)', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
