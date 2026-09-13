// Widget tests for the Invoice History / reprint feature: searching past
// invoices and viewing the read-only detail (lines + tenders) of one.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/pos/invoice_detail_screen.dart';
import 'package:feedmate_app/features/pos/invoice_history_screen.dart';

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

void main() {
  testWidgets('Invoice history lists results and navigates into a reprint detail view', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/pos/invoices/history') {
        return _jsonOk({
          'invoices': [
            {
              'id': 'inv-1', 'invoice_number': 'INV-0001', 'customer_name': 'Test Farmer',
              'grand_total': '3780.00', 'payment_status': 'PAID', 'finalized_at': '2026-09-12T12:00:00+05:30',
            }
          ],
          'total': 1,
        });
      }
      if (request.url.path == '/api/v1/pos/invoices/inv-1') {
        return _jsonOk({
          'id': 'inv-1', 'invoice_number': 'INV-0001', 'customer_name': 'Test Farmer',
          'subtotal': '3600.00', 'discount_total': '0.00', 'taxable_total': '3600.00',
          'tax_total': '180.00', 'rounding_amount': '0.00', 'grand_total': '3780.00',
          'payment_status': 'PAID', 'status': 'FINALIZED', 'finalized_at': '2026-09-12T12:00:00+05:30',
          'lines': [
            {
              'id': 'line-1', 'product_id': 'p1', 'product_name': 'Cattle Feed 50kg', 'sku': 'CF-01',
              'uom_code': 'BAG', 'quantity': '3', 'unit_price': '1200.00', 'line_total': '3600.00',
            }
          ],
          'tenders': [
            {'method': 'CASH', 'amount': '3780.00'}
          ],
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const InvoiceHistoryScreen()));
    await tester.pumpAndSettle();

    expect(find.text('INV-0001'), findsOneWidget);
    expect(find.textContaining('Test Farmer'), findsOneWidget);
    expect(find.text('₹3780.00'), findsOneWidget);

    await tester.tap(find.byKey(const Key('invoice_history_item_inv-1')));
    await tester.pumpAndSettle();

    expect(find.text('Cattle Feed 50kg', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('3 BAG'), findsOneWidget);
    expect(find.text('CASH'), findsOneWidget);
    expect(find.byKey(const Key('invoice_detail_grand_total')), findsOneWidget);
  });

  testWidgets('Invoice detail shows a split-tender breakdown', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/pos/invoices/inv-2') {
        return _jsonOk({
          'id': 'inv-2', 'invoice_number': 'INV-0002', 'customer_name': null,
          'subtotal': '1200.00', 'discount_total': '0.00', 'taxable_total': '1200.00',
          'tax_total': '0.00', 'rounding_amount': '0.00', 'grand_total': '1200.00',
          'payment_status': 'PAID', 'status': 'FINALIZED', 'finalized_at': null,
          'lines': [
            {
              'id': 'line-1', 'product_id': 'p1', 'product_name': 'Cattle Feed 50kg', 'sku': 'CF-01',
              'uom_code': 'BAG', 'quantity': '1', 'unit_price': '1200.00', 'line_total': '1200.00',
            }
          ],
          'tenders': [
            {'method': 'CASH', 'amount': '700.00'},
            {'method': 'CREDIT', 'amount': '500.00'},
          ],
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const InvoiceDetailScreen(invoiceId: 'inv-2')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invoice_detail_tender_CASH')), findsOneWidget);
    expect(find.byKey(const Key('invoice_detail_tender_CREDIT')), findsOneWidget);
    expect(find.text('₹700.00'), findsOneWidget);
    expect(find.text('₹500.00'), findsOneWidget);
  });
}
