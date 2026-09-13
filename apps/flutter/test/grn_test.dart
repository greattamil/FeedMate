// Widget tests for the procurement/GRN (goods receipt) screen: picking a
// supplier and location, adding a line via the product picker, posting the
// GRN, and the tare-override reasoned-exception retry path (PRD A7) when the
// server rejects a line's tare as exceeding the configured threshold.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/local_db.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/procurement/grn_screen.dart';
import 'package:feedmate_app/features/pos/product_repository.dart';

import 'fake_local_db.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

/// GrnLineFormScreen's plain ListView only inflates elements within its
/// viewport + cache extent (Flutter's normal Sliver lazy-build behavior), so
/// a field further down the form may not exist in the tree yet — ensureVisible
/// can't reveal it because it requires the element to already exist. Scrolling
/// incrementally (like a real user would) brings each field into the cache
/// extent as we go.
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
    child: const MaterialApp(home: GrnScreen()),
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

Future<void> _addBasicLine(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('grn_add_line_button')));
  await tester.pumpAndSettle();

  await tester.enterText(find.byKey(const Key('product_picker_search_field')), 'cattle');
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(const Key('product_picker_result_prod-1')));
  await tester.pumpAndSettle();

  await tester.enterText(find.byKey(const Key('grn_line_batch_code_field')), 'B-100');
  await _revealAndEnterText(tester, const Key('grn_line_qty_field'), '20');
  await _revealAndEnterText(tester, const Key('grn_line_unit_cost_field'), '900.00');
  await _revealAndTap(tester, const Key('grn_line_save_button'));
}

void main() {
  testWidgets('post a GRN with one line end-to-end', (tester) async {
    Map<String, dynamic>? postedBody;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/locations') {
        return _jsonOk({
          'locations': [
            {'id': 'loc-1', 'code': 'MAIN', 'name': 'Main Store', 'type': 'STORE'},
          ]
        });
      }
      if (request.url.path == '/api/v1/suppliers') {
        return _jsonOk({
          'suppliers': [
            {'id': 'sup-1', 'supplier_code': 'SUP001', 'name': 'Test Feed Mill', 'phone': '9876543210', 'gstin': null},
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
      if (request.url.path == '/api/v1/procurement/grns') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'grn_id': 'grn-1', 'grn_number': 'GRN-0001'}), 201);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    // Location auto-selected (only one), so pick the supplier next.
    await tester.tap(find.byKey(const Key('grn_supplier_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('supplier_picker_result_sup-1')));
    await tester.pumpAndSettle();

    expect(find.text('Test Feed Mill'), findsOneWidget);

    await _addBasicLine(tester);

    expect(find.textContaining('Batch B-100'), findsOneWidget);

    await _revealAndTap(tester, const Key('grn_post_button'));

    expect(find.text('GRN Posted'), findsOneWidget);
    expect(find.textContaining('GRN-0001'), findsOneWidget);

    expect(postedBody, isNotNull);
    expect(postedBody!['supplier_id'], 'sup-1');
    final lines = postedBody!['lines'] as List<dynamic>;
    expect(lines, hasLength(1));
    final line = lines.first as Map<String, dynamic>;
    expect(line['product_id'], 'prod-1');
    expect(line['batch_code'], 'B-100');
    expect(line['location_id'], 'loc-1');
    expect(line['uom_id'], 'uom-bag');
    expect(line['tax_profile_id'], 'tax-gst5');

    await tester.tap(find.byKey(const Key('grn_posted_ok_button')));
    await tester.pumpAndSettle();

    // Form clears after a successful post, ready for the next GRN.
    expect(find.text('Select supplier'), findsOneWidget);
  });

  testWidgets('tare exceeding the threshold prompts for an override reason, then retries and succeeds', (tester) async {
    var postAttempts = 0;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/locations') {
        return _jsonOk({
          'locations': [
            {'id': 'loc-1', 'code': 'MAIN', 'name': 'Main Store', 'type': 'STORE'},
          ]
        });
      }
      if (request.url.path == '/api/v1/suppliers') {
        return _jsonOk({
          'suppliers': [
            {'id': 'sup-1', 'supplier_code': 'SUP001', 'name': 'Test Feed Mill', 'phone': null, 'gstin': null},
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
      if (request.url.path == '/api/v1/procurement/grns') {
        postAttempts++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (postAttempts == 1) {
          return http.Response(
            jsonEncode({
              'error': {
                'code': 'CONFLICT',
                'message': 'validation error: tare weight exceeds the configured maximum threshold',
              }
            }),
            409,
          );
        }
        expect(body['override_tare'], true);
        expect(body['override_tare_reason'], 'Wet bags, confirmed with supplier');
        return http.Response(jsonEncode({'grn_id': 'grn-2', 'grn_number': 'GRN-0002'}), 201);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('grn_supplier_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('supplier_picker_result_sup-1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('grn_add_line_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('product_picker_search_field')), 'cattle');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('product_picker_result_prod-1')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('grn_line_batch_code_field')), 'B-200');
    await _revealAndEnterText(tester, const Key('grn_line_qty_field'), '10');
    await _revealAndEnterText(tester, const Key('grn_line_unit_cost_field'), '850.00');
    await _revealAndTap(tester, const Key('grn_line_capture_weight_switch'));
    await _revealAndEnterText(tester, const Key('grn_line_gross_weight_field'), '520.00');
    await _revealAndEnterText(tester, const Key('grn_line_measured_tare_field'), '20.00');
    await _revealAndTap(tester, const Key('grn_line_save_button'));

    await _revealAndTap(tester, const Key('grn_post_button'));

    expect(find.text('Tare Exceeds Threshold'), findsOneWidget);
    expect(find.textContaining('tare weight exceeds'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('grn_tare_override_reason_field')),
      'Wet bags, confirmed with supplier',
    );
    await tester.tap(find.byKey(const Key('grn_tare_override_submit')));
    await tester.pumpAndSettle();

    expect(postAttempts, 2);
    expect(find.text('GRN Posted'), findsOneWidget);
    expect(find.textContaining('GRN-0002'), findsOneWidget);
  });
}
