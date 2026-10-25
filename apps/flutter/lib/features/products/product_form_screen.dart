import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_decorations.dart';
import '../../core/theme/app_typography.dart';
import 'product_admin_api.dart';

/// Create-or-edit form for a master product. Passing `existing` switches the
/// screen into edit mode: SKU becomes read-only and the submit action calls
/// Update instead of Create. Pops `true` on a successful save so the caller
/// knows to refresh its list.
class ProductFormScreen extends StatefulWidget {
  final ProductDetail? existing;

  const ProductFormScreen({super.key, this.existing});

  @override
  State<ProductFormScreen> createState() => _ProductFormScreenState();
}

class _ProductFormScreenState extends State<ProductFormScreen> {
  static const _productTypes = ['FEED', 'SUPPLEMENT', 'ADDITIVE', 'SERVICE', 'OTHER'];

  final _skuController = TextEditingController();
  final _nameController = TextEditingController();
  final _localNameController = TextEditingController();
  final _hsnController = TextEditingController();
  final _packSizeController = TextEditingController();
  final _weightController = TextEditingController();
  final _mrpController = TextEditingController();
  final _priceController = TextEditingController();
  final _reorderLevelController = TextEditingController();
  final _reorderTargetController = TextEditingController();
  final _minPriceFloorController = TextEditingController();
  final _barcodeInputController = TextEditingController();
  final _aliasInputController = TextEditingController();

  String? _categoryId;
  String? _brandId;
  String? _saleUomId;
  String? _purchaseUomId;
  String? _baseUomId;
  String? _taxProfileId;
  String _productType = 'FEED';
  bool _batchRequired = true;
  bool _expiryRequired = false;
  bool _looseSaleAllowed = false;
  bool _scaleRequired = false;
  bool _stockAlertEnabled = true;
  final List<String> _barcodes = [];
  final List<String> _aliases = [];

  List<MasterDataOption> _categories = [];
  List<MasterDataOption> _brands = [];
  List<MasterDataOption> _uoms = [];
  List<MasterDataOption> _taxProfiles = [];

  bool _loadingOptions = true;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _skuController.text = e.sku;
      _nameController.text = e.name;
      _localNameController.text = e.localNameTa ?? '';
      _hsnController.text = e.hsnCode ?? '';
      _packSizeController.text = e.packSize?.toString() ?? '';
      _weightController.text = e.standardWeightKg?.toString() ?? '';
      _mrpController.text = e.mrp?.toStringAsFixed(2) ?? '';
      _priceController.text = e.sellingPrice?.toStringAsFixed(2) ?? '';
      _reorderLevelController.text = e.reorderLevel?.toString() ?? '';
      _reorderTargetController.text = e.reorderTarget?.toString() ?? '';
      _minPriceFloorController.text = e.minPriceFloor?.toStringAsFixed(2) ?? '';
      _categoryId = e.categoryId;
      _brandId = e.brandId;
      _saleUomId = e.defaultSaleUomId;
      _purchaseUomId = e.defaultPurchaseUomId;
      _baseUomId = e.baseInventoryUomId;
      _taxProfileId = e.taxProfileId;
      _productType = e.productType;
      _batchRequired = e.batchRequired;
      _expiryRequired = e.expiryRequired;
      _looseSaleAllowed = e.looseSaleAllowed;
      _scaleRequired = e.scaleRequired;
      _stockAlertEnabled = e.stockAlertEnabled;
      _barcodes.addAll(e.barcodes);
      _aliases.addAll(e.aliases);
    }
    _loadOptions();
  }

  @override
  void dispose() {
    for (final c in [
      _skuController,
      _nameController,
      _localNameController,
      _hsnController,
      _packSizeController,
      _weightController,
      _mrpController,
      _priceController,
      _reorderLevelController,
      _reorderTargetController,
      _minPriceFloorController,
      _barcodeInputController,
      _aliasInputController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadOptions() async {
    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      final results = await Future.wait([
        api.listCategories(),
        api.listBrands(),
        api.listUoms(),
        api.listTaxProfiles(),
      ]);
      if (!mounted) return;
      setState(() {
        _categories = results[0];
        _brands = results[1];
        _uoms = results[2];
        _taxProfiles = results[3];
        _loadingOptions = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loadingOptions = false;
      });
    }
  }

  Decimal? _parseDecimal(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    return Decimal.tryParse(trimmed);
  }

  void _addBarcode() {
    final val = _barcodeInputController.text.trim();
    if (val.isEmpty || _barcodes.contains(val)) return;
    setState(() {
      _barcodes.add(val);
      _barcodeInputController.clear();
    });
  }

  void _addAlias() {
    final val = _aliasInputController.text.trim();
    if (val.isEmpty || _aliases.contains(val)) return;
    setState(() {
      _aliases.add(val);
      _aliasInputController.clear();
    });
  }

  Future<void> _save() async {
    setState(() {
      _error = null;
      _saving = true;
    });

    final sku = _skuController.text.trim();
    final name = _nameController.text.trim();

    if (sku.isEmpty) {
      setState(() {
        _error = 'SKU is required';
        _saving = false;
      });
      return;
    }
    if (name.isEmpty) {
      setState(() {
        _error = 'Product name is required';
        _saving = false;
      });
      return;
    }
    if (_saleUomId == null || _purchaseUomId == null || _baseUomId == null) {
      setState(() {
        _error = 'Default sale, purchase, and base UOMs are all required';
        _saving = false;
      });
      return;
    }
    if (_taxProfileId == null) {
      setState(() {
        _error = 'Tax profile is required — a product with no tax profile cannot be quoted or sold at the counter';
        _saving = false;
      });
      return;
    }

    final draft = ProductDetail(
      id: widget.existing?.id ?? '',
      sku: sku,
      name: name,
      localNameTa: _localNameController.text.trim().isEmpty ? null : _localNameController.text.trim(),
      categoryId: _categoryId,
      brandId: _brandId,
      defaultSaleUomId: _saleUomId!,
      defaultPurchaseUomId: _purchaseUomId!,
      baseInventoryUomId: _baseUomId!,
      hsnCode: _hsnController.text.trim().isEmpty ? null : _hsnController.text.trim(),
      taxProfileId: _taxProfileId,
      packSize: _parseDecimal(_packSizeController.text),
      standardWeightKg: _parseDecimal(_weightController.text),
      mrp: _parseDecimal(_mrpController.text),
      sellingPrice: _parseDecimal(_priceController.text),
      reorderLevel: _parseDecimal(_reorderLevelController.text),
      reorderTarget: _parseDecimal(_reorderTargetController.text),
      minPriceFloor: _parseDecimal(_minPriceFloorController.text),
      batchRequired: _batchRequired,
      expiryRequired: _expiryRequired,
      looseSaleAllowed: _looseSaleAllowed,
      scaleRequired: _scaleRequired,
      productType: _productType,
      active: widget.existing?.active ?? true,
      stockAlertEnabled: _stockAlertEnabled,
      barcodes: _barcodes,
      aliases: _aliases,
    );

    try {
      final api = ProductAdminApi(context.read<ApiClient>());
      if (_isEdit) {
        await api.update(widget.existing!.id, draft);
      } else {
        await api.create(draft);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    }
  }

  Widget _sectionCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required LinearGradient iconGradient,
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

  InputDecoration _fieldDecoration(String label, {IconData? prefixIcon, String? helperText}) {
    return InputDecoration(
      labelText: label,
      helperText: helperText,
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
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.border.withValues(alpha: 0.5)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Product' : 'Add Product', style: AppTypography.headline),
      ),
      body: _loadingOptions
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : ListView(
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
                        child: Icon(
                          _isEdit ? Icons.edit_note_rounded : Icons.add_box_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _isEdit ? 'Update Product Details' : 'Register New Master Product',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _isEdit
                                  ? 'Update pricing, barcodes, reorder rules & handling flags'
                                  : 'Specify SKU, units of measure, tax profile & initial pricing',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                if (_error != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.dangerContainer,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 20),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_error!, style: const TextStyle(color: AppColors.danger))),
                      ],
                    ),
                  ),

                // 1. Product Identity Section
                _sectionCard(
                  title: 'Product Identity & Classification',
                  subtitle: 'SKU identifier, product name and catalog grouping',
                  icon: Icons.badge_rounded,
                  iconColor: AppColors.primary,
                  iconGradient: AppColors.gradientEmerald,
                  children: [
                    TextField(
                      key: const Key('product_form_sku_field'),
                      controller: _skuController,
                      enabled: !_isEdit,
                      decoration: _fieldDecoration(
                        'SKU',
                        prefixIcon: Icons.qr_code_rounded,
                        helperText: _isEdit ? 'SKU cannot be changed after creation' : null,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      key: const Key('product_form_name_field'),
                      controller: _nameController,
                      decoration: _fieldDecoration('Name', prefixIcon: Icons.label_rounded),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      key: const Key('product_form_local_name_field'),
                      controller: _localNameController,
                      decoration: _fieldDecoration('Local name (Tamil, optional)', prefixIcon: Icons.translate_rounded),
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      key: const Key('product_form_category_dropdown'),
                      initialValue: _categoryId,
                      decoration: _fieldDecoration('Category (optional)', prefixIcon: Icons.category_rounded),
                      items: _categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.label))).toList(),
                      onChanged: (v) => setState(() => _categoryId = v),
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      key: const Key('product_form_brand_dropdown'),
                      initialValue: _brandId,
                      decoration: _fieldDecoration('Brand (optional)', prefixIcon: Icons.branding_watermark_rounded),
                      items: _brands.map((b) => DropdownMenuItem(value: b.id, child: Text(b.label))).toList(),
                      onChanged: (v) => setState(() => _brandId = v),
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      key: const Key('product_form_product_type_dropdown'),
                      initialValue: _productType,
                      decoration: _fieldDecoration('Product type', prefixIcon: Icons.layers_rounded),
                      items: _productTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                      onChanged: (v) => setState(() => _productType = v ?? 'FEED'),
                    ),
                  ],
                ),

                // 2. Units of Measure Section
                _sectionCard(
                  title: 'Units of Measure (UOM)',
                  subtitle: 'Units for sale, purchase receiving and base inventory conversion',
                  icon: Icons.straighten_rounded,
                  iconColor: AppColors.secondary,
                  iconGradient: AppColors.gradientIndigo,
                  children: [
                    DropdownButtonFormField<String>(
                      key: const Key('product_form_sale_uom_dropdown'),
                      initialValue: _saleUomId,
                      decoration: _fieldDecoration('Default sale UOM', prefixIcon: Icons.point_of_sale_rounded),
                      items: _uoms.map((u) => DropdownMenuItem(value: u.id, child: Text(u.label))).toList(),
                      onChanged: (v) => setState(() => _saleUomId = v),
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      key: const Key('product_form_purchase_uom_dropdown'),
                      initialValue: _purchaseUomId,
                      decoration: _fieldDecoration('Default purchase UOM', prefixIcon: Icons.shopping_cart_rounded),
                      items: _uoms.map((u) => DropdownMenuItem(value: u.id, child: Text(u.label))).toList(),
                      onChanged: (v) => setState(() => _purchaseUomId = v),
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      key: const Key('product_form_base_uom_dropdown'),
                      initialValue: _baseUomId,
                      decoration: _fieldDecoration('Base inventory UOM', prefixIcon: Icons.scale_rounded),
                      items: _uoms.map((u) => DropdownMenuItem(value: u.id, child: Text(u.label))).toList(),
                      onChanged: (v) => setState(() => _baseUomId = v),
                    ),
                  ],
                ),

                // 3. Tax & Pricing Section
                _sectionCard(
                  title: 'Tax & Pricing Strategy',
                  subtitle: 'HSN code, tax profile rates, retail prices and minimum price cap',
                  icon: Icons.payments_rounded,
                  iconColor: AppColors.warning,
                  iconGradient: AppColors.gradientAmber,
                  children: [
                    TextField(
                      key: const Key('product_form_hsn_field'),
                      controller: _hsnController,
                      decoration: _fieldDecoration('HSN code (optional)', prefixIcon: Icons.receipt_long_rounded),
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      key: const Key('product_form_tax_profile_dropdown'),
                      initialValue: _taxProfileId,
                      decoration: _fieldDecoration('Tax profile *', prefixIcon: Icons.percent_rounded).copyWith(
                        helperText: 'Required — a product can\'t be billed at the counter without one',
                        helperMaxLines: 2,
                      ),
                      items: _taxProfiles.map((t) => DropdownMenuItem(value: t.id, child: Text(t.label))).toList(),
                      onChanged: (v) => setState(() => _taxProfileId = v),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('product_form_mrp_field'),
                            controller: _mrpController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: _fieldDecoration('MRP (₹, optional)', prefixIcon: Icons.currency_rupee_rounded),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            key: const Key('product_form_selling_price_field'),
                            controller: _priceController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: _fieldDecoration('Selling price (₹, optional)', prefixIcon: Icons.sell_rounded),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      key: const Key('product_form_min_price_floor_field'),
                      controller: _minPriceFloorController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: _fieldDecoration('Minimum price floor (₹, optional)', prefixIcon: Icons.shield_rounded),
                    ),
                  ],
                ),

                // 4. Pack & Reorder Section
                _sectionCard(
                  title: 'Pack & Reorder Thresholds',
                  subtitle: 'Physical dimensions and automated restocking replenishment points',
                  icon: Icons.inventory_2_rounded,
                  iconColor: AppColors.accent,
                  iconGradient: AppColors.gradientCyan,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('product_form_pack_size_field'),
                            controller: _packSizeController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: _fieldDecoration('Pack size (optional)', prefixIcon: Icons.unarchive_rounded),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            key: const Key('product_form_weight_field'),
                            controller: _weightController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: _fieldDecoration('Standard weight (kg)', prefixIcon: Icons.fitness_center_rounded),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('product_form_reorder_level_field'),
                            controller: _reorderLevelController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: _fieldDecoration('Reorder level (optional)', prefixIcon: Icons.trending_down_rounded),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            key: const Key('product_form_reorder_target_field'),
                            controller: _reorderTargetController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: _fieldDecoration('Reorder target (optional)', prefixIcon: Icons.trending_up_rounded),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: SwitchListTile(
                        key: const Key('product_form_stock_alert_switch'),
                        contentPadding: EdgeInsets.zero,
                        activeColor: AppColors.primary,
                        title: const Text('Low/out-of-stock alerts', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        subtitle: const Text(
                          'When off, this product is excluded from the dashboard\'s '
                          'stock alert banner and the Stock Management screen\'s '
                          'counts — its real stock level still shows everywhere.',
                          style: TextStyle(fontSize: 12),
                        ),
                        value: _stockAlertEnabled,
                        onChanged: (v) => setState(() => _stockAlertEnabled = v),
                      ),
                    ),
                  ],
                ),

                // 5. Handling Flags Section
                _sectionCard(
                  title: 'Handling & POS Compliance',
                  subtitle: 'Mandatory checkout checks: batch number, expiry date and scale weights',
                  icon: Icons.tune_rounded,
                  iconColor: const Color(0xFF7C3AED),
                  iconGradient: AppColors.gradientPurple,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.surfaceSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(
                        children: [
                          SwitchListTile(
                            key: const Key('product_form_batch_required_switch'),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                            activeColor: AppColors.primary,
                            title: const Text('Batch tracking required', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                            value: _batchRequired,
                            onChanged: (v) => setState(() => _batchRequired = v),
                          ),
                          const Divider(height: 1, color: AppColors.border),
                          SwitchListTile(
                            key: const Key('product_form_expiry_required_switch'),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                            activeColor: AppColors.primary,
                            title: const Text('Expiry date required', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                            value: _expiryRequired,
                            onChanged: (v) => setState(() => _expiryRequired = v),
                          ),
                          const Divider(height: 1, color: AppColors.border),
                          SwitchListTile(
                            key: const Key('product_form_loose_sale_switch'),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                            activeColor: AppColors.primary,
                            title: const Text('Loose sale allowed', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                            value: _looseSaleAllowed,
                            onChanged: (v) => setState(() => _looseSaleAllowed = v),
                          ),
                          const Divider(height: 1, color: AppColors.border),
                          SwitchListTile(
                            key: const Key('product_form_scale_required_switch'),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                            activeColor: AppColors.primary,
                            title: const Text('Weighing scale required', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                            value: _scaleRequired,
                            onChanged: (v) => setState(() => _scaleRequired = v),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                // 6. Barcodes & Aliases Section
                _sectionCard(
                  title: 'Barcodes & Search Aliases',
                  subtitle: 'Scan codes and colloquial Tamil keywords for instant POS finding',
                  icon: Icons.qr_code_2_rounded,
                  iconColor: AppColors.primary,
                  iconGradient: AppColors.gradientEmerald,
                  children: [
                    Text('Barcodes', style: AppTypography.title.copyWith(fontSize: 14)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('product_form_barcode_input'),
                            controller: _barcodeInputController,
                            decoration: _fieldDecoration('Add a barcode', prefixIcon: Icons.qr_code_scanner_rounded),
                            onSubmitted: (_) => _addBarcode(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          key: const Key('product_form_add_barcode_button'),
                          icon: const Icon(Icons.add_rounded, color: Colors.white),
                          style: IconButton.styleFrom(backgroundColor: AppColors.primary),
                          onPressed: _addBarcode,
                        ),
                      ],
                    ),
                    if (_barcodes.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: List.generate(_barcodes.length, (i) {
                          return Chip(
                            key: Key('product_form_barcode_chip_$i'),
                            avatar: const Icon(Icons.qr_code_rounded, size: 16),
                            label: Text(_barcodes[i], style: const TextStyle(fontWeight: FontWeight.bold)),
                            backgroundColor: AppColors.surfaceSecondary,
                            side: const BorderSide(color: AppColors.border),
                            onDeleted: () => setState(() => _barcodes.removeAt(i)),
                          );
                        }),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Text('Aliases (Tamil / colloquial names)', style: AppTypography.title.copyWith(fontSize: 14)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('product_form_alias_input'),
                            controller: _aliasInputController,
                            decoration: _fieldDecoration('Add an alias', prefixIcon: Icons.translate_rounded),
                            onSubmitted: (_) => _addAlias(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          key: const Key('product_form_add_alias_button'),
                          icon: const Icon(Icons.add_rounded, color: Colors.white),
                          style: IconButton.styleFrom(backgroundColor: AppColors.primary),
                          onPressed: _addAlias,
                        ),
                      ],
                    ),
                    if (_aliases.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: List.generate(_aliases.length, (i) {
                          return Chip(
                            key: Key('product_form_alias_chip_$i'),
                            label: Text(_aliases[i]),
                            backgroundColor: AppColors.surfaceSecondary,
                            side: const BorderSide(color: AppColors.border),
                            onDeleted: () => setState(() => _aliases.removeAt(i)),
                          );
                        }),
                      ),
                    ],
                  ],
                ),

                const SizedBox(height: 8),

                // Save Action Button
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: AppDecorations.emeraldGlow,
                  ),
                  child: FilledButton(
                    key: const Key('product_form_save_button'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.save_rounded, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                _isEdit ? 'Save Changes' : 'Create Product',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                            ],
                          ),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}
