import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
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

  static final _dateFormat = DateFormat('EEEE, dd MMMM yyyy');

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
        title: 'Open Cash Drawer',
        label: 'Opening cash float (₹)',
        confirmLabel: 'Open Session',
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
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.successContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.lock_clock_rounded, color: AppColors.success, size: 24),
              ),
              const SizedBox(width: 12),
              const Text('Day Closed'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Expected: ₹${closeResult.expectedCash.toStringAsFixed(2)}'),
              const SizedBox(height: 4),
              Text('Counted: ₹${closeResult.actualCash.toStringAsFixed(2)}'),
              const SizedBox(height: 4),
              Text(
                'Variance: ₹${closeResult.variance.toStringAsFixed(2)}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: closeResult.variance == Decimal.zero
                      ? AppColors.success
                      : (closeResult.variance < Decimal.zero ? AppColors.danger : AppColors.warning),
                ),
              ),
            ],
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'VALIDATION_ERROR' && e.message.contains('reason is required')) {
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
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Cash Register (EOD)'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Date Header Card
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: AppDecorations.card(color: AppColors.surface),
                    child: Row(
                      children: [
                        const Icon(Icons.today_rounded, color: AppColors.primary, size: 20),
                        const SizedBox(width: 10),
                        Text(
                          _dateFormat.format(DateTime.now()),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.textPrimary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.dangerContainer,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.dangerLight),
                      ),
                      child: Text(_error!, style: const TextStyle(color: AppColors.onDangerContainer)),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (_notOpened) _buildNotOpened(),
                  if (_session != null) _buildSession(_session!),
                ],
              ),
      ),
    );
  }

  Widget _buildNotOpened() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: AppDecorations.card(color: AppColors.surface),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: AppColors.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.point_of_sale_rounded, size: 40, color: AppColors.primary),
          ),
          const SizedBox(height: 16),
          const Text(
            'No cash session opened for today yet.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 8),
          const Text(
            'Count your starting cash float to begin transactions.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('open_day_button'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _openDay,
              icon: const Icon(Icons.key_rounded, size: 20),
              label: const Text('Open Day', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSession(EodSession session) {
    final isOpen = session.status == 'OPEN';
    return Column(
      children: [
        // Hero Status Card
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            gradient: isOpen ? AppColors.gradientEmerald : AppColors.gradientDark,
            borderRadius: BorderRadius.circular(16),
            boxShadow: AppDecorations.cardShadow,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    isOpen ? Icons.lock_open_rounded : Icons.lock_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    session.status,
                    key: const Key('eod_status'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(50),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  isOpen ? 'ACTIVE' : 'RECONCILED',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // Session Journal Breakdown
        Container(
          padding: const EdgeInsets.all(14),
          decoration: AppDecorations.card(color: AppColors.surface),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Drawer Breakdown',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              _statRow('Opening Cash', session.openingCash),
              if (session.status != 'OPEN') ...[
                const Divider(height: 16),
                _statRow('Cash Sales', session.cashSales),
                _statRow('Cash Refunds', session.cashRefunds),
                _statRow('Expected Cash', session.expectedCash, bold: true),
                if (session.actualCash != null) ...[
                  const Divider(height: 16),
                  _statRow('Actual Cash', session.actualCash!, bold: true),
                ],
                if (session.variance != null)
                  _statRow(
                    'Variance',
                    session.variance!,
                    bold: true,
                    color: session.variance == Decimal.zero
                        ? AppColors.success
                        : (session.variance! < Decimal.zero ? AppColors.danger : AppColors.warning),
                  ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 16),

        if (session.status == 'OPEN')
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('close_day_button'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.danger,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _closeDay,
              icon: const Icon(Icons.lock_clock_rounded, size: 20),
              label: const Text('Count & Close Day', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        if (session.status == 'CLOSED')
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('reopen_day_button'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                side: const BorderSide(color: AppColors.primary, width: 1.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _reopenDay,
              icon: const Icon(Icons.lock_open_rounded, color: AppColors.primary, size: 20),
              label: const Text('Reopen Day (Correction)', style: TextStyle(color: AppColors.primary, fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
      ],
    );
  }

  Widget _statRow(String label, Decimal value, {Color? color, bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: bold ? AppColors.textPrimary : AppColors.textSecondary,
              fontWeight: bold ? FontWeight.bold : FontWeight.normal,
              fontSize: 14,
            ),
          ),
          Text(
            '₹${value.toStringAsFixed(2)}',
            style: TextStyle(
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
              fontSize: 15,
              color: color ?? AppColors.textPrimary,
            ),
          ),
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
        decoration: InputDecoration(
          labelText: widget.label,
          errorText: _error,
          prefixIcon: const Icon(Icons.currency_rupee_rounded, size: 20),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('amount_dialog_submit'),
          style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
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
        decoration: InputDecoration(
          labelText: widget.label,
          prefixIcon: const Icon(Icons.edit_note_rounded, size: 20),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('reason_dialog_submit'),
          style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
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
      title: const Text('Close Cash Day'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.serverMessage != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warningContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                widget.serverMessage!,
                style: const TextStyle(color: AppColors.onWarningContainer, fontSize: 13),
              ),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            key: const Key('close_actual_cash_field'),
            controller: _cashController,
            autofocus: widget.serverMessage == null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Actual cash counted (₹)',
              errorText: _error,
              prefixIcon: const Icon(Icons.payments_rounded, size: 20),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('close_variance_reason_field'),
            controller: _reasonController,
            autofocus: widget.serverMessage != null,
            decoration: const InputDecoration(
              labelText: 'Variance reason (if any difference)',
              prefixIcon: Icon(Icons.notes_rounded, size: 20),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('close_day_submit'),
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: _submit,
          child: const Text('Close Session'),
        ),
      ],
    );
  }
}

