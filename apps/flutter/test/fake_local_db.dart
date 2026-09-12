import 'package:feedmate_app/core/local_db.dart';

/// Pure in-memory implementation of [LocalDatabase] for widget tests.
///
/// `testWidgets`' fake-async pump zone does not correctly resolve real
/// native/FFI I/O — wiring the real sqflite-backed implementation into a
/// widget test hung indefinitely rather than failing fast. This fake keeps
/// every widget test synchronous-in-spirit (immediately-resolving Futures)
/// while exercising exactly the same interface the real screens depend on.
/// The real SQL implementation is covered separately, for real, in
/// test/local_db_test.dart (plain `test()`, no widget pump involved).
class FakeLocalDatabase implements LocalDatabase {
  final List<Map<String, Object?>> _products = [];
  final Map<String, Map<String, Object?>> _outbox = {};
  final Map<String, String> _cache = {};

  @override
  Future<void> upsertProducts(List<Map<String, Object?>> products) async {
    for (final p in products) {
      _products.removeWhere((existing) => existing['id'] == p['id']);
      _products.add(Map.of(p));
    }
  }

  @override
  Future<List<Map<String, Object?>>> searchProductsLocal(String query, {int limit = 25}) async {
    final lower = query.toLowerCase();
    final matches = _products.where((p) {
      if ((p['active'] as int?) != 1) return false;
      final sku = (p['sku'] as String).toLowerCase();
      final name = (p['name'] as String).toLowerCase();
      final localName = (p['local_name_ta'] as String?)?.toLowerCase() ?? '';
      return sku.contains(lower) || name.contains(lower) || localName.contains(lower);
    }).toList()
      ..sort((a, b) {
        final aSkuMatch = (a['sku'] as String).toLowerCase().startsWith(lower) ? 0 : 1;
        final bSkuMatch = (b['sku'] as String).toLowerCase().startsWith(lower) ? 0 : 1;
        if (aSkuMatch != bSkuMatch) return aSkuMatch - bSkuMatch;
        return (a['name'] as String).compareTo(b['name'] as String);
      });
    return matches.take(limit).toList();
  }

  @override
  Future<int> productCacheSize() async => _products.length;

  @override
  Future<void> enqueueInvoice({required String clientTransactionId, required String payloadJson}) async {
    _outbox.putIfAbsent(clientTransactionId, () => {
          'client_transaction_id': clientTransactionId,
          'payload_json': payloadJson,
          'status': 'PENDING',
          'created_at': DateTime.now().toIso8601String(),
        });
  }

  @override
  Future<List<Map<String, Object?>>> pendingInvoices() async {
    return _outbox.values.where((row) => row['status'] == 'PENDING').toList();
  }

  @override
  Future<int> pendingInvoiceCount() async {
    return _outbox.values.where((row) => row['status'] == 'PENDING').length;
  }

  @override
  Future<void> markInvoiceSynced(String clientTransactionId, {String? serverInvoiceNumber}) async {
    final row = _outbox[clientTransactionId];
    if (row == null) return;
    row['status'] = 'SYNCED';
    row['server_invoice_number'] = serverInvoiceNumber;
  }

  @override
  Future<void> markInvoiceFailed(String clientTransactionId, String error) async {
    final row = _outbox[clientTransactionId];
    if (row == null) return;
    row['status'] = 'FAILED';
    row['last_error'] = error;
  }

  @override
  Future<void> setCache(String key, String valueJson) async => _cache[key] = valueJson;

  @override
  Future<String?> getCache(String key) async => _cache[key];
}
