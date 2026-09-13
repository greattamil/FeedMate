import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/local_db.dart';
import '../../core/sync_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';

/// Review screen for the offline sale outbox — every queued sale, whatever
/// its status. PENDING entries are what the next sync attempt will send;
/// FAILED entries were rejected by the server for a reason a blind resend
/// can't fix (see SyncService) and need a human to look at them and decide
/// whether to retry (e.g. after raising a customer's credit limit) or accept
/// the sale is void. Nothing here is ever silently dropped — see
/// docs/IMPLEMENTATION_STATUS.md Phase 16's known gap this screen closes.
class OutboxScreen extends StatefulWidget {
  const OutboxScreen({super.key});

  @override
  State<OutboxScreen> createState() => _OutboxScreenState();
}

class _OutboxScreenState extends State<OutboxScreen> {
  List<Map<String, Object?>> _entries = [];
  bool _loading = true;
  bool _syncing = false;

  static final _dateFormat = DateFormat('dd MMM yyyy, h:mm a');

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final localDb = context.read<LocalDatabase>();
    final entries = await localDb.allOutboxEntries();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    final syncService = context.read<SyncService>();
    final result = await syncService.syncPendingInvoices();
    if (!mounted) return;
    await _refresh();
    setState(() => _syncing = false);
    final message = result.synced == 0 && result.failed == 0
        ? (result.remaining > 0 ? 'Still offline — nothing synced' : 'Nothing to sync')
        : 'Synced ${result.synced} sale(s)${result.failed > 0 ? ', ${result.failed} need review' : ''}';
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _retry(String clientTransactionId) async {
    final localDb = context.read<LocalDatabase>();
    await localDb.retryInvoice(clientTransactionId);
    await _refresh();
    await _syncNow();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Offline Sales Outbox'),
        actions: [
          IconButton(
            key: const Key('outbox_sync_now_button'),
            icon: _syncing
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.sync_rounded),
            tooltip: 'Sync now',
            onPressed: _syncing ? null : _syncNow,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: const BoxDecoration(
                          color: AppColors.primaryContainer,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.cloud_done_rounded, size: 48, color: AppColors.primary),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'No offline sales queued',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'All locally recorded transactions are synced with the server.',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.builder(
                    key: const Key('outbox_entries_list'),
                    padding: const EdgeInsets.all(16),
                    itemCount: _entries.length,
                    itemBuilder: (context, index) => _buildTile(_entries[index]),
                  ),
                ),
    );
  }

  Widget _buildTile(Map<String, Object?> row) {
    final status = row['status'] as String;
    final clientTransactionId = row['client_transaction_id'] as String;
    final createdAt = DateTime.tryParse(row['created_at'] as String);
    final lineCount = _lineCount(row['payload_json'] as String);
    final lastError = row['last_error'] as String?;

    Color statusColor;
    Color statusBg;
    IconData statusIcon;
    switch (status) {
      case 'SYNCED':
        statusColor = AppColors.success;
        statusBg = AppColors.successContainer;
        statusIcon = Icons.check_circle_rounded;
        break;
      case 'FAILED':
        statusColor = AppColors.danger;
        statusBg = AppColors.dangerContainer;
        statusIcon = Icons.error_rounded;
        break;
      default:
        statusColor = AppColors.warning;
        statusBg = AppColors.warningContainer;
        statusIcon = Icons.schedule_rounded;
    }

    final subtitleText = createdAt != null ? _dateFormat.format(createdAt.toLocal()) : '';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: AppDecorations.card(color: AppColors.surface),
      child: ListTile(
        key: Key('outbox_entry_$clientTransactionId'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: statusBg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(statusIcon, color: statusColor, size: 22),
        ),
        title: Text(
          '$lineCount item(s) — $status',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: lastError == null
              ? Text(subtitleText, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(subtitleText, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    const SizedBox(height: 4),
                    Text(lastError, style: const TextStyle(color: AppColors.danger, fontSize: 12, fontWeight: FontWeight.w600)),
                  ],
                ),
        ),
        trailing: status == 'FAILED'
            ? FilledButton(
                key: Key('outbox_retry_$clientTransactionId'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => _retry(clientTransactionId),
                child: const Text('Retry'),
              )
            : row['server_invoice_number'] != null
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceSecondary,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(
                      row['server_invoice_number'] as String,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.textPrimary),
                    ),
                  )
                : null,
      ),
    );
  }

  int _lineCount(String payloadJson) {
    try {
      final decoded = jsonDecode(payloadJson) as Map<String, dynamic>;
      return (decoded['lines'] as List<dynamic>? ?? []).length;
    } catch (_) {
      return 0;
    }
  }
}

