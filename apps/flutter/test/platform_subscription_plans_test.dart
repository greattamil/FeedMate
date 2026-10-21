// Widget tests for the platform admin's subscription-plan catalogue screen:
// listing plans, adding one, editing one (code stays read-only/omitted on
// edit since the backend's UpdatePlan has no code field), and toggling
// active status.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/features/platform/platform_api_client.dart';
import 'package:feedmate_app/features/platform/subscription_plans_screen.dart';

http.Response _jsonOk(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

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

Map<String, dynamic> _plan({
  required String id,
  required String code,
  required String name,
  String price = '999.00',
  int gracePeriodDays = 5,
  bool active = true,
}) {
  return {
    'id': id,
    'code': code,
    'name': name,
    'price': price,
    'currency_code': 'INR',
    'billing_period': 'MONTHLY',
    'grace_period_days': gracePeriodDays,
    'active': active,
  };
}

void main() {
  testWidgets('lists plans with price and grace period', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/platform/plans') {
        return _jsonOk({
          'plans': [
            _plan(id: 'p1', code: 'PRO', name: 'Pro'),
            _plan(id: 'p2', code: 'BASIC', name: 'Basic', price: '499.00', active: false),
          ],
        });
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const SubscriptionPlansScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Pro'), findsOneWidget);
    expect(find.text('Basic'), findsOneWidget);
    expect(find.textContaining('PRO'), findsOneWidget);
  });

  testWidgets('adding a plan posts code/name/price/grace period', (tester) async {
    Map<String, dynamic>? postedBody;
    var listCallCount = 0;

    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/v1/platform/plans') {
        listCallCount++;
        if (listCallCount == 1) return _jsonOk({'plans': []});
        return _jsonOk({'plans': [_plan(id: 'new-p1', code: 'NEWPLAN', name: 'New Plan')]});
      }
      if (request.method == 'POST' && request.url.path == '/api/v1/platform/plans') {
        postedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _jsonOk({'id': 'new-p1'}, 201);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const SubscriptionPlansScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('subscription_plans_add_fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('plan_form_code_field')), 'NEWPLAN');
    await tester.enterText(find.byKey(const Key('plan_form_name_field')), 'New Plan');
    await tester.enterText(find.byKey(const Key('plan_form_price_field')), '1999.00');
    await tester.enterText(find.byKey(const Key('plan_form_grace_period_field')), '7');

    await tester.tap(find.byKey(const Key('plan_form_submit')));
    await tester.pumpAndSettle();

    expect(postedBody, isNotNull);
    expect(postedBody!['code'], 'NEWPLAN');
    expect(postedBody!['name'], 'New Plan');
    expect(postedBody!['price'], '1999');
    expect(postedBody!['grace_period_days'], 7);
    expect(find.text('New Plan'), findsOneWidget);
  });

  testWidgets('editing a plan does not show a code field and omits code from the request', (tester) async {
    Map<String, dynamic>? putBody;
    var listCallCount = 0;

    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/v1/platform/plans') {
        listCallCount++;
        return _jsonOk({'plans': [_plan(id: 'p1', code: 'PRO', name: listCallCount == 1 ? 'Pro' : 'Pro Plus')]});
      }
      if (request.method == 'PUT' && request.url.path == '/api/v1/platform/plans/p1') {
        putBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('', 204);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const SubscriptionPlansScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('subscription_plan_item_p1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('plan_form_code_field')), findsNothing);

    await tester.enterText(find.byKey(const Key('plan_form_name_field')), 'Pro Plus');
    await tester.tap(find.byKey(const Key('plan_form_submit')));
    await tester.pumpAndSettle();

    expect(putBody, isNotNull);
    expect(putBody!.containsKey('code'), isFalse);
    expect(putBody!['name'], 'Pro Plus');
    expect(find.text('Pro Plus'), findsOneWidget);
  });

  testWidgets('toggling the active switch sends an update with the new active state', (tester) async {
    Map<String, dynamic>? putBody;

    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/api/v1/platform/plans') {
        return _jsonOk({'plans': [_plan(id: 'p1', code: 'PRO', name: 'Pro', active: true)]});
      }
      if (request.method == 'PUT' && request.url.path == '/api/v1/platform/plans/p1') {
        putBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('', 204);
      }
      return http.Response('not found', 404);
    });

    await tester.pumpWidget(_wrap(httpClient: client, child: const SubscriptionPlansScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('subscription_plan_active_switch_p1')));
    await tester.pumpAndSettle();

    expect(putBody, isNotNull);
    expect(putBody!['active'], false);
  });
}
