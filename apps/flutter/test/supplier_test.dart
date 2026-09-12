// Widget tests for the supplier payable feature — the mirror image of
// khata_test.dart on the payable side: searching for a supplier, viewing
// their statement (payable summary + itemized ledger), and recording a
// payment. Uses a mocked HTTP client — end-to-end behavior against the real
// Go server is verified separately (see docs/IMPLEMENTATION_STATUS.md).
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/supplier/supplier_detail_screen.dart';
import 'package:feedmate_app/features/supplier/supplier_list_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

Widget _wrapWithProviders({required http.Client httpClient, required Widget child}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  return MultiProvider(
    providers: [
      Provider<SecureStorage>.value(value: storage),
      Provider<ApiClient>.value(value: apiClient),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('Supplier list shows search results and navigates into a statement', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/suppliers') {
        return _jsonOk({
          'suppliers': [
            {'id': 'sup-1', 'supplier_code': 'SUP001', 'name': 'Test Feed Mill', 'phone': '9876543210', 'gstin': '29ABCDE1234F1Z5'}
          ]
        });
      }
      if (request.url.path == '/api/v1/suppliers/sup-1') {
        return _jsonOk({
          'id': 'sup-1', 'supplier_code': 'SUP001', 'name': 'Test Feed Mill',
          'phone': '9876543210', 'gstin': '29ABCDE1234F1Z5', 'payment_terms_days': 30,
          'outstanding_payable': '12000.00',
        });
      }
      if (request.url.path == '/api/v1/suppliers/sup-1/ledger') {
        return _jsonOk({
          'entries': [
            {
              'id': 'e2', 'entry_date': '2026-09-12T12:00:00+05:30', 'document_type': 'GRN',
              'document_id': 'grn-2', 'debit': '0.00', 'credit': '12000.00', 'description': 'GRN received',
            },
            {
              'id': 'e1', 'entry_date': '2026-09-10T09:00:00+05:30', 'document_type': 'PAYMENT',
              'document_id': 'pmt-1', 'debit': '5000.00', 'credit': '0.00', 'description': 'Cash payment',
            },
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const SupplierListScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Test Feed Mill'), findsOneWidget);
    expect(find.textContaining('SUP001'), findsOneWidget);

    await tester.tap(find.byKey(const Key('supplier_sup-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('supplier_outstanding_payable')), findsOneWidget);
    expect(find.text('₹12000.00'), findsOneWidget);
    expect(find.text('30 days'), findsOneWidget);

    expect(find.text('GRN received'), findsOneWidget);
    expect(find.text('Cash payment'), findsOneWidget);
    expect(find.text('+₹12000.00'), findsOneWidget);
    expect(find.text('-₹5000.00'), findsOneWidget);
  });

  testWidgets('Record Payment posts a manual payment and refreshes the balance', (tester) async {
    var getDetailCalls = 0;
    String? sentIdempotencyKey;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/suppliers/sup-2') {
        getDetailCalls++;
        final payable = getDetailCalls == 1 ? '10000.00' : '7500.00';
        return _jsonOk({
          'id': 'sup-2', 'supplier_code': 'SUP002', 'name': 'Payment Test Mill',
          'phone': null, 'gstin': null, 'payment_terms_days': 15,
          'outstanding_payable': payable,
        });
      }
      if (request.url.path == '/api/v1/suppliers/sup-2/ledger') {
        return _jsonOk({'entries': []});
      }
      if (request.url.path == '/api/v1/payments/supplier-payments') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['supplier_id'], 'sup-2');
        expect(Decimal.parse(body['amount'] as String), Decimal.parse('2500.00'));
        expect(body['method'], 'CASH');
        sentIdempotencyKey = body['idempotency_key'] as String;
        return _jsonOk({'payment_id': 'pay-1', 'duplicate': false});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const SupplierDetailScreen(supplierId: 'sup-2'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('₹10000.00'), findsWidgets);

    await tester.tap(find.byKey(const Key('record_payment_fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('payment_amount_field')), '2500.00');
    await tester.tap(find.byKey(const Key('payment_submit_button')));
    await tester.pumpAndSettle();

    expect(sentIdempotencyKey, isNotNull);
    expect(sentIdempotencyKey, isNotEmpty);
    expect(find.textContaining('Payment of ₹2500.00 recorded'), findsOneWidget);
    expect(find.text('₹7500.00'), findsOneWidget);
  });

  testWidgets('Record Payment rejects a zero amount client-side before calling the server', (tester) async {
    var paymentCallCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/suppliers/sup-3') {
        return _jsonOk({
          'id': 'sup-3', 'supplier_code': 'SUP003', 'name': 'Zero Amount Mill',
          'phone': null, 'gstin': null, 'payment_terms_days': 0,
          'outstanding_payable': '1000.00',
        });
      }
      if (request.url.path == '/api/v1/suppliers/sup-3/ledger') {
        return _jsonOk({'entries': []});
      }
      if (request.url.path == '/api/v1/payments/supplier-payments') {
        paymentCallCount++;
        return _jsonOk({'payment_id': 'pay-2', 'duplicate': false});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const SupplierDetailScreen(supplierId: 'sup-3'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('record_payment_fab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('payment_submit_button')));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid amount greater than zero'), findsOneWidget);
    expect(paymentCallCount, 0);
  });
}
