// Widget tests for the reports/dashboard screen: all four tabs (sales
// summary, stock on hand, customer balances, EOD history) against a mocked
// HTTP client. End-to-end behavior against the real Go server is verified
// separately (see docs/IMPLEMENTATION_STATUS.md).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/reports/reports_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

Widget _wrap({required http.Client httpClient}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  return MultiProvider(
    providers: [
      Provider<SecureStorage>.value(value: storage),
      Provider<ApiClient>.value(value: apiClient),
    ],
    child: const MaterialApp(home: ReportsScreen()),
  );
}

http.Response _handleReportsRequest(http.Request request) {
  if (request.url.path == '/api/v1/reports/sales-summary') {
    return _jsonOk({
      'invoice_count': 12,
      'gross_sales': '50000.00',
      'discount_total': '500.00',
      'tax_total': '2500.00',
      'net_sales': '52000.00',
      'by_tender': [
        {'method': 'CASH', 'total': '30000.00'},
        {'method': 'CREDIT', 'total': '22000.00'},
      ],
    });
  }
  if (request.url.path == '/api/v1/reports/stock-on-hand') {
    return _jsonOk({
      'products': [
        {
          'product_id': 'p1', 'sku': 'CF-01', 'name': 'Cattle Feed 50kg',
          'total_available': '120.5', 'batch_count': 3,
          'expiring_within_30_days': true, 'nearest_expiry': '2026-10-01',
        },
        {
          'product_id': 'p2', 'sku': 'PF-02', 'name': 'Poultry Feed 25kg',
          'total_available': '80', 'batch_count': 1,
          'expiring_within_30_days': false,
        },
      ]
    });
  }
  if (request.url.path == '/api/v1/reports/customer-balances') {
    return _jsonOk({
      'customers': [
        {'customer_id': 'c1', 'name': 'Over Limit Farmer', 'balance': '12000.00', 'credit_limit': '5000.00'},
        {'customer_id': 'c2', 'name': 'Healthy Farmer', 'balance': '1000.00', 'credit_limit': '5000.00'},
      ]
    });
  }
  if (request.url.path == '/api/v1/reports/eod-history') {
    return _jsonOk({
      'sessions': [
        {
          'business_date': '2026-09-12', 'opening_cash': '2000.00', 'cash_sales': '14647.50',
          'cash_refunds': '0.00', 'expected_cash': '16647.50', 'actual_cash': '16647.50',
          'variance': '0.00', 'status': 'CLOSED',
        },
        {
          'business_date': '2026-09-11', 'opening_cash': '1500.00', 'cash_sales': '9000.00',
          'cash_refunds': '200.00', 'expected_cash': '10300.00', 'actual_cash': '10000.00',
          'variance': '-300.00', 'status': 'CLOSED',
        },
      ]
    });
  }
  return http.Response('not found', 404);
}

void main() {
  testWidgets('Sales tab shows the server-computed summary and tender breakdown', (tester) async {
    final client = MockClient((request) async => _handleReportsRequest(request));
    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.text('12'), findsOneWidget); // invoice count
    expect(find.text('₹50000.00'), findsOneWidget); // gross
    expect(find.text('₹52000.00'), findsOneWidget); // net
    expect(find.text('₹30000.00'), findsOneWidget); // CASH tender
    expect(find.text('₹22000.00'), findsOneWidget); // CREDIT tender
  });

  testWidgets('Stock tab lists products with expiry warnings', (tester) async {
    final client = MockClient((request) async => _handleReportsRequest(request));
    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tab_stock')));
    await tester.pumpAndSettle();

    expect(find.text('Cattle Feed 50kg'), findsOneWidget);
    expect(find.text('Poultry Feed 25kg'), findsOneWidget);
    expect(find.text('Expiring soon'), findsOneWidget);
    expect(find.textContaining('nearest expiry'), findsOneWidget);
  });

  testWidgets('Balances tab highlights an over-limit customer', (tester) async {
    final client = MockClient((request) async => _handleReportsRequest(request));
    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tab_balances')));
    await tester.pumpAndSettle();

    expect(find.text('Over Limit Farmer'), findsOneWidget);
    expect(find.text('₹12000.00'), findsOneWidget);
    expect(find.text('Healthy Farmer'), findsOneWidget);

    final overLimitText = tester.widget<Text>(find.text('₹12000.00'));
    expect(overLimitText.style?.color, Colors.red);
  });

  testWidgets('EOD History tab lists sessions with variance coloring', (tester) async {
    final client = MockClient((request) async => _handleReportsRequest(request));
    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tab_eod')));
    await tester.pumpAndSettle();

    expect(find.textContaining('12 Sep 2026'), findsOneWidget);
    expect(find.textContaining('11 Sep 2026'), findsOneWidget);
    expect(find.text('₹0.00'), findsOneWidget);
    expect(find.text('₹-300.00'), findsOneWidget);
  });
}
