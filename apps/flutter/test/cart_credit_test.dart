// Widget tests for the cart screen's CREDIT tender path: selecting a
// customer via the picker, finalizing a credit sale, and the credit-limit
// override dialog when the server rejects an over-limit sale. Uses a mocked
// HTTP client — end-to-end behavior against the real Go server (including
// the actual CREDIT_LIMIT_EXCEEDED rejection) is verified separately.
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/local_db.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/pos/cart_model.dart';
import 'package:feedmate_app/features/pos/cart_screen.dart';
import 'package:feedmate_app/features/pos/product.dart';

import 'fake_local_db.dart';

Widget _wrapCartScreen({required http.Client httpClient, required CartModel cart}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  final localDb = FakeLocalDatabase();
  return MultiProvider(
    providers: [
      Provider<SecureStorage>.value(value: storage),
      Provider<ApiClient>.value(value: apiClient),
      ChangeNotifierProvider<CartModel>.value(value: cart),
      Provider<LocalDatabase>.value(value: localDb),
    ],
    child: const MaterialApp(home: CartScreen()),
  );
}

Product _testProduct() => Product(
      id: 'p1',
      sku: 'CF-01',
      name: 'Cattle Feed 50kg',
      sellingPrice: Decimal.parse('1200.00'),
      batchRequired: false,
      looseSaleAllowed: false,
      active: true,
    );

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

void main() {
  testWidgets('selecting CREDIT tender requires picking a customer before charging', (tester) async {
    final cart = CartModel()..addProduct(_testProduct(), quantity: Decimal.one);
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/locations') {
        return _jsonOk({
          'locations': [
            {'id': 'loc-1', 'name': 'Main Store'}
          ]
        });
      }
      if (request.url.path == '/api/v1/pos/quote') {
        return _jsonOk({
          'lines': [
            {'product_id': 'p1', 'product_name': 'Cattle Feed 50kg', 'line_total': '1200.00'}
          ],
          'taxable_total': '1200.00',
          'tax_total': '0.00',
          'grand_total': '1200.00',
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapCartScreen(httpClient: client, cart: cart));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Credit (Khata)'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('customer_picker_tile')), findsOneWidget);
    expect(find.text('Select customer'), findsOneWidget);

    await tester.tap(find.byKey(const Key('checkout_button')));
    await tester.pumpAndSettle();
    expect(find.text('Select a customer for a credit sale'), findsOneWidget);
  });

  testWidgets('credit sale over the limit prompts for an override reason, then retries and succeeds',
      (tester) async {
    final cart = CartModel()..addProduct(_testProduct(), quantity: Decimal.one);
    var invoiceAttempts = 0;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/locations') {
        return _jsonOk({
          'locations': [
            {'id': 'loc-1', 'name': 'Main Store'}
          ]
        });
      }
      if (request.url.path == '/api/v1/pos/quote') {
        return _jsonOk({
          'lines': [
            {'product_id': 'p1', 'product_name': 'Cattle Feed 50kg', 'line_total': '1200.00'}
          ],
          'taxable_total': '1200.00',
          'tax_total': '0.00',
          'grand_total': '1200.00',
        });
      }
      if (request.url.path == '/api/v1/customers') {
        return _jsonOk({
          'customers': [
            {'id': 'cust-1', 'customer_code': 'FARM001', 'name': 'Test Farmer', 'customer_type': 'FARMER'}
          ]
        });
      }
      if (request.url.path == '/api/v1/pos/invoices') {
        invoiceAttempts++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (invoiceAttempts == 1) {
          expect(body['override_credit_limit'], isNot(true));
          return http.Response(
            jsonEncode({
              'error': {
                'code': 'CREDIT_LIMIT_EXCEEDED',
                'message': 'credit limit exceeded: projected balance 1200.00 exceeds limit 1000.00',
                'retryable': false,
              }
            }),
            409,
          );
        }
        expect(body['override_credit_limit'], true);
        expect(body['override_reason'], 'Regular customer, approved by owner');
        return _jsonOk({
          'invoice_id': 'inv-1',
          'invoice_number': 'INV-0001',
          'grand_total': '1200.00',
          'duplicate': false,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapCartScreen(httpClient: client, cart: cart));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Credit (Khata)'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('customer_picker_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test Farmer'));
    await tester.pumpAndSettle();
    expect(find.text('Test Farmer'), findsOneWidget);

    await tester.tap(find.byKey(const Key('checkout_button')));
    await tester.pumpAndSettle();

    expect(find.text('Credit Limit Exceeded'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('override_reason_field')), 'Regular customer, approved by owner');
    await tester.tap(find.text('Override & Charge'));
    await tester.pumpAndSettle();

    expect(invoiceAttempts, 2);
    expect(find.text('Sale Complete'), findsOneWidget);
    expect(find.textContaining('INV-0001'), findsOneWidget);
  });

  testWidgets('split payment across CASH and CREDIT posts both tenders summing to the total', (tester) async {
    final cart = CartModel()..addProduct(_testProduct(), quantity: Decimal.one);
    Map<String, dynamic>? postedBody;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/locations') {
        return _jsonOk({
          'locations': [
            {'id': 'loc-1', 'name': 'Main Store'}
          ]
        });
      }
      if (request.url.path == '/api/v1/pos/quote') {
        return _jsonOk({
          'lines': [
            {'product_id': 'p1', 'product_name': 'Cattle Feed 50kg', 'line_total': '1200.00'}
          ],
          'taxable_total': '1200.00',
          'tax_total': '0.00',
          'grand_total': '1200.00',
        });
      }
      if (request.url.path == '/api/v1/customers') {
        return _jsonOk({
          'customers': [
            {'id': 'cust-1', 'customer_code': 'FARM001', 'name': 'Test Farmer', 'customer_type': 'FARMER'}
          ]
        });
      }
      if (request.url.path == '/api/v1/pos/invoices') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _jsonOk({
          'invoice_id': 'inv-2',
          'invoice_number': 'INV-0002',
          'grand_total': '1200.00',
          'duplicate': false,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapCartScreen(httpClient: client, cart: cart));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('split_payment_switch')));
    await tester.pumpAndSettle();

    // Single row starts prefilled with the full total (CASH) — checkout
    // should already be enabled with this one row alone.
    expect(find.byKey(const Key('split_tender_row_0')), findsOneWidget);
    expect(find.text('Fully allocated'), findsOneWidget);

    // Split it: reduce the first row and add a CREDIT row for the remainder.
    await tester.enterText(find.byKey(const Key('split_tender_amount_0')), '700.00');
    await tester.pumpAndSettle();
    expect(find.text('Remaining: ₹500.00'), findsOneWidget);

    await tester.tap(find.byKey(const Key('add_tender_button')));
    await tester.pumpAndSettle();
    // The new row is prefilled with the remaining amount.
    expect(find.byKey(const Key('split_tender_row_1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('split_tender_method_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Credit').last);
    await tester.pumpAndSettle();

    expect(find.text('Fully allocated'), findsOneWidget);

    // A CREDIT row now exists, so a customer must be picked before charging.
    await tester.tap(find.byKey(const Key('customer_picker_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test Farmer'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('checkout_button')));
    await tester.pumpAndSettle();

    expect(find.text('Sale Complete'), findsOneWidget);
    expect(postedBody, isNotNull);
    expect(postedBody!['customer_id'], 'cust-1');
    final tenders = postedBody!['tenders'] as List<dynamic>;
    expect(tenders, hasLength(2));
    expect(tenders[0], {'method': 'CASH', 'amount': '700.00'});
    expect(tenders[1], {'method': 'CREDIT', 'amount': '500.00'});
  });

  testWidgets('split payment blocks checkout until amounts add up to the invoice total', (tester) async {
    final cart = CartModel()..addProduct(_testProduct(), quantity: Decimal.one);
    var invoiceCallCount = 0;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/locations') {
        return _jsonOk({
          'locations': [
            {'id': 'loc-1', 'name': 'Main Store'}
          ]
        });
      }
      if (request.url.path == '/api/v1/pos/quote') {
        return _jsonOk({
          'lines': [
            {'product_id': 'p1', 'product_name': 'Cattle Feed 50kg', 'line_total': '1200.00'}
          ],
          'taxable_total': '1200.00',
          'tax_total': '0.00',
          'grand_total': '1200.00',
        });
      }
      if (request.url.path == '/api/v1/pos/invoices') {
        invoiceCallCount++;
        return _jsonOk({'invoice_id': 'x', 'invoice_number': 'X', 'grand_total': '1200.00', 'duplicate': false});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapCartScreen(httpClient: client, cart: cart));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('split_payment_switch')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('split_tender_amount_0')), '900.00');
    await tester.pumpAndSettle();
    expect(find.text('Remaining: ₹300.00'), findsOneWidget);

    // The checkout button itself is disabled while unallocated remains.
    final button = tester.widget<FilledButton>(find.byKey(const Key('checkout_button')));
    expect(button.onPressed, isNull);
    expect(invoiceCallCount, 0);
  });

  testWidgets('a cash sale with no customer picked omits customer_id — the server bills the Walking Customer', (tester) async {
    final cart = CartModel()..addProduct(_testProduct(), quantity: Decimal.one);
    Map<String, dynamic>? postedBody;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/locations') {
        return _jsonOk({
          'locations': [
            {'id': 'loc-1', 'name': 'Main Store'}
          ]
        });
      }
      if (request.url.path == '/api/v1/pos/quote') {
        return _jsonOk({
          'lines': [
            {'product_id': 'p1', 'product_name': 'Cattle Feed 50kg', 'line_total': '1200.00'}
          ],
          'taxable_total': '1200.00',
          'tax_total': '0.00',
          'grand_total': '1200.00',
        });
      }
      if (request.url.path == '/api/v1/pos/invoices') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _jsonOk({'invoice_id': 'inv-1', 'invoice_number': 'INV-0001', 'grand_total': '1200.00', 'duplicate': false});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapCartScreen(httpClient: client, cart: cart));
    await tester.pumpAndSettle();

    // Cash is the default tender — the customer picker is present but
    // clearly optional, unlike the required prompt shown for credit.
    expect(find.byKey(const Key('customer_picker_tile')), findsOneWidget);
    expect(find.text('Optional — billed to Walking Customer if left blank'), findsOneWidget);

    await tester.tap(find.byKey(const Key('checkout_button')));
    await tester.pumpAndSettle();

    expect(postedBody, isNotNull);
    expect(postedBody!.containsKey('customer_id'), isFalse);
  });

  testWidgets('picking a customer for a cash sale bills it to that customer, not anonymously', (tester) async {
    final cart = CartModel()..addProduct(_testProduct(), quantity: Decimal.one);
    Map<String, dynamic>? postedBody;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/locations') {
        return _jsonOk({
          'locations': [
            {'id': 'loc-1', 'name': 'Main Store'}
          ]
        });
      }
      if (request.url.path == '/api/v1/pos/quote') {
        return _jsonOk({
          'lines': [
            {'product_id': 'p1', 'product_name': 'Cattle Feed 50kg', 'line_total': '1200.00'}
          ],
          'taxable_total': '1200.00',
          'tax_total': '0.00',
          'grand_total': '1200.00',
        });
      }
      if (request.url.path == '/api/v1/customers') {
        return _jsonOk({
          'customers': [
            {'id': 'cust-1', 'customer_code': 'FARM001', 'name': 'Test Farmer', 'customer_type': 'FARMER'}
          ]
        });
      }
      if (request.url.path == '/api/v1/pos/invoices') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _jsonOk({'invoice_id': 'inv-1', 'invoice_number': 'INV-0001', 'grand_total': '1200.00', 'duplicate': false});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapCartScreen(httpClient: client, cart: cart));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('customer_picker_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test Farmer'));
    await tester.pumpAndSettle();
    expect(find.text('Test Farmer'), findsOneWidget);

    await tester.tap(find.byKey(const Key('checkout_button')));
    await tester.pumpAndSettle();

    expect(postedBody, isNotNull);
    expect(postedBody!['customer_id'], 'cust-1');
  });
}
