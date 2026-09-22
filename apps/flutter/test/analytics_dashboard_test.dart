// Widget tests for the detailed Analytics Dashboard screen: confirms every
// section (KPIs, trend chart, payment mix, stock health, best sellers,
// receivables/payables, recent activity) renders real data from a single
// GET /api/v1/reports/dashboard response, and that errors surface honestly.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/dashboard/analytics_dashboard_screen.dart';

/// The dashboard body is a lazily-built ListView, so sections below the
/// fold don't exist in the widget tree until scrolled into view — this
/// repeatedly drags the list up until the given finder appears (or the
/// list stops scrolling), rather than assuming pumpAndSettle alone
/// materializes every section.
Future<void> _scrollUntilVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 300, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

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

Map<String, dynamic> _periodSales({
  required int invoiceCount,
  required String gross,
  required String discount,
  required String tax,
  required String net,
  List<Map<String, String>> tenders = const [],
}) {
  return {
    'invoice_count': invoiceCount,
    'gross_sales': gross,
    'discount_total': discount,
    'tax_total': tax,
    'net_sales': net,
    'by_tender': tenders.map((t) => {'method': t['method'], 'total': t['total']}).toList(),
  };
}

Map<String, dynamic> _fullDashboardPayload() {
  return {
    'today': _periodSales(invoiceCount: 5, gross: '4200.00', discount: '200.00', tax: '0.00', net: '4000.00'),
    'yesterday': _periodSales(invoiceCount: 4, gross: '3200.00', discount: '200.00', tax: '0.00', net: '3000.00'),
    'last_30_days': _periodSales(
      invoiceCount: 90,
      gross: '95000.00',
      discount: '5000.00',
      tax: '0.00',
      net: '90000.00',
      tenders: [
        {'method': 'CASH', 'total': '60000.00'},
        {'method': 'UPI', 'total': '30000.00'},
      ],
    ),
    'sales_trend': [
      {'date': '2026-09-08', 'invoice_count': 3, 'net_sales': '2500.00'},
      {'date': '2026-09-09', 'invoice_count': 5, 'net_sales': '4000.00'},
    ],
    'top_products': [
      {'product_id': 'p1', 'sku': 'SKU-1', 'name': 'Cattle Feed 50kg', 'qty_sold': '120', 'revenue': '36000.00'},
      {'product_id': 'p2', 'sku': 'SKU-2', 'name': 'Poultry Feed 25kg', 'qty_sold': '80', 'revenue': '16000.00'},
    ],
    'stock_health': {
      'total_products': 40,
      'in_stock': 30,
      'low_stock': 7,
      'out_of_stock': 3,
      'total_stock_value': '512340.00',
    },
    'receivables': [
      {'customer_id': 'c1', 'name': 'Murugan Traders', 'balance': '18500.00', 'credit_limit': '25000.00'},
    ],
    'total_receivables': '18500.00',
    'payables': [
      {'supplier_id': 's1', 'name': 'Andipatti Feed Mills', 'payable': '25000.00'},
    ],
    'total_payables': '25000.00',
    'recent_invoices': [
      {
        'invoice_number': 'INV-1042',
        'customer_name': 'Ramesh Kumar',
        'grand_total': '3780.00',
        'payment_status': 'PAID',
        'finalized_at': '2026-09-21T10:15:00+05:30',
      },
    ],
  };
}

void main() {
  testWidgets('Analytics Dashboard renders every section with real data', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/reports/dashboard') {
        return _jsonOk(_fullDashboardPayload());
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const AnalyticsDashboardScreen()));
    await tester.pumpAndSettle();

    // KPI row
    expect(find.byKey(const Key('kpi_today_net_sales')), findsOneWidget);
    expect(find.text('₹4,000.00'), findsOneWidget);
    expect(find.text('5'), findsOneWidget); // today's invoice count
    expect(find.text('₹18,500.00'), findsOneWidget); // total receivables
    expect(find.text('₹25,000.00'), findsOneWidget); // total payables
    expect(find.text('₹5,12,340.00'), findsOneWidget); // stock value
    expect(find.textContaining('33%'), findsOneWidget); // (4000-3000)/3000 = +33%

    // Sections present — scroll each into view since the body is a lazy
    // ListView and below-the-fold sections aren't built until visible.
    expect(find.byKey(const Key('dashboard_sales_trend_card')), findsOneWidget);

    await _scrollUntilVisible(tester, find.byKey(const Key('dashboard_payment_mix_card')));
    expect(find.byKey(const Key('dashboard_payment_mix_card')), findsOneWidget);
    expect(find.text('CASH'), findsOneWidget);
    expect(find.text('UPI'), findsOneWidget);

    await _scrollUntilVisible(tester, find.byKey(const Key('dashboard_stock_health_card')));
    expect(find.byKey(const Key('dashboard_stock_health_card')), findsOneWidget);

    await _scrollUntilVisible(tester, find.byKey(const Key('dashboard_top_products_card')));
    expect(find.text('Cattle Feed 50kg'), findsOneWidget);
    expect(find.text('Poultry Feed 25kg'), findsOneWidget);

    await _scrollUntilVisible(tester, find.byKey(const Key('dashboard_receivables_card')));
    expect(find.text('Murugan Traders'), findsOneWidget);
    expect(find.byKey(const Key('dashboard_payables_card')), findsOneWidget);
    expect(find.text('Andipatti Feed Mills'), findsOneWidget);

    await _scrollUntilVisible(tester, find.byKey(const Key('dashboard_recent_activity_card')));
    expect(find.text('Ramesh Kumar'), findsOneWidget);
    expect(find.textContaining('INV-1042'), findsOneWidget);
  });

  testWidgets('Analytics Dashboard shows empty states when there is no activity yet', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/reports/dashboard') {
        return _jsonOk({
          'today': _periodSales(invoiceCount: 0, gross: '0.00', discount: '0.00', tax: '0.00', net: '0.00'),
          'yesterday': _periodSales(invoiceCount: 0, gross: '0.00', discount: '0.00', tax: '0.00', net: '0.00'),
          'last_30_days': _periodSales(invoiceCount: 0, gross: '0.00', discount: '0.00', tax: '0.00', net: '0.00'),
          'sales_trend': [
            {'date': '2026-09-20', 'invoice_count': 0, 'net_sales': '0.00'},
          ],
          'top_products': [],
          'stock_health': {'total_products': 0, 'in_stock': 0, 'low_stock': 0, 'out_of_stock': 0, 'total_stock_value': '0.00'},
          'receivables': [],
          'total_receivables': '0.00',
          'payables': [],
          'total_payables': '0.00',
          'recent_invoices': [],
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const AnalyticsDashboardScreen()));
    await tester.pumpAndSettle();

    await _scrollUntilVisible(tester, find.text('No payments yet'));
    expect(find.text('No payments yet'), findsOneWidget);

    await _scrollUntilVisible(tester, find.text('No sales yet')); // Best Sellers section
    expect(find.text('No sales yet'), findsOneWidget);

    await _scrollUntilVisible(tester, find.text('No outstanding receivables'));
    expect(find.text('No outstanding receivables'), findsOneWidget);
    expect(find.text('No outstanding payables'), findsOneWidget);

    await _scrollUntilVisible(tester, find.text('No invoices yet'));
    expect(find.text('No invoices yet'), findsOneWidget);

    // No growth pill when yesterday had zero net sales (undefined % change).
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('Analytics Dashboard surfaces a retry option on load failure', (tester) async {
    final client = MockClient((request) async => http.Response('server error', 500));

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const AnalyticsDashboardScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    expect(find.byKey(const Key('kpi_today_net_sales')), findsNothing);
  });
}
