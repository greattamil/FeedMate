// Widget tests for the Categories & Brands admin screen: browsing, adding,
// and deactivating both lookup types.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/products/master_data_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

Widget _wrapWithProviders({required http.Client httpClient}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  return MultiProvider(
    providers: [
      Provider<SecureStorage>.value(value: storage),
      Provider<ApiClient>.value(value: apiClient),
    ],
    child: const MaterialApp(home: MasterDataScreen()),
  );
}

void main() {
  testWidgets('Lists categories and brands in their respective tabs', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/categories') {
        return _jsonOk({
          'categories': [
            {'id': 'cat-1', 'name': 'Cattle Feed'}
          ]
        });
      }
      if (request.url.path == '/api/v1/brands') {
        return _jsonOk({
          'brands': [
            {'id': 'brand-1', 'name': 'Godrej Agrovet'}
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.text('Cattle Feed'), findsOneWidget);

    await tester.tap(find.text('Brands'));
    await tester.pumpAndSettle();
    expect(find.text('Godrej Agrovet'), findsOneWidget);
  });

  testWidgets('Adding a category posts the name and refreshes the list', (tester) async {
    var categories = <Map<String, dynamic>>[];
    Map<String, dynamic>? postedBody;

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/categories') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        categories = [
          {'id': 'cat-new', 'name': postedBody!['name']}
        ];
        return http.Response(jsonEncode({'id': 'cat-new', 'name': postedBody!['name']}), 201);
      }
      if (request.url.path == '/api/v1/categories') {
        return _jsonOk({'categories': categories});
      }
      if (request.url.path == '/api/v1/brands') {
        return _jsonOk({'brands': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('master_data_add_fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('category_name_field')), 'Mineral Mix');
    await tester.tap(find.byKey(const Key('category_name_field_submit')));
    await tester.pumpAndSettle();

    expect(postedBody!['name'], 'Mineral Mix');
    expect(find.text('Mineral Mix'), findsOneWidget);
  });

  testWidgets('Deactivating a brand requires confirmation and posts the status change', (tester) async {
    var brands = [
      {'id': 'brand-1', 'name': 'Godrej Agrovet'}
    ];
    Map<String, dynamic>? statusBody;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/categories') {
        return _jsonOk({'categories': []});
      }
      if (request.method == 'POST' && request.url.path == '/api/v1/brands/brand-1/status') {
        statusBody = jsonDecode(request.body) as Map<String, dynamic>;
        brands = [];
        return http.Response('', 204);
      }
      if (request.url.path == '/api/v1/brands') {
        return _jsonOk({'brands': brands});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Brands'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('master_data_deactivate_brand-1')));
    await tester.pumpAndSettle();

    expect(find.text('Deactivate?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('master_data_deactivate_confirm')));
    await tester.pumpAndSettle();

    expect(statusBody!['active'], false);
    expect(find.text('Godrej Agrovet'), findsNothing);
    expect(find.text('No brands yet'), findsOneWidget);
  });
}
