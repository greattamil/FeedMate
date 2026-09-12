import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import 'eod_api.dart';

/// End-of-day cash reconciliation: open the day with an opening float,
/// close it by counting the physical cash drawer (the server computes
/// expected cash from the accounting journal — never a client-side running
/// total, see PRD 12.2), and reopen a closed day when a correction is
/// needed. Always operates on today's business date; a real multi-day
/// catch-up UI is out of scope for this pass.
class EodScreen extends StatefulWidget {
  const EodScreen({super.key});

  @override
  State<EodScreen> createState() => _EodScreenState();
}

class _EodScreenState extends State<EodScreen> {
  EodSession? _session;
  bool _loading = true;
  bool _notOpened = false;
  String? _error;

  static final _dateFormat = DateFormat('dd MMM yyyy');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _notOpened = false;
    });
    try {
      final api = EodApi(context.read<ApiClient>());
      final session = await api.getSession();
      if (!mounted) return;
      setState(() {
        _session = session;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'NOT_FOUND') {
        setState(() {
          _notOpened = true;
          _session = null;
          _loading = false;
        });
      } else {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  Future<void> _openDay() async {
    final openingCash = await showDialog<Decimal>(
      context: context,
      builder: (context) => const _AmountDialog(
        title: 'Open Day',
        label: 'Opening cash float',
        confirmLabel: 'Open',
      ),
    );
    if (openingCash == null) return;

    try {
      final api = EodApi(context.read<ApiClient>());
      await api.openSession(openingCash: openingCash);
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _closeDay() async {
    final result = await showDialog<_CloseFormResult>(
      context: context,
      builder: (context) => const _CloseDayDialog(),
    );
    if (result == null) return;
    await _submitClose(result.actualCash, result.reason);
  }

  Future<void> _submitClose(Decimal actualCash, String reason) async {
    try {
      final api = EodApi(context.read<ApiClient>());
      final closeResult = await api.closeSession(actualCash: actualCash, varianceReason: reason);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Day Closed'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Expected: ₹${closeResult.expectedCash.toStringAsFixed(2)}'),
              Text('Counted: ₹${closeResult.actualCash.toStringAsFixed(2)}'),
              Text(
                'Variance: ₹${closeResult.variance.toStringAsFixed(2)}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: closeResult.variance == Decimal.zero
                      ? Colors.green
                      : (closeResult.variance < Decimal.zero ? Colors.red : Colors.orange),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
          ],
        ),
      );
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'VALIDATION_ERROR' && e.message.contains('reason is required')) {
        // The server won't accept a non-zero variance without a reason —
        // reopen the same close dialog pre-filled with the amount so the
        // cashier only has to add the reason, not recount and retype cash.
        final retryResult = await showDialog<_CloseFormResult>(
          context: context,
          builder: (context) => _CloseDayDialog(
            initialActualCash: actualCash,
            serverMessage: e.message,
          ),
        );
        if (retryResult != null) {
          await _submitClose(retryResult.actualCash, retryResult.reason);
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _reopenDay() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => const _ReasonDialog(title: 'Reopen Day', label: 'Reason for reopening'),
    );
    if (reason == null || reason.isEmpty) return;

    try {
      final api = EodApi(context.read<ApiClient>());
      await api.reopenSession(reason: reason);
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('End of Day')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(_dateFormat.format(DateTime.now()), style: const TextStyle(color: Colors.grey)),
                  const SizedBox(height: 16),
                  if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
                  if (_notOpened) _buildNotOpened(),
                  if (_session != null) _buildSession(_session!),
                ],
              ),
      ),
    );
  }

  Widget _buildNotOpened() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('No cash session opened for today yet.'),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('open_day_button'),
          onPressed: _openDay,
          child: const Text('Open Day'),
        ),
      ],
    );
  }

  Widget _buildSession(EodSession session) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(session.status, key: const Key('eod_status'), style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const Divider(),
            _statRow('Opening Cash', session.openingCash),
            if (session.status != 'OPEN') ...[
              _statRow('Cash Sales', session.cashSales),
              _statRow('Cash Refunds', session.cashRefunds),
              _statRow('Expected Cash', session.expectedCash),
              if (session.actualCash != null) _statRow('Actual Cash', session.actualCash!),
              if (session.variance != null)
                _statRow('Variance', session.variance!,
                    color: session.variance! == Decimal.zero
                        ? Colors.green
                        : (session.variance! < Decimal.zero ? Colors.red : Colors.orange)),
            ],
            const SizedBox(height: 16),
            if (session.status == 'OPEN')
              FilledButton(
                key: const Key('close_day_button'),
                onPressed: _closeDay,
                child: const Text('Close Day'),
              ),
            if (session.status == 'CLOSED')
              OutlinedButton(
                key: const Key('reopen_day_button'),
                onPressed: _reopenDay,
                child: const Text('Reopen Day'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statRow(String label, Decimal value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text('₹${value.toStringAsFixed(2)}', style: TextStyle(fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }
}

class _AmountDialog extends StatefulWidget {
  final String title;
  final String label;
  final String confirmLabel;

  const _AmountDialog({required this.title, required this.label, required this.confirmLabel});

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = Decimal.tryParse(_controller.text.trim());
    if (amount == null || amount < Decimal.zero) {
      setState(() => _error = 'Enter a valid amount (zero or more)');
      return;
    }
    Navigator.of(context).pop(amount);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('amount_dialog_field'),
        controller: _controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: widget.label, errorText: _error),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const Key('amount_dialog_submit'), onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

class _ReasonDialog extends StatefulWidget {
  final String title;
  final String label;

  const _ReasonDialog({required this.title, required this.label});

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('reason_dialog_field'),
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('reason_dialog_submit'),
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}

class _CloseFormResult {
  final Decimal actualCash;
  final String reason;

  _CloseFormResult({required this.actualCash, required this.reason});
}

class _CloseDayDialog extends StatefulWidget {
  final Decimal? initialActualCash;
  final String? serverMessage;

  const _CloseDayDialog({this.initialActualCash, this.serverMessage});

  @override
  State<_CloseDayDialog> createState() => _CloseDayDialogState();
}

class _CloseDayDialogState extends State<_CloseDayDialog> {
  late final TextEditingController _cashController;
  final _reasonController = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _cashController = TextEditingController(text: widget.initialActualCash?.toStringAsFixed(2) ?? '');
  }

  @override
  void dispose() {
    _cashController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = Decimal.tryParse(_cashController.text.trim());
    if (amount == null || amount < Decimal.zero) {
      setState(() => _error = 'Enter a valid amount (zero or more)');
      return;
    }
    Navigator.of(context).pop(_CloseFormResult(actualCash: amount, reason: _reasonController.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Close Day'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.serverMessage != null) ...[
            Text(widget.serverMessage!, style: const TextStyle(color: Colors.orange)),
            const SizedBox(height: 12),
          ],
          TextField(
            key: const Key('close_actual_cash_field'),
            controller: _cashController,
            autofocus: widget.serverMessage == null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: 'Actual cash counted', errorText: _error),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('close_variance_reason_field'),
            controller: _reasonController,
            autofocus: widget.serverMessage != null,
            decoration: const InputDecoration(labelText: 'Variance reason (if any difference)'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(key: const Key('close_day_submit'), onPressed: _submit, child: const Text('Close')),
      ],
    );
  }
}
