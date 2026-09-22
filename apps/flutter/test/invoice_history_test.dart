// Widget tests for the Invoice History / reprint feature: searching past
// invoices and viewing the read-only detail (lines + tenders) of one.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/pos/invoice_detail_screen.dart';
import 'package:feedmate_app/features/pos/invoice_history_screen.dart';
import 'package:feedmate_app/features/pos/invoice_pdf_preview_screen.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Redirects path_provider's platform channel to a real temp directory so
/// the invoice detail screen's "Download PDF" action can be exercised
/// without a device — mirrors invoice_pdf_test.dart's fake.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.dir);
  final Directory dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir.path;

  @override
  Future<String?> getExternalStoragePath() async => dir.path;

  @override
  Future<String?> getDownloadsPath() async => null;
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
    expect(find.text('₹3,780.00'), findsOneWidget);

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

  Future<void> pumpSimpleInvoice(WidgetTester tester, http.Client client) async {
    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const InvoiceDetailScreen(invoiceId: 'inv-3')));
    await tester.pumpAndSettle();
  }

  http.Client simpleInvoiceClient() {
    return MockClient((request) async {
      if (request.url.path == '/api/v1/pos/invoices/inv-3') {
        return _jsonOk({
          'id': 'inv-3', 'invoice_number': 'INV-0003', 'customer_name': null,
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
            {'method': 'CASH', 'amount': '1200.00'},
          ],
        });
      }
      return http.Response('not found', 404);
    });
  }

  testWidgets('Invoice detail offers Preview, Download, and Share as three distinct actions', (tester) async {
    await pumpSimpleInvoice(tester, simpleInvoiceClient());

    // The AppBar icons are always visible; the bottom buttons are further
    // down the body's ListView and need scrolling into view first.
    expect(find.byKey(const Key('invoice_detail_preview_button')), findsOneWidget);
    expect(find.byKey(const Key('invoice_detail_download_button')), findsOneWidget);
    expect(find.byKey(const Key('invoice_detail_share_button')), findsOneWidget);

    await tester.dragUntilVisible(
      find.byKey(const Key('invoice_detail_share_pdf_bottom_button')),
      find.byType(Scrollable).first,
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invoice_detail_preview_pdf_bottom_button')), findsOneWidget);
    expect(find.byKey(const Key('invoice_detail_download_pdf_bottom_button')), findsOneWidget);
    expect(find.byKey(const Key('invoice_detail_share_pdf_bottom_button')), findsOneWidget);
  });

  testWidgets('tapping Preview opens the real PDF preview screen for this invoice', (tester) async {
    await pumpSimpleInvoice(tester, simpleInvoiceClient());

    await tester.tap(find.byKey(const Key('invoice_detail_preview_button')));
    // Not pumpAndSettle(): PdfPreview kicks off real PDF rasterization via a
    // platform channel with no mock registered in a widget test, which
    // would never settle and hang the test. A handful of fixed pumps is
    // enough to let the navigation transition complete and the screen
    // mount — this test only asserts the right screen was pushed with the
    // right invoice, not that PDF rendering itself works headlessly.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(InvoicePdfPreviewScreen), findsOneWidget);
    expect(find.text('Preview — INV-0003'), findsOneWidget);
  });

  testWidgets('tapping Download saves a real PDF file and confirms the path', (tester) async {
    // Every step touching real dart:io/platform-channel work (creating the
    // temp dir, and the tap+pump that drives the widget's real file write)
    // must run inside tester.runAsync() — outside it, testWidgets' fake
    // async zone never lets a real Future backed by native I/O resolve,
    // which hangs the test indefinitely rather than failing fast.
    final tempDir = await tester.runAsync(() => Directory.systemTemp.createTemp('invoice_detail_download_test'));
    addTearDown(() => tempDir!.delete(recursive: true));
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!);

    await pumpSimpleInvoice(tester, simpleInvoiceClient());

    // tap() fires the button's onPressed but does not await its returned
    // Future, so the real file write it kicks off may still be in flight
    // once tap() returns — poll with real delays (inside runAsync, so the
    // underlying dart:io Future actually gets to progress) until the
    // resulting SnackBar shows up, rather than guessing a fixed wait.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('invoice_detail_download_button')));
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (find.textContaining('Saved to').evaluate().isNotEmpty) break;
      }
    });

    expect(find.textContaining('Saved to'), findsOneWidget);
    expect(find.textContaining('Invoice_INV-0003.pdf'), findsOneWidget);
    final savedFile = File('${tempDir.path}${Platform.pathSeparator}Invoice_INV-0003.pdf');
    expect(savedFile.existsSync(), isTrue);
  });
}
