// Widget tests for the End-of-Day cash reconciliation screen: opening the
// day, closing it (including the variance-reason retry path when the
// counted cash doesn't match what the server expects), and reopening a
// closed day. Uses a mocked HTTP client — end-to-end behavior against the
// real Go server is verified separately (see docs/IMPLEMENTATION_STATUS.md).
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/eod/eod_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body) => http.Response(jsonEncode(body), 200);
http.Response _notFound() => http.Response(
      jsonEncode({
        'error': {'code': 'NOT_FOUND', 'message': 'no EOD session for this business date', 'retryable': false}
      }),
      404,
    );

Widget _wrap({required http.Client httpClient}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  storage.saveTokens(accessToken: 'tok', refreshToken: 'ref', tenantId: 'tenant-123');
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  return MultiProvider(
    providers: [
      Provider<SecureStorage>.value(value: storage),
      Provider<ApiClient>.value(value: apiClient),
    ],
    child: const MaterialApp(home: EodScreen()),
  );
}

void main() {
  testWidgets('shows "Open Day" when no session exists yet, and opening posts the float', (tester) async {
    var sessionOpened = false;
    String? sentOpeningCash;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/eod' && request.method == 'GET') {
        if (sessionOpened) {
          return _jsonOk({
            'session_id': 's1', 'business_date': '2026-09-12', 'opening_cash': '2000.00',
            'cash_sales': '0.00', 'cash_refunds': '0.00', 'expected_cash': '0.00', 'status': 'OPEN',
          });
        }
        return _notFound();
      }
      if (request.url.path == '/api/v1/eod/cash-movements' && request.method == 'GET') {
        return _jsonOk({'movements': []});
      }
      if (request.url.path == '/api/v1/eod/open') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        sentOpeningCash = body['opening_cash'] as String;
        sessionOpened = true;
        return _jsonOk({'session_id': 's1'});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.text('No cash session opened for today yet.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('open_day_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('amount_dialog_field')), '2000.00');
    await tester.tap(find.byKey(const Key('amount_dialog_submit')));
    await tester.pumpAndSettle();

    expect(Decimal.parse(sentOpeningCash!), Decimal.parse('2000.00'));
    expect(find.byKey(const Key('eod_status')), findsOneWidget);
    expect(find.text('OPEN'), findsOneWidget);
    expect(find.byKey(const Key('close_day_button')), findsOneWidget);
  });

  testWidgets('closing with a mismatched cash count prompts for a reason, then retries and succeeds', (tester) async {
    var closeAttempts = 0;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/eod' && request.method == 'GET') {
        return _jsonOk({
          'session_id': 's1', 'business_date': '2026-09-12', 'opening_cash': '2000.00',
          'cash_sales': '0.00', 'cash_refunds': '0.00', 'expected_cash': '0.00', 'status': 'OPEN',
        });
      }
      if (request.url.path == '/api/v1/eod/cash-movements' && request.method == 'GET') {
        return _jsonOk({'movements': []});
      }
      if (request.url.path == '/api/v1/eod/close') {
        closeAttempts++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (closeAttempts == 1) {
          expect(body.containsKey('variance_reason'), isFalse);
          return http.Response(
            jsonEncode({
              'error': {
                'code': 'VALIDATION_ERROR',
                'message': 'validation error: a reason is required when actual cash does not match expected cash (variance -500.00)',
                'retryable': false,
              }
            }),
            422,
          );
        }
        expect(body['variance_reason'], 'Short due to a torn note discarded');
        return _jsonOk({
          'session_id': 's1', 'expected_cash': '7000.00', 'actual_cash': '6500.00', 'variance': '-500.00',
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('close_day_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('close_actual_cash_field')), '6500.00');
    await tester.tap(find.byKey(const Key('close_day_submit')));
    await tester.pumpAndSettle();

    // The server's validation message surfaces in a fresh dialog, cash
    // amount pre-filled so the cashier doesn't have to recount and retype.
    expect(find.textContaining('reason is required'), findsOneWidget);
    expect(find.text('6500.00'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('close_variance_reason_field')), 'Short due to a torn note discarded');
    await tester.tap(find.byKey(const Key('close_day_submit')));
    await tester.pumpAndSettle();

    expect(closeAttempts, 2);
    expect(find.text('Day Closed'), findsOneWidget);
    expect(find.textContaining('-500.00'), findsOneWidget);
  });

  testWidgets('a closed day shows Reopen, and reopening posts the reason', (tester) async {
    var status = 'CLOSED';
    String? sentReopenReason;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/eod' && request.method == 'GET') {
        return _jsonOk({
          'session_id': 's1', 'business_date': '2026-09-12', 'opening_cash': '2000.00',
          'cash_sales': '5000.00', 'cash_refunds': '0.00', 'expected_cash': '7000.00',
          'actual_cash': '7000.00', 'variance': '0.00', 'status': status,
        });
      }
      if (request.url.path == '/api/v1/eod/cash-movements' && request.method == 'GET') {
        return _jsonOk({'movements': []});
      }
      if (request.url.path == '/api/v1/eod/reopen') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        sentReopenReason = body['reason'] as String;
        status = 'REOPENED';
        return http.Response('', 204);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    expect(find.text('CLOSED'), findsOneWidget);
    expect(find.byKey(const Key('reopen_day_button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('reopen_day_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('reason_dialog_field')), 'Late credit sale needs posting');
    await tester.tap(find.byKey(const Key('reason_dialog_submit')));
    await tester.pumpAndSettle();

    expect(sentReopenReason, 'Late credit sale needs posting');
    expect(find.text('REOPENED'), findsOneWidget);
  });

  testWidgets('recording cash out posts the movement and shows it in the log', (tester) async {
    var movements = <Map<String, dynamic>>[];
    Map<String, dynamic>? postedBody;

    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/eod' && request.method == 'GET') {
        return _jsonOk({
          'session_id': 's1', 'business_date': '2026-09-12', 'opening_cash': '2000.00',
          'cash_sales': '0.00', 'cash_refunds': '0.00', 'expected_cash': '0.00', 'status': 'OPEN',
        });
      }
      if (request.url.path == '/api/v1/eod/cash-movements' && request.method == 'GET') {
        return _jsonOk({'movements': movements});
      }
      if (request.url.path == '/api/v1/eod/cash-movements' && request.method == 'POST') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        movements = [
          {
            'id': 'mv-1', 'movement_type': postedBody!['movement_type'], 'direction': postedBody!['direction'],
            'amount': postedBody!['amount'], 'reason': postedBody!['reason'], 'created_at': '2026-09-12T10:00:00+05:30',
          }
        ];
        return _jsonOk({'movement_id': 'mv-1'});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('cash_movement_button')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('cash_movement_amount_field')), '300.00');
    await tester.enterText(find.byKey(const Key('cash_movement_reason_field')), 'Tea and snacks');
    await tester.tap(find.byKey(const Key('cash_movement_submit_button')));
    await tester.pumpAndSettle();

    expect(postedBody, isNotNull);
    expect(postedBody!['movement_type'], 'EXPENSE');
    expect(postedBody!['direction'], 'OUT');
    expect(postedBody!['amount'], '300.00');
    expect(postedBody!['reason'], 'Tea and snacks');

    expect(find.textContaining('Cash out of ₹300.00 recorded'), findsOneWidget);
    expect(find.text('Cash Movements Today'), findsOneWidget);
    expect(find.textContaining('EXPENSE'), findsOneWidget);
    expect(find.text('-₹300.00'), findsOneWidget);
  });

  testWidgets('cash movement form rejects a non-positive amount client-side', (tester) async {
    var postCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/eod' && request.method == 'GET') {
        return _jsonOk({
          'session_id': 's1', 'business_date': '2026-09-12', 'opening_cash': '2000.00',
          'cash_sales': '0.00', 'cash_refunds': '0.00', 'expected_cash': '0.00', 'status': 'OPEN',
        });
      }
      if (request.url.path == '/api/v1/eod/cash-movements' && request.method == 'GET') {
        return _jsonOk({'movements': []});
      }
      if (request.url.path == '/api/v1/eod/cash-movements' && request.method == 'POST') {
        postCount++;
        return _jsonOk({'movement_id': 'mv-x'});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('cash_movement_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cash_movement_submit_button')));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid amount greater than zero'), findsOneWidget);
    expect(postCount, 0);
  });
}
