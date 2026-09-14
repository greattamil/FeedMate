// Widget tests proving the POS catalog's category filter is a real,
// dynamic source of truth — populated from the same categories table the
// Categories & Brands admin screen manages (see product_admin_api.dart's
// listCategories()) — rather than a fixed list of category names baked
// into the client that could drift from what a shop owner has actually
// configured.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/local_db.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/pos/cart_model.dart';
import 'package:feedmate_app/features/pos/catalog_panel.dart';
import 'package:feedmate_app/features/pos/product_repository.dart';

import 'fake_local_db.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

Widget _wrap({required http.Client httpClient}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  final localDb = FakeLocalDatabase();
  return MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: apiClient),
      ChangeNotifierProvider<CartModel>(create: (_) => CartModel()),
      Provider<LocalDatabase>.value(value: localDb),
      Provider<ProductRepository>(create: (_) => ProductRepository(client: apiClient, localDb: localDb)),
    ],
    child: const MaterialApp(home: Scaffold(body: CatalogPanel())),
  );
}

void main() {
  testWidgets('category chips are populated from the real /categories endpoint, not a fixed list', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/categories') {
        return _jsonOk({
          'categories': [
            {'id': 'cat-goat', 'name': 'Goat Feed Special'}, // a name no hard-coded list would ever contain
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('category_chip_all')), findsOneWidget);
    expect(find.text('Goat Feed Special'), findsOneWidget);
    // None of the previously hard-coded category names should appear.
    expect(find.text('Cattle Feed'), findsNothing);
    expect(find.text('Poultry Feed'), findsNothing);
    expect(find.text('Mineral Mix'), findsNothing);
  });

  testWidgets('selecting a category browses it via category_id, with no search text required', (tester) async {
    String? capturedQ;
    String? capturedCategoryId;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/categories') {
        return _jsonOk({
          'categories': [
            {'id': 'cat-goat', 'name': 'Goat Feed Special'},
          ]
        });
      }
      if (request.url.path == '/api/v1/products/search') {
        capturedQ = request.url.queryParameters['q'];
        capturedCategoryId = request.url.queryParameters['category_id'];
        return _jsonOk({
          'results': [
            {
              'product': {
                'id': 'p-goat', 'sku': 'GF-01', 'name': 'Goat Feed Premium',
                'selling_price': '800.00', 'batch_required': false,
                'loose_sale_allowed': false, 'active': true,
              },
              'match_type': 'FUZZY',
            }
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    // No search text typed at all — selecting the category alone must
    // browse it via category_id, never by faking a text search on the
    // category's label (the old, non-single-source-of-truth behavior).
    await tester.tap(find.text('Goat Feed Special'));
    await tester.pumpAndSettle();

    expect(capturedCategoryId, 'cat-goat');
    expect(capturedQ == null || capturedQ == '', isTrue, reason: 'no q param should be sent when only browsing by category');
    expect(find.text('Goat Feed Premium'), findsOneWidget);
  });

  testWidgets('typing a search query while a category is selected sends both filters together', (tester) async {
    String? capturedQ;
    String? capturedCategoryId;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/categories') {
        return _jsonOk({
          'categories': [
            {'id': 'cat-goat', 'name': 'Goat Feed Special'},
          ]
        });
      }
      if (request.url.path == '/api/v1/products/search') {
        capturedQ = request.url.queryParameters['q'];
        capturedCategoryId = request.url.queryParameters['category_id'];
        return _jsonOk({'results': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Goat Feed Special'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('search_field')), 'premium');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(capturedQ, 'premium');
    expect(capturedCategoryId, 'cat-goat');
  });
}
