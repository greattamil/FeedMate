// Widget tests for the Stock Management screen — the single, real-time
// portal for stock status the shop owner asked for. Every number rendered
// here must come from the mocked GET /api/v1/reports/stock-summary
// response, never a client-side literal.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/auth_session.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/reports/stock_management_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

Widget _wrap({required http.Client httpClient}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  final session = AuthSession(apiClient: apiClient, storage: storage);
  session.tenantId = 'tenant-123';
  session.displayName = 'Test Owner';
  session.permissions = <String>[];
  session.status = AuthStatus.loggedIn;
  return MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: apiClient),
      ChangeNotifierProvider<AuthSession>.value(value: session),
    ],
    child: const MaterialApp(home: StockManagementScreen()),
  );
}

Map<String, dynamic> _stockSummaryFixture() => {
      'products': [
        {'product_id': 'p1', 'sku': 'CF-ECO-01', 'name': 'Cattle Feed Economy 50kg', 'uom_code': 'BAG', 'on_hand_qty': '42.000', 'reorder_level': '10.000', 'status': 'OK'},
        {'product_id': 'p2', 'sku': 'CF-LOW-01', 'name': 'Low Stock Feed', 'uom_code': 'BAG', 'on_hand_qty': '5.000', 'reorder_level': '10.000', 'status': 'LOW_STOCK'},
        {'product_id': 'p3', 'sku': 'CF-OUT-01', 'name': 'Out Of Stock Feed', 'uom_code': 'BAG', 'on_hand_qty': '0.000', 'status': 'OUT_OF_STOCK'},
      ],
      'low_stock_count': 1,
      'out_of_stock_count': 1,
    };

void main() {
  testWidgets('renders every product with its real on-hand qty and status, and filters by tapping a chip', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/reports/stock-summary') {
        return _jsonOk(_stockSummaryFixture());
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    // All three products visible by default, each with its real qty — not
    // a placeholder like "0" or "—" for everything.
    expect(find.text('Cattle Feed Economy 50kg'), findsOneWidget);
    expect(find.text('Low Stock Feed'), findsOneWidget);
    expect(find.text('Out Of Stock Feed'), findsOneWidget);
    expect(find.textContaining('42 BAG'), findsOneWidget);
    expect(find.textContaining('5 BAG'), findsOneWidget);
    expect(find.text('All (3)'), findsOneWidget);
    expect(find.text('Low Stock (1)'), findsOneWidget);
    expect(find.text('Out of Stock (1)'), findsOneWidget);

    // Filtering to Low Stock hides the other two.
    await tester.tap(find.byKey(const Key('stock_filter_low')));
    await tester.pumpAndSettle();
    expect(find.text('Low Stock Feed'), findsOneWidget);
    expect(find.text('Cattle Feed Economy 50kg'), findsNothing);
    expect(find.text('Out Of Stock Feed'), findsNothing);

    // Filtering to Out of Stock shows only that one.
    await tester.tap(find.byKey(const Key('stock_filter_out')));
    await tester.pumpAndSettle();
    expect(find.text('Out Of Stock Feed'), findsOneWidget);
    expect(find.text('Low Stock Feed'), findsNothing);
  });

  testWidgets('search filters by product name or SKU', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/reports/stock-summary') {
        return _jsonOk(_stockSummaryFixture());
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('stock_search_field')), 'CF-LOW-01');
    await tester.pumpAndSettle();

    expect(find.text('Low Stock Feed'), findsOneWidget);
    expect(find.text('Cattle Feed Economy 50kg'), findsNothing);
    expect(find.text('Out Of Stock Feed'), findsNothing);
  });
}
