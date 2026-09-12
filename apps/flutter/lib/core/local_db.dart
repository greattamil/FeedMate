import 'package:sqflite_common/sqlite_api.dart';

/// The on-device offline store's contract. Schema is intentionally small: a
/// read-through cache of products (so the search screen still works with no
/// network) and an outbox of sale intents queued while offline (so a sale is
/// never lost just because the shop's connection dropped — PRD's
/// offline-first mandate).
///
/// This is an interface, not a single class, because real SQL I/O (even via
/// the plain, unencrypted sqflite_common_ffi backend used in tests) does not
/// resolve correctly inside `flutter_test`'s fake-async widget-pump zone —
/// verified directly: wiring `SqlLocalDatabase` into a `testWidgets` test
/// hung indefinitely instead of failing fast. So screens are tested against
/// [FakeLocalDatabase] (test/fake_local_db.dart), a pure in-memory
/// implementation of this same contract, while [SqlLocalDatabase] itself is
/// covered by real, non-widget `test()`s in test/local_db_test.dart (plain
/// async Dart, no fake-async zone, where sqflite_common_ffi works fine).
abstract class LocalDatabase {
  Future<void> upsertProducts(List<Map<String, Object?>> products);
  Future<List<Map<String, Object?>>> searchProductsLocal(String query, {int limit = 25});
  Future<int> productCacheSize();

  Future<void> enqueueInvoice({required String clientTransactionId, required String payloadJson});
  Future<List<Map<String, Object?>>> pendingInvoices();
  Future<int> pendingInvoiceCount();
  Future<void> markInvoiceSynced(String clientTransactionId, {String? serverInvoiceNumber});
  Future<void> markInvoiceFailed(String clientTransactionId, String error);

  /// Every outbox entry regardless of status, newest-first — for a review
  /// screen showing PENDING/FAILED/SYNCED sales, not just what's about to
  /// sync.
  Future<List<Map<String, Object?>>> allOutboxEntries();

  /// Resets a FAILED entry back to PENDING (clearing the recorded error) so
  /// the next sync attempt retries it — e.g. after a cashier fixes whatever
  /// made the sale unsyncable (a product was reactivated, a credit limit was
  /// raised). A no-op if the entry isn't currently FAILED, so it can't
  /// accidentally resurrect an already-SYNCED sale.
  Future<void> retryInvoice(String clientTransactionId);

  Future<void> setCache(String key, String valueJson);
  Future<String?> getCache(String key);
}

/// Production (and real-engine-test) implementation, backed by an
/// already-open [Database] — SQLCipher-encrypted in production (see
/// local_db_sqlcipher.dart), plain sqflite_common_ffi in test/local_db_test.dart.
/// Both backends implement the same `package:sqflite_common` `Database`
/// interface, so every query below runs unmodified against either.
class SqlLocalDatabase implements LocalDatabase {
  final Database db;

  SqlLocalDatabase(this.db);

  static const schemaVersion = 1;

  static Future<void> createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS products_cache (
        id TEXT PRIMARY KEY,
        sku TEXT NOT NULL,
        name TEXT NOT NULL,
        local_name_ta TEXT,
        mrp TEXT,
        selling_price TEXT,
        batch_required INTEGER NOT NULL,
        loose_sale_allowed INTEGER NOT NULL,
        active INTEGER NOT NULL,
        cached_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_products_cache_name ON products_cache(name)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_products_cache_sku ON products_cache(sku)');

    // status: PENDING (never sent) -> SYNCED (server confirmed) or FAILED
    // (server rejected for a reason a resync can't fix, e.g. validation --
    // kept for manual review rather than silently dropped).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS outbox_invoices (
        client_transaction_id TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        last_error TEXT,
        server_invoice_number TEXT
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_outbox_status ON outbox_invoices(status)');

    // Small generic cache for reference data that changes rarely (e.g. the
    // location list) and is only ever read as a whole blob — not worth a
    // dedicated table each time something like this is needed offline.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS kv_cache (
        cache_key TEXT PRIMARY KEY,
        value_json TEXT NOT NULL,
        cached_at TEXT NOT NULL
      )
    ''');
  }

  // ---- Generic reference-data cache ---------------------------------------

  @override
  Future<void> setCache(String key, String valueJson) async {
    await db.insert(
      'kv_cache',
      {'cache_key': key, 'value_json': valueJson, 'cached_at': DateTime.now().toIso8601String()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<String?> getCache(String key) async {
    final rows = await db.query('kv_cache', where: 'cache_key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['value_json'] as String;
  }

  // ---- Product cache -----------------------------------------------------

  @override
  Future<void> upsertProducts(List<Map<String, Object?>> products) async {
    final batch = db.batch();
    final now = DateTime.now().toIso8601String();
    for (final p in products) {
      batch.insert(
        'products_cache',
        {...p, 'cached_at': now},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Mirrors the server's search ranking closely enough to be useful offline:
  /// SKU-prefix matches first, then a name/local-name substring match. Not a
  /// replacement for the server's phonetic/fuzzy ranking (PRD A4) — a
  /// best-effort fallback for when there is no server to ask.
  @override
  Future<List<Map<String, Object?>>> searchProductsLocal(String query, {int limit = 25}) async {
    final like = '%$query%';
    final skuPrefix = '$query%';
    return db.rawQuery(
      '''
      SELECT * FROM products_cache
      WHERE active = 1 AND (sku LIKE ? OR name LIKE ? OR local_name_ta LIKE ?)
      ORDER BY CASE WHEN sku LIKE ? THEN 0 ELSE 1 END, name
      LIMIT ?
      ''',
      [like, like, like, skuPrefix, limit],
    );
  }

  @override
  Future<int> productCacheSize() async {
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM products_cache');
    return (result.first['c'] as int?) ?? 0;
  }

  // ---- Invoice outbox -----------------------------------------------------

  @override
  Future<void> enqueueInvoice({
    required String clientTransactionId,
    required String payloadJson,
  }) async {
    await db.insert(
      'outbox_invoices',
      {
        'client_transaction_id': clientTransactionId,
        'payload_json': payloadJson,
        'status': 'PENDING',
        'created_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  @override
  Future<List<Map<String, Object?>>> pendingInvoices() async {
    return db.query('outbox_invoices', where: "status = 'PENDING'", orderBy: 'created_at');
  }

  @override
  Future<int> pendingInvoiceCount() async {
    final result = await db.rawQuery("SELECT COUNT(*) AS c FROM outbox_invoices WHERE status = 'PENDING'");
    return (result.first['c'] as int?) ?? 0;
  }

  @override
  Future<void> markInvoiceSynced(String clientTransactionId, {String? serverInvoiceNumber}) async {
    await db.update(
      'outbox_invoices',
      {'status': 'SYNCED', 'server_invoice_number': serverInvoiceNumber},
      where: 'client_transaction_id = ?',
      whereArgs: [clientTransactionId],
    );
  }

  @override
  Future<void> markInvoiceFailed(String clientTransactionId, String error) async {
    await db.update(
      'outbox_invoices',
      {'status': 'FAILED', 'last_error': error},
      where: 'client_transaction_id = ?',
      whereArgs: [clientTransactionId],
    );
  }

  @override
  Future<List<Map<String, Object?>>> allOutboxEntries() async {
    return db.query('outbox_invoices', orderBy: 'created_at DESC');
  }

  @override
  Future<void> retryInvoice(String clientTransactionId) async {
    await db.update(
      'outbox_invoices',
      {'status': 'PENDING', 'last_error': null},
      where: "client_transaction_id = ? AND status = 'FAILED'",
      whereArgs: [clientTransactionId],
    );
  }
}
