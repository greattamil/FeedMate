// Widget tests for the Home Dashboard's "MANAGE" section: every module
// added in Phases 27-40 must be reachable from Home, not only from the
// Counter tab's overflow menu, each gated by the same permission its own
// screen/menu-item requires.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:feedmate_app/core/api_client.dart';
import 'package:feedmate_app/core/auth_session.dart';
import 'package:feedmate_app/core/branding_provider.dart';
import 'package:feedmate_app/core/local_db.dart';
import 'package:feedmate_app/core/secure_storage.dart';
import 'package:feedmate_app/features/auditlog/audit_log_screen.dart';
import 'package:feedmate_app/features/auth/device_management_screen.dart';
import 'package:feedmate_app/features/contra/contra_screen.dart';
import 'package:feedmate_app/features/dashboard/home_dashboard_screen.dart';
import 'package:feedmate_app/features/docseries/doc_series_screen.dart';
import 'package:feedmate_app/features/pos/invoice_history_screen.dart';
import 'package:feedmate_app/features/procurement/grn_history_screen.dart';
import 'package:feedmate_app/features/products/master_data_screen.dart';
import 'package:feedmate_app/features/products/product_list_screen.dart';
import 'package:feedmate_app/features/returns/return_screen.dart';
import 'package:feedmate_app/features/staff/staff_list_screen.dart';
import 'package:feedmate_app/features/stockcount/stock_count_history_screen.dart';

import 'fake_local_db.dart';

// Deliberately excludes report.view and cash.eod_close so
// _loadDashboardData's optional KPI fetches are skipped entirely — this
// test is only about the MANAGE grid's gating and navigation, not the KPI
// cards, so it needs no HTTP mocking beyond a 404 fallback.
const _allManagePermissions = [
  'product.manage',
  'stock.count',
  'pos.sell',
  'grn.post',
  'return.create',
  'contra.approve',
  'user.manage',
  'device.manage',
  'tenant.admin',
];

AuthSession _session({required http.Client httpClient, required List<String> permissions}) {
  final storage = SecureStorage(store: InMemoryKeyValueStore());
  final apiClient = ApiClient(baseUrl: 'http://test.invalid', storage: storage, httpClient: httpClient);
  return AuthSession(apiClient: apiClient, storage: storage)
    ..status = AuthStatus.loggedIn
    ..tenantId = 'tenant-123'
    ..displayName = 'Test Owner'
    ..permissions = permissions;
}

/// HomeDashboardScreen's body is a plain ListView(children: [...]), whose
/// SliverChildListDelegate only inflates elements within the viewport +
/// cache extent — the same lazy-build gotcha documented in grn_test.dart.
/// The MANAGE section is well below the fold, so it must be scrolled into
/// view incrementally rather than asserted on directly.
Future<void> _scrollToManageSection(WidgetTester tester) async {
  await tester.dragUntilVisible(find.text('MANAGE'), find.byType(Scrollable).first, const Offset(0, -300));
  await tester.pumpAndSettle();
}

Widget _wrap({required AuthSession session}) {
  final localDb = FakeLocalDatabase();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthSession>.value(value: session),
      Provider<ApiClient>.value(value: session.apiClient),
      ChangeNotifierProvider<BrandingProvider>(create: (_) => BrandingProvider(client: session.apiClient, storage: session.storage)),
      Provider<LocalDatabase>.value(value: localDb),
    ],
    child: MaterialApp(home: HomeDashboardScreen(onOpenPos: () {})),
  );
}

void main() {
  testWidgets('MANAGE section shows every module when all permissions are granted', (tester) async {
    final client = MockClient((request) async => http.Response('not found', 404));
    final session = _session(httpClient: client, permissions: _allManagePermissions);

    await tester.pumpWidget(_wrap(session: session));
    await tester.pumpAndSettle();
    await _scrollToManageSection(tester);

    expect(find.text('MANAGE'), findsOneWidget);
    expect(find.text('Products'), findsOneWidget);
    expect(find.text('Categories & Brands'), findsOneWidget);
    expect(find.text('Stock Counts'), findsOneWidget);
    expect(find.text('Invoice History'), findsOneWidget);
    expect(find.text('GRN History'), findsOneWidget);
    expect(find.text('Sales Return'), findsOneWidget);
    expect(find.text('Contra / Buy-Back'), findsOneWidget);
    expect(find.text('Staff'), findsOneWidget);
    expect(find.text('Manage Devices'), findsOneWidget);
    expect(find.text('Financial Years'), findsOneWidget);
    expect(find.text('Audit Log'), findsOneWidget);
  });

  testWidgets('MANAGE section hides every module when no permissions are granted', (tester) async {
    final client = MockClient((request) async => http.Response('not found', 404));
    final session = _session(httpClient: client, permissions: const []);

    await tester.pumpWidget(_wrap(session: session));
    await tester.pumpAndSettle();
    await _scrollToManageSection(tester);

    // The section header itself always renders, but every card is gated.
    expect(find.text('MANAGE'), findsOneWidget);
    expect(find.text('Products'), findsNothing);
    expect(find.text('Stock Counts'), findsNothing);
    expect(find.text('Staff'), findsNothing);
    expect(find.text('Financial Years'), findsNothing);
    expect(find.text('Audit Log'), findsNothing);
  });

  testWidgets('tapping each MANAGE card navigates to its real screen', (tester) async {
    final client = MockClient((request) async => http.Response('not found', 404));

    final destinations = <String, Type>{
      'Products': ProductListScreen,
      'Categories & Brands': MasterDataScreen,
      'Stock Counts': StockCountHistoryScreen,
      'Invoice History': InvoiceHistoryScreen,
      'GRN History': GrnHistoryScreen,
      'Sales Return': ReturnScreen,
      'Contra / Buy-Back': ContraScreen,
      'Staff': StaffListScreen,
      'Manage Devices': DeviceManagementScreen,
      'Financial Years': DocSeriesScreen,
      'Audit Log': AuditLogScreen,
    };

    final session = _session(httpClient: client, permissions: _allManagePermissions);
    await tester.pumpWidget(_wrap(session: session));
    await tester.pumpAndSettle();

    // A single HomeDashboardScreen instance is reused for every destination
    // below: pumpWidget() rebuilds in place rather than tearing down the
    // Navigator (same widget types at the same tree position), so pushing a
    // second route without popping the first would leave it stacked
    // underneath, making the dashboard's own cards unreachable.
    for (final entry in destinations.entries) {
      // Scroll to the card itself, not just the section header: the grid's
      // taller icon-over-label tiles mean a card several rows into the
      // MANAGE section can still sit below the fold even once the header
      // is visible.
      await tester.dragUntilVisible(find.text(entry.key), find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pumpAndSettle();

      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();

      expect(find.byType(entry.value), findsOneWidget, reason: 'tapping "${entry.key}" should open ${entry.value}');

      Navigator.pop(tester.element(find.byType(entry.value)));
      await tester.pumpAndSettle();
    }
  });
}
