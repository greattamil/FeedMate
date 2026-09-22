// Widget tests for the sales-return screen: looking an invoice up by its
// printed number, returning a line as sellable (default) and as a
// non-sellable condition requiring a quarantine location (PRD 9.7).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/returns/return_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

/// ReturnScreen's plain ListView only inflates elements within its viewport
/// + cache extent, so a widget further down the form may not exist in the
/// tree yet — a plain tap/ensureVisible can't reveal it. Scroll
/// incrementally (like a real user) to bring it into range first.
Future<void> _revealAndTap(WidgetTester tester, Key key) async {
  await tester.dragUntilVisible(find.byKey(key), find.byType(Scrollable).first, const Offset(0, -150));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

Map<String, dynamic> _invoiceJson() => {
      'id': 'inv-1',
      'invoice_number': 'INV-2627-0001',
      'grand_total': '6300.00',
      'status': 'FINALIZED',
      'lines': [
        {
          'id': 'line-1',
          'product_id': 'prod-1',
          'product_name': 'Cattle Feed Economy 50kg',
          'sku': 'CF-ECO-01',
          'uom_code': 'BAG',
          'quantity': '5.000',
          'unit_price': '1200.00',
          'line_total': '6300.00',
          'already_returned': '0.000',
          'remaining_eligible': '5.000',
        },
      ],
    };

Widget _wrap({required http.Client httpClient}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  return MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: apiClient),
    ],
    child: const MaterialApp(home: ReturnScreen()),
  );
}

void main() {
  testWidgets('looks up an invoice and posts a sellable return', (tester) async {
    Map<String, dynamic>? postedBody;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/pos/invoices') {
        expect(request.url.queryParameters['number'], 'INV-2627-0001');
        return _jsonOk(_invoiceJson());
      }
      if (request.url.path == '/api/v1/locations') {
        return _jsonOk({
          'locations': [
            {'id': 'loc-1', 'code': 'MAIN', 'name': 'Main Store', 'type': 'STORE'},
          ]
        });
      }
      if (request.url.path == '/api/v1/pos/returns') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
            jsonEncode({'return_id': 'ret-1', 'return_number': 'RET-2627-0001', 'total_refund': '2520.00'}), 201);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('return_invoice_number_field')), 'INV-2627-0001');
    await tester.tap(find.byKey(const Key('return_lookup_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('return_invoice_summary')), findsOneWidget);
    expect(find.textContaining('Eligible 5.000'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('return_qty_field_line-1')), '2');
    await tester.pump();

    await _revealAndTap(tester, const Key('return_post_button'));

    expect(postedBody, isNotNull);
    expect(postedBody!['original_invoice_id'], 'inv-1');
    expect(postedBody!['refund_method'], 'CASH');
    final lines = postedBody!['lines'] as List<dynamic>;
    expect(lines, hasLength(1));
    final line = lines.first as Map<String, dynamic>;
    expect(line['original_line_id'], 'line-1');
    expect(line['quantity'], '2');
    expect(line['condition_status'], 'SELLABLE');
    expect(line.containsKey('restock_location_id'), isFalse);

    expect(find.text('Return Posted'), findsOneWidget);
    expect(find.textContaining('RET-2627-0001'), findsOneWidget);
    expect(find.textContaining('₹2,520.00'), findsOneWidget);

    await tester.tap(find.byKey(const Key('return_posted_ok_button')));
    await tester.pumpAndSettle();

    // Form resets after a successful post.
    expect(find.byKey(const Key('return_invoice_summary')), findsNothing);
  });

  testWidgets('a non-sellable return requires a quarantine location', (tester) async {
    Map<String, dynamic>? postedBody;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/pos/invoices') {
        return _jsonOk(_invoiceJson());
      }
      if (request.url.path == '/api/v1/locations') {
        return _jsonOk({
          'locations': [
            {'id': 'loc-1', 'code': 'MAIN', 'name': 'Main Store', 'type': 'STORE'},
            {'id': 'loc-2', 'code': 'QUAR', 'name': 'Quarantine Bin', 'type': 'STORE'},
          ]
        });
      }
      if (request.url.path == '/api/v1/pos/returns') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
            jsonEncode({'return_id': 'ret-2', 'return_number': 'RET-2627-0002', 'total_refund': '1260.00'}), 201);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('return_invoice_number_field')), 'INV-2627-0001');
    await tester.tap(find.byKey(const Key('return_lookup_button')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('return_qty_field_line-1')), '1');
    await tester.pump();

    // Switch condition to DAMAGED, which reveals the quarantine-location dropdown.
    await _revealAndTap(tester, const Key('return_condition_dropdown_line-1'));
    await tester.tap(find.text('DAMAGED').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('return_restock_location_dropdown_line-1')), findsOneWidget);

    // Attempting to post without picking a location is rejected client-side.
    await _revealAndTap(tester, const Key('return_post_button'));
    expect(postedBody, isNull);
    final errorFinder = find.textContaining('pick a quarantine location');
    await tester.dragUntilVisible(errorFinder, find.byType(Scrollable).first, const Offset(0, 150));
    await tester.pumpAndSettle();
    expect(errorFinder, findsOneWidget);

    await _revealAndTap(tester, const Key('return_restock_location_dropdown_line-1'));
    await tester.tap(find.text('Quarantine Bin').last);
    await tester.pumpAndSettle();

    await _revealAndTap(tester, const Key('return_post_button'));

    expect(postedBody, isNotNull);
    final lines = postedBody!['lines'] as List<dynamic>;
    final line = lines.first as Map<String, dynamic>;
    expect(line['condition_status'], 'DAMAGED');
    expect(line['restock_location_id'], 'loc-2');
  });
}
