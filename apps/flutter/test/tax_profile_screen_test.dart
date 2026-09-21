// Widget tests for the Tax Profile management screen: the "central
// control" for GST-inclusive vs GST-exclusive product pricing. Covers
// listing (including the inclusive/exclusive badge), creating a new
// profile with the Price Includes GST switch, and toggling active status.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/products/tax_profile_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

Widget _wrapWithProviders({required http.Client httpClient, required Widget child}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  return MultiProvider(
    providers: [
      Provider<SecureStorage>.value(value: storage),
      Provider<ApiClient>.value(value: apiClient),
    ],
    child: MaterialApp(home: child),
  );
}

Map<String, dynamic> _profileJson({
  required String id,
  required String code,
  required String description,
  bool priceInclusive = false,
  bool active = true,
  String cgst = '9.00',
  String sgst = '9.00',
}) {
  return {
    'id': id,
    'code': code,
    'description': description,
    'supply_type': 'INTRA_STATE',
    'cgst_rate': cgst,
    'sgst_rate': sgst,
    'igst_rate': '0.00',
    'cess_rate': '0.00',
    'price_inclusive': priceInclusive,
    'active': active,
  };
}

void main() {
  testWidgets('lists tax profiles and shows the inclusive/exclusive badge', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/tax-profiles/all') {
        return _jsonOk({
          'tax_profiles': [
            _profileJson(id: 'tp-1', code: 'GST18-EXCL', description: 'GST 18% exclusive', priceInclusive: false),
            _profileJson(id: 'tp-2', code: 'GST18-INCL', description: 'GST 18% inclusive', priceInclusive: true),
          ],
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const TaxProfileScreen()));
    await tester.pumpAndSettle();

    expect(find.textContaining('GST18-EXCL'), findsOneWidget);
    expect(find.textContaining('GST18-INCL'), findsOneWidget);
    expect(find.text('Price incl. GST'), findsOneWidget);
    expect(find.text('Price excl. GST'), findsOneWidget);
  });

  testWidgets('creating a tax profile posts the form fields including price_inclusive', (tester) async {
    Map<String, dynamic>? postedBody;
    var listCallCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/tax-profiles/all') {
        listCallCount++;
        if (listCallCount == 1) {
          return _jsonOk({'tax_profiles': []});
        }
        return _jsonOk({
          'tax_profiles': [_profileJson(id: 'tp-new', code: 'GST5-INCL', description: 'GST 5% inclusive', priceInclusive: true, cgst: '2.5', sgst: '2.5')],
        });
      }
      if (request.method == 'POST' && request.url.path == '/api/v1/tax-profiles') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode(_profileJson(id: 'tp-new', code: 'GST5-INCL', description: 'GST 5% inclusive', priceInclusive: true, cgst: '2.5', sgst: '2.5')), 201);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const TaxProfileScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tax_profile_add_fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('tax_profile_code_field')), 'GST5-INCL');
    await tester.enterText(find.byKey(const Key('tax_profile_description_field')), 'GST 5% inclusive');
    await tester.enterText(find.byKey(const Key('tax_profile_cgst_field')), '2.5');
    await tester.enterText(find.byKey(const Key('tax_profile_sgst_field')), '2.5');

    // Flip the central control this feature is about.
    await tester.ensureVisible(find.byKey(const Key('tax_profile_price_inclusive_switch')));
    await tester.tap(find.byKey(const Key('tax_profile_price_inclusive_switch')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('tax_profile_save_button')));
    await tester.tap(find.byKey(const Key('tax_profile_save_button')));
    await tester.pumpAndSettle();

    expect(postedBody, isNotNull);
    expect(postedBody!['code'], 'GST5-INCL');
    expect(postedBody!['price_inclusive'], isTrue);
    expect(postedBody!['cgst_rate'], '2.5');

    // Returned to the list, refreshed with the new profile.
    expect(find.byType(TaxProfileScreen), findsOneWidget);
    expect(find.textContaining('GST5-INCL'), findsOneWidget);
  });

  testWidgets('toggling the active switch posts the new status', (tester) async {
    String? postedPath;
    Map<String, dynamic>? postedBody;
    var active = true;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/tax-profiles/all') {
        return _jsonOk({'tax_profiles': [_profileJson(id: 'tp-1', code: 'GST18-EXCL', description: 'GST 18%', active: active)]});
      }
      if (request.method == 'POST' && request.url.path == '/api/v1/tax-profiles/tp-1/status') {
        postedPath = request.url.path;
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        active = postedBody!['active'] as bool;
        return http.Response('', 204);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const TaxProfileScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tax_profile_active_switch_tp-1')));
    await tester.pumpAndSettle();

    expect(postedPath, '/api/v1/tax-profiles/tp-1/status');
    expect(postedBody!['active'], isFalse);
    expect(find.textContaining('Inactive'), findsOneWidget);
  });
}
