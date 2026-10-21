import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'platform_api.dart';
import 'platform_api_client.dart';

/// The Billing tab of [TenantDetailScreen]: the tenant's current
/// subscription (plan/period/status), a "Change Plan" action, a
/// "Record Payment" action for money collected out of band (UPI/bank/cash —
/// there is no payment gateway here), and a paginated history of past
/// payments. A tenant with no subscription assigned yet (the normal state
/// for anything created before this feature, or never assigned a plan)
/// shows a setup prompt instead of an error.
class TenantBillingTab extends StatefulWidget {
  final String tenantId;
  const TenantBillingTab({super.key, required this.tenantId});

  @override
  State<TenantBillingTab> createState() => _TenantBillingTabState();
}

class _TenantBillingTabState extends State<TenantBillingTab> {
  TenantSubscription? _subscription;
  List<SubscriptionPayment> _payments = [];
  int _total = 0;
  int _offset = 0;
  static const _pageSize = 20;
  bool _loading = true;
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
    });
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      final subscription = await api.getTenantSubscription(widget.tenantId);
      if (!mounted) return;
      if (subscription == null) {
        setState(() {
          _subscription = null;
          _payments = [];
          _total = 0;
          _loading = false;
        });
        return;
      }
      final history = await api.listBillingHistory(widget.tenantId, limit: _pageSize, offset: _offset);
      if (!mounted) return;
      setState(() {
        _subscription = subscription;
        _payments = history.payments;
        _total = history.total;
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

  Future<void> _changePage(int newOffset) async {
    setState(() => _offset = newOffset);
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      final history = await api.listBillingHistory(widget.tenantId, limit: _pageSize, offset: _offset);
      if (!mounted) return;
      setState(() {
        _payments = history.payments;
        _total = history.total;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _changePlan() async {
    final api = PlatformApi(context.read<PlatformApiClient>());
    List<SubscriptionPlan> plans;
    try {
      plans = await api.listPlans();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!mounted) return;
    final result = await showDialog<(String, DateTime?)>(
      context: context,
      builder: (context) => _ChangePlanDialog(plans: plans, currentPlanId: _subscription?.planId),
    );
    if (result == null) return;
    try {
      await api.setTenantSubscriptionPlan(widget.tenantId, result.$1, periodStart: result.$2);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Plan updated')));
      _offset = 0;
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _recordPayment() async {
    final draft = await showDialog<_PaymentDraft>(
      context: context,
      builder: (context) => const _RecordPaymentDialog(),
    );
    if (draft == null) return;
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      final result = await api.recordSubscriptionPayment(
        widget.tenantId,
        amount: draft.amount,
        method: draft.method,
        reference: draft.reference,
        notes: draft.notes,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.duplicate ? 'Payment already recorded (duplicate ignored)' : 'Payment recorded')),
      );
      _offset = 0;
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'ACTIVE':
        return AppColors.success;
      case 'PAST_DUE':
        return AppColors.warning;
      case 'SUSPENDED':
        return AppColors.danger;
      default:
        return AppColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, style: const TextStyle(color: AppColors.danger)),
        ),
      );
    }
    final subscription = _subscription;
    if (subscription == null) {
      return _buildEmptyState();
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('tenant_billing_list'),
        padding: const EdgeInsets.all(16),
        children: [
          _subscriptionCard(subscription),
          const SizedBox(height: 16),
          _historySection(),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.receipt_long_outlined, size: 56, color: AppColors.textTertiary),
            const SizedBox(height: 16),
            Text('No subscription assigned yet', style: AppTypography.title),
            const SizedBox(height: 8),
            const Text(
              'This tenant has no billing plan set up. Assign a plan to start tracking subscription status and payments.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('tenant_billing_assign_plan_button'),
              onPressed: _changePlan,
              icon: const Icon(Icons.add_card_rounded),
              label: const Text('Assign Plan'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _subscriptionCard(TenantSubscription subscription) {
    final statusColor = _statusColor(subscription.status);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppDecorations.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(subscription.planName, style: AppTypography.headline),
              ),
              Container(
                key: const Key('tenant_billing_status_badge'),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.12), borderRadius: AppDecorations.borderRadiusFull),
                child: Text(subscription.status, style: AppTypography.caption.copyWith(color: statusColor, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('${subscription.planCode} · ${subscription.planPrice}/period', style: AppTypography.bodySecondary),
          const SizedBox(height: 14),
          _kv('Current period', '${_dateFormat.format(subscription.currentPeriodStart)} – ${_dateFormat.format(subscription.currentPeriodEnd)}'),
          _kv('Grace period', '${subscription.effectiveGracePeriodDays} days'),
          if (subscription.pastDueSince != null) _kv('Past due since', _dateFormat.format(subscription.pastDueSince!.toLocal())),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                key: const Key('tenant_billing_change_plan_button'),
                onPressed: _changePlan,
                icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                label: const Text('Change Plan'),
              ),
              FilledButton.icon(
                key: const Key('tenant_billing_record_payment_button'),
                onPressed: _recordPayment,
                icon: const Icon(Icons.payments_outlined, size: 18),
                label: const Text('Record Payment'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 120, child: Text(label, style: AppTypography.caption)),
          Expanded(child: Text(value, style: AppTypography.body)),
        ],
      ),
    );
  }

  Widget _historySection() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: AppDecorations.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Billing History', style: AppTypography.title),
          const SizedBox(height: 12),
          if (_payments.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No payments recorded yet', style: AppTypography.bodySecondary),
            )
          else
            ListView.separated(
              key: const Key('tenant_billing_payments_list'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _payments.length,
              separatorBuilder: (context, index) => const Divider(height: 1, color: AppColors.border),
              itemBuilder: (context, index) {
                final p = _payments[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    key: Key('tenant_billing_payment_item_${p.id}'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_dateFormat.format(p.paidAt.toLocal()), style: AppTypography.body),
                            Text(
                              '${_dateFormat.format(p.periodStart)} – ${_dateFormat.format(p.periodEnd)}',
                              style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                      Expanded(child: Text(p.method, style: AppTypography.caption)),
                      Text(p.amount.toString(), style: AppTypography.body.copyWith(fontWeight: FontWeight.bold)),
                    ],
                  ),
                );
              },
            ),
          if (_total > _pageSize) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text('${_offset + 1}-${(_offset + _payments.length).clamp(0, _total)} of $_total', style: AppTypography.caption),
                IconButton(
                  key: const Key('tenant_billing_history_prev'),
                  icon: const Icon(Icons.chevron_left_rounded),
                  onPressed: _offset > 0 ? () => _changePage((_offset - _pageSize).clamp(0, _total)) : null,
                ),
                IconButton(
                  key: const Key('tenant_billing_history_next'),
                  icon: const Icon(Icons.chevron_right_rounded),
                  onPressed: _offset + _pageSize < _total ? () => _changePage(_offset + _pageSize) : null,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ChangePlanDialog extends StatefulWidget {
  final List<SubscriptionPlan> plans;
  final String? currentPlanId;
  const _ChangePlanDialog({required this.plans, this.currentPlanId});

  @override
  State<_ChangePlanDialog> createState() => _ChangePlanDialogState();
}

class _ChangePlanDialogState extends State<_ChangePlanDialog> {
  String? _selectedPlanId;
  DateTime? _periodStart;

  List<SubscriptionPlan> get _selectablePlans =>
      widget.plans.where((p) => p.active || p.id == widget.currentPlanId).toList();

  @override
  void initState() {
    super.initState();
    final selectable = _selectablePlans;
    _selectedPlanId = widget.currentPlanId ?? (selectable.isNotEmpty ? selectable.first.id : null);
  }

  @override
  Widget build(BuildContext context) {
    final plans = _selectablePlans;
    return AlertDialog(
      title: const Text('Change Plan'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (plans.isEmpty)
            const Text('No plans available. Create one in the Plans catalogue first.')
          else
            DropdownButtonFormField<String>(
              key: const Key('billing_plan_dialog_plan_field'),
              initialValue: _selectedPlanId,
              decoration: const InputDecoration(labelText: 'Plan'),
              items: plans.map((p) => DropdownMenuItem(value: p.id, child: Text('${p.name} (${p.price})'))).toList(),
              onChanged: (v) => setState(() => _selectedPlanId = v),
            ),
          const SizedBox(height: 12),
          ListTile(
            key: const Key('billing_plan_dialog_period_start_field'),
            contentPadding: EdgeInsets.zero,
            title: Text(_periodStart == null ? 'Starting today' : 'Starts ${_periodStart!.toLocal().toString().split(' ').first}'),
            trailing: const Icon(Icons.calendar_today_rounded, size: 18),
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _periodStart ?? DateTime.now(),
                firstDate: DateTime.now().subtract(const Duration(days: 365)),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (picked != null) setState(() => _periodStart = picked);
            },
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('billing_plan_dialog_submit'),
          onPressed: _selectedPlanId == null ? null : () => Navigator.of(context).pop((_selectedPlanId!, _periodStart)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _PaymentDraft {
  final Decimal amount;
  final String method;
  final String? reference;
  final String? notes;

  _PaymentDraft({required this.amount, required this.method, this.reference, this.notes});
}

class _RecordPaymentDialog extends StatefulWidget {
  const _RecordPaymentDialog();

  @override
  State<_RecordPaymentDialog> createState() => _RecordPaymentDialogState();
}

class _RecordPaymentDialogState extends State<_RecordPaymentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _referenceController = TextEditingController();
  final _notesController = TextEditingController();
  String _method = 'UPI';

  static const _methods = ['CASH', 'BANK', 'UPI', 'OTHER'];

  @override
  void dispose() {
    _amountController.dispose();
    _referenceController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Decimal amount;
    try {
      amount = Decimal.parse(_amountController.text.trim());
    } catch (_) {
      return;
    }
    Navigator.of(context).pop(_PaymentDraft(
      amount: amount,
      method: _method,
      reference: _referenceController.text.trim().isEmpty ? null : _referenceController.text.trim(),
      notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Record Payment'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('billing_payment_amount_field'),
                controller: _amountController,
                decoration: const InputDecoration(labelText: 'Amount'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  final parsed = Decimal.tryParse(v.trim());
                  if (parsed == null || parsed <= Decimal.zero) return 'Enter a valid amount';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('billing_payment_method_field'),
                initialValue: _method,
                decoration: const InputDecoration(labelText: 'Method'),
                items: _methods.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                onChanged: (v) => setState(() => _method = v ?? _method),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('billing_payment_reference_field'),
                controller: _referenceController,
                decoration: const InputDecoration(labelText: 'Reference (optional)'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('billing_payment_notes_field'),
                controller: _notesController,
                decoration: const InputDecoration(labelText: 'Notes (optional)'),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('billing_payment_submit'),
          onPressed: _submit,
          child: const Text('Record'),
        ),
      ],
    );
  }
}
