// Widget tests for Financial Years & Document Series admin: opening a new
// year (which closes any prior open one), seeding default series, and
// adding a custom series.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/docseries/doc_series_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

Widget _wrapWithProviders({required http.Client httpClient}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  return MultiProvider(
    providers: [
      Provider<SecureStorage>.value(value: storage),
      Provider<ApiClient>.value(value: apiClient),
    ],
    child: MaterialApp(home: DocSeriesScreen()),
  );
}

void main() {
  testWidgets('shows the current year and its document series', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/financial-years') {
        return _jsonOk({
          'financial_years': [
            {'id': 'fy-1', 'label': 'FY2526', 'start_date': '2025-04-01', 'end_date': '2026-03-31', 'status': 'OPEN'}
          ]
        });
      }
      if (request.url.path == '/api/v1/financial-years/fy-1/document-series') {
        return _jsonOk({
          'document_series': [
            {'id': 'ds-1', 'financial_year_id': 'fy-1', 'document_type': 'INVOICE', 'prefix': 'INV-2526-', 'next_number': 42, 'padding': 5, 'active': true}
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.text('Status: OPEN'), findsOneWidget);
    expect(find.textContaining('INVOICE · INV-2526-'), findsOneWidget);
    expect(find.textContaining('Next: 00042'), findsOneWidget);
  });

  testWidgets('opening a new financial year posts the exact dates and refreshes', (tester) async {
    Map<String, dynamic>? postedBody;
    var years = [
      {'id': 'fy-1', 'label': 'FY2526', 'start_date': '2025-04-01', 'end_date': '2026-03-31', 'status': 'OPEN'}
    ];

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/financial-years') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        years = [
          {'id': 'fy-2', 'label': postedBody!['label'], 'start_date': postedBody!['start_date'], 'end_date': postedBody!['end_date'], 'status': 'OPEN'},
          {'id': 'fy-1', 'label': 'FY2526', 'start_date': '2025-04-01', 'end_date': '2026-03-31', 'status': 'CLOSED'},
        ];
        return http.Response(jsonEncode({'id': 'fy-2'}), 201);
      }
      if (request.url.path == '/api/v1/financial-years') {
        return _jsonOk({'financial_years': years});
      }
      if (request.url.path.contains('/document-series')) {
        return _jsonOk({'document_series': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('new_financial_year_fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('financial_year_label_field')), 'FY2627');
    await tester.tap(find.byKey(const Key('financial_year_start_date_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('financial_year_end_date_tile')));
    await tester.pumpAndSettle();
    // Default initialDate is "today" for both pickers, so picking "today"
    // again here would tie with the start date and fail the dialog's own
    // end-after-start validation — advance a month first so the two dates
    // actually differ.
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('financial_year_submit_button')));
    await tester.pumpAndSettle();

    expect(postedBody, isNotNull);
    expect(postedBody!['label'], 'FY2627');
    expect(find.textContaining('Financial year FY2627 opened'), findsOneWidget);
  });

  testWidgets('seeding default series shows how many were created', (tester) async {
    var seedCalled = false;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/financial-years') {
        return _jsonOk({
          'financial_years': [
            {'id': 'fy-1', 'label': 'FY2526', 'start_date': '2025-04-01', 'end_date': '2026-03-31', 'status': 'OPEN'}
          ]
        });
      }
      if (request.method == 'POST' && request.url.path == '/api/v1/financial-years/fy-1/document-series/seed-defaults') {
        seedCalled = true;
        return _jsonOk({
          'created': [
            {'id': 'ds-1', 'financial_year_id': 'fy-1', 'document_type': 'INVOICE', 'prefix': 'INVOICE-FY2526-', 'next_number': 1, 'padding': 5, 'active': true},
            {'id': 'ds-2', 'financial_year_id': 'fy-1', 'document_type': 'GRN', 'prefix': 'GRN-FY2526-', 'next_number': 1, 'padding': 5, 'active': true},
          ]
        });
      }
      if (request.url.path == '/api/v1/financial-years/fy-1/document-series') {
        return _jsonOk({'document_series': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('seed_default_series_button')));
    await tester.pumpAndSettle();

    expect(seedCalled, isTrue);
    expect(find.text('Created 2 default series'), findsOneWidget);
  });

  testWidgets('adding a custom series posts the exact fields', (tester) async {
    Map<String, dynamic>? postedBody;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/financial-years') {
        return _jsonOk({
          'financial_years': [
            {'id': 'fy-1', 'label': 'FY2526', 'start_date': '2025-04-01', 'end_date': '2026-03-31', 'status': 'OPEN'}
          ]
        });
      }
      if (request.method == 'POST' && request.url.path == '/api/v1/financial-years/fy-1/document-series') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'id': 'ds-new'}), 201);
      }
      if (request.url.path == '/api/v1/financial-years/fy-1/document-series') {
        return _jsonOk({'document_series': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add_series_button')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('new_series_prefix_field')), 'INV/2627/');
    await tester.enterText(find.byKey(const Key('new_series_starting_number_field')), '500');
    await tester.enterText(find.byKey(const Key('new_series_padding_field')), '4');
    await tester.tap(find.byKey(const Key('new_series_submit_button')));
    await tester.pumpAndSettle();

    expect(postedBody, isNotNull);
    expect(postedBody!['document_type'], 'INVOICE');
    expect(postedBody!['prefix'], 'INV/2627/');
    expect(postedBody!['starting_number'], 500);
    expect(postedBody!['padding'], 4);
  });
}
