// Widget tests for the product search screen's overflow "more" menu: it
// must show Khata (available to everyone) always, and gate
// Suppliers/Reports/EOD/Pair-device behind their respective permissions —
// and each entry must actually navigate to its screen.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/auth_session.dart';
import 'package:feedmate_app/core/local_db.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/khata/khata_customer_list_screen.dart';
import 'package:feedmate_app/features/pos/cart_model.dart';
import 'package:feedmate_app/features/pos/product_repository.dart';
import 'package:feedmate_app/features/pos/product_search_screen.dart';
import 'package:feedmate_app/features/reports/reports_screen.dart';
import 'package:feedmate_app/features/supplier/supplier_list_screen.dart';

import 'fake_local_db.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

Future<AuthSession> _loggedInSession({
  required http.Client httpClient,
  required List<String> permissions,
}) async {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  final session = AuthSession(apiClient: apiClient, storage: storage);
  await storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  session.tenantId = 'tenant-123';
  session.displayName = 'Test User';
  session.permissions = permissions;
  session.status = AuthStatus.loggedIn;
  return session;
}

Widget _wrap({required http.Client httpClient, required AuthSession session}) {
  final localDb = FakeLocalDatabase();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthSession>.value(value: session),
      Provider<ApiClient>.value(value: session.apiClient),
      ChangeNotifierProvider<CartModel>(create: (_) => CartModel()),
      Provider<LocalDatabase>.value(value: localDb),
      Provider<ProductRepository>(create: (_) => ProductRepository(client: session.apiClient, localDb: localDb)),
    ],
    child: const MaterialApp(home: ProductSearchScreen()),
  );
}

void main() {
  testWidgets('a user with no extra permissions only sees Khata in the menu', (tester) async {
    final client = MockClient((request) async => http.Response('not found', 404));
    final session = await _loggedInSession(httpClient: client, permissions: ['pos.sell']);

    await tester.pumpWidget(_wrap(httpClient: client, session: session));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('more_menu_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('menu_item_khata')), findsOneWidget);
    expect(find.byKey(const Key('menu_item_suppliers')), findsNothing);
    expect(find.byKey(const Key('menu_item_reports')), findsNothing);
    expect(find.byKey(const Key('menu_item_eod')), findsNothing);
    expect(find.byKey(const Key('menu_item_pair_device')), findsNothing);
  });

  testWidgets('a user with all permissions sees every menu item, and each navigates correctly', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers') return _jsonOk({'customers': []});
      if (request.url.path == '/api/v1/suppliers') return _jsonOk({'suppliers': []});
      return http.Response('not found', 404);
    });
    final session = await _loggedInSession(
      httpClient: client,
      permissions: ['pos.sell', 'supplier.manage', 'report.view', 'cash.eod_close', 'device.manage'],
    );

    await tester.pumpWidget(_wrap(httpClient: client, session: session));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('more_menu_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menu_item_khata')), findsOneWidget);
    expect(find.byKey(const Key('menu_item_suppliers')), findsOneWidget);
    expect(find.byKey(const Key('menu_item_reports')), findsOneWidget);
    expect(find.byKey(const Key('menu_item_eod')), findsOneWidget);
    expect(find.byKey(const Key('menu_item_pair_device')), findsOneWidget);

    await tester.tap(find.byKey(const Key('menu_item_reports')));
    await tester.pumpAndSettle();
    expect(find.byType(ReportsScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('more_menu_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu_item_suppliers')));
    await tester.pumpAndSettle();
    expect(find.byType(SupplierListScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('more_menu_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu_item_khata')));
    await tester.pumpAndSettle();
    expect(find.byType(KhataCustomerListScreen), findsOneWidget);
  });
}
