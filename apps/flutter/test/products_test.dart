// Widget tests for the product master-data CRUD screens: list/search,
// create, edit, and activate/deactivate. Uses a mocked HTTP client so these
// run without a live backend — end-to-end behavior against the real Go
// server is verified separately (see docs/IMPLEMENTATION_STATUS.md).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/auth_session.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/products/product_detail_screen.dart';
import 'package:feedmate_app/features/products/product_form_screen.dart';
import 'package:feedmate_app/features/products/product_list_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

/// GrnLineFormScreen-style lazy ListView means a widget far down the form
/// may not be built yet — scroll incrementally (like a real user) before
/// tapping or checking it, matching the pattern established in
/// grn_test.dart/returns_test.dart.
Future<void> _revealAndTap(WidgetTester tester, Key key) async {
  await tester.dragUntilVisible(find.byKey(key), find.byType(Scrollable).first, const Offset(0, -200));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

Future<void> _revealAndEnterText(WidgetTester tester, Key key, String text) async {
  await tester.dragUntilVisible(find.byKey(key), find.byType(Scrollable).first, const Offset(0, -200));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(key), text);
}

Map<String, dynamic> _masterDataFixtures() => {
      'categories': {
        'categories': [
          {'id': 'cat-1', 'name': 'Cattle Feed'},
        ]
      },
      'brands': {
        'brands': [
          {'id': 'brand-1', 'name': 'Andipatti Mills'},
        ]
      },
      'uoms': {
        'uoms': [
          {'id': 'uom-bag', 'code': 'BAG', 'name': 'Bag'},
          {'id': 'uom-kg', 'code': 'KG', 'name': 'Kilogram'},
        ]
      },
      'taxProfiles': {
        'tax_profiles': [
          {'id': 'tax-gst5', 'code': 'GST5', 'description': '5% GST', 'cgst_rate': '2.5', 'sgst_rate': '2.5', 'igst_rate': '5'},
        ]
      },
    };

http.Response? _handleMasterData(http.Request request, Map<String, dynamic> fixtures) {
  switch (request.url.path) {
    case '/api/v1/categories':
      return _jsonOk(fixtures['categories'] as Map<String, dynamic>);
    case '/api/v1/brands':
      return _jsonOk(fixtures['brands'] as Map<String, dynamic>);
    case '/api/v1/uoms':
      return _jsonOk(fixtures['uoms'] as Map<String, dynamic>);
    case '/api/v1/tax-profiles':
      return _jsonOk(fixtures['taxProfiles'] as Map<String, dynamic>);
  }
  return null;
}

Widget _wrap({required http.Client httpClient, required Widget child}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  final session = AuthSession(apiClient: apiClient, storage: storage);
  session.tenantId = 'tenant-123';
  session.displayName = 'Test Owner';
  session.permissions = ['product.manage'];
  session.status = AuthStatus.loggedIn;
  return MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: apiClient),
      ChangeNotifierProvider<AuthSession>.value(value: session),
    ],
    child: MaterialApp(home: child),
  );
}

Map<String, dynamic> _productJson({
  String id = 'prod-1',
  String sku = 'CF-ECO-01',
  String name = 'Cattle Feed Economy 50kg',
  bool active = true,
  String sellingPrice = '1050.00',
}) =>
    {
      'id': id,
      'sku': sku,
      'name': name,
      'default_sale_uom_id': 'uom-bag',
      'default_purchase_uom_id': 'uom-bag',
      'base_inventory_uom_id': 'uom-kg',
      'tax_profile_id': 'tax-gst5',
      'mrp': '1100.00',
      'selling_price': sellingPrice,
      'batch_required': true,
      'expiry_required': true,
      'loose_sale_allowed': false,
      'scale_required': false,
      'product_type': 'FEED',
      'active': active,
      'barcodes': ['8901234567890'],
      'aliases': ['cattle economy'],
    };

void main() {
  testWidgets('lists products, searches, and toggles the inactive filter', (tester) async {
    var lastActiveParam = '';
    final fixtures = _masterDataFixtures();

    final client = MockClient((request) async {
      final masterData = _handleMasterData(request, fixtures);
      if (masterData != null) return masterData;
      if (request.url.path == '/api/v1/products') {
        lastActiveParam = request.url.queryParameters['active'] ?? '';
        return _jsonOk({
          'products': [_productJson()],
          'total': 1,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const ProductListScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Cattle Feed Economy 50kg'), findsOneWidget);
    expect(find.textContaining('1 product'), findsOneWidget);
    expect(lastActiveParam, 'true');

    await tester.tap(find.byKey(const Key('product_show_inactive_switch')));
    await tester.pumpAndSettle();
    expect(lastActiveParam, 'false');
  });

  testWidgets('shows real stock badges from the stock-summary endpoint, not a hardcoded value', (tester) async {
    final fixtures = _masterDataFixtures();

    final client = MockClient((request) async {
      final masterData = _handleMasterData(request, fixtures);
      if (masterData != null) return masterData;
      if (request.url.path == '/api/v1/products') {
        return _jsonOk({
          'products': [_productJson(id: 'prod-1', sku: 'CF-ECO-01'), _productJson(id: 'prod-2', sku: 'CF-LOW-01', name: 'Low Stock Feed')],
          'total': 2,
        });
      }
      if (request.url.path == '/api/v1/reports/stock-summary') {
        return _jsonOk({
          'products': [
            {'product_id': 'prod-1', 'sku': 'CF-ECO-01', 'name': 'Cattle Feed Economy 50kg', 'uom_code': 'BAG', 'on_hand_qty': '42.000', 'status': 'OK'},
            {'product_id': 'prod-2', 'sku': 'CF-LOW-01', 'name': 'Low Stock Feed', 'uom_code': 'BAG', 'on_hand_qty': '0.000', 'status': 'OUT_OF_STOCK'},
          ],
          'low_stock_count': 0,
          'out_of_stock_count': 1,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const ProductListScreen()));
    await tester.pumpAndSettle();

    expect(find.textContaining('42 BAG'), findsOneWidget);
    expect(find.text('0 BAG'), findsOneWidget);
  });

  testWidgets('creating a product posts the form fields and returns to a refreshed list', (tester) async {
    Map<String, dynamic>? postedBody;
    final fixtures = _masterDataFixtures();
    var productListedAfterCreate = false;

    final client = MockClient((request) async {
      final masterData = _handleMasterData(request, fixtures);
      if (masterData != null) return masterData;
      if (request.method == 'GET' && request.url.path == '/api/v1/products') {
        return _jsonOk({
          'products': productListedAfterCreate ? [_productJson(sku: 'CF-NEW-01', name: 'New Cattle Feed')] : [],
          'total': productListedAfterCreate ? 1 : 0,
        });
      }
      if (request.method == 'POST' && request.url.path == '/api/v1/products') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        productListedAfterCreate = true;
        return http.Response(jsonEncode({'id': 'prod-new'}), 201);
      }
      if (request.method == 'GET' && request.url.path == '/api/v1/products/prod-new') {
        return _jsonOk(_productJson(id: 'prod-new', sku: 'CF-NEW-01', name: 'New Cattle Feed'));
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const ProductListScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('product_add_fab')));
    await tester.pumpAndSettle();

    expect(find.byType(ProductFormScreen), findsOneWidget);

    await tester.enterText(find.byKey(const Key('product_form_sku_field')), 'CF-NEW-01');
    await tester.enterText(find.byKey(const Key('product_form_name_field')), 'New Cattle Feed');

    await _revealAndTap(tester, const Key('product_form_sale_uom_dropdown'));
    await tester.tap(find.text('Bag (BAG)').last);
    await tester.pumpAndSettle();
    await _revealAndTap(tester, const Key('product_form_purchase_uom_dropdown'));
    await tester.tap(find.text('Bag (BAG)').last);
    await tester.pumpAndSettle();
    await _revealAndTap(tester, const Key('product_form_base_uom_dropdown'));
    await tester.tap(find.text('Kilogram (KG)').last);
    await tester.pumpAndSettle();

    await _revealAndEnterText(tester, const Key('product_form_selling_price_field'), '1050.00');

    await _revealAndTap(tester, const Key('product_form_save_button'));

    expect(postedBody, isNotNull);
    expect(postedBody!['sku'], 'CF-NEW-01');
    expect(postedBody!['name'], 'New Cattle Feed');
    expect(postedBody!['default_sale_uom_id'], 'uom-bag');
    expect(postedBody!['selling_price'], '1050.00');

    // The form pops(true) on success, and the list screen refreshes.
    expect(find.byType(ProductListScreen), findsOneWidget);
    expect(find.text('New Cattle Feed'), findsOneWidget);
  });

  testWidgets('editing a product pre-fills the form, keeps SKU read-only, and PUTs the changes', (tester) async {
    Map<String, dynamic>? putBody;
    var currentName = 'Cattle Feed Economy 50kg';
    final fixtures = _masterDataFixtures();

    final client = MockClient((request) async {
      final masterData = _handleMasterData(request, fixtures);
      if (masterData != null) return masterData;
      if (request.method == 'GET' && request.url.path == '/api/v1/products/prod-1') {
        return _jsonOk(_productJson(name: currentName));
      }
      if (request.method == 'PUT' && request.url.path == '/api/v1/products/prod-1') {
        putBody = jsonDecode(request.body) as Map<String, dynamic>;
        currentName = putBody!['name'] as String;
        return _jsonOk(_productJson(name: currentName));
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const ProductDetailScreen(productId: 'prod-1')));
    await tester.pumpAndSettle();

    expect(find.text('Cattle Feed Economy 50kg'), findsWidgets);
    expect(find.byKey(const Key('product_detail_status_badge')), findsOneWidget);
    expect(find.text('ACTIVE'), findsOneWidget);

    await tester.tap(find.byKey(const Key('product_detail_edit_button')));
    await tester.pumpAndSettle();

    // SKU is pre-filled but disabled (read-only) in edit mode.
    final skuField = tester.widget<TextField>(find.byKey(const Key('product_form_sku_field')));
    expect(skuField.controller?.text, 'CF-ECO-01');
    expect(skuField.enabled, isFalse);

    await tester.enterText(find.byKey(const Key('product_form_name_field')), 'Renamed Feed');
    await _revealAndTap(tester, const Key('product_form_save_button'));

    expect(putBody, isNotNull);
    expect(putBody!['name'], 'Renamed Feed');
    // The barcodes/aliases that came back from GetDetail must round-trip.
    expect(putBody!['barcodes'], ['8901234567890']);
    expect(putBody!['aliases'], ['cattle economy']);

    expect(find.byType(ProductDetailScreen), findsOneWidget);
    expect(find.text('Renamed Feed'), findsWidgets);
  });

  testWidgets('deactivating a product asks for confirmation and calls the status endpoint', (tester) async {
    var statusCalls = 0;
    Map<String, dynamic>? statusBody;
    var active = true;
    final fixtures = _masterDataFixtures();

    final client = MockClient((request) async {
      final masterData = _handleMasterData(request, fixtures);
      if (masterData != null) return masterData;
      if (request.method == 'GET' && request.url.path == '/api/v1/products/prod-1') {
        return _jsonOk(_productJson(active: active));
      }
      if (request.method == 'POST' && request.url.path == '/api/v1/products/prod-1/status') {
        statusCalls++;
        statusBody = jsonDecode(request.body) as Map<String, dynamic>;
        active = statusBody!['active'] as bool;
        return _jsonOk(_productJson(active: active));
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const ProductDetailScreen(productId: 'prod-1')));
    await tester.pumpAndSettle();

    expect(find.text('ACTIVE'), findsOneWidget);

    await tester.dragUntilVisible(
      find.byKey(const Key('product_detail_toggle_status_button')),
      find.byType(Scrollable).first,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.text('Deactivate Product'), findsOneWidget);

    await _revealAndTap(tester, const Key('product_detail_toggle_status_button'));

    // A confirmation dialog must appear before anything is called.
    expect(statusCalls, 0);
    expect(find.text('Deactivate Product'), findsWidgets);

    await tester.tap(find.byKey(const Key('product_detail_confirm_status_button')));
    await tester.pumpAndSettle();

    expect(statusCalls, 1);
    expect(statusBody!['active'], false);

    // The list was scrolled down to reach the toggle button; scroll back up
    // to see the status badge near the top of the page.
    await tester.dragUntilVisible(
      find.byKey(const Key('product_detail_status_badge')),
      find.byType(Scrollable).first,
      const Offset(0, 200),
    );
    await tester.pumpAndSettle();
    expect(find.text('INACTIVE'), findsOneWidget);
  });
}
