import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

import 'local_db.dart';
import 'secure_storage.dart';

/// Opens the on-device encrypted store (SQLCipher via sqflite_sqlcipher —
/// see docs/OFFLINE_FIRST_SYNC spec: "Flutter uses SQLCipher for encrypted
/// offline storage"). The passphrase is a random key generated once and held
/// in the platform secure keystore (Android Keystore-backed), never
/// hard-coded and never derived from anything guessable (device UUID, user
/// password) — losing the keystore key means the offline cache is
/// unrecoverable by design, which is acceptable because it is a cache/outbox,
/// not the system of record (the server is).
Future<LocalDatabase> openEncryptedLocalDatabase(SecureStorage storage) async {
  final passphrase = await storage.getOrCreateLocalDbPassphrase();
  final dbDir = await cipher.getDatabasesPath();
  final path = p.join(dbDir, 'feedmate_offline.db');

  final db = await cipher.openDatabase(
    path,
    password: passphrase,
    version: SqlLocalDatabase.schemaVersion,
    onCreate: (db, version) => SqlLocalDatabase.createSchema(db),
  );
  return SqlLocalDatabase(db);
}
