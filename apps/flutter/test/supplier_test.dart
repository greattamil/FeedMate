// Widget tests for the supplier payable feature — the mirror image of
// customer_management_test.dart on the payable side: searching for a supplier, viewing
// their statement (payable summary + itemized ledger), and recording a
// payment. Uses a mocked HTTP client — end-to-end behavior against the real
// Go server is verified separately (see docs/IMPLEMENTATION_STATUS.md).
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
import 'package:feedmate_app/features/supplier/supplier_detail_screen.dart';
import 'package:feedmate_app/features/supplier/supplier_list_screen.dart';

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
  testWidgets('Supplier list shows search results and navigates into a statement', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/suppliers') {
        return _jsonOk({
          'suppliers': [
            {
              'id': 'sup-1', 'supplier_code': 'SUP001', 'name': 'Test Feed Mill', 'phone': '9876543210',
              'gstin': '29ABCDE1234F1Z5', 'payable': '12000.00',
            }
          ]
        });
      }
      if (request.url.path == '/api/v1/suppliers/sup-1') {
        return _jsonOk({
          'id': 'sup-1', 'supplier_code': 'SUP001', 'name': 'Test Feed Mill',
          'phone': '9876543210', 'gstin': '29ABCDE1234F1Z5', 'payment_terms_days': 30,
          'outstanding_payable': '12000.00',
        });
      }
      if (request.url.path == '/api/v1/suppliers/sup-1/ledger') {
        return _jsonOk({
          'entries': [
            {
              'id': 'e2', 'entry_date': '2026-09-12T12:00:00+05:30', 'document_type': 'GRN',
              'document_id': 'grn-2', 'debit': '0.00', 'credit': '12000.00', 'description': 'GRN received',
            },
            {
              'id': 'e1', 'entry_date': '2026-09-10T09:00:00+05:30', 'document_type': 'PAYMENT',
              'document_id': 'pmt-1', 'debit': '5000.00', 'credit': '0.00', 'description': 'Cash payment',
            },
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const SupplierListScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Test Feed Mill'), findsOneWidget);
    expect(find.textContaining('SUP001'), findsOneWidget);
    expect(find.text('₹12,000.00 Payable'), findsOneWidget);

    await tester.tap(find.byKey(const Key('supplier_sup-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('supplier_outstanding_payable')), findsOneWidget);
    expect(find.text('₹12,000.00'), findsOneWidget);
    expect(find.text('30 days'), findsOneWidget);

    expect(find.text('GRN received'), findsOneWidget);
    expect(find.text('Cash payment'), findsOneWidget);
    expect(find.text('+₹12,000.00'), findsOneWidget);
    expect(find.text('-₹5,000.00'), findsOneWidget);
  });

  testWidgets('a long phone number and a large payable amount never overflow the list tile', (tester) async {
    // Regression guard: caught live on the emulator — a wide payable badge
    // (e.g. "₹171825.00 Payable") squeezed the subtitle row below the
    // phone number's natural width, overflowing the tile on the right.
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/suppliers') {
        return _jsonOk({
          'suppliers': [
            {
              'id': 'sup-3', 'supplier_code': 'SUP-LIVE-01', 'name': 'Live Test Feed Mill',
              'phone': '9998887770', 'payable': '171825.00',
            }
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const SupplierListScreen()));
    await tester.pumpAndSettle();

    expect(find.text('₹1,71,825.00 Payable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Supplier list shows a Settled badge for a zero payable, not a Payable amount', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/suppliers') {
        return _jsonOk({
          'suppliers': [
            {'id': 'sup-2', 'supplier_code': 'SUP002', 'name': 'Settled Mill', 'payable': '0.00'}
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(httpClient: client, child: const SupplierListScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Settled Mill'), findsOneWidget);
    expect(find.text('Settled'), findsOneWidget);
    expect(find.textContaining('Payable'), findsNothing);
  });

  testWidgets('Record Payment posts a manual payment and refreshes the balance', (tester) async {
    var getDetailCalls = 0;
    String? sentIdempotencyKey;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/suppliers/sup-2') {
        getDetailCalls++;
        final payable = getDetailCalls == 1 ? '10000.00' : '7500.00';
        return _jsonOk({
          'id': 'sup-2', 'supplier_code': 'SUP002', 'name': 'Payment Test Mill',
          'phone': null, 'gstin': null, 'payment_terms_days': 15,
          'outstanding_payable': payable,
        });
      }
      if (request.url.path == '/api/v1/suppliers/sup-2/ledger') {
        return _jsonOk({'entries': []});
      }
      if (request.url.path == '/api/v1/payments/supplier-payments') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['supplier_id'], 'sup-2');
        expect(Decimal.parse(body['amount'] as String), Decimal.parse('2500.00'));
        expect(body['method'], 'CASH');
        sentIdempotencyKey = body['idempotency_key'] as String;
        return _jsonOk({'payment_id': 'pay-1', 'duplicate': false});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const SupplierDetailScreen(supplierId: 'sup-2'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('₹10,000.00'), findsWidgets);

    await tester.tap(find.byKey(const Key('record_payment_fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('payment_amount_field')), '2500.00');
    await tester.tap(find.byKey(const Key('payment_submit_button')));
    await tester.pumpAndSettle();

    expect(sentIdempotencyKey, isNotNull);
    expect(sentIdempotencyKey, isNotEmpty);
    expect(find.textContaining('Payment of ₹2,500.00 recorded'), findsOneWidget);
    expect(find.text('₹7,500.00'), findsOneWidget);
  });

  testWidgets('Record Payment rejects a zero amount client-side before calling the server', (tester) async {
    var paymentCallCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/suppliers/sup-3') {
        return _jsonOk({
          'id': 'sup-3', 'supplier_code': 'SUP003', 'name': 'Zero Amount Mill',
          'phone': null, 'gstin': null, 'payment_terms_days': 0,
          'outstanding_payable': '1000.00',
        });
      }
      if (request.url.path == '/api/v1/suppliers/sup-3/ledger') {
        return _jsonOk({'entries': []});
      }
      if (request.url.path == '/api/v1/payments/supplier-payments') {
        paymentCallCount++;
        return _jsonOk({'payment_id': 'pay-2', 'duplicate': false});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const SupplierDetailScreen(supplierId: 'sup-3'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('record_payment_fab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('payment_submit_button')));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid amount greater than zero'), findsOneWidget);
    expect(paymentCallCount, 0);
  });

  testWidgets('Add Supplier FAB is hidden without supplier.manage permission', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/suppliers') {
        return _jsonOk({'suppliers': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const SupplierListScreen(),
      permissions: const [],
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('add_supplier_fab')), findsNothing);
  });

  testWidgets('Add Supplier creates a new supplier and refreshes the list', (tester) async {
    Map<String, dynamic>? createdBody;
    var searchCallCount = 0;

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/suppliers') {
        createdBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({
          'id': 'sup-new', 'supplier_code': 'SUPP-0001', 'name': createdBody!['name'],
          'payment_terms_days': createdBody!['payment_terms_days'], 'status': 'ACTIVE',
        }), 201);
      }
      if (request.url.path == '/api/v1/suppliers/sup-new') {
        return _jsonOk({
          'id': 'sup-new', 'supplier_code': 'SUPNEW', 'name': 'New Feed Mill',
          'phone': '9000000000', 'gstin': null, 'payment_terms_days': 20,
          'outstanding_payable': '0.00', 'status': 'ACTIVE',
        });
      }
      if (request.url.path == '/api/v1/suppliers') {
        searchCallCount++;
        if (searchCallCount == 1) return _jsonOk({'suppliers': []});
        return _jsonOk({
          'suppliers': [
            {'id': 'sup-new', 'supplier_code': 'SUPNEW', 'name': 'New Feed Mill', 'phone': '9000000000', 'gstin': null}
          ]
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const SupplierListScreen(),
      permissions: const ['supplier.manage'],
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('add_supplier_fab')), findsOneWidget);
    await tester.tap(find.byKey(const Key('add_supplier_fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('supplier_name_field')), 'New Feed Mill');
    await tester.enterText(find.byKey(const Key('supplier_phone_field')), '9000000000');
    await tester.enterText(find.byKey(const Key('supplier_payment_terms_field')), '20');
    await tester.tap(find.byKey(const Key('supplier_form_submit')));
    await tester.pumpAndSettle();

    expect(createdBody, isNotNull);
    expect(createdBody!.containsKey('supplier_code'), isFalse, reason: 'supplier_code is server-generated and must never be sent by the client');
    expect(createdBody!['name'], 'New Feed Mill');
    expect(createdBody!['phone'], '9000000000');
    expect(createdBody!['payment_terms_days'], 20);

    expect(find.textContaining('New Feed Mill added to supplier directory'), findsOneWidget);
    expect(find.text('New Feed Mill'), findsOneWidget);
  });

  testWidgets('Add Supplier form rejects missing required fields client-side', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/suppliers') {
        return _jsonOk({'suppliers': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const SupplierListScreen(),
      permissions: const ['supplier.manage'],
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add_supplier_fab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('supplier_form_submit')));
    await tester.pumpAndSettle();

    expect(find.text('Required'), findsWidgets);
  });

  testWidgets('Edit/deactivate buttons are hidden without supplier.manage permission', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/suppliers/sup-4') {
        return _jsonOk({
          'id': 'sup-4', 'supplier_code': 'SUP004', 'name': 'No Permission Mill',
          'phone': null, 'gstin': null, 'payment_terms_days': 0,
          'outstanding_payable': '0.00', 'status': 'ACTIVE',
        });
      }
      if (request.url.path == '/api/v1/suppliers/sup-4/ledger') {
        return _jsonOk({'entries': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const SupplierDetailScreen(supplierId: 'sup-4'),
      permissions: const [],
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('edit_supplier_button')), findsNothing);
    expect(find.byKey(const Key('toggle_supplier_active_button')), findsNothing);
  });

  testWidgets('Edit Supplier updates fields (never supplier_code) and refreshes the summary', (tester) async {
    var getDetailCalls = 0;
    Map<String, dynamic>? putBody;

    final client = MockClient((request) async {
      if (request.method == 'PUT' && request.url.path == '/api/v1/suppliers/sup-5') {
        putBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _jsonOk({
          'id': 'sup-5', 'supplier_code': 'SUP005', 'name': putBody!['name'],
          'payment_terms_days': putBody!['payment_terms_days'], 'status': 'ACTIVE',
        });
      }
      if (request.url.path == '/api/v1/suppliers/sup-5') {
        getDetailCalls++;
        final name = getDetailCalls == 1 ? 'Original Mill' : 'Renamed Mill';
        return _jsonOk({
          'id': 'sup-5', 'supplier_code': 'SUP005', 'name': name,
          'phone': null, 'gstin': null, 'payment_terms_days': getDetailCalls == 1 ? 10 : 60,
          'outstanding_payable': '0.00', 'status': 'ACTIVE',
        });
      }
      if (request.url.path == '/api/v1/suppliers/sup-5/ledger') {
        return _jsonOk({'entries': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const SupplierDetailScreen(supplierId: 'sup-5'),
      permissions: const ['supplier.manage'],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Original Mill'), findsOneWidget);

    await tester.tap(find.byKey(const Key('edit_supplier_button')));
    await tester.pumpAndSettle();

    // supplier_code field must be present but disabled (read-only) in edit mode.
    final codeField = tester.widget<TextFormField>(find.byKey(const Key('supplier_code_field_readonly')));
    expect(codeField.enabled, false);

    await tester.enterText(find.byKey(const Key('supplier_name_field')), 'Renamed Mill');
    await tester.enterText(find.byKey(const Key('supplier_payment_terms_field')), '60');
    await tester.tap(find.byKey(const Key('supplier_form_submit')));
    await tester.pumpAndSettle();

    expect(putBody, isNotNull);
    expect(putBody!.containsKey('supplier_code'), false);
    expect(putBody!['name'], 'Renamed Mill');
    expect(putBody!['payment_terms_days'], 60);

    expect(find.text('Supplier updated'), findsOneWidget);
    expect(find.text('Renamed Mill'), findsOneWidget);
  });

  testWidgets('Deactivate/reactivate toggle requires confirmation and posts the status change', (tester) async {
    var getDetailCalls = 0;
    Map<String, dynamic>? statusBody;

    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/api/v1/suppliers/sup-6/status') {
        statusBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('', 200);
      }
      if (request.url.path == '/api/v1/suppliers/sup-6') {
        getDetailCalls++;
        final status = getDetailCalls == 1 ? 'ACTIVE' : 'INACTIVE';
        return _jsonOk({
          'id': 'sup-6', 'supplier_code': 'SUP006', 'name': 'Toggle Test Mill',
          'phone': null, 'gstin': null, 'payment_terms_days': 0,
          'outstanding_payable': '0.00', 'status': status,
        });
      }
      if (request.url.path == '/api/v1/suppliers/sup-6/ledger') {
        return _jsonOk({'entries': []});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrapWithProviders(
      httpClient: client,
      child: const SupplierDetailScreen(supplierId: 'sup-6'),
      permissions: const ['supplier.manage'],
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('toggle_supplier_active_button')));
    await tester.pumpAndSettle();

    expect(find.text('Deactivate Supplier?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('supplier_toggle_active_confirm')));
    await tester.pumpAndSettle();

    expect(statusBody, isNotNull);
    expect(statusBody!['active'], false);
    expect(find.text('Supplier deactivated'), findsOneWidget);
  });
}
