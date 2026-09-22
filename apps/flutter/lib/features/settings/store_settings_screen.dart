import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'store_settings_api.dart';

/// Server-side cap on the stored data URI length (settings.maxLogoDataURILen
/// server-side) — enforced client-side too so a rejected upload fails
/// immediately with a clear message instead of round-tripping to the API.
const _maxLogoBytes = 1100000;

/// The shop profile screen every tenant needs before going live: legal/
/// trade name, GSTIN, FSSAI license, contact, address, invoice number
/// prefix, and receipt header/footer text.
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

  /// The logo actually persisted server-side, as loaded — used to detect
  /// whether the pending edit below is a genuine change worth showing a
  /// "Remove" affordance for.
  String? _savedLogoDataUri;
  /// Pending edit: null means "no change to the saved logo", an empty
  /// string means "remove the logo on next save", anything else is a new
  /// data: URI staged from a freshly picked image.
  String? _pendingLogoDataUri;

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
    _savedLogoDataUri = p.logoDataUri;
    _pendingLogoDataUri = null;
  }

  /// The logo that should actually be shown in the preview right now: a
  /// freshly picked image, an explicit removal, or whatever is already
  /// saved — in that priority order.
  String? get _effectiveLogoDataUri {
    if (_pendingLogoDataUri == null) return _savedLogoDataUri;
    return _pendingLogoDataUri!.isEmpty ? null : _pendingLogoDataUri;
  }

  Future<void> _pickLogo() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      final files = result?.files;
      if (files == null || files.isEmpty) return;
      final picked = files.first;
      if (picked.bytes == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read that file — please try a different image')),
        );
        return;
      }

      if (picked.bytes!.length > _maxLogoBytes) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Logo image is too large — please use one under ~800KB')),
        );
        return;
      }

      final ext = (picked.extension ?? '').toLowerCase();
      final mimeType = switch (ext) {
        'png' => 'image/png',
        'jpg' || 'jpeg' => 'image/jpeg',
        'webp' => 'image/webp',
        _ => null,
      };
      if (mimeType == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please choose a PNG, JPEG, or WEBP image')),
        );
        return;
      }

      setState(() => _pendingLogoDataUri = 'data:$mimeType;base64,${base64Encode(picked.bytes!)}');
    } catch (e, st) {
      // FilePicker's web implementation touches the DOM directly (creates
      // and clicks a hidden <input type=file>) — on some browsers/extension
      // combinations that can throw instead of just returning null. Never
      // let that vanish as a silent, unreported failure.
      debugPrint('StoreSettingsScreen._pickLogo failed: $e\n$st');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the file picker: $e')),
      );
    }
  }

  void _removeLogo() {
    setState(() => _pendingLogoDataUri = '');
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
    } catch (e, st) {
      // Anything other than ApiError (a bad response shape, a rendering
      // bug in _fillControllers, etc.) must still surface — silently
      // leaving _loading true forever renders as an unexplained frozen
      // spinner with only a console error, which is exactly what's
      // impossible for a user to report back usefully.
      debugPrint('StoreSettingsScreen._load failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _error = 'Unexpected error loading store settings: $e';
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
        logoDataUri: _effectiveLogoDataUri,
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
    } catch (e, st) {
      debugPrint('StoreSettingsScreen._save failed: $e\n$st');
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  Widget _sectionCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required Gradient iconGradient,
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppDecorations.borderRadiusLg,
        border: Border.all(color: AppColors.border),
        boxShadow: AppDecorations.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: iconGradient,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: iconColor.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Icon(icon, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppTypography.title.copyWith(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1, color: AppColors.border),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    Key? key,
    bool required = false,
    TextInputType? keyboardType,
    int maxLines = 1,
    IconData? prefixIcon,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        key: key,
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: required ? '$label *' : label,
          prefixIcon: prefixIcon != null ? Icon(prefixIcon, size: 18, color: AppColors.primary) : null,
          filled: true,
          fillColor: AppColors.surfaceSecondary,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
          ),
        ),
        validator: required ? (v) => (v == null || v.trim().isEmpty) ? '$label is required' : null : null,
      ),
    );
  }

  Widget _logoUploadRow() {
    final logo = _effectiveLogoDataUri;
    Uint8List? bytes;
    if (logo != null && logo.isNotEmpty) {
      try {
        bytes = base64Decode(logo.substring(logo.indexOf(',') + 1));
      } catch (_) {
        bytes = null;
      }
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          key: const Key('store_settings_logo_preview'),
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            color: AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: bytes != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(13),
                  child: Image.memory(bytes, fit: BoxFit.contain),
                )
              : const Icon(Icons.storefront_rounded, color: AppColors.textTertiary, size: 32),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'PNG, JPEG, or WEBP · shown on your invoice header and here in the app',
                style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    key: const Key('store_settings_upload_logo_button'),
                    onPressed: _pickLogo,
                    icon: const Icon(Icons.upload_rounded, size: 18),
                    label: Text(bytes != null ? 'Replace Logo' : 'Upload Logo'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      side: const BorderSide(color: AppColors.primary),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  if (bytes != null)
                    OutlinedButton.icon(
                      key: const Key('store_settings_remove_logo_button'),
                      onPressed: _removeLogo,
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      label: const Text('Remove'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.danger,
                        side: const BorderSide(color: AppColors.danger),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Store Settings', style: AppTypography.headline),
      ),
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
                      // Hero Header Banner
                      Container(
                        padding: const EdgeInsets.all(20),
                        margin: const EdgeInsets.only(bottom: 20),
                        decoration: BoxDecoration(
                          gradient: AppColors.gradientHeroMesh,
                          borderRadius: AppDecorations.borderRadiusLg,
                          boxShadow: AppDecorations.emeraldGlow,
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                              ),
                              child: const Icon(Icons.storefront_rounded, color: Colors.white, size: 28),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Store & Brand Profile',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.3,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Manage legal entity, tax GSTIN, address & receipt branding',
                                    style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      // 1. Logo Section
                      _sectionCard(
                        title: 'Store Logo',
                        subtitle: 'Printed on the invoice PDF and shown in the app header',
                        icon: Icons.image_rounded,
                        iconColor: const Color(0xFF7C3AED),
                        iconGradient: AppColors.gradientPurple,
                        children: [_logoUploadRow()],
                      ),

                      // 2. Shop Identity Section
                      _sectionCard(
                        title: 'Shop Identity & Tax',
                        subtitle: 'Legal names and statutory registration licenses',
                        icon: Icons.business_rounded,
                        iconColor: AppColors.primary,
                        iconGradient: AppColors.gradientEmerald,
                        children: [
                          _field(
                            _legalNameCtrl,
                            'Legal Name',
                            key: const Key('store_settings_legal_name'),
                            required: true,
                            prefixIcon: Icons.badge_rounded,
                          ),
                          _field(_tradeNameCtrl, 'Trade Name', prefixIcon: Icons.store_rounded),
                          _field(_gstinCtrl, 'GSTIN', prefixIcon: Icons.receipt_rounded),
                          _field(_fssaiCtrl, 'FSSAI License No.', prefixIcon: Icons.verified_rounded),
                        ],
                      ),

                      // 3. Contact Section
                      _sectionCard(
                        title: 'Contact Information',
                        subtitle: 'Store phone and customer care communications',
                        icon: Icons.contact_phone_rounded,
                        iconColor: AppColors.secondary,
                        iconGradient: AppColors.gradientIndigo,
                        children: [
                          _field(_phoneCtrl, 'Phone', keyboardType: TextInputType.phone, prefixIcon: Icons.phone_rounded),
                          _field(_emailCtrl, 'Email', keyboardType: TextInputType.emailAddress, prefixIcon: Icons.email_rounded),
                        ],
                      ),

                      // 4. Address Section
                      _sectionCard(
                        title: 'Store Location & Address',
                        subtitle: 'Physical outlet address printed on tax invoices',
                        icon: Icons.location_on_rounded,
                        iconColor: AppColors.accent,
                        iconGradient: AppColors.gradientCyan,
                        children: [
                          _field(_addressLine1Ctrl, 'Address Line 1', required: true, prefixIcon: Icons.home_rounded),
                          _field(_addressLine2Ctrl, 'Address Line 2', prefixIcon: Icons.location_city_rounded),
                          _field(_cityCtrl, 'City', required: true, prefixIcon: Icons.apartment_rounded),
                          _field(_districtCtrl, 'District', prefixIcon: Icons.map_rounded),
                          _field(_stateCodeCtrl, 'State Code', required: true, prefixIcon: Icons.flag_rounded),
                          _field(_postalCodeCtrl, 'Postal Code', keyboardType: TextInputType.number, prefixIcon: Icons.markunread_mailbox_rounded),
                        ],
                      ),

                      // 5. Billing Configuration
                      _sectionCard(
                        title: 'Billing & Invoice Prefix',
                        subtitle: 'Sequential invoice numbering prefix',
                        icon: Icons.receipt_long_rounded,
                        iconColor: AppColors.warning,
                        iconGradient: AppColors.gradientAmber,
                        children: [
                          _field(
                            _invoicePrefixCtrl,
                            'Invoice Prefix',
                            key: const Key('store_settings_invoice_prefix'),
                            required: true,
                            prefixIcon: Icons.confirmation_number_rounded,
                          ),
                        ],
                      ),

                      // 6. Receipt Text
                      _sectionCard(
                        title: 'Receipt Header & Footer',
                        subtitle: 'Custom greetings and terms printed on physical slips',
                        icon: Icons.print_rounded,
                        iconColor: const Color(0xFF7C3AED),
                        iconGradient: AppColors.gradientPurple,
                        children: [
                          _field(_receiptHeaderCtrl, 'Receipt Header', maxLines: 2, prefixIcon: Icons.notes_rounded),
                          _field(_receiptFooterCtrl, 'Receipt Footer', maxLines: 2, prefixIcon: Icons.favorite_rounded),
                        ],
                      ),

                      const SizedBox(height: 10),

                      // Save Action Button
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: AppDecorations.emeraldGlow,
                        ),
                        child: FilledButton(
                          key: const Key('store_settings_save_button'),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          onPressed: _saving ? null : _save,
                          child: _saving
                              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.save_rounded, size: 20),
                                    SizedBox(width: 8),
                                    Text('Save Store Settings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                  ],
                                ),
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
    );
  }
}
