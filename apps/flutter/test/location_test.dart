// Widget tests for the Locations & Warehouses management screen: listing
// (including inactive), creating, editing, and reactivating a location —
// the full CRUD that item 06 of the feature request required (previously
// there was no in-app way to add a receiving location at all).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/products/location_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

Widget _wrap({required http.Client httpClient}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  return MultiProvider(
    providers: [
      Provider<SecureStorage>.value(value: storage),
      Provider<ApiClient>.value(value: apiClient),
    ],
    child: const MaterialApp(home: LocationScreen()),
  );
}

Map<String, dynamic> _location({required String id, required String code, required String name, String type = 'SHOP', bool active = true}) {
  return {'id': id, 'code': code, 'name': name, 'type': type, 'active': active};
}

void main() {
  testWidgets('shows an empty-state prompt when the tenant has no locations yet', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/locations/all') {
        return _jsonOk({'locations': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.textContaining('No locations yet'), findsOneWidget);
    expect(find.byKey(const Key('location_add_fab')), findsOneWidget);
  });

  testWidgets('lists locations, including inactive ones dimmed with a label', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/locations/all') {
        return _jsonOk({
          'locations': [
            _location(id: 'loc-1', code: 'MAIN', name: 'Main Shop'),
            _location(id: 'loc-2', code: 'OLD', name: 'Closed Godown', type: 'GODOWN', active: false),
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('location_item_loc-1')), findsOneWidget);
    expect(find.byKey(const Key('location_item_loc-2')), findsOneWidget);
    expect(find.text('Main Shop (MAIN)'), findsOneWidget);
    expect(find.text('Closed Godown (OLD)'), findsOneWidget);
    expect(find.textContaining('Inactive'), findsOneWidget);
  });

  testWidgets('creates a new location via the add form', (tester) async {
    Map<String, dynamic>? postedBody;
    var listCallCount = 0;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/locations/all') {
        listCallCount++;
        if (listCallCount == 1) return _jsonOk({'locations': []});
        return _jsonOk({
          'locations': [_location(id: 'loc-9', code: 'GDN1', name: 'New Godown', type: 'GODOWN')]
        });
      }
      if (request.method == 'POST' && request.url.path == '/api/v1/locations') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _jsonOk(_location(id: 'loc-9', code: 'GDN1', name: 'New Godown', type: 'GODOWN'));
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('location_add_fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('location_code_field')), 'GDN1');
    await tester.enterText(find.byKey(const Key('location_name_field')), 'New Godown');
    await tester.tap(find.byKey(const Key('location_type_field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Godown / Warehouse').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('location_save_button')));
    await tester.pumpAndSettle();

    expect(postedBody, isNotNull);
    expect(postedBody!['code'], 'GDN1');
    expect(postedBody!['name'], 'New Godown');
    expect(postedBody!['type'], 'GODOWN');
    expect(find.text('New Godown (GDN1)'), findsOneWidget);
  });

  testWidgets('edits an existing location — code field is locked, name/type editable', (tester) async {
    Map<String, dynamic>? putBody;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/locations/all') {
        return _jsonOk({
          'locations': [_location(id: 'loc-1', code: 'MAIN', name: 'Main Shop')]
        });
      }
      if (request.method == 'PUT' && request.url.path == '/api/v1/locations/loc-1') {
        putBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _jsonOk({'ok': true});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('location_edit_loc-1')));
    await tester.pumpAndSettle();

    final codeField = tester.widget<TextFormField>(find.byKey(const Key('location_code_field')));
    expect(codeField.enabled, isFalse);

    await tester.enterText(find.byKey(const Key('location_name_field')), 'Main Shop Renamed');
    await tester.tap(find.byKey(const Key('location_save_button')));
    await tester.pumpAndSettle();

    expect(putBody, isNotNull);
    expect(putBody!['name'], 'Main Shop Renamed');
  });

  testWidgets('toggling the switch deactivates then reactivates a location', (tester) async {
    var active = true;
    bool? lastRequestedActive;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/locations/all') {
        return _jsonOk({
          'locations': [_location(id: 'loc-1', code: 'MAIN', name: 'Main Shop', active: active)]
        });
      }
      if (request.method == 'POST' && request.url.path == '/api/v1/locations/loc-1/status') {
        lastRequestedActive = (jsonDecode(request.body) as Map<String, dynamic>)['active'] as bool;
        active = lastRequestedActive!;
        return _jsonOk({'ok': true});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('location_active_switch_loc-1')));
    await tester.pumpAndSettle();

    expect(lastRequestedActive, isFalse);
    expect(find.textContaining('Inactive'), findsOneWidget);

    await tester.tap(find.byKey(const Key('location_active_switch_loc-1')));
    await tester.pumpAndSettle();

    expect(lastRequestedActive, isTrue);
    expect(find.textContaining('Inactive'), findsNothing);
  });
}
