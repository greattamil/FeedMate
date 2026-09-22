// Widget tests for the Contra / Buy-Back screen: picking a customer and
// location, adding a line via the product picker, and posting the contra
// transaction (PRD 8 — stock taken back from a farmer, credited against
// their receivable instead of paid in cash).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/local_db.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/contra/contra_screen.dart';
import 'package:feedmate_app/features/pos/product_repository.dart';

import 'fake_local_db.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

/// ContraLineFormScreen's plain ListView only inflates elements within its
/// viewport + cache extent — same lazy-build gotcha documented in
/// grn_test.dart. Scroll incrementally rather than jumping with ensureVisible.
Future<void> _revealAndTap(WidgetTester tester, Key key) async {
  await tester.dragUntilVisible(find.byKey(key), find.byType(Scrollable).first, const Offset(0, -150));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

Future<void> _revealAndEnterText(WidgetTester tester, Key key, String text) async {
  await tester.dragUntilVisible(find.byKey(key), find.byType(Scrollable).first, const Offset(0, -150));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(key), text);
}

Widget _wrap({required http.Client httpClient}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  final localDb = FakeLocalDatabase();
  return MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: apiClient),
      Provider<LocalDatabase>.value(value: localDb),
      Provider<ProductRepository>(create: (_) => ProductRepository(client: apiClient, localDb: localDb)),
    ],
    child: const MaterialApp(home: ContraScreen()),
  );
}

Map<String, dynamic> _cattleFeedProduct() => {
      'id': 'prod-1',
      'sku': 'CF-ECO-01',
      'name': 'Cattle Feed Economy 50kg',
      'default_purchase_uom_id': 'uom-bag',
      'tax_profile_id': 'tax-gst5',
      'batch_required': true,
      'loose_sale_allowed': false,
      'active': true,
    };

void main() {
  testWidgets('post a contra transaction with one line end-to-end', (tester) async {
    Map<String, dynamic>? postedBody;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/locations') {
        return _jsonOk({
          'locations': [
            {'id': 'loc-1', 'code': 'MAIN', 'name': 'Main Store', 'type': 'STORE'},
          ]
        });
      }
      if (request.url.path == '/api/v1/customers') {
        return _jsonOk({
          'customers': [
            {'id': 'cust-1', 'customer_code': 'FARM001', 'name': 'Test Farmer', 'customer_type': 'FARMER', 'phone': '9876543210'},
          ]
        });
      }
      if (request.url.path == '/api/v1/products/search') {
        return _jsonOk({
          'results': [
            {'product': _cattleFeedProduct(), 'match_type': 'EXACT_NAME'},
          ]
        });
      }
      if (request.url.path == '/api/v1/contra') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'contra_id': 'contra-1', 'contra_number': 'CN-0001', 'total_value': '2000.00'}),
          201,
        );
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    // Location auto-selected (only one), so pick the customer next.
    await tester.tap(find.byKey(const Key('contra_customer_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('customer_result_cust-1')));
    await tester.pumpAndSettle();

    expect(find.text('Test Farmer'), findsOneWidget);

    await tester.tap(find.byKey(const Key('contra_add_line_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('product_picker_search_field')), 'cattle');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('product_picker_result_prod-1')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('contra_line_batch_field')), 'B-100');
    await _revealAndEnterText(tester, const Key('contra_line_qty_field'), '20');
    await _revealAndEnterText(tester, const Key('contra_line_price_field'), '100.00');
    await _revealAndTap(tester, const Key('contra_line_save_button'));

    expect(find.textContaining('Batch B-100'), findsOneWidget);

    await _revealAndTap(tester, const Key('contra_post_button'));

    expect(find.text('Contra Posted'), findsOneWidget);
    expect(find.textContaining('CN-0001'), findsOneWidget);
    expect(find.textContaining('₹2,000.00'), findsOneWidget);

    expect(postedBody, isNotNull);
    expect(postedBody!['customer_id'], 'cust-1');
    final lines = postedBody!['lines'] as List<dynamic>;
    expect(lines, hasLength(1));
    final line = lines.first as Map<String, dynamic>;
    expect(line['product_id'], 'prod-1');
    expect(line['batch_code'], 'B-100');
    expect(line['location_id'], 'loc-1');
    expect(line['uom_id'], 'uom-bag');
    expect(line['quantity'], '20');
    expect(line['valuation_unit_price'], '100.00');
    expect(line['quality_status'], 'ACCEPTED');

    await tester.tap(find.byKey(const Key('contra_posted_ok_button')));
    await tester.pumpAndSettle();

    // Form clears after a successful post, ready for the next contra.
    expect(find.text('Select customer'), findsOneWidget);
  });

  testWidgets('line form rejects a zero quantity and a missing required batch code', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/locations') {
        return _jsonOk({
          'locations': [
            {'id': 'loc-1', 'code': 'MAIN', 'name': 'Main Store', 'type': 'STORE'},
          ]
        });
      }
      if (request.url.path == '/api/v1/customers') {
        return _jsonOk({'customers': []});
      }
      if (request.url.path == '/api/v1/products/search') {
        return _jsonOk({
          'results': [
            {'product': _cattleFeedProduct(), 'match_type': 'EXACT_NAME'},
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('contra_add_line_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('product_picker_search_field')), 'cattle');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('product_picker_result_prod-1')));
    await tester.pumpAndSettle();

    // No quantity entered, no batch code — this product is batch_required.
    await _revealAndTap(tester, const Key('contra_line_save_button'));
    expect(find.text('Enter a quantity greater than zero'), findsOneWidget);

    await _revealAndEnterText(tester, const Key('contra_line_qty_field'), '5');
    await _revealAndEnterText(tester, const Key('contra_line_price_field'), '50.00');
    await _revealAndTap(tester, const Key('contra_line_save_button'));
    expect(find.text('This product requires a batch code'), findsOneWidget);
  });
}
