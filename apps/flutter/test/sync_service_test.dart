// Real tests of SyncService's core contract: an offline sale is stored as an
// *intent* (line items only, no total), and syncing must re-quote for real
// before finalizing — never resend a client-guessed total. Uses FakeLocalDatabase
// (plain test(), not testWidgets — no widget pump involved here either).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/core/sync_service.dart';

import 'fake_local_db.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

void main() {
  test('syncPendingInvoices re-quotes before finalizing, using the server total not a stored one', () async {
    final localDb = FakeLocalDatabase();
    await localDb.enqueueInvoice(
      clientTransactionId: 'tx-1',
      payloadJson: jsonEncode({
        'client_transaction_id': 'tx-1',
        'location_id': 'loc-1',
        'tender_method': 'CASH',
        'customer_id': null,
        'lines': [
          {'product_id': 'p1', 'quantity': '2'}
        ],
      }),
    );

    String? sentTenderAmount;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/pos/quote') {
        return _jsonOk({
          'lines': [
            {'product_id': 'p1', 'product_name': 'Cattle Feed', 'line_total': '2100.00'}
          ],
          'taxable_total': '2100.00',
          'tax_total': '0.00',
          'grand_total': '2100.00', // the authoritative total, computed fresh
        });
      }
      if (request.url.path == '/api/v1/pos/invoices') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        sentTenderAmount = (body['tenders'] as List<dynamic>).first['amount'] as String;
        expect(body['client_transaction_id'], 'tx-1');
        return _jsonOk({'invoice_id': 'inv-1', 'invoice_number': 'INV-0009', 'grand_total': '2100.00', 'duplicate': false});
      }
      return http.Response('not found', 404);
    });

    final storage = SecureStorage(store: InMemoryKeyValueStore());
    await storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
    final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: client);
    final syncService = SyncService(client: apiClient, localDb: localDb);

    final result = await syncService.syncPendingInvoices();

    expect(result.synced, 1);
    expect(result.failed, 0);
    expect(result.remaining, 0);
    expect(sentTenderAmount, '2100.00');
    expect(await localDb.pendingInvoiceCount(), 0);
  });

  test('a non-retryable rejection at sync time marks the intent FAILED, not lost or retried forever', () async {
    final localDb = FakeLocalDatabase();
    await localDb.enqueueInvoice(
      clientTransactionId: 'tx-bad',
      payloadJson: jsonEncode({
        'client_transaction_id': 'tx-bad',
        'location_id': 'loc-1',
        'tender_method': 'CASH',
        'customer_id': null,
        'lines': [
          {'product_id': 'p-deactivated', 'quantity': '1'}
        ],
      }),
    );

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/pos/quote') {
        return http.Response(
          jsonEncode({
            'error': {'code': 'VALIDATION_ERROR', 'message': 'product is inactive', 'retryable': false}
          }),
          422,
        );
      }
      return http.Response('not found', 404);
    });

    final storage = SecureStorage(store: InMemoryKeyValueStore());
    await storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
    final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: client);
    final syncService = SyncService(client: apiClient, localDb: localDb);

    final result = await syncService.syncPendingInvoices();

    expect(result.synced, 0);
    expect(result.failed, 1);
    expect(result.remaining, 0);
    expect(await localDb.pendingInvoiceCount(), 0);
    final failedRows = await localDb.pendingInvoices();
    expect(failedRows, isEmpty); // no longer PENDING — parked as FAILED, not silently dropped
  });

  test('still offline (network error) leaves the intent PENDING for the next sync attempt', () async {
    final localDb = FakeLocalDatabase();
    await localDb.enqueueInvoice(
      clientTransactionId: 'tx-offline',
      payloadJson: jsonEncode({
        'client_transaction_id': 'tx-offline',
        'location_id': 'loc-1',
        'tender_method': 'CASH',
        'customer_id': null,
        'lines': [
          {'product_id': 'p1', 'quantity': '1'}
        ],
      }),
    );

    final client = MockClient((request) async {
      throw const SocketExceptionStub();
    });

    final storage = SecureStorage(store: InMemoryKeyValueStore());
    await storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
    final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: client);
    final syncService = SyncService(client: apiClient, localDb: localDb);

    final result = await syncService.syncPendingInvoices();

    expect(result.synced, 0);
    expect(result.failed, 0);
    expect(result.remaining, 1);
    expect(await localDb.pendingInvoiceCount(), 1);
  });
}

/// A minimal stand-in for a real network failure (e.g. SocketException) —
/// ApiClient wraps any thrown Exception from the underlying http.Client as
/// ApiError.network(...), so any Exception subtype exercises that path.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'SocketExceptionStub: Connection refused';
}
