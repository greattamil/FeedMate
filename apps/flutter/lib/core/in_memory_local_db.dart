import 'local_db.dart';

/// A [LocalDatabase] with no persistence at all — the offline store used on
/// platforms with no SQLCipher plugin (Windows, web; see
/// local_db_sqlcipher.dart's doc comment for which platforms that plugin
/// actually supports). Those platforms run FeedMate as an always-connected
/// back-office/admin client (reports, stock management, product/customer
/// master data, and POS when online) rather than the offline-first physical
/// counter terminal — that role stays Android/iOS, where the real encrypted
/// [SqlLocalDatabase] is used. Everything here still behaves correctly
/// (nothing throws, nothing is silently wrong), it just doesn't survive a
/// restart: a product cache that's rebuilt from the next search anyway, and
/// an outbox that would only ever hold something if this session's network
/// dropped mid-sale — acceptable for a client role that assumes
/// connectivity, and never claimed to survive a browser refresh.
class InMemoryLocalDatabase implements LocalDatabase {
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
  Future<List<Map<String, Object?>>> allOutboxEntries() async {
    final rows = _outbox.values.toList()
      ..sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
    return rows;
  }

  @override
  Future<void> retryInvoice(String clientTransactionId) async {
    final row = _outbox[clientTransactionId];
    if (row == null || row['status'] != 'FAILED') return;
    row['status'] = 'PENDING';
    row['last_error'] = null;
  }

  @override
  Future<void> setCache(String key, String valueJson) async => _cache[key] = valueJson;

  @override
  Future<String?> getCache(String key) async => _cache[key];
}
