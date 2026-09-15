// Covers InMemoryLocalDatabase — the LocalDatabase used on Windows/web,
// where the SQLCipher plugin has no platform implementation (see
// lib/core/in_memory_local_db.dart's doc comment). Same contract as
// SqlLocalDatabase (local_db_test.dart), so the same behaviors are checked
// here: a Windows/web session must never see different search/outbox
// semantics just because it's running on a different backend.
import 'package:feedmate_app/core/in_memory_local_db.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InMemoryLocalDatabase', () {
    test('upsertProducts + searchProductsLocal finds by name, sku, and local name', () async {
      final db = InMemoryLocalDatabase();
      await db.upsertProducts([
        {'id': 'p1', 'sku': 'CF-ECO-01', 'name': 'Cattle Feed Economy', 'local_name_ta': 'மாட்டு தீவனம்', 'active': 1},
        {'id': 'p2', 'sku': 'GF-01', 'name': 'Goat Feed', 'local_name_ta': null, 'active': 1},
      ]);

      final bySku = await db.searchProductsLocal('CF-ECO');
      expect(bySku.map((r) => r['id']), ['p1']);

      final byName = await db.searchProductsLocal('goat');
      expect(byName.map((r) => r['id']), ['p2']);

      final byLocalName = await db.searchProductsLocal('தீவனம்');
      expect(byLocalName.map((r) => r['id']), ['p1']);
    });

    test('upsertProducts overwrites a product with the same id rather than duplicating it', () async {
      final db = InMemoryLocalDatabase();
      await db.upsertProducts([
        {'id': 'p1', 'sku': 'CF-01', 'name': 'Old Name', 'local_name_ta': null, 'active': 1},
      ]);
      await db.upsertProducts([
        {'id': 'p1', 'sku': 'CF-01', 'name': 'New Name', 'local_name_ta': null, 'active': 1},
      ]);

      expect(await db.productCacheSize(), 1);
      final results = await db.searchProductsLocal('New Name');
      expect(results, hasLength(1));
    });

    test('an inactive product is not returned by search', () async {
      final db = InMemoryLocalDatabase();
      await db.upsertProducts([
        {'id': 'p1', 'sku': 'CF-01', 'name': 'Inactive Feed', 'local_name_ta': null, 'active': 0},
      ]);
      expect(await db.searchProductsLocal('Inactive'), isEmpty);
    });

    test('enqueue -> pending -> synced lifecycle', () async {
      final db = InMemoryLocalDatabase();
      await db.enqueueInvoice(clientTransactionId: 'tx-1', payloadJson: '{}');
      expect(await db.pendingInvoiceCount(), 1);

      await db.markInvoiceSynced('tx-1', serverInvoiceNumber: 'INV-0001');
      expect(await db.pendingInvoiceCount(), 0);
      final all = await db.allOutboxEntries();
      expect(all.single['status'], 'SYNCED');
      expect(all.single['server_invoice_number'], 'INV-0001');
    });

    test('enqueueInvoice is idempotent on client_transaction_id', () async {
      final db = InMemoryLocalDatabase();
      await db.enqueueInvoice(clientTransactionId: 'tx-1', payloadJson: '{"a":1}');
      await db.enqueueInvoice(clientTransactionId: 'tx-1', payloadJson: '{"a":2}');
      expect(await db.pendingInvoiceCount(), 1);
    });

    test('markInvoiceFailed records the reason and stops counting it as pending', () async {
      final db = InMemoryLocalDatabase();
      await db.enqueueInvoice(clientTransactionId: 'tx-1', payloadJson: '{}');
      await db.markInvoiceFailed('tx-1', 'validation error');
      expect(await db.pendingInvoiceCount(), 0);
      expect((await db.allOutboxEntries()).single['last_error'], 'validation error');
    });

    test('retryInvoice resets only a FAILED entry back to PENDING', () async {
      final db = InMemoryLocalDatabase();
      await db.enqueueInvoice(clientTransactionId: 'tx-failed', payloadJson: '{}');
      await db.enqueueInvoice(clientTransactionId: 'tx-pending', payloadJson: '{}');
      await db.markInvoiceFailed('tx-failed', 'oops');

      await db.retryInvoice('tx-pending'); // no-op: not FAILED
      await db.retryInvoice('tx-failed');

      expect(await db.pendingInvoiceCount(), 2);
    });

    test('setCache/getCache round-trips, and an unknown key returns null', () async {
      final db = InMemoryLocalDatabase();
      expect(await db.getCache('missing'), isNull);
      await db.setCache('locations', '[{"id":"loc-1"}]');
      expect(await db.getCache('locations'), '[{"id":"loc-1"}]');
    });
  });
}
