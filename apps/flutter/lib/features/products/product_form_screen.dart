import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import 'product_admin_api.dart';

/// Create-or-edit form for a master product. Passing `existing` switches the
/// screen into edit mode: SKU becomes read-only (it is the immutable
/// business key referenced by every historical invoice/batch/GRN line — see
/// product.repository.Update's doc comment) and the submit action calls
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
        _error = 'Failed to load form options: ${e.message}';
        _loadingOptions = false;
      });
    }
  }

  Decimal? _parseDecimal(String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : Decimal.tryParse(trimmed);
  }

  void _addBarcode() {
    final value = _barcodeInputController.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _barcodes.add(value);
      _barcodeInputController.clear();
    });
  }

  void _addAlias() {
    final value = _aliasInputController.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _aliases.add(value);
      _aliasInputController.clear();
    });
  }

  Future<void> _save() async {
    if (!_isEdit && _skuController.text.trim().isEmpty) {
      setState(() => _error = 'SKU is required');
      return;
    }
    if (_nameController.text.trim().isEmpty) {
      setState(() => _error = 'Name is required');
      return;
    }
    if (_saleUomId == null || _purchaseUomId == null || _baseUomId == null) {
      setState(() => _error = 'Sale, purchase, and base UOM are all required');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final draft = ProductDetail(
      id: widget.existing?.id ?? '',
      sku: _skuController.text.trim(),
      name: _nameController.text.trim(),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: Text(_isEdit ? 'Edit Product' : 'Add Product', style: AppTypography.headline)),
      body: _loadingOptions
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null) ...[
                  Text(_error!, style: const TextStyle(color: AppColors.danger)),
                  const SizedBox(height: 12),
                ],
                TextField(
                  key: const Key('product_form_sku_field'),
                  controller: _skuController,
                  enabled: !_isEdit,
                  decoration: InputDecoration(
                    labelText: 'SKU',
                    helperText: _isEdit ? 'SKU cannot be changed after creation' : null,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('product_form_name_field'),
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('product_form_local_name_field'),
                  controller: _localNameController,
                  decoration: const InputDecoration(labelText: 'Local name (Tamil, optional)'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('product_form_category_dropdown'),
                  initialValue: _categoryId,
                  decoration: const InputDecoration(labelText: 'Category (optional)'),
                  items: _categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.label))).toList(),
                  onChanged: (v) => setState(() => _categoryId = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('product_form_brand_dropdown'),
                  initialValue: _brandId,
                  decoration: const InputDecoration(labelText: 'Brand (optional)'),
                  items: _brands.map((b) => DropdownMenuItem(value: b.id, child: Text(b.label))).toList(),
                  onChanged: (v) => setState(() => _brandId = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('product_form_product_type_dropdown'),
                  initialValue: _productType,
                  decoration: const InputDecoration(labelText: 'Product type'),
                  items: _productTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                  onChanged: (v) => setState(() => _productType = v ?? 'FEED'),
                ),
                const Divider(height: 32),
                Text('Units of measure', style: AppTypography.title),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  key: const Key('product_form_sale_uom_dropdown'),
                  initialValue: _saleUomId,
                  decoration: const InputDecoration(labelText: 'Default sale UOM'),
                  items: _uoms.map((u) => DropdownMenuItem(value: u.id, child: Text(u.label))).toList(),
                  onChanged: (v) => setState(() => _saleUomId = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('product_form_purchase_uom_dropdown'),
                  initialValue: _purchaseUomId,
                  decoration: const InputDecoration(labelText: 'Default purchase UOM'),
                  items: _uoms.map((u) => DropdownMenuItem(value: u.id, child: Text(u.label))).toList(),
                  onChanged: (v) => setState(() => _purchaseUomId = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('product_form_base_uom_dropdown'),
                  initialValue: _baseUomId,
                  decoration: const InputDecoration(labelText: 'Base inventory UOM'),
                  items: _uoms.map((u) => DropdownMenuItem(value: u.id, child: Text(u.label))).toList(),
                  onChanged: (v) => setState(() => _baseUomId = v),
                ),
                const Divider(height: 32),
                Text('Tax & pricing', style: AppTypography.title),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('product_form_hsn_field'),
                  controller: _hsnController,
                  decoration: const InputDecoration(labelText: 'HSN code (optional)'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('product_form_tax_profile_dropdown'),
                  initialValue: _taxProfileId,
                  decoration: const InputDecoration(labelText: 'Tax profile (optional)'),
                  items: _taxProfiles.map((t) => DropdownMenuItem(value: t.id, child: Text(t.label))).toList(),
                  onChanged: (v) => setState(() => _taxProfileId = v),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('product_form_mrp_field'),
                        controller: _mrpController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'MRP (₹, optional)'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const Key('product_form_selling_price_field'),
                        controller: _priceController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Selling price (₹, optional)'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('product_form_min_price_floor_field'),
                  controller: _minPriceFloorController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Minimum price floor (₹, optional)'),
                ),
                const Divider(height: 32),
                Text('Pack & reorder', style: AppTypography.title),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('product_form_pack_size_field'),
                        controller: _packSizeController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Pack size (optional)'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const Key('product_form_weight_field'),
                        controller: _weightController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Standard weight (kg, optional)'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('product_form_reorder_level_field'),
                        controller: _reorderLevelController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Reorder level (optional)'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const Key('product_form_reorder_target_field'),
                        controller: _reorderTargetController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Reorder target (optional)'),
                      ),
                    ),
                  ],
                ),
                const Divider(height: 32),
                Text('Handling flags', style: AppTypography.title),
                SwitchListTile(
                  key: const Key('product_form_batch_required_switch'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Batch tracking required'),
                  value: _batchRequired,
                  onChanged: (v) => setState(() => _batchRequired = v),
                ),
                SwitchListTile(
                  key: const Key('product_form_expiry_required_switch'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Expiry date required'),
                  value: _expiryRequired,
                  onChanged: (v) => setState(() => _expiryRequired = v),
                ),
                SwitchListTile(
                  key: const Key('product_form_loose_sale_switch'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Loose sale allowed'),
                  value: _looseSaleAllowed,
                  onChanged: (v) => setState(() => _looseSaleAllowed = v),
                ),
                SwitchListTile(
                  key: const Key('product_form_scale_required_switch'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Weighing scale required'),
                  value: _scaleRequired,
                  onChanged: (v) => setState(() => _scaleRequired = v),
                ),
                const Divider(height: 32),
                Text('Barcodes', style: AppTypography.title),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('product_form_barcode_input'),
                        controller: _barcodeInputController,
                        decoration: const InputDecoration(labelText: 'Add a barcode'),
                        onSubmitted: (_) => _addBarcode(),
                      ),
                    ),
                    IconButton(
                      key: const Key('product_form_add_barcode_button'),
                      icon: const Icon(Icons.add_circle, color: AppColors.primary),
                      onPressed: _addBarcode,
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: List.generate(_barcodes.length, (i) {
                    return Chip(
                      key: Key('product_form_barcode_chip_$i'),
                      label: Text(_barcodes[i]),
                      onDeleted: () => setState(() => _barcodes.removeAt(i)),
                    );
                  }),
                ),
                const SizedBox(height: 16),
                Text('Aliases (Tamil / colloquial names)', style: AppTypography.title),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('product_form_alias_input'),
                        controller: _aliasInputController,
                        decoration: const InputDecoration(labelText: 'Add an alias'),
                        onSubmitted: (_) => _addAlias(),
                      ),
                    ),
                    IconButton(
                      key: const Key('product_form_add_alias_button'),
                      icon: const Icon(Icons.add_circle, color: AppColors.primary),
                      onPressed: _addAlias,
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: List.generate(_aliases.length, (i) {
                    return Chip(
                      key: Key('product_form_alias_chip_$i'),
                      label: Text(_aliases[i]),
                      onDeleted: () => setState(() => _aliases.removeAt(i)),
                    );
                  }),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('product_form_save_button'),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_isEdit ? 'Save Changes' : 'Create Product'),
                ),
              ],
            ),
    );
  }
}
