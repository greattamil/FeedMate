import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/app_update_service.dart';
import 'core/auth_session.dart';
import 'core/branding_provider.dart';
import 'core/firebase_options_web.dart';
import 'core/notification_service.dart';
import 'core/push_diagnostics.dart';
import 'core/widgets/update_prompt_dialog.dart';
import 'core/in_memory_local_db.dart';
import 'core/local_db.dart';
import 'core/local_db_sqlcipher.dart';
import 'core/secure_storage.dart';
import 'core/sync_service.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/login_screen.dart';
import 'features/platform/platform_api_client.dart';
import 'features/platform/platform_shell.dart';
import 'features/pos/cart_model.dart';
import 'features/pos/product_repository.dart';
import 'features/shell/app_shell.dart';

/// sqflite_sqlcipher (the encrypted offline store) only ships platform
/// channels for Android/iOS/macOS — see local_db_sqlcipher.dart's doc
/// comment. Windows and web run as always-connected back-office/admin
/// clients instead (the physical counter terminal role stays Android/iOS),
/// so they get [InMemoryLocalDatabase] rather than crashing on a missing
/// plugin. Never uses `dart:io`'s `Platform` — that import alone fails to
/// compile for web; `defaultTargetPlatform` is the cross-platform-safe
/// equivalent.
bool get _supportsEncryptedLocalDb =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

/// Resolves the API base URL for local development. An Android emulator
/// reaches the host machine's localhost via the special alias 10.0.2.2;
/// Windows/desktop/web reach it directly via 127.0.0.1. Override with
/// --dart-define=API_BASE_URL=... for a physical device or real deployment.
String _defaultApiBaseUrl() {
  const override = String.fromEnvironment('API_BASE_URL');
  if (override.isNotEmpty) return override;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) return 'http://10.0.2.2:8081';
  return 'http://127.0.0.1:8081';
}

/// Where AppUpdateService looks for version.json and the APK it points at
/// (see deploy/cloudflare/upload-downloads.sh). No safe local-dev default
/// makes sense here the way API_BASE_URL has one — an empty string just
/// means AppUpdateService.checkForUpdate no-ops, which is correct for any
/// build that didn't set --dart-define=DOWNLOADS_BASE_URL=...
String _defaultDownloadsBaseUrl() => const String.fromEnvironment('DOWNLOADS_BASE_URL');

/// Lets any part of the app show a SnackBar without needing a screen-local
/// BuildContext — used by the global error handlers below, which by
/// definition may fire from code that isn't inside any particular screen's
/// widget tree.
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Lets NotificationService push a screen from a notification tap without
/// a screen-local BuildContext — the tap can arrive while the app is fully
/// backgrounded or freshly cold-started, long before any screen's own
/// context would exist. Same rationale as rootScaffoldMessengerKey above.
final rootNavigatorKey = GlobalKey<NavigatorState>();


/// Before this, an uncaught exception anywhere in the app (outside a
/// screen's own try/catch) vanished into the browser/native console with
/// zero on-screen indication — a user just saw "nothing happened" and had
/// no way to report anything more specific than that. Both Flutter's own
/// framework errors (build/layout/paint) and plain Dart async errors are
/// now guaranteed to at least show a red SnackBar with the real message,
/// on top of the console log every framework still also prints.
void _showGlobalError(String message) {
  rootScaffoldMessengerKey.currentState?.showSnackBar(
    SnackBar(
      content: Text('Unexpected error: $message'),
      backgroundColor: Colors.red.shade700,
      duration: const Duration(seconds: 8),
    ),
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _showGlobalError(details.exceptionAsString());
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught error: $error\n$stack');
    _showGlobalError(error.toString());
    return true;
  };

  // Push notifications (internal/domain/pushnotify) run on Android and web
  // — the two platforms with a registered Firebase app (see
  // core/firebase_options_web.dart's doc comment for why web needs
  // explicit FirebaseOptions, unlike Android's auto-configured
  // google-services.json). Windows has no Firebase project configured at
  // all and stays excluded.
  //
  // Wrapped in try/catch deliberately: this runs before runApp(), so an
  // unhandled exception here (a browser blocking third-party cookies, a
  // transient network blip reaching Firebase, a service-worker
  // registration failure, anything) would abort main() entirely and the
  // user would see a blank page with no way to even log in — the exact
  // outage this caused once already on web. Push is explicitly a
  // nice-to-have everywhere else in this codebase (see
  // auth_session.dart's _registerPushToken doc comment); it must never be
  // able to take the whole app down.
  try {
    if (kIsWeb) {
      await Firebase.initializeApp(options: webFirebaseOptions);
      await NotificationService.instance.init(rootNavigatorKey);
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseBackgroundMessageHandler);
      await NotificationService.instance.init(rootNavigatorKey);
    }
  } catch (e, st) {
    debugPrint('Push notification setup failed (app continues without it): $e\n$st');
    // No ScaffoldMessenger exists yet this early (runApp() hasn't run), so
    // _showGlobalError can't display anything here — PushDiagnostics holds
    // the message until _SessionGate can show it, once one does.
    PushDiagnostics.report('Push setup failed', e);
  }

  final storage = SecureStorage();
  final localDb = _supportsEncryptedLocalDb ? await openEncryptedLocalDatabase(storage) : InMemoryLocalDatabase();
  runApp(FeedMateApp(
    apiBaseUrl: _defaultApiBaseUrl(),
    downloadsBaseUrl: _defaultDownloadsBaseUrl(),
    storageOverride: storage,
    localDbOverride: localDb,
  ));
}

class FeedMateApp extends StatelessWidget {
  final String apiBaseUrl;
  final String downloadsBaseUrl;

  /// Overridable for tests (e.g. integration_test needs to pre-seed a known
  /// device UUID that matches a fixture already registered in the backend,
  /// since a real device would otherwise generate a fresh random UUID that
  /// the backend has never seen). Production always uses the default, which
  /// wraps real platform secure storage.
  final SecureStorage? storageOverride;

  /// Overridable for tests, which can't open a real SQLCipher database (the
  /// native plugin channel isn't available under `flutter test`) — pass a
  /// LocalDatabase built on sqflite_common_ffi instead. Production always
  /// gets one from main(), opened before runApp so it's ready before any
  /// screen needs it.
  final LocalDatabase? localDbOverride;

  const FeedMateApp({
    super.key,
    required this.apiBaseUrl,
    this.downloadsBaseUrl = '',
    this.storageOverride,
    this.localDbOverride,
  });

  @override
  Widget build(BuildContext context) {
    final storage = storageOverride ?? SecureStorage();
    final apiClient = ApiClient(baseUrl: apiBaseUrl, storage: storage);
    final localDb = localDbOverride;

    return MultiProvider(
      providers: [
        Provider<SecureStorage>.value(value: storage),
        Provider<ApiClient>.value(value: apiClient),
        ChangeNotifierProvider<AuthSession>(
          create: (_) => AuthSession(apiClient: apiClient, storage: storage),
        ),
        ChangeNotifierProvider<CartModel>(create: (_) => CartModel()),
        ChangeNotifierProvider<PlatformApiClient>(create: (_) => PlatformApiClient(baseUrl: apiBaseUrl)),
        ChangeNotifierProvider<BrandingProvider>(
          create: (_) => BrandingProvider(client: apiClient, storage: storage)..refresh(),
        ),
        Provider<AppUpdateService>(create: (_) => AppUpdateService(downloadsBaseUrl: downloadsBaseUrl)),
        if (localDb != null) ...[
          Provider<LocalDatabase>.value(value: localDb),
          Provider<ProductRepository>(create: (_) => ProductRepository(client: apiClient, localDb: localDb)),
          Provider<SyncService>(create: (_) => SyncService(client: apiClient, localDb: localDb)),
        ],
      ],
      child: MaterialApp(
        navigatorKey: rootNavigatorKey,
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        onGenerateTitle: (context) => context.watch<BrandingProvider>().appName,
        theme: AppTheme.lightTheme,
        home: localDb != null ? const _ConnectivitySyncGate(child: _SessionGate()) : const _SessionGate(),
      ),
    );
  }
}

/// Automatically drains the offline outbox whenever connectivity is
/// (re)established, in addition to the manual sync button on the search
/// screen — so a queued sale doesn't just sit there until someone remembers
/// to tap sync.
class _ConnectivitySyncGate extends StatefulWidget {
  final Widget child;
  const _ConnectivitySyncGate({required this.child});

  @override
  State<_ConnectivitySyncGate> createState() => _ConnectivitySyncGateState();
}

class _ConnectivitySyncGateState extends State<_ConnectivitySyncGate> {
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  @override
  void initState() {
    super.initState();
    final syncService = context.read<SyncService>();
    _subscription = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) {
        syncService.syncPendingInvoices();
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Shows a loading indicator while restoring any persisted session, then
/// routes to the login screen or straight into the app.
class _SessionGate extends StatefulWidget {
  const _SessionGate();

  @override
  State<_SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<_SessionGate> {
  bool _updateChecked = false;

  @override
  void initState() {
    super.initState();
    context.read<AuthSession>().restoreSession();
    // Restored independently of the tenant session above — a platform
    // admin and a shop's tenant login are two entirely separate sessions
    // (see PlatformApiClient's doc comment), so both are checked here and
    // whichever one has a valid persisted session wins the initial route.
    context.read<PlatformApiClient>().restoreSession();

    PushDiagnostics.lastError.addListener(_showPushError);
    // Covers a failure that already happened before this listener was
    // attached (main()'s own Firebase.initializeApp() call, which runs
    // before _SessionGate exists at all).
    if (PushDiagnostics.lastError.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showPushError());
    }
  }

  void _showPushError() {
    final message = PushDiagnostics.lastError.value;
    if (message == null) return;
    PushDiagnostics.lastError.value = null; // show each failure once
    rootScaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.orange.shade800,
        duration: const Duration(seconds: 20),
        action: SnackBarAction(label: 'Dismiss', textColor: Colors.white, onPressed: () {}),
      ),
    );
  }

  @override
  void dispose() {
    PushDiagnostics.lastError.removeListener(_showPushError);
    super.dispose();
  }

  /// Fires once per app launch, the first time the shop login screen is
  /// actually shown — a silent, best-effort check (see
  /// AppUpdateService.checkForUpdate's doc comment on why it never surfaces
  /// an error). Deliberately not awaited by build(): a slow or failed check
  /// must never delay getting into the app.
  void _maybeCheckForUpdate() {
    if (_updateChecked) return;
    _updateChecked = true;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final service = context.read<AppUpdateService>();
    service.checkForUpdate().then((info) {
      if (info == null || !mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => UpdatePromptDialog(info: info, service: service),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AuthSession>();
    final platform = context.watch<PlatformApiClient>();

    if (session.status == AuthStatus.unknown || platform.status == PlatformAuthStatus.unknown) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // A restored platform-admin session takes priority: if an admin was on
    // the platform-admin area and refreshes, they land back there, not on
    // the tenant login screen, even if a tenant session also happens to be
    // persisted on the same browser/device.
    if (platform.status == PlatformAuthStatus.loggedIn) {
      return const PlatformShell();
    }
    switch (session.status) {
      case AuthStatus.unknown:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case AuthStatus.loggedOut:
        return const LoginScreen();
      case AuthStatus.loggedIn:
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybeCheckForUpdate());
        return const AppShell();
    }
  }
}
