// Widget tests for the login -> product search flow, using a mocked HTTP
// client so they run without a live backend. End-to-end behavior against the
// real Go server is verified separately (see docs/IMPLEMENTATION_STATUS.md).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/auth_session.dart';
import 'package:feedmate_app/core/branding_provider.dart';
import 'package:feedmate_app/core/local_db.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/core/sync_service.dart';
import 'package:feedmate_app/features/auth/login_screen.dart';
import 'package:feedmate_app/features/dashboard/home_dashboard_screen.dart';
import 'package:feedmate_app/features/pos/cart_model.dart';
import 'package:feedmate_app/features/pos/product_repository.dart';
import 'package:feedmate_app/features/pos/product_search_screen.dart';

import 'fake_local_db.dart';

Widget _wrapWithProviders({
  required http.Client httpClient,
  required Widget child,
  LocalDatabase? localDb,
}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  final db = localDb ?? FakeLocalDatabase();
  return MultiProvider(
    providers: [
      Provider<SecureStorage>.value(value: storage),
      Provider<ApiClient>.value(value: apiClient),
      ChangeNotifierProvider<AuthSession>(
        create: (_) => AuthSession(apiClient: apiClient, storage: storage),
      ),
      ChangeNotifierProvider<CartModel>(create: (_) => CartModel()),
      ChangeNotifierProvider<BrandingProvider>(create: (_) => BrandingProvider(client: apiClient, storage: storage)),
      Provider<LocalDatabase>.value(value: db),
      Provider<ProductRepository>(create: (_) => ProductRepository(client: apiClient, localDb: db)),
      Provider<SyncService>(create: (_) => SyncService(client: apiClient, localDb: db)),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('login screen shows username/password fields and a login button', (tester) async {
    final client = MockClient((request) async => http.Response('{}', 200));
    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const LoginScreen()));

    expect(find.byKey(const Key('username_field')), findsOneWidget);
    expect(find.byKey(const Key('password_field')), findsOneWidget);
    expect(find.byKey(const Key('login_button')), findsOneWidget);
  });

  testWidgets('failed login shows the server error message, not a generic one', (tester) async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v1/auth/login');
      return http.Response(
        jsonEncode({
          'error': {'code': 'UNAUTHORIZED', 'message': 'invalid username or password', 'retryable': false}
        }),
        401,
      );
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const LoginScreen()));
    await tester.enterText(find.byKey(const Key('username_field')), 'owner');
    await tester.enterText(find.byKey(const Key('password_field')), 'wrong-password');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();

    expect(find.text('invalid username or password'), findsOneWidget);
  });

  testWidgets('successful login navigates to product search', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/auth/login') {
        return http.Response(
          jsonEncode({
            'access_token': 'test-access-token',
            'refresh_token': 'test-refresh-token',
            'tenant_id': 'tenant-123',
            'display_name': 'Test Owner',
            'permissions': ['pos.sell'],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const LoginScreen()));
    await tester.enterText(find.byKey(const Key('username_field')), 'owner');
    await tester.enterText(find.byKey(const Key('password_field')), 'TestPass123!');
    await tester.tap(find.byKey(const Key('login_button')));
    await tester.pumpAndSettle();

    // A successful login now lands on the app shell's home dashboard (the
    // product search / counter screen is a separate bottom-nav tab, mounted
    // but inactive — see AppShell).
    expect(find.byType(HomeDashboardScreen), findsOneWidget);
    expect(find.byType(ProductSearchScreen, skipOffstage: false), findsWidgets);
    expect(find.textContaining('Test Owner'), findsWidgets);
  });

  testWidgets('product search shows ranked results from the API', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/products/search') {
        // CatalogPanel also browses the whole catalog on load (an empty
        // q), before any query is typed — only assert the ranking-relevant
        // shape of the request once the cashier actually searches "cattle".
        if (request.url.queryParameters['q'] != 'cattle') {
          return http.Response(jsonEncode({'results': []}), 200);
        }
        return http.Response(
          jsonEncode({
            'results': [
              {
                'product': {
                  'id': 'p1', 'sku': 'CF-01', 'name': 'Cattle Feed 50kg',
                  'selling_price': '1200.00', 'batch_required': true,
                  'loose_sale_allowed': false, 'active': true,
                },
                'match_type': 'NAME',
              }
            ]
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });

    final storage = SecureStorage(store: InMemoryKeyValueStore());
    await storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
    final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: client);
    final localDb = FakeLocalDatabase();

    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SecureStorage>.value(value: storage),
        Provider<ApiClient>.value(value: apiClient),
        ChangeNotifierProvider<AuthSession>(create: (_) => AuthSession(apiClient: apiClient, storage: storage)),
        ChangeNotifierProvider<CartModel>(create: (_) => CartModel()),
        ChangeNotifierProvider<BrandingProvider>(create: (_) => BrandingProvider(client: apiClient, storage: storage)),
        Provider<LocalDatabase>.value(value: localDb),
        Provider<ProductRepository>(create: (_) => ProductRepository(client: apiClient, localDb: localDb)),
        Provider<SyncService>(create: (_) => SyncService(client: apiClient, localDb: localDb)),
      ],
      child: const MaterialApp(home: ProductSearchScreen()),
    ));

    await tester.enterText(find.byKey(const Key('search_field')), 'cattle');
    await tester.pump(const Duration(milliseconds: 350)); // past the debounce
    await tester.pumpAndSettle();

    expect(find.text('Cattle Feed 50kg'), findsOneWidget);
    expect(find.textContaining('₹1,200.00'), findsOneWidget);
  });

  testWidgets('tapping a search result adds it to the cart, shown as a badge', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/products/search') {
        return http.Response(
          jsonEncode({
            'results': [
              {
                'product': {
                  'id': 'p1', 'sku': 'CF-01', 'name': 'Cattle Feed 50kg',
                  'selling_price': '1200.00', 'batch_required': true,
                  'loose_sale_allowed': false, 'active': true,
                },
                'match_type': 'NAME',
              }
            ]
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });

    final storage = SecureStorage(store: InMemoryKeyValueStore());
    await storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
    final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: client);
    final cart = CartModel();
    final localDb = FakeLocalDatabase();

    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SecureStorage>.value(value: storage),
        Provider<ApiClient>.value(value: apiClient),
        ChangeNotifierProvider<AuthSession>(create: (_) => AuthSession(apiClient: apiClient, storage: storage)),
        ChangeNotifierProvider<CartModel>.value(value: cart),
        ChangeNotifierProvider<BrandingProvider>(create: (_) => BrandingProvider(client: apiClient, storage: storage)),
        Provider<LocalDatabase>.value(value: localDb),
        Provider<ProductRepository>(create: (_) => ProductRepository(client: apiClient, localDb: localDb)),
        Provider<SyncService>(create: (_) => SyncService(client: apiClient, localDb: localDb)),
      ],
      child: const MaterialApp(home: ProductSearchScreen()),
    ));

    await tester.enterText(find.byKey(const Key('search_field')), 'cattle');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(cart.isEmpty, isTrue);
    await tester.tap(find.text('Cattle Feed 50kg'));
    await tester.pump(); // let the SnackBar animation start
    await tester.pump(const Duration(seconds: 2)); // let it finish so it doesn't linger into other checks

    expect(cart.isEmpty, isFalse);
    expect(cart.lines.single.product.id, 'p1');
    expect(find.text('1'), findsWidgets); // the cart badge showing 1 item
  });
}
