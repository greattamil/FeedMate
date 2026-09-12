import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Minimal key/value contract SecureStorage depends on, so tests can inject
/// an in-memory fake instead of exercising the real platform secure-storage
/// plugin (whose native channel isn't available under `flutter test` and
/// would otherwise hang every test that touches tokens indefinitely).
abstract class KeyValueStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

/// Production backend: platform secure storage (Android Keystore-backed
/// EncryptedSharedPreferences, Windows DPAPI-backed credential storage).
class PlatformSecureKeyValueStore implements KeyValueStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Test-only backend: a plain in-memory map. Never used in production code —
/// only widget/unit tests should construct this directly.
class InMemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> _values = {};

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// Wraps [KeyValueStore] for tokens and the device identity.
///
/// PRD A2 requires the offline SQLCipher database key to come from the
/// platform secure keystore, never hard-coded or stored in plaintext
/// preferences. This class is also where that SQLCipher key will be held
/// once the offline database is wired up — see docs/IMPLEMENTATION_STATUS.md
/// for what's implemented so far.
class SecureStorage {
  final KeyValueStore _store;

  SecureStorage({KeyValueStore? store}) : _store = store ?? PlatformSecureKeyValueStore();

  static const _keyAccessToken = 'access_token';
  static const _keyRefreshToken = 'refresh_token';
  static const _keyTenantId = 'tenant_id';
  static const _keyDeviceUuid = 'device_uuid';

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    required String tenantId,
  }) async {
    await _store.write(_keyAccessToken, accessToken);
    await _store.write(_keyRefreshToken, refreshToken);
    await _store.write(_keyTenantId, tenantId);
  }

  Future<String?> getAccessToken() => _store.read(_keyAccessToken);
  Future<String?> getRefreshToken() => _store.read(_keyRefreshToken);
  Future<String?> getTenantId() => _store.read(_keyTenantId);

  Future<void> clearTokens() async {
    await _store.delete(_keyAccessToken);
    await _store.delete(_keyRefreshToken);
    await _store.delete(_keyTenantId);
  }

  /// Returns this installation's persistent device UUID, generating and
  /// storing one on first launch. This is the identity the backend uses to
  /// resolve which tenant the device belongs to at login (see
  /// services/api/internal/domain/identity), and must remain stable across
  /// app restarts — it is never regenerated once set.
  Future<String> getOrCreateDeviceUuid() async {
    final existing = await _store.read(_keyDeviceUuid);
    if (existing != null) return existing;
    final generated = const Uuid().v4();
    await _store.write(_keyDeviceUuid, generated);
    return generated;
  }

  /// Test-only: pre-seeds the device UUID so an integration test can log in
  /// as a device the backend already has a fixture registration for, instead
  /// of a fresh random UUID the backend has never seen. Never call this from
  /// production code.
  Future<void> seedDeviceUuidForTesting(String uuid) => _store.write(_keyDeviceUuid, uuid);
}
