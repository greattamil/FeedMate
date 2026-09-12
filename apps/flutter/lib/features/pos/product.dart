import 'package:decimal/decimal.dart';

/// Mirrors services/api/internal/httpapi/product_handlers.go's productResponse.
/// Money fields are parsed as Decimal, never double, matching the mandatory
/// numeric-precision rule that applies across the whole stack.
class Product {
  final String id;
  final String sku;
  final String name;
  final String? localNameTa;
  final Decimal? mrp;
  final Decimal? sellingPrice;
  final bool batchRequired;
  final bool looseSaleAllowed;
  final bool active;
  final String matchType;

  Product({
    required this.id,
    required this.sku,
    required this.name,
    this.localNameTa,
    this.mrp,
    this.sellingPrice,
    required this.batchRequired,
    required this.looseSaleAllowed,
    required this.active,
    this.matchType = '',
  });

  factory Product.fromSearchResult(Map<String, dynamic> json) {
    final productJson = json['product'] as Map<String, dynamic>;
    return Product(
      id: productJson['id'] as String,
      sku: productJson['sku'] as String,
      name: productJson['name'] as String,
      localNameTa: productJson['local_name_ta'] as String?,
      mrp: _decimalOrNull(productJson['mrp']),
      sellingPrice: _decimalOrNull(productJson['selling_price']),
      batchRequired: productJson['batch_required'] as bool? ?? false,
      looseSaleAllowed: productJson['loose_sale_allowed'] as bool? ?? false,
      active: productJson['active'] as bool? ?? false,
      matchType: json['match_type'] as String? ?? '',
    );
  }

  static Decimal? _decimalOrNull(dynamic value) {
    if (value == null || (value is String && value.isEmpty)) return null;
    return Decimal.parse(value as String);
  }
}
