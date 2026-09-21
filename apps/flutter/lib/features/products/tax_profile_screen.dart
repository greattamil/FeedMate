import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'product_admin_api.dart';

const _supplyTypes = ['INTRA_STATE', 'INTER_STATE', 'EXPORT', 'EXEMPT', 'NON_GST'];

String _supplyTypeLabel(String value) {
  switch (value) {
    case 'INTRA_STATE':
      return 'Intra-State (CGST+SGST)';
    case 'INTER_STATE':
      return 'Inter-State (IGST)';
    case 'EXPORT':
      return 'Export';
    case 'EXEMPT':
      return 'Exempt';
    case 'NON_GST':
      return 'Non-GST';
    default:
      return value;
  }
}

/// The dedicated GST management screen the product master-data doc comment
/// always said tax profiles deserved rather than a quick add button: full
/// create/edit, and — the reason this screen exists — the central,
/// per-profile "Price Includes GST" control. A shop owner creates one
/// profile per distinct GST treatment they need (e.g. two profiles both at
/// 18%, one inclusive and one exclusive) and assigns products to whichever
/// applies from the existing tax-profile picker on the product form.
class TaxProfileScreen extends StatefulWidget {
  const TaxProfileScreen({super.key});

  @override
  State<TaxProfileScreen> createState() => _TaxProfileScreenState();
}

class _TaxProfileScreenState extends State<TaxProfileScreen> {
  List<TaxProfileDetail> _profiles = [];
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
      final api = ProductAdminApi(context.read<ApiClient>());
      final profiles = await api.listAllTaxProfiles();
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
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

  Future<void> _openForm({TaxProfileDetail? existing}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TaxProfileForm(existing: existing),
    );
    if (saved == true) await _load();
  }

  Future<void> _toggleActive(TaxProfileDetail profile) async {
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      await api.setTaxProfileActive(profile.id, !profile.active);
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
      appBar: AppBar(title: const Text('Tax Profiles (GST)', style: AppTypography.headline)),
      floatingActionButton: FloatingActionButton(
        key: const Key('tax_profile_add_fab'),
        backgroundColor: AppColors.primary,
        onPressed: () => _openForm(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: Colors.red))))
              : _profiles.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No tax profiles yet.\nCreate one for each GST rate your products need — mark it '
                          '"Price Includes GST" if the selling price already has tax baked in.',
                          textAlign: TextAlign.center,
                          style: AppTypography.bodySecondary,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _profiles.length,
                      itemBuilder: (context, index) {
                        final p = _profiles[index];
                        return Opacity(
                          opacity: p.active ? 1 : 0.55,
                          child: Container(
                            key: Key('tax_profile_item_${p.id}'),
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: AppDecorations.borderRadiusMd,
                              border: Border.all(color: AppColors.border),
                            ),
                            child: ListTile(
                              onTap: () => _openForm(existing: p),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text('${p.code} — ${p.description}', style: const TextStyle(fontWeight: FontWeight.w600)),
                                  ),
                                  if (p.priceInclusive)
                                    Container(
                                      key: Key('tax_profile_inclusive_badge_${p.id}'),
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(color: AppColors.infoContainer, borderRadius: BorderRadius.circular(20)),
                                      child: const Text('Price incl. GST', style: TextStyle(fontSize: 11, color: AppColors.onInfoContainer, fontWeight: FontWeight.w600)),
                                    )
                                  else
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(color: AppColors.surfaceTertiary, borderRadius: BorderRadius.circular(20)),
                                      child: const Text('Price excl. GST', style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                                    ),
                                ],
                              ),
                              subtitle: Text(
                                '${_supplyTypeLabel(p.supplyType)} · Total ${p.totalRate.toStringAsFixed(2)}% '
                                '(CGST ${p.cgstRate.toStringAsFixed(2)} / SGST ${p.sgstRate.toStringAsFixed(2)} / IGST ${p.igstRate.toStringAsFixed(2)} / CESS ${p.cessRate.toStringAsFixed(2)})'
                                '${p.active ? '' : ' · Inactive'}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: Switch(
                                key: Key('tax_profile_active_switch_${p.id}'),
                                value: p.active,
                                onChanged: (_) => _toggleActive(p),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}

class _TaxProfileForm extends StatefulWidget {
  final TaxProfileDetail? existing;
  const _TaxProfileForm({this.existing});

  @override
  State<_TaxProfileForm> createState() => _TaxProfileFormState();
}

class _TaxProfileFormState extends State<_TaxProfileForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _codeController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _cgstController;
  late final TextEditingController _sgstController;
  late final TextEditingController _igstController;
  late final TextEditingController _cessController;
  late String _supplyType;
  late bool _priceInclusive;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _codeController = TextEditingController(text: e?.code ?? '');
    _descriptionController = TextEditingController(text: e?.description ?? '');
    _cgstController = TextEditingController(text: e?.cgstRate.toString() ?? '0');
    _sgstController = TextEditingController(text: e?.sgstRate.toString() ?? '0');
    _igstController = TextEditingController(text: e?.igstRate.toString() ?? '0');
    _cessController = TextEditingController(text: e?.cessRate.toString() ?? '0');
    _supplyType = e?.supplyType ?? 'INTRA_STATE';
    _priceInclusive = e?.priceInclusive ?? false;
  }

  @override
  void dispose() {
    _codeController.dispose();
    _descriptionController.dispose();
    _cgstController.dispose();
    _sgstController.dispose();
    _igstController.dispose();
    _cessController.dispose();
    super.dispose();
  }

  Decimal _rate(TextEditingController c) => Decimal.tryParse(c.text.trim()) ?? Decimal.zero;

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      final profile = TaxProfileDetail(
        id: widget.existing?.id ?? '',
        code: _codeController.text.trim(),
        description: _descriptionController.text.trim(),
        supplyType: _supplyType,
        cgstRate: _rate(_cgstController),
        sgstRate: _rate(_sgstController),
        igstRate: _rate(_igstController),
        cessRate: _rate(_cessController),
        priceInclusive: _priceInclusive,
        active: widget.existing?.active ?? true,
      );
      if (_isEdit) {
        await api.updateTaxProfile(widget.existing!.id, profile);
      } else {
        await api.createTaxProfile(profile);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        minChildSize: 0.5,
        expand: false,
        builder: (context, scrollController) {
          return Container(
            decoration: const BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Form(
              key: _formKey,
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.all(20),
                children: [
                  Text(_isEdit ? 'Edit Tax Profile' : 'Add Tax Profile', style: AppTypography.headline),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const Key('tax_profile_code_field'),
                    controller: _codeController,
                    enabled: !_isEdit,
                    decoration: const InputDecoration(labelText: 'Code (e.g. GST18-INCL)'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Code is required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('tax_profile_description_field'),
                    controller: _descriptionController,
                    decoration: const InputDecoration(labelText: 'Description'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Description is required' : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const Key('tax_profile_supply_type_field'),
                    initialValue: _supplyType,
                    decoration: const InputDecoration(labelText: 'Supply Type'),
                    items: _supplyTypes.map((t) => DropdownMenuItem(value: t, child: Text(_supplyTypeLabel(t)))).toList(),
                    onChanged: (v) => setState(() => _supplyType = v ?? _supplyType),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          key: const Key('tax_profile_cgst_field'),
                          controller: _cgstController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'CGST %'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextFormField(
                          key: const Key('tax_profile_sgst_field'),
                          controller: _sgstController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'SGST %'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          key: const Key('tax_profile_igst_field'),
                          controller: _igstController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'IGST %'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextFormField(
                          key: const Key('tax_profile_cess_field'),
                          controller: _cessController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'CESS %'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _priceInclusive ? AppColors.infoContainer : AppColors.surfaceSecondary,
                      borderRadius: AppDecorations.borderRadiusMd,
                    ),
                    child: SwitchListTile(
                      key: const Key('tax_profile_price_inclusive_switch'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Price Includes GST', style: TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        _priceInclusive
                            ? 'Selling price already has GST baked in — tax is backed out of it, never added on top.'
                            : 'Selling price is before GST — tax is added on top at billing (default).',
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: _priceInclusive,
                      onChanged: (v) => setState(() => _priceInclusive = v),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const Key('tax_profile_save_button'),
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? 'Saving…' : (_isEdit ? 'Save Changes' : 'Create Tax Profile')),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
