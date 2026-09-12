// Real tests of SqlLocalDatabase against an actual (in-memory) SQLite engine
// via sqflite_common_ffi — plain `test()`, not `testWidgets()`, because real
// native/FFI I/O does not resolve correctly inside flutter_test's fake-async
// widget-pump zone (confirmed directly: wiring this into a widget test hung
// indefinitely). This is the real coverage for the query logic that
// production actually runs (against SQLCipher instead of plain SQLite, but
// through the identical `Database` interface — see local_db.dart).
import 'package:flutter_test/flutter_test.dart';

import 'test_local_db.dart';

void main() {
  group('product cache', () {
    test('upsertProducts + searchProductsLocal finds by name, sku, and local name', () async {
      final db = await openTestLocalDatabase();
      await db.upsertProducts([
        {
          'id': 'p1', 'sku': 'CF-01', 'name': 'Cattle Feed Economy 50kg',
          'local_name_ta': 'மாட்டு தீவனம்', 'mrp': '1100.00', 'selling_price': '1050.00',
          'batch_required': 1, 'loose_sale_allowed': 0, 'active': 1,
        },
        {
          'id': 'p2', 'sku': 'PF-02', 'name': 'Poultry Feed 25kg',
          'local_name_ta': null, 'mrp': null, 'selling_price': '600.00',
          'batch_required': 0, 'loose_sale_allowed': 1, 'active': 1,
        },
      ]);

      expect(await db.productCacheSize(), 2);

      final byName = await db.searchProductsLocal('cattle');
      expect(byName, hasLength(1));
      expect(byName.first['id'], 'p1');

      final bySku = await db.searchProductsLocal('PF-02');
      expect(bySku, hasLength(1));
      expect(bySku.first['id'], 'p2');

      final byLocalName = await db.searchProductsLocal('மாட்டு');
      expect(byLocalName, hasLength(1));
      expect(byLocalName.first['id'], 'p1');

      expect(await db.searchProductsLocal('nonexistent'), isEmpty);
    });

    test('upsertProducts overwrites a product with the same id rather than duplicating it', () async {
      final db = await openTestLocalDatabase();
      await db.upsertProducts([
        {
          'id': 'p1', 'sku': 'CF-01', 'name': 'Old Name', 'local_name_ta': null,
          'mrp': null, 'selling_price': '100.00', 'batch_required': 0,
          'loose_sale_allowed': 0, 'active': 1,
        },
      ]);
      await db.upsertProducts([
        {
          'id': 'p1', 'sku': 'CF-01', 'name': 'New Name', 'local_name_ta': null,
          'mrp': null, 'selling_price': '150.00', 'batch_required': 0,
          'loose_sale_allowed': 0, 'active': 1,
        },
      ]);

      expect(await db.productCacheSize(), 1);
      final results = await db.searchProductsLocal('CF-01');
      expect(results.single['name'], 'New Name');
      expect(results.single['selling_price'], '150.00');
    });

    test('an inactive product is not returned by search', () async {
      final db = await openTestLocalDatabase();
      await db.upsertProducts([
        {
          'id': 'p1', 'sku': 'OLD-01', 'name': 'Discontinued Feed', 'local_name_ta': null,
          'mrp': null, 'selling_price': '100.00', 'batch_required': 0,
          'loose_sale_allowed': 0, 'active': 0,
        },
      ]);
      expect(await db.searchProductsLocal('Discontinued'), isEmpty);
    });
  });

  group('invoice outbox', () {
    test('enqueue -> pending -> synced lifecycle', () async {
      final db = await openTestLocalDatabase();
      expect(await db.pendingInvoiceCount(), 0);

      await db.enqueueInvoice(clientTransactionId: 'tx-1', payloadJson: '{"lines":[]}');
      expect(await db.pendingInvoiceCount(), 1);

      final pending = await db.pendingInvoices();
      expect(pending, hasLength(1));
      expect(pending.single['client_transaction_id'], 'tx-1');
      expect(pending.single['status'], 'PENDING');

      await db.markInvoiceSynced('tx-1', serverInvoiceNumber: 'INV-0001');
      expect(await db.pendingInvoiceCount(), 0);
      expect(await db.pendingInvoices(), isEmpty);
    });

    test('enqueueInvoice is idempotent on client_transaction_id', () async {
      final db = await openTestLocalDatabase();
      await db.enqueueInvoice(clientTransactionId: 'tx-1', payloadJson: '{"a":1}');
      await db.enqueueInvoice(clientTransactionId: 'tx-1', payloadJson: '{"a":2}');

      expect(await db.pendingInvoiceCount(), 1);
      final pending = await db.pendingInvoices();
      // First write wins; a duplicate enqueue (e.g. a retry) must never
      // silently replace a queued sale's contents.
      expect(pending.single['payload_json'], '{"a":1}');
    });

    test('markInvoiceFailed records the reason and stops counting it as pending', () async {
      final db = await openTestLocalDatabase();
      await db.enqueueInvoice(clientTransactionId: 'tx-1', payloadJson: '{}');
      await db.markInvoiceFailed('tx-1', 'VALIDATION_ERROR: bad line');

      expect(await db.pendingInvoiceCount(), 0);
      expect(await db.pendingInvoices(), isEmpty);
    });

    test('allOutboxEntries returns every status, and retryInvoice resets only a FAILED one', () async {
      final db = await openTestLocalDatabase();
      await db.enqueueInvoice(clientTransactionId: 'tx-pending', payloadJson: '{}');
      await db.enqueueInvoice(clientTransactionId: 'tx-failed', payloadJson: '{}');
      await db.enqueueInvoice(clientTransactionId: 'tx-synced', payloadJson: '{}');
      await db.markInvoiceFailed('tx-failed', 'boom');
      await db.markInvoiceSynced('tx-synced', serverInvoiceNumber: 'INV-0001');

      final all = await db.allOutboxEntries();
      expect(all, hasLength(3));
      final statuses = {for (final row in all) row['client_transaction_id']: row['status']};
      expect(statuses, {'tx-pending': 'PENDING', 'tx-failed': 'FAILED', 'tx-synced': 'SYNCED'});

      // Retrying a PENDING or SYNCED entry must be a no-op — only a FAILED
      // entry should ever be resurrected back to PENDING.
      await db.retryInvoice('tx-pending');
      await db.retryInvoice('tx-synced');
      expect(await db.pendingInvoiceCount(), 1);

      await db.retryInvoice('tx-failed');
      expect(await db.pendingInvoiceCount(), 2);
      final retried = (await db.pendingInvoices()).firstWhere((r) => r['client_transaction_id'] == 'tx-failed');
      expect(retried['last_error'], isNull);
    });
  });

  group('generic cache', () {
    test('setCache/getCache round-trips, and an unknown key returns null', () async {
      final db = await openTestLocalDatabase();
      expect(await db.getCache('locations'), isNull);

      await db.setCache('locations', '[{"id":"loc-1","name":"Main Store"}]');
      expect(await db.getCache('locations'), '[{"id":"loc-1","name":"Main Store"}]');

      await db.setCache('locations', '[{"id":"loc-2","name":"Branch"}]');
      expect(await db.getCache('locations'), '[{"id":"loc-2","name":"Branch"}]');
    });
  });
}
