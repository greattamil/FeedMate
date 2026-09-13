// Widget tests for the Stock Count feature: starting a count, adding a
// product/batch/quantity, and posting it (which should adjust inventory
// for any line with a variance).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/local_db.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/pos/product_repository.dart';
import 'package:feedmate_app/features/stockcount/stock_count_history_screen.dart';

import 'fake_local_db.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

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
    child: const MaterialApp(home: StockCountHistoryScreen()),
  );
}

Map<String, dynamic> _cattleFeedProduct() => {
      'id': 'prod-1',
      'sku': 'CF-ECO-01',
      'name': 'Cattle Feed Economy 50kg',
      'default_purchase_uom_id': 'uom-bag',
      'batch_required': true,
      'loose_sale_allowed': false,
      'active': true,
    };

void main() {
  testWidgets('start a count, record a shortage, and post it', (tester) async {
    Map<String, dynamic>? postedLineBody;
    var countStatus = 'IN_PROGRESS';
    var postCalled = false;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/stock-counts' && request.method == 'GET') {
        return _jsonOk({'stock_counts': [], 'total': 0});
      }
      if (request.url.path == '/api/v1/locations') {
        return _jsonOk({
          'locations': [
            {'id': 'loc-1', 'name': 'Main Store'}
          ]
        });
      }
      if (request.url.path == '/api/v1/stock-counts' && request.method == 'POST') {
        return http.Response(jsonEncode({'id': 'sc-1'}), 201);
      }
      if (request.url.path == '/api/v1/stock-counts/sc-1' && request.method == 'GET') {
        return _jsonOk({
          'id': 'sc-1', 'location_id': 'loc-1', 'count_mode': 'CYCLE', 'status': countStatus,
          'started_at': '2026-09-13T10:00:00+05:30',
          'lines': postedLineBody == null
              ? []
              : [
                  {
                    'id': 'line-1', 'product_id': 'prod-1', 'product_name': 'Cattle Feed Economy 50kg', 'sku': 'CF-ECO-01',
                    'batch_id': 'batch-1', 'batch_code': 'B-100', 'expected_qty': '20.000', 'counted_qty': '18.000',
                    'variance_qty': '-2.000',
                  }
                ],
        });
      }
      if (request.url.path == '/api/v1/products/search') {
        return _jsonOk({
          'results': [
            {'product': _cattleFeedProduct(), 'match_type': 'EXACT_NAME'},
          ]
        });
      }
      if (request.url.path == '/api/v1/stock-counts/sc-1/batches') {
        return _jsonOk({
          'batches': [
            {'id': 'batch-1', 'batch_code': 'B-100', 'available_qty': '20.000'}
          ]
        });
      }
      if (request.url.path == '/api/v1/stock-counts/sc-1/lines') {
        postedLineBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('', 204);
      }
      if (request.url.path == '/api/v1/stock-counts/sc-1/post') {
        postCalled = true;
        countStatus = 'POSTED';
        return _jsonOk({'lines_adjusted': 1, 'net_value_delta': '-2000.00'});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('start_stock_count_fab')));
    await tester.pumpAndSettle();

    // Location auto-selected (only one) — just pick the count mode and start.
    await tester.tap(find.byKey(const Key('stock_count_start_submit')));
    await tester.pumpAndSettle();

    expect(find.text('Stock Count · CYCLE'), findsOneWidget);

    await tester.tap(find.byKey(const Key('stock_count_add_item_fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('product_picker_search_field')), 'cattle');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('product_picker_result_prod-1')));
    await tester.pumpAndSettle();

    await _revealAndEnterText(tester, const Key('stock_count_line_qty_field'), '18');
    await _revealAndTap(tester, const Key('stock_count_line_save_button'));

    expect(postedLineBody, isNotNull);
    expect(postedLineBody!['product_id'], 'prod-1');
    expect(postedLineBody!['batch_id'], 'batch-1');
    expect(postedLineBody!['counted_qty'], '18');

    expect(find.byKey(const Key('stock_count_line_line-1')), findsOneWidget);
    expect(find.byKey(const Key('stock_count_export_csv_button')), findsOneWidget);
    expect(find.textContaining('Expected 20 · Counted 18'), findsOneWidget);

    await tester.tap(find.byKey(const Key('stock_count_post_button')));
    await tester.pumpAndSettle();
    expect(find.text('Post Stock Count?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('stock_count_post_confirm')));
    await tester.pumpAndSettle();

    expect(postCalled, isTrue);
    expect(find.text('Stock Count Posted'), findsOneWidget);
    expect(find.textContaining('1 line(s) adjusted'), findsOneWidget);
    expect(find.textContaining('-2000.00'), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.text('Status: POSTED'), findsOneWidget);
    // A posted (resolved) count no longer offers add/post/cancel actions.
    expect(find.byKey(const Key('stock_count_add_item_fab')), findsNothing);
  });

  testWidgets('cancelling an in-progress count requires confirmation', (tester) async {
    var cancelCalled = false;
    var countStatus = 'IN_PROGRESS';

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/stock-counts' && request.method == 'GET') {
        return _jsonOk({'stock_counts': [], 'total': 0});
      }
      if (request.url.path == '/api/v1/locations') {
        return _jsonOk({
          'locations': [
            {'id': 'loc-1', 'name': 'Main Store'}
          ]
        });
      }
      if (request.url.path == '/api/v1/stock-counts' && request.method == 'POST') {
        return http.Response(jsonEncode({'id': 'sc-2'}), 201);
      }
      if (request.url.path == '/api/v1/stock-counts/sc-2' && request.method == 'GET') {
        return _jsonOk({
          'id': 'sc-2', 'location_id': 'loc-1', 'count_mode': 'CYCLE', 'status': countStatus,
          'started_at': '2026-09-13T10:00:00+05:30', 'lines': [],
        });
      }
      if (request.url.path == '/api/v1/stock-counts/sc-2/cancel') {
        cancelCalled = true;
        countStatus = 'CANCELLED';
        return http.Response('', 204);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('start_stock_count_fab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('stock_count_start_submit')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('stock_count_cancel_button')));
    await tester.pumpAndSettle();
    expect(find.text('Cancel Stock Count?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('stock_count_cancel_confirm')));
    await tester.pumpAndSettle();

    expect(cancelCalled, isTrue);
    expect(find.text('Status: CANCELLED'), findsOneWidget);
  });
}
