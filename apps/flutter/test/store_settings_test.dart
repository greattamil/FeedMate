// Widget tests for the Store Settings screen: loading the current shop
// profile, editing it, saving, and surfacing validation errors.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/settings/store_settings_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

Map<String, dynamic> _seedProfile() => {
      'legal_name': 'Andipatti Animal Feed System',
      'trade_name': 'AAFS',
      'gstin': '33AAAAA0000A1Z5',
      'fssai_license_no': null,
      'phone': '9876543210',
      'email': null,
      'address_line1': '12 Market Road',
      'address_line2': null,
      'city': 'Andipatti',
      'district': null,
      'state_code': 'TN',
      'postal_code': null,
      'invoice_prefix': 'AAFS',
      'receipt_header': null,
      'receipt_footer': null,
    };

/// StoreSettingsScreen's form is a plain ListView(children: [...]), whose
/// SliverChildListDelegate only inflates elements within the viewport +
/// cache extent — the same lazy-build gotcha documented elsewhere in this
/// suite (see e.g. home_dashboard_manage_test.dart). Fields below the fold
/// must be scrolled into view before they can be read or interacted with.
Future<void> _scrollUntilVisible(WidgetTester tester, Finder finder, {bool up = false}) async {
  final delta = up ? const Offset(0, 300) : const Offset(0, -300);
  await tester.dragUntilVisible(finder, find.byType(Scrollable).first, delta);
  await tester.pumpAndSettle();
}

Widget _wrapWithProviders({required http.Client httpClient}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  return MultiProvider(
    providers: [
      Provider<SecureStorage>.value(value: storage),
      Provider<ApiClient>.value(value: apiClient),
    ],
    child: const MaterialApp(home: StoreSettingsScreen()),
  );
}

void main() {
  testWidgets('loads and displays the current store profile', (tester) async {
    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/v1/settings/store-profile') {
        return _jsonOk(_seedProfile());
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextFormField, 'Legal Name *'), findsOneWidget);
    expect(find.text('Andipatti Animal Feed System'), findsOneWidget);
    expect(find.text('AAFS'), findsOneWidget); // trade name, visible above the fold

    await _scrollUntilVisible(tester, find.text('12 Market Road'));
    expect(find.text('12 Market Road'), findsOneWidget);

    await _scrollUntilVisible(tester, find.byKey(const Key('store_settings_invoice_prefix')));
    expect(find.widgetWithText(TextFormField, 'Invoice Prefix *'), findsOneWidget);
    expect(find.text('AAFS'), findsOneWidget); // invoice prefix, now that it's scrolled into view
  });

  testWidgets('editing a field and saving sends the full updated profile', (tester) async {
    Map<String, dynamic>? putBody;
    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/v1/settings/store-profile') {
        return _jsonOk(_seedProfile());
      }
      if (request.method == 'PUT' && request.url.path == '/api/v1/settings/store-profile') {
        putBody = jsonDecode(request.body) as Map<String, dynamic>;
        final updated = Map<String, dynamic>.from(_seedProfile())..addAll(putBody!);
        return _jsonOk(updated);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    await _scrollUntilVisible(tester, find.byKey(const Key('store_settings_invoice_prefix')));
    await tester.enterText(find.byKey(const Key('store_settings_invoice_prefix')), 'FEED');

    await _scrollUntilVisible(tester, find.widgetWithText(TextFormField, 'Receipt Footer'));
    await tester.enterText(find.widgetWithText(TextFormField, 'Receipt Footer'), 'Thank you, visit again!');

    await _scrollUntilVisible(tester, find.byKey(const Key('store_settings_save_button')));
    await tester.tap(find.byKey(const Key('store_settings_save_button')));
    await tester.pumpAndSettle();

    expect(putBody, isNotNull);
    expect(putBody!['invoice_prefix'], 'FEED');
    expect(putBody!['receipt_footer'], 'Thank you, visit again!');
    expect(putBody!['legal_name'], 'Andipatti Animal Feed System');
    expect(find.text('Store settings saved'), findsOneWidget);
  });

  testWidgets('clearing the required legal name blocks save with a validation error', (tester) async {
    var putCalled = false;
    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/v1/settings/store-profile') {
        return _jsonOk(_seedProfile());
      }
      if (request.method == 'PUT' && request.url.path == '/api/v1/settings/store-profile') {
        putCalled = true;
        return _jsonOk(_seedProfile());
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('store_settings_legal_name')), '');

    await _scrollUntilVisible(tester, find.byKey(const Key('store_settings_save_button')));
    await tester.tap(find.byKey(const Key('store_settings_save_button')));
    await tester.pumpAndSettle();

    expect(putCalled, isFalse);
    await _scrollUntilVisible(tester, find.text('Legal Name is required'), up: true);
    expect(find.text('Legal Name is required'), findsOneWidget);
  });
}
