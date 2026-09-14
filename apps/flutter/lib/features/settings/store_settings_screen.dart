import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import 'store_settings_api.dart';

/// The shop profile screen every tenant needs before going live: legal/
/// trade name, GSTIN, FSSAI license, contact, address, invoice number
/// prefix, and receipt header/footer text. Before this screen existed, none
/// of it was editable from the app — onboarding a real tenant required a
/// raw SQL UPDATE against the tenants table.
class StoreSettingsScreen extends StatefulWidget {
  const StoreSettingsScreen({super.key});

  @override
  State<StoreSettingsScreen> createState() => _StoreSettingsScreenState();
}

class _StoreSettingsScreenState extends State<StoreSettingsScreen> {
  final _formKey = GlobalKey<FormState>();

  final _legalNameCtrl = TextEditingController();
  final _tradeNameCtrl = TextEditingController();
  final _gstinCtrl = TextEditingController();
  final _fssaiCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _addressLine1Ctrl = TextEditingController();
  final _addressLine2Ctrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _districtCtrl = TextEditingController();
  final _stateCodeCtrl = TextEditingController();
  final _postalCodeCtrl = TextEditingController();
  final _invoicePrefixCtrl = TextEditingController();
  final _receiptHeaderCtrl = TextEditingController();
  final _receiptFooterCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _legalNameCtrl.dispose();
    _tradeNameCtrl.dispose();
    _gstinCtrl.dispose();
    _fssaiCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _addressLine1Ctrl.dispose();
    _addressLine2Ctrl.dispose();
    _cityCtrl.dispose();
    _districtCtrl.dispose();
    _stateCodeCtrl.dispose();
    _postalCodeCtrl.dispose();
    _invoicePrefixCtrl.dispose();
    _receiptHeaderCtrl.dispose();
    _receiptFooterCtrl.dispose();
    super.dispose();
  }

  void _fillControllers(StoreProfile p) {
    _legalNameCtrl.text = p.legalName;
    _tradeNameCtrl.text = p.tradeName ?? '';
    _gstinCtrl.text = p.gstin ?? '';
    _fssaiCtrl.text = p.fssaiLicenseNo ?? '';
    _phoneCtrl.text = p.phone ?? '';
    _emailCtrl.text = p.email ?? '';
    _addressLine1Ctrl.text = p.addressLine1;
    _addressLine2Ctrl.text = p.addressLine2 ?? '';
    _cityCtrl.text = p.city;
    _districtCtrl.text = p.district ?? '';
    _stateCodeCtrl.text = p.stateCode;
    _postalCodeCtrl.text = p.postalCode ?? '';
    _invoicePrefixCtrl.text = p.invoicePrefix;
    _receiptHeaderCtrl.text = p.receiptHeader ?? '';
    _receiptFooterCtrl.text = p.receiptFooter ?? '';
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = StoreSettingsApi(context.read<ApiClient>());
      final profile = await api.getStoreProfile();
      if (!mounted) return;
      _fillControllers(profile);
      setState(() => _loading = false);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  String? _blank(String value) => value.trim().isEmpty ? null : value.trim();

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final api = StoreSettingsApi(context.read<ApiClient>());
      final updated = StoreProfile(
        legalName: _legalNameCtrl.text.trim(),
        tradeName: _blank(_tradeNameCtrl.text),
        gstin: _blank(_gstinCtrl.text),
        fssaiLicenseNo: _blank(_fssaiCtrl.text),
        phone: _blank(_phoneCtrl.text),
        email: _blank(_emailCtrl.text),
        addressLine1: _addressLine1Ctrl.text.trim(),
        addressLine2: _blank(_addressLine2Ctrl.text),
        city: _cityCtrl.text.trim(),
        district: _blank(_districtCtrl.text),
        stateCode: _stateCodeCtrl.text.trim(),
        postalCode: _blank(_postalCodeCtrl.text),
        invoicePrefix: _invoicePrefixCtrl.text.trim(),
        receiptHeader: _blank(_receiptHeaderCtrl.text),
        receiptFooter: _blank(_receiptFooterCtrl.text),
      );
      final saved = await api.updateStoreProfile(updated);
      if (!mounted) return;
      _fillControllers(saved);
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Store settings saved')));
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(title, style: AppTypography.caption.copyWith(fontWeight: FontWeight.bold, letterSpacing: 0.8, color: AppColors.primary)),
      );

  Widget _field(
    TextEditingController controller,
    String label, {
    Key? key,
    bool required = false,
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        key: key,
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: required ? '$label *' : label, border: const OutlineInputBorder()),
        validator: required ? (v) => (v == null || v.trim().isEmpty) ? '$label is required' : null : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Store Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, style: AppTypography.body.copyWith(color: AppColors.danger)),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                )
              : Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _sectionHeader('SHOP IDENTITY'),
                      _field(_legalNameCtrl, 'Legal Name', key: const Key('store_settings_legal_name'), required: true),
                      _field(_tradeNameCtrl, 'Trade Name'),
                      _field(_gstinCtrl, 'GSTIN'),
                      _field(_fssaiCtrl, 'FSSAI License No.'),

                      _sectionHeader('CONTACT'),
                      _field(_phoneCtrl, 'Phone', keyboardType: TextInputType.phone),
                      _field(_emailCtrl, 'Email', keyboardType: TextInputType.emailAddress),

                      _sectionHeader('ADDRESS'),
                      _field(_addressLine1Ctrl, 'Address Line 1', required: true),
                      _field(_addressLine2Ctrl, 'Address Line 2'),
                      _field(_cityCtrl, 'City', required: true),
                      _field(_districtCtrl, 'District'),
                      _field(_stateCodeCtrl, 'State Code', required: true),
                      _field(_postalCodeCtrl, 'Postal Code', keyboardType: TextInputType.number),

                      _sectionHeader('BILLING'),
                      _field(_invoicePrefixCtrl, 'Invoice Prefix', key: const Key('store_settings_invoice_prefix'), required: true),

                      _sectionHeader('RECEIPT TEXT'),
                      _field(_receiptHeaderCtrl, 'Receipt Header', maxLines: 2),
                      _field(_receiptFooterCtrl, 'Receipt Footer', maxLines: 2),

                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          key: const Key('store_settings_save_button'),
                          onPressed: _saving ? null : _save,
                          child: _saving
                              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Text('Save'),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}
