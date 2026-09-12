// Widget tests for the Khata (customer credit ledger) feature: searching for
// a customer, then viewing their statement (credit summary + itemized
// ledger). Uses a mocked HTTP client — end-to-end behavior against the real
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
import 'package:feedmate_app/features/khata/khata_customer_list_screen.dart';
import 'package:feedmate_app/features/khata/khata_detail_screen.dart';

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
  testWidgets('Khata customer list shows search results and navigates into a statement', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers') {
        return _jsonOk({
          'customers': [
            {'id': 'cust-1', 'customer_code': 'FARM001', 'name': 'Test Farmer', 'customer_type': 'FARMER', 'phone': '9876543210'}
          ]
        });
      }
      if (request.url.path == '/api/v1/customers/cust-1') {
        return _jsonOk({
          'id': 'cust-1', 'customer_code': 'FARM001', 'name': 'Test Farmer',
          'customer_type': 'FARMER', 'phone': '9876543210',
          'credit_limit': '5000.00', 'outstanding_balance': '6200.00',
          'available_credit': '-1200.00', 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-1/ledger') {
        return _jsonOk({
          'entries': [
            {
              'id': 'e2', 'entry_date': '2026-09-12T12:00:00+05:30', 'document_type': 'INVOICE',
              'document_id': 'inv-2', 'debit': '1200.00', 'credit': '0.00', 'description': 'Credit sale INV-0002',
            },
            {
              'id': 'e1', 'entry_date': '2026-09-10T09:00:00+05:30', 'document_type': 'RECEIPT',
              'document_id': 'rcpt-1', 'debit': '0.00', 'credit': '500.00', 'description': 'Cash received',
            },
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const KhataCustomerListScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Test Farmer'), findsOneWidget);
    expect(find.textContaining('FARM001'), findsOneWidget);

    await tester.tap(find.byKey(const Key('khata_customer_cust-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('khata_outstanding_balance')), findsOneWidget);
    expect(find.text('₹6200.00'), findsOneWidget);
    expect(find.text('₹5000.00'), findsOneWidget);
    expect(find.text('₹-1200.00'), findsOneWidget);
    expect(find.text('Over credit limit'), findsOneWidget);

    expect(find.text('Credit sale INV-0002'), findsOneWidget);
    expect(find.text('Cash received'), findsOneWidget);
    expect(find.text('+₹1200.00'), findsOneWidget);
    expect(find.text('-₹500.00'), findsOneWidget);
  });

  testWidgets('Khata detail shows no over-limit warning when within limit', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers/cust-2') {
        return _jsonOk({
          'id': 'cust-2', 'customer_code': 'FARM002', 'name': 'Healthy Balance Farmer',
          'customer_type': 'FARMER', 'phone': null,
          'credit_limit': '5000.00', 'outstanding_balance': '1000.00',
          'available_credit': '4000.00', 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-2/ledger') {
        return _jsonOk({'entries': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const KhataDetailScreen(customerId: 'cust-2'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('No ledger entries yet'), findsOneWidget);
    expect(find.text('Over credit limit'), findsNothing);
  });

  testWidgets('Record Receipt posts a manual receipt and refreshes the balance', (tester) async {
    var getDetailCalls = 0;
    String? sentIdempotencyKey;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers/cust-3') {
        getDetailCalls++;
        final balance = getDetailCalls == 1 ? '5000.00' : '4200.00';
        final available = getDetailCalls == 1 ? '0.00' : '800.00';
        return _jsonOk({
          'id': 'cust-3', 'customer_code': 'FARM003', 'name': 'Receipt Test Farmer',
          'customer_type': 'FARMER', 'phone': null,
          'credit_limit': '5000.00', 'outstanding_balance': balance,
          'available_credit': available, 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-3/ledger') {
        return _jsonOk({'entries': []});
      }
      if (request.url.path == '/api/v1/payments/receipts') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['customer_id'], 'cust-3');
        // Decimal.toString() drops trailing zeros ("800.00" -> "800"), the
        // same formatting pos_api.dart already relies on for tender amounts
        // — the Go backend parses either representation to an identical
        // decimal value, so this must compare numerically, not as strings.
        expect(Decimal.parse(body['amount'] as String), Decimal.parse('800.00'));
        expect(body['method'], 'CASH');
        sentIdempotencyKey = body['idempotency_key'] as String;
        return _jsonOk({'payment_id': 'pay-1', 'duplicate': false});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const KhataDetailScreen(customerId: 'cust-3'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('₹5000.00'), findsWidgets);

    await tester.tap(find.byKey(const Key('record_receipt_fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('receipt_amount_field')), '800.00');
    await tester.tap(find.byKey(const Key('receipt_submit_button')));
    await tester.pumpAndSettle();

    expect(sentIdempotencyKey, isNotNull);
    expect(sentIdempotencyKey, isNotEmpty);
    expect(find.textContaining('Receipt of ₹800.00 recorded'), findsOneWidget);
    // The balance shown must come from a fresh fetch after recording, not a
    // client-side subtraction — asserted by the mock returning a different
    // balance on the second GET and that new value actually appearing.
    expect(find.text('₹4200.00'), findsOneWidget);
  });

  testWidgets('Record Receipt rejects a zero amount client-side before calling the server', (tester) async {
    var receiptCallCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers/cust-4') {
        return _jsonOk({
          'id': 'cust-4', 'customer_code': 'FARM004', 'name': 'Zero Amount Farmer',
          'customer_type': 'FARMER', 'phone': null,
          'credit_limit': '5000.00', 'outstanding_balance': '1000.00',
          'available_credit': '4000.00', 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-4/ledger') {
        return _jsonOk({'entries': []});
      }
      if (request.url.path == '/api/v1/payments/receipts') {
        receiptCallCount++;
        return _jsonOk({'payment_id': 'pay-2', 'duplicate': false});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const KhataDetailScreen(customerId: 'cust-4'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('record_receipt_fab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('receipt_submit_button')));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid amount greater than zero'), findsOneWidget);
    expect(receiptCallCount, 0);
  });
}
