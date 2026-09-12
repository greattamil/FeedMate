// Widget tests for the offline-sales outbox review screen: it must show
// PENDING/FAILED/SYNCED entries, let a FAILED entry be retried (which resets
// it to PENDING and re-attempts sync immediately), and never silently drop
// a FAILED entry from view.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/local_db.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/core/sync_service.dart';
import 'package:feedmate_app/features/sync/outbox_screen.dart';

import 'fake_local_db.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

Widget _wrap({required http.Client httpClient, required FakeLocalDatabase localDb}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  return MultiProvider(
    providers: [
      Provider<SecureStorage>.value(value: storage),
      Provider<ApiClient>.value(value: apiClient),
      Provider<LocalDatabase>.value(value: localDb),
      Provider<SyncService>(create: (_) => SyncService(client: apiClient, localDb: localDb)),
    ],
    child: const MaterialApp(home: OutboxScreen()),
  );
}

void main() {
  testWidgets('shows an empty state with nothing queued', (tester) async {
    final localDb = FakeLocalDatabase();
    final client = MockClient((request) async => http.Response('not found', 404));

    await tester.pumpWidget(_wrap(httpClient: client, localDb: localDb));
    await tester.pumpAndSettle();

    expect(find.text('No offline sales queued'), findsOneWidget);
  });

  testWidgets('lists a FAILED entry with its error, and Retry resyncs it successfully', (tester) async {
    final localDb = FakeLocalDatabase();
    await localDb.enqueueInvoice(
      clientTransactionId: 'tx-failed',
      payloadJson: jsonEncode({
        'client_transaction_id': 'tx-failed',
        'location_id': 'loc-1',
        'tender_method': 'CASH',
        'customer_id': null,
        'lines': [
          {'product_id': 'p1', 'quantity': '1'}
        ],
      }),
    );
    await localDb.markInvoiceFailed('tx-failed', 'VALIDATION_ERROR: product is inactive');

    var quoteCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/pos/quote') {
        quoteCalls++;
        return _jsonOk({
          'lines': [
            {'product_id': 'p1', 'product_name': 'Cattle Feed', 'line_total': '1000.00'}
          ],
          'taxable_total': '1000.00',
          'tax_total': '0.00',
          'grand_total': '1000.00',
        });
      }
      if (request.url.path == '/api/v1/pos/invoices') {
        return _jsonOk({'invoice_id': 'inv-1', 'invoice_number': 'INV-0099', 'grand_total': '1000.00', 'duplicate': false});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, localDb: localDb));
    await tester.pumpAndSettle();

    expect(find.textContaining('FAILED'), findsOneWidget);
    expect(find.textContaining('VALIDATION_ERROR: product is inactive'), findsOneWidget);
    expect(find.byKey(const Key('outbox_retry_tx-failed')), findsOneWidget);

    await tester.tap(find.byKey(const Key('outbox_retry_tx-failed')));
    await tester.pumpAndSettle();

    expect(quoteCalls, 1);
    expect(find.textContaining('SYNCED'), findsOneWidget);
    expect(find.textContaining('INV-0099'), findsOneWidget);
    expect(await localDb.pendingInvoiceCount(), 0);
  });

  testWidgets('manual Sync Now button drains a PENDING entry', (tester) async {
    final localDb = FakeLocalDatabase();
    await localDb.enqueueInvoice(
      clientTransactionId: 'tx-pending',
      payloadJson: jsonEncode({
        'client_transaction_id': 'tx-pending',
        'location_id': 'loc-1',
        'tender_method': 'CASH',
        'customer_id': null,
        'lines': [
          {'product_id': 'p1', 'quantity': '1'}
        ],
      }),
    );

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/pos/quote') {
        return _jsonOk({
          'lines': [],
          'taxable_total': '500.00',
          'tax_total': '0.00',
          'grand_total': '500.00',
        });
      }
      if (request.url.path == '/api/v1/pos/invoices') {
        return _jsonOk({'invoice_id': 'inv-2', 'invoice_number': 'INV-0100', 'grand_total': '500.00', 'duplicate': false});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, localDb: localDb));
    await tester.pumpAndSettle();

    expect(find.textContaining('PENDING'), findsOneWidget);

    await tester.tap(find.byKey(const Key('outbox_sync_now_button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('SYNCED'), findsOneWidget);
  });
}
