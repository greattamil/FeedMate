// Widget tests for the GRN Product Picker (item 05): it must browse the
// full catalog immediately on open (not require typing first), and offer
// category filter chips, mirroring the POS catalog panel's experience.
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
import 'package:feedmate_app/features/procurement/product_picker_screen.dart';

import 'fake_local_db.dart';

http.Response _jsonOk(Map<String, dynamic> body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

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
    child: const MaterialApp(home: ProductPickerScreen()),
  );
}

Map<String, dynamic> _product({required String id, required String sku, required String name}) => {
      'id': id,
      'sku': sku,
      'name': name,
      'default_purchase_uom_id': 'uom-bag',
      'batch_required': true,
      'loose_sale_allowed': false,
      'active': true,
    };

void main() {
  testWidgets('shows the full catalog immediately on open, without requiring a search term', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/categories') {
        return _jsonOk({
          'categories': [
            {'id': 'cat-1', 'name': 'Cattle Feed'},
            {'id': 'cat-2', 'name': 'Poultry Feed'},
          ]
        });
      }
      if (request.url.path == '/api/v1/products/search') {
        expect(request.url.queryParameters['q'] ?? '', isEmpty);
        return _jsonOk({
          'results': [
            {'product': _product(id: 'p1', sku: 'CF-01', name: 'Cattle Feed 50kg'), 'match_type': 'ALL'},
            {'product': _product(id: 'p2', sku: 'PF-01', name: 'Poultry Feed 25kg'), 'match_type': 'ALL'},
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('product_picker_result_p1')), findsOneWidget);
    expect(find.byKey(const Key('product_picker_result_p2')), findsOneWidget);
  });

  testWidgets('shows category filter chips and narrows results when one is selected', (tester) async {
    String? lastCategoryId;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/categories') {
        return _jsonOk({
          'categories': [
            {'id': 'cat-1', 'name': 'Cattle Feed'},
            {'id': 'cat-2', 'name': 'Poultry Feed'},
          ]
        });
      }
      if (request.url.path == '/api/v1/products/search') {
        lastCategoryId = request.url.queryParameters['category_id'];
        if (lastCategoryId == 'cat-2') {
          return _jsonOk({
            'results': [
              {'product': _product(id: 'p2', sku: 'PF-01', name: 'Poultry Feed 25kg'), 'match_type': 'ALL'},
            ]
          });
        }
        return _jsonOk({
          'results': [
            {'product': _product(id: 'p1', sku: 'CF-01', name: 'Cattle Feed 50kg'), 'match_type': 'ALL'},
            {'product': _product(id: 'p2', sku: 'PF-01', name: 'Poultry Feed 25kg'), 'match_type': 'ALL'},
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('product_picker_category_chip_all')), findsOneWidget);
    expect(find.byKey(const Key('product_picker_category_chip_cat-1')), findsOneWidget);
    expect(find.byKey(const Key('product_picker_category_chip_cat-2')), findsOneWidget);
    expect(find.byKey(const Key('product_picker_result_p1')), findsOneWidget);
    expect(find.byKey(const Key('product_picker_result_p2')), findsOneWidget);

    await tester.tap(find.byKey(const Key('product_picker_category_chip_cat-2')));
    await tester.pumpAndSettle();

    expect(lastCategoryId, 'cat-2');
    expect(find.byKey(const Key('product_picker_result_p2')), findsOneWidget);
    expect(find.byKey(const Key('product_picker_result_p1')), findsNothing);
  });

  testWidgets('typing a search term narrows the browsed catalog', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/categories') {
        return _jsonOk({'categories': []});
      }
      if (request.url.path == '/api/v1/products/search') {
        final q = request.url.queryParameters['q'] ?? '';
        if (q == 'poultry') {
          return _jsonOk({
            'results': [
              {'product': _product(id: 'p2', sku: 'PF-01', name: 'Poultry Feed 25kg'), 'match_type': 'EXACT_NAME'},
            ]
          });
        }
        return _jsonOk({
          'results': [
            {'product': _product(id: 'p1', sku: 'CF-01', name: 'Cattle Feed 50kg'), 'match_type': 'ALL'},
            {'product': _product(id: 'p2', sku: 'PF-01', name: 'Poultry Feed 25kg'), 'match_type': 'ALL'},
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('product_picker_result_p1')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('product_picker_search_field')), 'poultry');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('product_picker_result_p1')), findsNothing);
    expect(find.byKey(const Key('product_picker_result_p2')), findsOneWidget);
  });

  testWidgets('shows an empty state when the catalog has no products at all', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/categories') {
        return _jsonOk({'categories': []});
      }
      if (request.url.path == '/api/v1/products/search') {
        return _jsonOk({'results': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.text('No products found'), findsOneWidget);
  });
}
