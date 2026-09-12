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
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/auth/login_screen.dart';
import 'package:feedmate_app/features/pos/product_search_screen.dart';

Widget _wrapWithProviders({
  required http.Client httpClient,
  required Widget child,
}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  return MultiProvider(
    providers: [
      Provider<SecureStorage>.value(value: storage),
      Provider<ApiClient>.value(value: apiClient),
      ChangeNotifierProvider<AuthSession>(
        create: (_) => AuthSession(apiClient: apiClient, storage: storage),
      ),
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

    expect(find.byType(ProductSearchScreen), findsOneWidget);
    expect(find.text('Test Owner'), findsOneWidget);
  });

  testWidgets('product search shows ranked results from the API', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/products/search') {
        expect(request.url.queryParameters['q'], 'cattle');
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

    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SecureStorage>.value(value: storage),
        Provider<ApiClient>.value(value: apiClient),
        ChangeNotifierProvider<AuthSession>(create: (_) => AuthSession(apiClient: apiClient, storage: storage)),
      ],
      child: const MaterialApp(home: ProductSearchScreen()),
    ));

    await tester.enterText(find.byKey(const Key('search_field')), 'cattle');
    await tester.pump(const Duration(milliseconds: 350)); // past the debounce
    await tester.pumpAndSettle();

    expect(find.text('Cattle Feed 50kg'), findsOneWidget);
    expect(find.textContaining('₹1200.00'), findsOneWidget);
  });
}
