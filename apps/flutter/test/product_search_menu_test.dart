// Widget tests for the POS Counter screen as a single-screen point of sale:
// the catalog and the cart/checkout panel are both on screen at once — no
// navigation to a separate cart page — and the AppBar stays focused on
// counter operations (sync outbox, logout), without the back-office
// overflow clutter that now lives on the Home Dashboard's MANAGE grid.
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
import 'package:feedmate_app/features/pos/cart_model.dart';
import 'package:feedmate_app/features/pos/product_repository.dart';
import 'package:feedmate_app/features/pos/product_search_screen.dart';

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
  session.displayName = 'Counter Cashier';
  session.permissions = permissions;
  session.status = AuthStatus.loggedIn;
  return session;
}

Widget _wrap({required http.Client httpClient, required AuthSession session, CartModel? cart}) {
  final localDb = FakeLocalDatabase();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthSession>.value(value: session),
      Provider<ApiClient>.value(value: session.apiClient),
      ChangeNotifierProvider<CartModel>(create: (_) => cart ?? CartModel()),
      Provider<LocalDatabase>.value(value: localDb),
      Provider<ProductRepository>(create: (_) => ProductRepository(client: session.apiClient, localDb: localDb)),
    ],
    child: const MaterialApp(home: ProductSearchScreen()),
  );
}

void main() {
  testWidgets('POS Counter AppBar has clean actions and no back-office overflow menu', (tester) async {
    final client = MockClient((request) async => http.Response('not found', 404));
    final session = await _loggedInSession(httpClient: client, permissions: ['pos.sell']);

    await tester.pumpWidget(_wrap(httpClient: client, session: session));
    await tester.pumpAndSettle();

    // Verify clean POS controls — no separate cart page/button any more.
    expect(find.byKey(const Key('sync_button')), findsOneWidget);
    expect(find.byIcon(Icons.logout_rounded), findsOneWidget);
    expect(find.byKey(const Key('cart_button')), findsNothing);
    expect(find.byKey(const Key('more_menu_button')), findsNothing);

    // The catalog search field and the cart panel are both on screen at
    // once — the whole point of a single-screen POS.
    expect(find.byKey(const Key('search_field')), findsOneWidget);
    expect(find.byKey(const Key('cart_panel_container')), findsOneWidget);
    expect(find.text('Cart is empty'), findsOneWidget);
  });

  testWidgets('tapping a product adds it to the cart panel on the same screen, no navigation', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/products/search') {
        return _jsonOk({
          'results': [
            {
              'product': {
                'id': 'p1', 'sku': 'CF-01', 'name': 'Cattle Feed 50kg',
                'selling_price': '1200.00', 'batch_required': false,
                'loose_sale_allowed': false, 'active': true,
              },
              'match_type': 'NAME',
            }
          ]
        });
      }
      return http.Response('not found', 404);
    });
    final session = await _loggedInSession(httpClient: client, permissions: ['pos.sell']);
    final cart = CartModel();

    await tester.pumpWidget(_wrap(httpClient: client, session: session, cart: cart));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('search_field')), 'cattle');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('Cattle Feed 50kg'), findsOneWidget);

    await tester.tap(find.text('Cattle Feed 50kg'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2)); // let the "added" SnackBar clear

    // Still on the same screen — the search field and results are still
    // visible — and the cart panel (not a pushed route) now shows the line.
    expect(find.byKey(const Key('search_field')), findsOneWidget);
    expect(cart.lines.single.product.id, 'p1');
    expect(find.text('Cattle Feed 50kg'), findsWidgets); // once in results, once in the cart line
    expect(find.text('Cart is empty'), findsNothing);
  });
}
