import 'package:decimal/decimal.dart';

import '../../core/api_client.dart';

/// A single master product record with everything the create/edit form and
/// the read-only detail screen need — mirrors
/// services/api/internal/httpapi/product_handlers.go's productDetailResponse.
class ProductDetail {
  final String id;
  final String sku;
  final String name;
  final String? localNameTa;
  final String? categoryId;
  final String? brandId;
  final String defaultSaleUomId;
  final String defaultPurchaseUomId;
  final String baseInventoryUomId;
  final String? hsnCode;
  final String? taxProfileId;
  final Decimal? packSize;
  final Decimal? standardWeightKg;
  final Decimal? mrp;
  final Decimal? sellingPrice;
  final Decimal? reorderLevel;
  final Decimal? reorderTarget;
  final Decimal? minPriceFloor;
  final bool batchRequired;
  final bool expiryRequired;
  final bool looseSaleAllowed;
  final bool scaleRequired;
  final String productType;
  final bool active;
  final List<String> barcodes;
  final List<String> aliases;

  ProductDetail({
    required this.id,
    required this.sku,
    required this.name,
    this.localNameTa,
    this.categoryId,
    this.brandId,
    required this.defaultSaleUomId,
    required this.defaultPurchaseUomId,
    required this.baseInventoryUomId,
    this.hsnCode,
    this.taxProfileId,
    this.packSize,
    this.standardWeightKg,
    this.mrp,
    this.sellingPrice,
    this.reorderLevel,
    this.reorderTarget,
    this.minPriceFloor,
    required this.batchRequired,
    required this.expiryRequired,
    required this.looseSaleAllowed,
    required this.scaleRequired,
    required this.productType,
    required this.active,
    this.barcodes = const [],
    this.aliases = const [],
  });

  static Decimal? _decimalOrNull(dynamic v) {
    if (v == null || (v is String && v.isEmpty)) return null;
    return Decimal.parse(v as String);
  }

  static String? _stringOrNull(dynamic v) => (v == null || (v is String && v.isEmpty)) ? null : v as String;

  factory ProductDetail.fromJson(Map<String, dynamic> json) {
    return ProductDetail(
      id: json['id'] as String,
      sku: json['sku'] as String,
      name: json['name'] as String,
      localNameTa: _stringOrNull(json['local_name_ta']),
      categoryId: _stringOrNull(json['category_id']),
      brandId: _stringOrNull(json['brand_id']),
      defaultSaleUomId: json['default_sale_uom_id'] as String,
      defaultPurchaseUomId: json['default_purchase_uom_id'] as String,
      baseInventoryUomId: json['base_inventory_uom_id'] as String,
      hsnCode: _stringOrNull(json['hsn_code']),
      taxProfileId: _stringOrNull(json['tax_profile_id']),
      packSize: _decimalOrNull(json['pack_size']),
      standardWeightKg: _decimalOrNull(json['standard_weight_kg']),
      mrp: _decimalOrNull(json['mrp']),
      sellingPrice: _decimalOrNull(json['selling_price']),
      reorderLevel: _decimalOrNull(json['reorder_level']),
      reorderTarget: _decimalOrNull(json['reorder_target']),
      minPriceFloor: _decimalOrNull(json['min_price_floor']),
      batchRequired: json['batch_required'] as bool? ?? false,
      expiryRequired: json['expiry_required'] as bool? ?? false,
      looseSaleAllowed: json['loose_sale_allowed'] as bool? ?? false,
      scaleRequired: json['scale_required'] as bool? ?? false,
      productType: json['product_type'] as String? ?? 'FEED',
      active: json['active'] as bool? ?? true,
      barcodes: (json['barcodes'] as List<dynamic>? ?? []).cast<String>(),
      aliases: (json['aliases'] as List<dynamic>? ?? []).cast<String>(),
    );
  }

  Map<String, dynamic> toJson() {
    // Decimal.toString() strips trailing zeros ("1050.00" -> "1050"), which
    // is harmless for the server's own decimal.NewFromString parsing but
    // wrong for anything display-oriented or string-compared — the same
    // formatting class of bug documented repeatedly elsewhere in this app
    // (see IMPLEMENTATION_STATUS.md). Money fields always use
    // toStringAsFixed(2); quantity/weight fields (no fixed currency scale)
    // use plain toString().
    String? money(Decimal? d) => d?.toStringAsFixed(2);
    String? qty(Decimal? d) => d?.toString();
    return {
      'sku': sku,
      'name': name,
      if (localNameTa != null) 'local_name_ta': localNameTa,
      if (categoryId != null) 'category_id': categoryId,
      if (brandId != null) 'brand_id': brandId,
      'default_sale_uom_id': defaultSaleUomId,
      'default_purchase_uom_id': defaultPurchaseUomId,
      'base_inventory_uom_id': baseInventoryUomId,
      if (hsnCode != null) 'hsn_code': hsnCode,
      if (taxProfileId != null) 'tax_profile_id': taxProfileId,
      if (qty(packSize) != null) 'pack_size': qty(packSize),
      if (qty(standardWeightKg) != null) 'standard_weight_kg': qty(standardWeightKg),
      if (money(mrp) != null) 'mrp': money(mrp),
      if (money(sellingPrice) != null) 'selling_price': money(sellingPrice),
      if (qty(reorderLevel) != null) 'reorder_level': qty(reorderLevel),
      if (qty(reorderTarget) != null) 'reorder_target': qty(reorderTarget),
      if (money(minPriceFloor) != null) 'min_price_floor': money(minPriceFloor),
      'batch_required': batchRequired,
      'expiry_required': expiryRequired,
      'loose_sale_allowed': looseSaleAllowed,
      'scale_required': scaleRequired,
      'product_type': productType,
      'barcodes': barcodes,
      'aliases': aliases,
    };
  }
}

class ProductListItem {
  final String id;
  final String sku;
  final String name;
  final Decimal? sellingPrice;
  final bool active;

  ProductListItem({required this.id, required this.sku, required this.name, this.sellingPrice, required this.active});

  factory ProductListItem.fromJson(Map<String, dynamic> json) {
    return ProductListItem(
      id: json['id'] as String,
      sku: json['sku'] as String,
      name: json['name'] as String,
      sellingPrice: json['selling_price'] == null || (json['selling_price'] as String).isEmpty
          ? null
          : Decimal.parse(json['selling_price'] as String),
      active: json['active'] as bool? ?? true,
    );
  }
}

class ProductPage {
  final List<ProductListItem> products;
  final int total;

  ProductPage({required this.products, required this.total});
}

/// A simple {id, name} or {id, code, name} master-data option, used to
/// populate the category/brand/UOM/tax-profile dropdowns on the product form.
class MasterDataOption {
  final String id;
  final String label;

  MasterDataOption({required this.id, required this.label});
}

/// Wraps the product master-data CRUD endpoints and the small read-only
/// category/brand/UOM/tax-profile lookup lists a product form needs. All
/// business rules (SKU immutability, never hard-deleting a referenced
/// product) live server-side — see services/api/internal/domain/product.
class ProductAdminApi {
  final ApiClient client;

  ProductAdminApi(this.client);

  Future<ProductPage> list({String query = '', bool activeOnly = true, int limit = 50, int offset = 0}) async {
    final params = {
      if (query.isNotEmpty) 'q': query,
      'active': activeOnly.toString(),
      'limit': limit.toString(),
      'offset': offset.toString(),
    };
    final qs = params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
    final response = await client.getAuthed('/api/v1/products?$qs');
    return ProductPage(
      products: (response['products'] as List<dynamic>)
          .map((p) => ProductListItem.fromJson(p as Map<String, dynamic>))
          .toList(),
      total: response['total'] as int? ?? 0,
    );
  }

  Future<ProductDetail> getDetail(String productId) async {
    final response = await client.getAuthed('/api/v1/products/$productId');
    return ProductDetail.fromJson(response);
  }

  Future<ProductDetail> create(ProductDetail product) async {
    final response = await client.postAuthed('/api/v1/products', product.toJson());
    return getDetail(response['id'] as String);
  }

  Future<ProductDetail> update(String productId, ProductDetail product) async {
    await client.putAuthed('/api/v1/products/$productId', product.toJson());
    return getDetail(productId);
  }

  Future<void> setActive(String productId, bool active) async {
    await client.postAuthed('/api/v1/products/$productId/status', {'active': active});
  }

  Future<List<MasterDataOption>> listCategories() async {
    final response = await client.getAuthed('/api/v1/categories');
    return (response['categories'] as List<dynamic>)
        .map((c) => MasterDataOption(id: c['id'] as String, label: c['name'] as String))
        .toList();
  }

  Future<List<MasterDataOption>> listBrands() async {
    final response = await client.getAuthed('/api/v1/brands');
    return (response['brands'] as List<dynamic>)
        .map((b) => MasterDataOption(id: b['id'] as String, label: b['name'] as String))
        .toList();
  }

  Future<List<MasterDataOption>> listUoms() async {
    final response = await client.getAuthed('/api/v1/uoms');
    return (response['uoms'] as List<dynamic>)
        .map((u) => MasterDataOption(id: u['id'] as String, label: '${u['name']} (${u['code']})'))
        .toList();
  }

  Future<List<MasterDataOption>> listTaxProfiles() async {
    final response = await client.getAuthed('/api/v1/tax-profiles');
    return (response['tax_profiles'] as List<dynamic>)
        .map((t) => MasterDataOption(id: t['id'] as String, label: '${t['code']} — ${t['description']}'))
        .toList();
  }
}
