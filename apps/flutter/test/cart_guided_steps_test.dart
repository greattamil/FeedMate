// Regression test for the mobile split-payment bug: on a narrow/short
// phone viewport, the cart's checkout controls used to share a fixed
// non-scrolling bottom container with no guaranteed space, so enabling
// split payment (which adds extra tender rows) could push the Pay button
// below the visible screen entirely — see CartPanel.useGuidedSteps's doc
// comment. This test mounts CartPanel(useGuidedSteps: true) inside a
// deliberately short viewport (shorter than the old cramped mobile split)
// and proves the Pay button is still found and tappable after enabling
// split payment with two tender rows, via the new guided stages.
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
import 'package:feedmate_app/features/pos/cart_panel.dart';
import 'package:feedmate_app/features/pos/product.dart';

import 'fake_local_db.dart';

Widget _wrapGuidedCart({required http.Client httpClient, required CartModel cart}) {
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
    child: MaterialApp(
      home: Scaffold(
        // Deliberately short — this test targets the *vertical* overflow
        // bug specifically (the Pay button disappearing below the
        // viewport). Width is left comfortably wide on purpose: some of
        // the payment-stage widgets (e.g. the tender SegmentedButton) are
        // pre-existing and have their own, separate width sensitivity in
        // the test environment's font metrics that has nothing to do with
        // the bug this test exists to catch.
        body: SizedBox(
          height: 420,
          width: 480,
          child: const CartPanel(standalone: true, useGuidedSteps: true),
        ),
      ),
    ),
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
  testWidgets('guided stages keep the Pay button reachable even with split payment on a short screen',
      (tester) async {
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

    await tester.pumpWidget(_wrapGuidedCart(httpClient: client, cart: cart));
    await tester.pumpAndSettle();

    // Stage 0: cart lines only — payment controls aren't shown yet.
    expect(find.byKey(const Key('cart_lines_list')), findsOneWidget);
    expect(find.byKey(const Key('checkout_button')), findsNothing);
    expect(find.text('Next: Customer'), findsOneWidget);

    await tester.tap(find.byKey(const Key('guided_stage_next')));
    await tester.pumpAndSettle();

    // Stage 1: customer picker only.
    expect(find.byKey(const Key('customer_picker_tile')), findsOneWidget);
    expect(find.byKey(const Key('checkout_button')), findsNothing);

    await tester.tap(find.byKey(const Key('guided_stage_primary')));
    await tester.pumpAndSettle();

    // Stage 2: payment — this is the stage that used to overflow.
    expect(find.byKey(const Key('tender_method_toggle')), findsOneWidget);
    await tester.tap(find.byKey(const Key('split_payment_switch')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('split_tender_row_0')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('split_tender_amount_0')), '700.00');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add_tender_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('split_tender_row_1')), findsOneWidget);

    // The whole point of this test: even with two tender rows on a 420px-
    // tall viewport, the Pay button must still be a real, hittable widget
    // — not scrolled out of the render tree or clipped off-screen.
    final payButton = find.byKey(const Key('checkout_button'));
    expect(payButton, findsOneWidget);
    await tester.ensureVisible(payButton);
    await tester.pumpAndSettle();
    final renderBox = tester.renderObject<RenderBox>(payButton);
    final topLeft = renderBox.localToGlobal(Offset.zero);
    expect(topLeft.dy, greaterThanOrEqualTo(0));
    expect(topLeft.dy, lessThan(420));
  });
}
