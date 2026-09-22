import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/auth_session.dart';
import 'core/branding_provider.dart';
import 'core/in_memory_local_db.dart';
import 'core/local_db.dart';
import 'core/local_db_sqlcipher.dart';
import 'core/secure_storage.dart';
import 'core/sync_service.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/login_screen.dart';
import 'features/platform/platform_api_client.dart';
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

/// Lets any part of the app show a SnackBar without needing a screen-local
/// BuildContext — used by the global error handlers below, which by
/// definition may fire from code that isn't inside any particular screen's
/// widget tree.
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

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

  final storage = SecureStorage();
  final localDb = _supportsEncryptedLocalDb ? await openEncryptedLocalDatabase(storage) : InMemoryLocalDatabase();
  runApp(FeedMateApp(apiBaseUrl: _defaultApiBaseUrl(), storageOverride: storage, localDbOverride: localDb));
}

class FeedMateApp extends StatelessWidget {
  final String apiBaseUrl;

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

  const FeedMateApp({super.key, required this.apiBaseUrl, this.storageOverride, this.localDbOverride});

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
        if (localDb != null) ...[
          Provider<LocalDatabase>.value(value: localDb),
          Provider<ProductRepository>(create: (_) => ProductRepository(client: apiClient, localDb: localDb)),
          Provider<SyncService>(create: (_) => SyncService(client: apiClient, localDb: localDb)),
        ],
      ],
      child: MaterialApp(
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
  @override
  void initState() {
    super.initState();
    context.read<AuthSession>().restoreSession();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AuthSession>();
    switch (session.status) {
      case AuthStatus.unknown:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case AuthStatus.loggedOut:
        return const LoginScreen();
      case AuthStatus.loggedIn:
        return const AppShell();
    }
  }
}
