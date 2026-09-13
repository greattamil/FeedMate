// Widget tests for the GRN History feature: searching past goods receipts
// and viewing the read-only detail (lines received) of one.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/procurement/grn_history_screen.dart';

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
  testWidgets('GRN history lists results and navigates into a detail view', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/procurement/grns') {
        return _jsonOk({
          'grns': [
            {
              'id': 'grn-1', 'grn_number': 'GRN-0001', 'supplier_name': 'Test Feed Mill',
              'supplier_document_no': 'SUP-INV-99', 'posted_at': '2026-09-12T12:00:00+05:30',
            }
          ],
          'total': 1,
        });
      }
      if (request.url.path == '/api/v1/procurement/grns/grn-1') {
        return _jsonOk({
          'id': 'grn-1', 'grn_number': 'GRN-0001', 'supplier_name': 'Test Feed Mill',
          'supplier_document_no': 'SUP-INV-99', 'vehicle_no': 'TN01AB1234',
          'net_weight_kg': '2545.000', 'posted_at': '2026-09-12T12:00:00+05:30',
          'lines': [
            {
              'product_name': 'Cattle Feed Economy 50kg', 'sku': 'CF-ECO-01', 'batch_code': 'B-100',
              'received_qty': '20.000', 'uom_code': 'BAG', 'unit_cost': '900.00', 'quality_status': 'ACCEPTED',
            }
          ],
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const GrnHistoryScreen()));
    await tester.pumpAndSettle();

    expect(find.text('GRN-0001'), findsOneWidget);
    expect(find.textContaining('Test Feed Mill'), findsOneWidget);

    await tester.tap(find.byKey(const Key('grn_history_item_grn-1')));
    await tester.pumpAndSettle();

    expect(find.text('Cattle Feed Economy 50kg'), findsOneWidget);
    expect(find.textContaining('Batch B-100'), findsOneWidget);
    expect(find.textContaining('Vehicle: TN01AB1234'), findsOneWidget);
    expect(find.textContaining('Net weight: 2545.00 kg'), findsOneWidget);
    expect(find.text('₹18000.00'), findsOneWidget);
  });

  testWidgets('GRN history shows an empty state with no results', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/procurement/grns') {
        return _jsonOk({'grns': [], 'total': 0});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const GrnHistoryScreen()));
    await tester.pumpAndSettle();

    expect(find.text('No GRNs found'), findsOneWidget);
  });
}
