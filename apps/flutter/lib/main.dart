import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/auth_session.dart';
import 'core/secure_storage.dart';
import 'features/auth/login_screen.dart';
import 'features/pos/cart_model.dart';
import 'features/pos/product_search_screen.dart';

/// Resolves the API base URL for local development. An Android emulator
/// reaches the host machine's localhost via the special alias 10.0.2.2;
/// Windows/desktop/web reach it directly via 127.0.0.1. Override with
/// --dart-define=API_BASE_URL=... for a physical device or real deployment.
String _defaultApiBaseUrl() {
  const override = String.fromEnvironment('API_BASE_URL');
  if (override.isNotEmpty) return override;
  if (!kIsWeb && Platform.isAndroid) return 'http://10.0.2.2:8081';
  return 'http://127.0.0.1:8081';
}

void main() {
  runApp(FeedMateApp(apiBaseUrl: _defaultApiBaseUrl()));
}

class FeedMateApp extends StatelessWidget {
  final String apiBaseUrl;

  /// Overridable for tests (e.g. integration_test needs to pre-seed a known
  /// device UUID that matches a fixture already registered in the backend,
  /// since a real device would otherwise generate a fresh random UUID that
  /// the backend has never seen). Production always uses the default, which
  /// wraps real platform secure storage.
  final SecureStorage? storageOverride;

  const FeedMateApp({super.key, required this.apiBaseUrl, this.storageOverride});

  @override
  Widget build(BuildContext context) {
    final storage = storageOverride ?? SecureStorage();
    final apiClient = ApiClient(baseUrl: apiBaseUrl, storage: storage);

    return MultiProvider(
      providers: [
        Provider<SecureStorage>.value(value: storage),
        Provider<ApiClient>.value(value: apiClient),
        ChangeNotifierProvider<AuthSession>(
          create: (_) => AuthSession(apiClient: apiClient, storage: storage),
        ),
        ChangeNotifierProvider<CartModel>(create: (_) => CartModel()),
      ],
      child: MaterialApp(
        title: 'Andipatti Animal Feed System',
        theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
        home: const _SessionGate(),
      ),
    );
  }
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
        return const ProductSearchScreen();
    }
  }
}
