// Widget tests for the platform admin's tenant Billing tab: the no-
// subscription empty state, the subscription summary with its status
// badge, changing plans, and recording a manually-collected payment.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/features/platform/platform_api_client.dart';
import 'package:feedmate_app/features/platform/tenant_billing_tab.dart';

http.Response _jsonOk(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

http.Response _notFound() => http.Response(
      jsonEncode({'error': {'code': 'NOT_FOUND', 'message': 'not found'}}),
      404,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Widget _wrap({required http.Client httpClient, required Widget child}) {
  final client = PlatformApiClient(baseUrl: 'http://test.invalid', httpClient: httpClient);
  client.seedTokensForTesting(accessToken: 'test-access-token', refreshToken: 'test-refresh-token');
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<PlatformApiClient>.value(value: client),
    ],
    child: MaterialApp(home: Scaffold(backgroundColor: const Color(0xFF0F172A), body: child)),
  );
}

Map<String, dynamic> _subscription({String status = 'ACTIVE'}) {
  return {
    'id': 'sub1',
    'tenant_id': 't1',
    'plan_id': 'plan1',
    'plan_code': 'PRO',
    'plan_name': 'Pro',
    'plan_price': '999.00',
    'status': status,
    'current_period_start': '2026-10-01',
    'current_period_end': '2026-11-01',
    'effective_grace_period_days': 5,
  };
}

void main() {
  testWidgets('shows empty state with assign-plan button when tenant has no subscription', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/tenants/t1/subscription') {
        return _notFound();
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const TenantBillingTab(tenantId: 't1')));
    await tester.pumpAndSettle();

    expect(find.text('No subscription assigned yet'), findsOneWidget);
    expect(find.byKey(const Key('tenant_billing_assign_plan_button')), findsOneWidget);
  });

  testWidgets('shows subscription summary and status badge when assigned', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/tenants/t1/subscription') {
        return _jsonOk(_subscription(status: 'PAST_DUE'));
      }
      if (request.url.path == '/api/v1/platform/tenants/t1/subscription/payments') {
        return _jsonOk({'payments': [], 'total': 0});
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const TenantBillingTab(tenantId: 't1')));
    await tester.pumpAndSettle();

    expect(find.text('Pro'), findsOneWidget);
    expect(find.text('PAST_DUE'), findsOneWidget);
    expect(find.byKey(const Key('tenant_billing_change_plan_button')), findsOneWidget);
    expect(find.byKey(const Key('tenant_billing_record_payment_button')), findsOneWidget);
  });

  testWidgets('changing plan loads the plan catalogue and submits the selected plan', (tester) async {
    Map<String, dynamic>? putBody;

    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/v1/platform/tenants/t1/subscription') {
        return _jsonOk(_subscription());
      }
      if (request.method == 'GET' && request.url.path == '/api/v1/platform/tenants/t1/subscription/payments') {
        return _jsonOk({'payments': [], 'total': 0});
      }
      if (request.method == 'GET' && request.url.path == '/api/v1/platform/plans') {
        return _jsonOk({
          'plans': [
            {
              'id': 'plan1',
              'code': 'PRO',
              'name': 'Pro',
              'price': '999.00',
              'currency_code': 'INR',
              'billing_period': 'MONTHLY',
              'grace_period_days': 5,
              'active': true,
            },
            {
              'id': 'plan2',
              'code': 'BASIC',
              'name': 'Basic',
              'price': '499.00',
              'currency_code': 'INR',
              'billing_period': 'MONTHLY',
              'grace_period_days': 3,
              'active': true,
            },
          ],
        });
      }
      if (request.method == 'PUT' && request.url.path == '/api/v1/platform/tenants/t1/subscription/plan') {
        putBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('', 204);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const TenantBillingTab(tenantId: 't1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tenant_billing_change_plan_button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('billing_plan_dialog_submit')));
    await tester.pumpAndSettle();

    expect(putBody, isNotNull);
    expect(putBody!['plan_id'], 'plan1');
  });

  testWidgets('recording a payment posts amount/method and shows a success snackbar', (tester) async {
    Map<String, dynamic>? postedBody;

    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/v1/platform/tenants/t1/subscription') {
        return _jsonOk(_subscription());
      }
      if (request.method == 'GET' && request.url.path == '/api/v1/platform/tenants/t1/subscription/payments') {
        return _jsonOk({'payments': [], 'total': 0});
      }
      if (request.method == 'POST' && request.url.path == '/api/v1/platform/tenants/t1/subscription/payments') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _jsonOk({'payment_id': 'pay1', 'duplicate': false}, 201);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const TenantBillingTab(tenantId: 't1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tenant_billing_record_payment_button')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('billing_payment_amount_field')), '999.00');
    await tester.tap(find.byKey(const Key('billing_payment_submit')));
    await tester.pumpAndSettle();

    expect(postedBody, isNotNull);
    expect(postedBody!['amount'], '999');
    expect(postedBody!['method'], 'UPI');
    expect(postedBody!['idempotency_key'], isNotNull);
    expect(find.text('Payment recorded'), findsOneWidget);
  });
}
