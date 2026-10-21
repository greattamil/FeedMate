import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'platform_api.dart';
import 'platform_api_client.dart';

/// The global subscription-plan catalogue — reachable independently of any
/// one tenant, since a plan (price + grace period) is a platform-wide
/// template that a tenant's own billing tab then picks from. Code is
/// immutable once a plan is created (UpdatePlan has no code field
/// server-side), so the edit dialog never shows or sends one.
class SubscriptionPlansScreen extends StatefulWidget {
  const SubscriptionPlansScreen({super.key});

  @override
  State<SubscriptionPlansScreen> createState() => _SubscriptionPlansScreenState();
}

class _SubscriptionPlansScreenState extends State<SubscriptionPlansScreen> {
  List<SubscriptionPlan> _plans = [];
  bool _loading = true;
  String? _error;

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
      final plans = await api.listPlans();
      if (!mounted) return;
      setState(() {
        _plans = plans;
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

  Future<void> _addPlan() async {
    final draft = await showDialog<_PlanFormResult>(
      context: context,
      builder: (context) => const _PlanFormDialog(),
    );
    if (draft == null) return;
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      await api.createPlan(code: draft.code!, name: draft.name, price: draft.price, gracePeriodDays: draft.gracePeriodDays);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${draft.name} added')));
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _editPlan(SubscriptionPlan plan) async {
    final draft = await showDialog<_PlanFormResult>(
      context: context,
      builder: (context) => _PlanFormDialog(existing: plan),
    );
    if (draft == null) return;
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      await api.updatePlan(plan.id, name: draft.name, price: draft.price, gracePeriodDays: draft.gracePeriodDays, active: draft.active);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Plan updated')));
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _toggleActive(SubscriptionPlan plan, bool active) async {
    try {
      final api = PlatformApi(context.read<PlatformApiClient>());
      await api.updatePlan(plan.id, name: plan.name, price: plan.price, gracePeriodDays: plan.gracePeriodDays, active: active);
      if (!mounted) return;
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        key: const Key('subscription_plans_add_fab'),
        onPressed: _addPlan,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Plan'),
        backgroundColor: AppColors.primary,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!, style: const TextStyle(color: AppColors.danger)),
                  ),
                )
              : _plans.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.workspace_premium_outlined, size: 56, color: AppColors.textTertiary),
                          SizedBox(height: 12),
                          Text('No plans yet', style: AppTypography.bodySecondary),
                        ],
                      ),
                    )
                  : ListView.builder(
                      key: const Key('subscription_plans_list'),
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                      itemCount: _plans.length,
                      itemBuilder: (context, index) {
                        final plan = _plans[index];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration: AppDecorations.card(color: AppColors.surface),
                          child: ListTile(
                            key: Key('subscription_plan_item_${plan.id}'),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            onTap: () => _editPlan(plan),
                            title: Row(
                              children: [
                                Expanded(child: Text(plan.name, style: AppTypography.title)),
                                Text('${plan.price} ${plan.currencyCode}', style: AppTypography.body.copyWith(fontWeight: FontWeight.bold)),
                              ],
                            ),
                            subtitle: Text(
                              '${plan.code} · ${plan.billingPeriod} · ${plan.gracePeriodDays}d grace',
                              style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
                            ),
                            trailing: Switch(
                              key: Key('subscription_plan_active_switch_${plan.id}'),
                              value: plan.active,
                              activeThumbColor: AppColors.success,
                              onChanged: (v) => _toggleActive(plan, v),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

class _PlanFormResult {
  final String? code;
  final String name;
  final Decimal price;
  final int gracePeriodDays;
  final bool active;

  _PlanFormResult({this.code, required this.name, required this.price, required this.gracePeriodDays, required this.active});
}

class _PlanFormDialog extends StatefulWidget {
  final SubscriptionPlan? existing;
  const _PlanFormDialog({this.existing});

  @override
  State<_PlanFormDialog> createState() => _PlanFormDialogState();
}

class _PlanFormDialogState extends State<_PlanFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _codeController;
  late final TextEditingController _nameController;
  late final TextEditingController _priceController;
  late final TextEditingController _graceController;
  late bool _active;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _codeController = TextEditingController(text: existing?.code ?? '');
    _nameController = TextEditingController(text: existing?.name ?? '');
    _priceController = TextEditingController(text: existing?.price.toString() ?? '');
    _graceController = TextEditingController(text: existing?.gracePeriodDays.toString() ?? '');
    _active = existing?.active ?? true;
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _priceController.dispose();
    _graceController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final price = Decimal.parse(_priceController.text.trim());
    final grace = int.parse(_graceController.text.trim());
    Navigator.of(context).pop(_PlanFormResult(
      code: _isEdit ? null : _codeController.text.trim(),
      name: _nameController.text.trim(),
      price: price,
      gracePeriodDays: grace,
      active: _active,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit Plan' : 'Add Plan', style: AppTypography.headline),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_isEdit) ...[
                TextFormField(
                  key: const Key('plan_form_code_field'),
                  controller: _codeController,
                  decoration: const InputDecoration(labelText: 'Code'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                key: const Key('plan_form_name_field'),
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('plan_form_price_field'),
                controller: _priceController,
                decoration: const InputDecoration(labelText: 'Price'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  final parsed = Decimal.tryParse(v.trim());
                  if (parsed == null || parsed < Decimal.zero) return 'Enter a valid price';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('plan_form_grace_period_field'),
                controller: _graceController,
                decoration: const InputDecoration(labelText: 'Grace Period (days)'),
                keyboardType: TextInputType.number,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  final parsed = int.tryParse(v.trim());
                  if (parsed == null || parsed < 0) return 'Enter a valid number of days';
                  return null;
                },
              ),
              if (_isEdit) ...[
                const SizedBox(height: 8),
                SwitchListTile(
                  key: const Key('plan_form_active_switch'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  value: _active,
                  activeThumbColor: AppColors.success,
                  onChanged: (v) => setState(() => _active = v),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          key: const Key('plan_form_submit'),
          onPressed: _submit,
          child: Text(_isEdit ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}
