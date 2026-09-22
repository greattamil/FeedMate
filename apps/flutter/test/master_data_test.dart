// Widget tests for the Categories & Brands admin screen: browsing, adding,
// editing, and activating/deactivating both lookup types.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/products/master_data_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

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

Map<String, dynamic> _category({required String id, required String name, String localName = '', bool active = true}) {
  return {'id': id, 'name': name, 'local_name': localName, 'active': active};
}

Map<String, dynamic> _brand({required String id, required String name, String localName = '', bool active = true}) {
  return {'id': id, 'name': name, 'local_name': localName, 'active': active};
}

void main() {
  testWidgets('Lists categories and brands in their respective tabs', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/categories/all') {
        return _jsonOk({
          'categories': [_category(id: 'cat-1', name: 'Cattle Feed')]
        });
      }
      if (request.url.path == '/api/v1/brands/all') {
        return _jsonOk({
          'brands': [_brand(id: 'brand-1', name: 'Godrej Agrovet')]
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

  testWidgets('Adding a category posts the name and local name, then refreshes the list', (tester) async {
    var categories = <Map<String, dynamic>>[];
    Map<String, dynamic>? postedBody;

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/categories') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        categories = [_category(id: 'cat-new', name: postedBody!['name'] as String, localName: postedBody!['local_name'] as String? ?? '')];
        return http.Response(jsonEncode({'id': 'cat-new', 'name': postedBody!['name']}), 201);
      }
      if (request.url.path == '/api/v1/categories/all') {
        return _jsonOk({'categories': categories});
      }
      if (request.url.path == '/api/v1/brands/all') {
        return _jsonOk({'brands': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('master_data_add_fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('category_name_field')), 'Mineral Mix');
    await tester.enterText(find.byKey(const Key('category_name_field_local')), 'மினரல் மிக்ஸ்');
    await tester.tap(find.byKey(const Key('category_name_field_submit')));
    await tester.pumpAndSettle();

    expect(postedBody!['name'], 'Mineral Mix');
    expect(postedBody!['local_name'], 'மினரல் மிக்ஸ்');
    expect(find.text('Mineral Mix'), findsOneWidget);
  });

  testWidgets('Editing a category renames it in place via PUT', (tester) async {
    var categories = [_category(id: 'cat-1', name: 'Catle Feed')];
    Map<String, dynamic>? putBody;

    final client = MockClient((request) async {
      if (request.method == 'PUT' && request.url.path == '/api/v1/categories/cat-1') {
        putBody = jsonDecode(request.body) as Map<String, dynamic>;
        categories = [_category(id: 'cat-1', name: putBody!['name'] as String, localName: putBody!['local_name'] as String? ?? '')];
        return http.Response('', 204);
      }
      if (request.url.path == '/api/v1/categories/all') {
        return _jsonOk({'categories': categories});
      }
      if (request.url.path == '/api/v1/brands/all') {
        return _jsonOk({'brands': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.text('Catle Feed'), findsOneWidget);

    await tester.tap(find.byKey(const Key('master_data_edit_cat-1')));
    await tester.pumpAndSettle();

    // The edit dialog pre-fills the existing name.
    expect(find.text('Catle Feed'), findsWidgets);

    await tester.enterText(find.byKey(const Key('category_edit_name_field')), 'Cattle Feed');
    await tester.tap(find.byKey(const Key('category_edit_name_field_submit')));
    await tester.pumpAndSettle();

    expect(putBody!['name'], 'Cattle Feed');
    expect(find.text('Cattle Feed'), findsOneWidget);
    expect(find.text('Catle Feed'), findsNothing);
  });

  testWidgets('Deactivating a brand requires confirmation and posts the status change', (tester) async {
    var brands = [_brand(id: 'brand-1', name: 'Godrej Agrovet')];
    Map<String, dynamic>? statusBody;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/categories/all') {
        return _jsonOk({'categories': []});
      }
      if (request.method == 'POST' && request.url.path == '/api/v1/brands/brand-1/status') {
        statusBody = jsonDecode(request.body) as Map<String, dynamic>;
        brands = [_brand(id: 'brand-1', name: 'Godrej Agrovet', active: false)];
        return http.Response('', 204);
      }
      if (request.url.path == '/api/v1/brands/all') {
        return _jsonOk({'brands': brands});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Brands'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('master_data_toggle_active_brand-1')));
    await tester.pumpAndSettle();

    expect(find.text('Deactivate?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('master_data_deactivate_confirm')));
    await tester.pumpAndSettle();

    expect(statusBody!['active'], false);
    // Deactivated brands stay visible (dimmed, marked Inactive) rather than
    // disappearing — the whole point of "full CRUD" is being able to find
    // and reactivate them again, unlike the old active-only list.
    expect(find.text('Godrej Agrovet'), findsOneWidget);
    expect(find.textContaining('Inactive'), findsOneWidget);
  });

  testWidgets('Reactivating a deactivated category posts active:true', (tester) async {
    var categories = [_category(id: 'cat-1', name: 'Old Feed', active: false)];
    Map<String, dynamic>? statusBody;

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/categories/cat-1/status') {
        statusBody = jsonDecode(request.body) as Map<String, dynamic>;
        categories = [_category(id: 'cat-1', name: 'Old Feed', active: true)];
        return http.Response('', 204);
      }
      if (request.url.path == '/api/v1/categories/all') {
        return _jsonOk({'categories': categories});
      }
      if (request.url.path == '/api/v1/brands/all') {
        return _jsonOk({'brands': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.textContaining('Inactive'), findsOneWidget);

    // Reactivating skips the confirmation dialog entirely (only
    // deactivation is destructive enough to warrant one).
    await tester.tap(find.byKey(const Key('master_data_toggle_active_cat-1')));
    await tester.pumpAndSettle();

    expect(statusBody!['active'], true);
    expect(find.textContaining('Inactive'), findsNothing);
  });
}
