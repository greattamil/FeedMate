import 'package:decimal/decimal.dart';

import '../../core/api_client.dart';
import '../../core/api_error.dart';
import '../../core/local_db.dart';
import 'product.dart';

class ProductSearchResult {
  final List<Product> products;
  final bool fromCache;

  ProductSearchResult({required this.products, required this.fromCache});
}

/// Read-through cache in front of the product search endpoint. A live search
/// always hits the server first (it has the authoritative Tamil/phonetic
/// ranking — see PRD A4) and refreshes the local cache with whatever comes
/// back; only a genuine network failure falls back to the on-device cache,
/// so the cashier can keep selling during an outage instead of being blocked
/// (PRD's offline-first mandate).
class ProductRepository {
  final ApiClient client;
  final LocalDatabase localDb;

  ProductRepository({required this.client, required this.localDb});

  /// [categoryId] narrows results to one real category — the same rows
  /// `/api/v1/categories` returns, never a client-side list — and, combined
  /// with an empty [query], browses that whole category (see
  /// product.Search's server-side doc comment on why an empty query plus a
  /// category is meaningful while an empty query with no category is not).
  Future<ProductSearchResult> search(String query, {String? categoryId}) async {
    if (query.trim().isEmpty && categoryId == null) {
      return ProductSearchResult(products: [], fromCache: false);
    }
    try {
      final params = <String, String>{
        if (query.isNotEmpty) 'q': query,
        if (categoryId != null) 'category_id': categoryId,
      };
      final qs = params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
      final response = await client.getAuthed('/api/v1/products/search?$qs');
      final results = (response['results'] as List<dynamic>? ?? [])
          .map((e) => Product.fromSearchResult(e as Map<String, dynamic>))
          .toList();
      await _cacheProducts(results);
      return ProductSearchResult(products: results, fromCache: false);
    } on ApiError catch (e) {
      if (e.code != 'NETWORK_ERROR') rethrow;
      // The on-device cache has no category data (offline products are
      // cached from whatever was last searched, not the full catalog), so a
      // category filter can't be honored offline — fall back to a plain
      // text search of the cache, which still lets the cashier keep selling.
      final rows = await localDb.searchProductsLocal(query);
      return ProductSearchResult(products: rows.map(_productFromRow).toList(), fromCache: true);
    }
  }

  Future<void> _cacheProducts(List<Product> products) async {
    await localDb.upsertProducts(products
        .map((p) => {
              'id': p.id,
              'sku': p.sku,
              'name': p.name,
              'local_name_ta': p.localNameTa,
              'mrp': p.mrp?.toString(),
              'selling_price': p.sellingPrice?.toString(),
              'batch_required': p.batchRequired ? 1 : 0,
              'loose_sale_allowed': p.looseSaleAllowed ? 1 : 0,
              'active': p.active ? 1 : 0,
            })
        .toList());
  }

  Product _productFromRow(Map<String, Object?> row) {
    return Product(
      id: row['id'] as String,
      sku: row['sku'] as String,
      name: row['name'] as String,
      localNameTa: row['local_name_ta'] as String?,
      mrp: _decimalOrNull(row['mrp'] as String?),
      sellingPrice: _decimalOrNull(row['selling_price'] as String?),
      batchRequired: (row['batch_required'] as int) == 1,
      looseSaleAllowed: (row['loose_sale_allowed'] as int) == 1,
      active: (row['active'] as int) == 1,
      matchType: 'CACHED',
    );
  }

  static Decimal? _decimalOrNull(String? value) {
    if (value == null) return null;
    return Decimal.parse(value);
  }
}
