// Widget tests for the customer management feature: searching for a
// customer, viewing/editing their record, and viewing their ledger
// (credit summary + itemized history). Uses a mocked HTTP client — end-to-end
// behavior against the real Go server is verified separately (see
// docs/IMPLEMENTATION_STATUS.md).
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/auth_session.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/customers/customer_ledger_screen.dart';
import 'package:feedmate_app/features/customers/customer_list_screen.dart';
import 'package:feedmate_app/features/customers/receipt_pdf_preview_screen.dart';
import 'package:feedmate_app/features/pos/invoice_detail_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);

Widget _wrapWithProviders({
  required http.Client httpClient,
  required Widget child,
  List<String> permissions = const [],
}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  final session = AuthSession(apiClient: apiClient, storage: storage)
    ..status = AuthStatus.loggedIn
    ..permissions = permissions;
  return MultiProvider(
    providers: [
      Provider<SecureStorage>.value(value: storage),
      Provider<ApiClient>.value(value: apiClient),
      ChangeNotifierProvider<AuthSession>.value(value: session),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('Customer list shows search results and navigates into a ledger', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers') {
        return _jsonOk({
          'customers': [
            {
              'id': 'cust-1', 'customer_code': 'FARM001', 'name': 'Test Farmer', 'customer_type': 'FARMER',
              'phone': '9876543210', 'balance': '6200.00',
            }
          ]
        });
      }
      if (request.url.path == '/api/v1/customers/cust-1') {
        return _jsonOk({
          'id': 'cust-1', 'customer_code': 'FARM001', 'name': 'Test Farmer',
          'customer_type': 'FARMER', 'phone': '9876543210', 'status': 'ACTIVE',
          'credit_limit': '5000.00', 'outstanding_balance': '6200.00',
          'available_credit': '-1200.00', 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-1/ledger') {
        return _jsonOk({
          'entries': [
            {
              'id': 'e2', 'entry_date': '2026-09-12T12:00:00+05:30', 'document_type': 'INVOICE',
              'document_id': 'inv-2', 'debit': '1200.00', 'credit': '0.00', 'description': 'Credit sale INV-0002',
            },
            {
              'id': 'e1', 'entry_date': '2026-09-10T09:00:00+05:30', 'document_type': 'RECEIPT',
              'document_id': 'rcpt-1', 'debit': '0.00', 'credit': '500.00', 'description': 'Cash received',
            },
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const CustomerListScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Test Farmer'), findsOneWidget);
    expect(find.textContaining('FARM001'), findsOneWidget);
    expect(find.text('₹6,200.00 Due'), findsOneWidget);

    await tester.tap(find.byKey(const Key('customer_row_cust-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('customer_outstanding_balance')), findsOneWidget);
    expect(find.text('₹6,200.00'), findsOneWidget);
    expect(find.text('₹5,000.00'), findsOneWidget);
    expect(find.text('-₹1,200.00'), findsOneWidget);
    expect(find.text('Over credit limit'), findsOneWidget);

    // Invoices tab (default): shows the invoice, not the receipt.
    expect(find.text('Credit sale INV-0002'), findsOneWidget);
    expect(find.text('Cash received'), findsNothing);

    // Payments tab: shows the receipt, not the invoice.
    await tester.tap(find.textContaining('Payments'));
    await tester.pumpAndSettle();
    expect(find.text('Cash received'), findsOneWidget);
    expect(find.text('-₹500.00'), findsOneWidget);
    expect(find.text('Credit sale INV-0002'), findsNothing);

    // Transactions tab: the complete combined history, both entries.
    await tester.tap(find.textContaining('Transactions'));
    await tester.pumpAndSettle();
    expect(find.text('Credit sale INV-0002'), findsOneWidget);
    expect(find.text('Cash received'), findsOneWidget);
    expect(find.text('+₹1,200.00'), findsOneWidget);
    expect(find.text('-₹500.00'), findsOneWidget);
  });

  testWidgets('Tapping an invoice in the Invoices tab opens its full detail screen', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers/cust-11') {
        return _jsonOk({
          'id': 'cust-11', 'customer_code': 'FARM011', 'name': 'Invoice Nav Farmer',
          'customer_type': 'FARMER', 'phone': null, 'status': 'ACTIVE',
          'credit_limit': '5000.00', 'outstanding_balance': '1200.00',
          'available_credit': '3800.00', 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-11/ledger') {
        return _jsonOk({
          'entries': [
            {
              'id': 'e2', 'entry_date': '2026-09-12T12:00:00+05:30', 'document_type': 'INVOICE',
              'document_id': 'inv-2', 'debit': '1200.00', 'credit': '0.00', 'description': 'Credit sale INV-0002',
            },
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const CustomerLedgerScreen(customerId: 'cust-11'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('customer_ledger_invoice_inv-2')));
    await tester.pumpAndSettle();

    final detailScreen = tester.widget<InvoiceDetailScreen>(find.byType(InvoiceDetailScreen));
    expect(detailScreen.invoiceId, 'inv-2');
  });

  testWidgets('Customer list shows a Clear badge for a zero balance, not a Due amount', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers') {
        return _jsonOk({
          'customers': [
            {
              'id': 'cust-3', 'customer_code': 'FARM003', 'name': 'Zero Balance Farmer', 'customer_type': 'FARMER',
              'balance': '0.00',
            }
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const CustomerListScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Zero Balance Farmer'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
    expect(find.textContaining('Due'), findsNothing);
  });

  testWidgets('Customer ledger shows no over-limit warning when within limit', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers/cust-2') {
        return _jsonOk({
          'id': 'cust-2', 'customer_code': 'FARM002', 'name': 'Healthy Balance Farmer',
          'customer_type': 'FARMER', 'phone': null, 'status': 'ACTIVE',
          'credit_limit': '5000.00', 'outstanding_balance': '1000.00',
          'available_credit': '4000.00', 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-2/ledger') {
        return _jsonOk({'entries': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const CustomerLedgerScreen(customerId: 'cust-2'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('No invoices for this customer yet'), findsOneWidget);
    expect(find.text('Over credit limit'), findsNothing);

    await tester.tap(find.textContaining('Transactions'));
    await tester.pumpAndSettle();
    expect(find.text('No ledger entries yet'), findsOneWidget);
  });

  testWidgets('Record Receipt posts a manual receipt and refreshes the balance', (tester) async {
    var getDetailCalls = 0;
    String? sentIdempotencyKey;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers/cust-3') {
        getDetailCalls++;
        final balance = getDetailCalls == 1 ? '5000.00' : '4200.00';
        final available = getDetailCalls == 1 ? '0.00' : '800.00';
        return _jsonOk({
          'id': 'cust-3', 'customer_code': 'FARM003', 'name': 'Receipt Test Farmer',
          'customer_type': 'FARMER', 'phone': null, 'status': 'ACTIVE',
          'credit_limit': '5000.00', 'outstanding_balance': balance,
          'available_credit': available, 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-3/ledger') {
        return _jsonOk({'entries': []});
      }
      if (request.url.path == '/api/v1/payments/receipts') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['customer_id'], 'cust-3');
        // Decimal.toString() drops trailing zeros ("800.00" -> "800"), the
        // same formatting pos_api.dart already relies on for tender amounts
        // — the Go backend parses either representation to an identical
        // decimal value, so this must compare numerically, not as strings.
        expect(Decimal.parse(body['amount'] as String), Decimal.parse('800.00'));
        expect(body['method'], 'CASH');
        sentIdempotencyKey = body['idempotency_key'] as String;
        return _jsonOk({'payment_id': 'pay-1', 'duplicate': false});
      }
      if (request.url.path == '/api/v1/settings/store-profile') {
        return _jsonOk({
          'legal_name': 'Receipt Test Store', 'trade_name': null, 'gstin': null,
          'fssai_license_no': null, 'phone': null, 'email': null,
          'address_line1': '1 Market Road', 'address_line2': null, 'city': 'Testville',
          'district': null, 'state_code': 'TN', 'postal_code': null,
          'invoice_prefix': 'INV', 'receipt_header': null, 'receipt_footer': null,
          'logo_data_uri': null,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const CustomerLedgerScreen(customerId: 'cust-3'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('₹5,000.00'), findsWidgets);

    await tester.tap(find.byKey(const Key('record_receipt_fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('receipt_amount_field')), '800.00');
    await tester.tap(find.byKey(const Key('receipt_submit_button')));
    // Not pumpAndSettle(): a successful, non-duplicate receipt now opens
    // the real payment receipt PDF preview, which kicks off real PDF
    // rasterization via a platform channel with no mock registered in a
    // widget test — that never settles, so pumpAndSettle() here would hang
    // the test. A handful of fixed pumps is enough to let recordReceipt's
    // async chain (post receipt -> reload -> fetch store profile -> push
    // the preview screen) run to completion and the screen mount.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(sentIdempotencyKey, isNotNull);
    expect(sentIdempotencyKey, isNotEmpty);
    expect(find.byType(ReceiptPdfPreviewScreen), findsOneWidget);
    expect(find.textContaining('RCPT-'), findsOneWidget);

    // Go back to the ledger and confirm the balance shown came from a
    // fresh fetch after recording, not a client-side subtraction —
    // asserted by the mock returning a different balance on the second GET
    // and that new value actually appearing.
    Navigator.pop(tester.element(find.byType(ReceiptPdfPreviewScreen)));
    await tester.pumpAndSettle();
    expect(find.text('₹4,200.00'), findsOneWidget);
  });

  testWidgets('View Receipt reopens the PDF for a previously recorded receipt, with balances reconstructed from the ledger', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers/cust-12') {
        return _jsonOk({
          'id': 'cust-12', 'customer_code': 'FARM012', 'name': 'Old Receipt Farmer',
          'customer_type': 'FARMER', 'phone': null, 'status': 'ACTIVE',
          'credit_limit': '5000.00', 'outstanding_balance': '200.00',
          'available_credit': '4800.00', 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-12/ledger') {
        // Newest-first, matching the real backend's ledger ordering — the
        // receipt (index 0) is newer than the invoice that created the
        // balance it partially paid off (index 1).
        return _jsonOk({
          'entries': [
            {
              'id': 'led-9', 'entry_date': '2026-09-20T10:00:00Z', 'document_type': 'RECEIPT',
              'document_id': 'pay-9', 'debit': '0.00', 'credit': '300.00', 'description': 'Receipt',
            },
            {
              'id': 'led-8', 'entry_date': '2026-09-18T09:00:00Z', 'document_type': 'INVOICE',
              'document_id': 'inv-1', 'debit': '500.00', 'credit': '0.00', 'description': 'Invoice',
            },
          ],
        });
      }
      if (request.url.path == '/api/v1/payments/pay-9') {
        return _jsonOk({
          'payment_id': 'pay-9', 'amount': '300.00', 'method': 'CASH', 'reference': 'old receipt',
          'received_at': '2026-09-20T10:00:00Z', 'created_by_name': 'Ramadas',
        });
      }
      if (request.url.path == '/api/v1/settings/store-profile') {
        return _jsonOk({
          'legal_name': 'Old Receipt Store', 'trade_name': null, 'gstin': null,
          'fssai_license_no': null, 'phone': null, 'email': null,
          'address_line1': '1 Market Road', 'address_line2': null, 'city': 'Testville',
          'district': null, 'state_code': 'TN', 'postal_code': null,
          'invoice_prefix': 'INV', 'receipt_header': null, 'receipt_footer': null,
          'logo_data_uri': null,
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const CustomerLedgerScreen(customerId: 'cust-12'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Payments'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('view_receipt_led-9')), findsOneWidget);
    await tester.tap(find.byKey(const Key('view_receipt_led-9')));
    // See the Record Receipt test above for why pumpAndSettle() can't be
    // used once a real PdfPreview is on screen.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(ReceiptPdfPreviewScreen), findsOneWidget);
    expect(find.textContaining('RCPT-'), findsOneWidget);
  });

  testWidgets('Record Receipt rejects a zero amount client-side before calling the server', (tester) async {
    var receiptCallCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers/cust-4') {
        return _jsonOk({
          'id': 'cust-4', 'customer_code': 'FARM004', 'name': 'Zero Amount Farmer',
          'customer_type': 'FARMER', 'phone': null, 'status': 'ACTIVE',
          'credit_limit': '5000.00', 'outstanding_balance': '1000.00',
          'available_credit': '4000.00', 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-4/ledger') {
        return _jsonOk({'entries': []});
      }
      if (request.url.path == '/api/v1/payments/receipts') {
        receiptCallCount++;
        return _jsonOk({'payment_id': 'pay-2', 'duplicate': false});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const CustomerLedgerScreen(customerId: 'cust-4'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('record_receipt_fab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('receipt_submit_button')));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid amount greater than zero'), findsOneWidget);
    expect(receiptCallCount, 0);
  });

  testWidgets('Add Customer FAB is hidden without credit.configure permission', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers') {
        return _jsonOk({'customers': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const CustomerListScreen(),
      permissions: const [],
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('add_customer_fab')), findsNothing);
  });

  testWidgets('Add Customer creates a new customer and refreshes the list', (tester) async {
    Map<String, dynamic>? createdBody;
    var searchCallCount = 0;

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/customers') {
        createdBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({
          'id': 'cust-new', 'customer_code': 'CUST-0001', 'name': createdBody!['name'],
          'customer_type': createdBody!['customer_type'],
        }), 201);
      }
      if (request.url.path == '/api/v1/customers/cust-new') {
        return _jsonOk({
          'id': 'cust-new', 'customer_code': 'FARM010', 'name': 'New Farmer',
          'customer_type': 'FARMER', 'phone': '9000000000', 'status': 'ACTIVE',
          'credit_limit': '3000.00', 'outstanding_balance': '0.00',
          'available_credit': '3000.00', 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers') {
        searchCallCount++;
        if (searchCallCount == 1) return _jsonOk({'customers': []});
        return _jsonOk({
          'customers': [
            {'id': 'cust-new', 'customer_code': 'FARM010', 'name': 'New Farmer', 'customer_type': 'FARMER', 'phone': '9000000000'}
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const CustomerListScreen(),
      permissions: const ['credit.configure'],
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('add_customer_fab')), findsOneWidget);
    await tester.tap(find.byKey(const Key('add_customer_fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('customer_name_field')), 'New Farmer');
    await tester.enterText(find.byKey(const Key('customer_phone_field')), '9000000000');
    await tester.enterText(find.byKey(const Key('customer_credit_limit_field')), '3000.00');
    await tester.tap(find.byKey(const Key('customer_form_submit')));
    await tester.pumpAndSettle();

    expect(createdBody, isNotNull);
    expect(createdBody!.containsKey('customer_code'), isFalse, reason: 'customer_code is server-generated and must never be sent by the client');
    expect(createdBody!['name'], 'New Farmer');
    expect(createdBody!['phone'], '9000000000');
    // Regression check for a real live bug: the dropdown's default must be
    // a customer_type the customers_customer_type_check DB constraint
    // actually accepts (see customer.validCustomerTypes server-side) — the
    // previous default, "RETAIL", was rejected by every real create attempt.
    expect(createdBody!['customer_type'], 'FARMER');
    expect(Decimal.parse(createdBody!['credit_limit'] as String), Decimal.parse('3000.00'));

    expect(find.textContaining('New Farmer added to customer directory'), findsOneWidget);
    expect(find.text('New Farmer'), findsOneWidget);
  });

  testWidgets('Add Customer form rejects missing required fields client-side', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers') {
        return _jsonOk({'customers': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const CustomerListScreen(),
      permissions: const ['credit.configure'],
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add_customer_fab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('customer_form_submit')));
    await tester.pumpAndSettle();

    expect(find.text('Required'), findsWidgets);
  });

  testWidgets('Edit/status buttons are hidden without credit.configure permission', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers/cust-5') {
        return _jsonOk({
          'id': 'cust-5', 'customer_code': 'FARM005', 'name': 'No Permission Farmer',
          'customer_type': 'FARMER', 'phone': null, 'status': 'ACTIVE',
          'credit_limit': '5000.00', 'outstanding_balance': '1000.00',
          'available_credit': '4000.00', 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-5/ledger') {
        return _jsonOk({'entries': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const CustomerLedgerScreen(customerId: 'cust-5'),
      permissions: const [],
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('edit_customer_button')), findsNothing);
    expect(find.byKey(const Key('edit_credit_limit_button')), findsNothing);
    expect(find.byKey(const Key('toggle_customer_active_button')), findsNothing);
  });

  testWidgets('Edit Customer updates fields (never customer_code) and refreshes the ledger header', (tester) async {
    var getDetailCalls = 0;
    Map<String, dynamic>? putBody;

    final client = MockClient((request) async {
      if (request.method == 'PUT' && request.url.path == '/api/v1/customers/cust-8') {
        putBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _jsonOk({
          'id': 'cust-8', 'customer_code': 'FARM008', 'name': putBody!['name'],
          'customer_type': putBody!['customer_type'], 'status': 'ACTIVE',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-8') {
        getDetailCalls++;
        final name = getDetailCalls == 1 ? 'Original Farmer' : 'Renamed Farmer';
        return _jsonOk({
          'id': 'cust-8', 'customer_code': 'FARM008', 'name': name,
          'customer_type': 'FARMER', 'phone': null, 'status': 'ACTIVE',
          'credit_limit': '5000.00', 'outstanding_balance': '0.00',
          'available_credit': '5000.00', 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-8/ledger') {
        return _jsonOk({'entries': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const CustomerLedgerScreen(customerId: 'cust-8'),
      permissions: const ['credit.configure'],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Original Farmer'), findsWidgets);

    await tester.tap(find.byKey(const Key('edit_customer_button')));
    await tester.pumpAndSettle();

    // customer_code field must be present but disabled (read-only) in edit mode.
    final codeField = tester.widget<TextFormField>(find.byKey(const Key('customer_code_field_readonly')));
    expect(codeField.enabled, false);

    await tester.enterText(find.byKey(const Key('customer_name_field')), 'Renamed Farmer');
    await tester.tap(find.byKey(const Key('customer_form_submit')));
    await tester.pumpAndSettle();

    expect(putBody, isNotNull);
    expect(putBody!.containsKey('customer_code'), false);
    expect(putBody!['name'], 'Renamed Farmer');
    // The pre-existing type ("FARMER", loaded from the server detail) must
    // be preserved through the edit, never silently reset.
    expect(putBody!['customer_type'], 'FARMER');

    expect(find.text('Customer updated'), findsOneWidget);
    expect(find.text('Renamed Farmer'), findsWidgets);
  });

  testWidgets('Deactivate/reactivate toggle requires confirmation and posts the status change', (tester) async {
    var getDetailCalls = 0;
    Map<String, dynamic>? statusBody;

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/customers/cust-9/status') {
        statusBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('', 200);
      }
      if (request.url.path == '/api/v1/customers/cust-9') {
        getDetailCalls++;
        final status = getDetailCalls == 1 ? 'ACTIVE' : 'INACTIVE';
        return _jsonOk({
          'id': 'cust-9', 'customer_code': 'FARM009', 'name': 'Toggle Test Farmer',
          'customer_type': 'FARMER', 'phone': null, 'status': status,
          'credit_limit': '5000.00', 'outstanding_balance': '0.00',
          'available_credit': '5000.00', 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-9/ledger') {
        return _jsonOk({'entries': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const CustomerLedgerScreen(customerId: 'cust-9'),
      permissions: const ['credit.configure'],
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('toggle_customer_active_button')));
    await tester.pumpAndSettle();

    expect(find.text('Deactivate Customer?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('customer_toggle_active_confirm')));
    await tester.pumpAndSettle();

    expect(statusBody, isNotNull);
    expect(statusBody!['active'], false);
    expect(find.text('Customer deactivated'), findsOneWidget);
  });

  testWidgets('Edit Credit Limit button is hidden without credit.configure permission', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/customers/cust-10') {
        return _jsonOk({
          'id': 'cust-10', 'customer_code': 'FARM011', 'name': 'No Permission Farmer',
          'customer_type': 'FARMER', 'phone': null, 'status': 'ACTIVE',
          'credit_limit': '5000.00', 'outstanding_balance': '1000.00',
          'available_credit': '4000.00', 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-10/ledger') {
        return _jsonOk({'entries': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const CustomerLedgerScreen(customerId: 'cust-10'),
      permissions: const [],
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('edit_credit_limit_button')), findsNothing);
  });

  testWidgets('Edit Credit Limit updates the limit and refreshes the summary', (tester) async {
    var getDetailCalls = 0;
    Map<String, dynamic>? putBody;

    final client = MockClient((request) async {
      if (request.method == 'PUT' && request.url.path == '/api/v1/customers/cust-6/credit-limit') {
        putBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('', 204);
      }
      if (request.url.path == '/api/v1/customers/cust-6') {
        getDetailCalls++;
        final limit = getDetailCalls == 1 ? '5000.00' : '8000.00';
        final available = getDetailCalls == 1 ? '4000.00' : '7000.00';
        return _jsonOk({
          'id': 'cust-6', 'customer_code': 'FARM006', 'name': 'Limit Change Farmer',
          'customer_type': 'FARMER', 'phone': null, 'status': 'ACTIVE',
          'credit_limit': limit, 'outstanding_balance': '1000.00',
          'available_credit': available, 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-6/ledger') {
        return _jsonOk({'entries': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const CustomerLedgerScreen(customerId: 'cust-6'),
      permissions: const ['credit.configure'],
    ));
    await tester.pumpAndSettle();

    expect(find.text('₹5,000.00'), findsOneWidget);

    await tester.tap(find.byKey(const Key('edit_credit_limit_button')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('credit_limit_field')), '8000.00');
    await tester.tap(find.byKey(const Key('credit_limit_submit_button')));
    await tester.pumpAndSettle();

    expect(putBody, isNotNull);
    expect(Decimal.parse(putBody!['credit_limit'] as String), Decimal.parse('8000.00'));
    expect(find.textContaining('Credit limit updated to ₹8,000.00'), findsOneWidget);
    expect(find.text('₹8,000.00'), findsOneWidget);
  });

  testWidgets('Edit Credit Limit rejects a negative amount client-side', (tester) async {
    var putCallCount = 0;
    final client = MockClient((request) async {
      if (request.method == 'PUT' && request.url.path == '/api/v1/customers/cust-7/credit-limit') {
        putCallCount++;
        return http.Response('', 204);
      }
      if (request.url.path == '/api/v1/customers/cust-7') {
        return _jsonOk({
          'id': 'cust-7', 'customer_code': 'FARM007', 'name': 'Negative Test Farmer',
          'customer_type': 'FARMER', 'phone': null, 'status': 'ACTIVE',
          'credit_limit': '5000.00', 'outstanding_balance': '1000.00',
          'available_credit': '4000.00', 'risk_status': 'NORMAL',
        });
      }
      if (request.url.path == '/api/v1/customers/cust-7/ledger') {
        return _jsonOk({'entries': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const CustomerLedgerScreen(customerId: 'cust-7'),
      permissions: const ['credit.configure'],
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('edit_credit_limit_button')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('credit_limit_field')), '-100');
    await tester.tap(find.byKey(const Key('credit_limit_submit_button')));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid, non-negative amount'), findsOneWidget);
    expect(putCallCount, 0);
  });
}
