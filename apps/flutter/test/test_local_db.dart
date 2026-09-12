import 'package:feedmate_app/core/local_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Builds a real, in-memory SqlLocalDatabase via sqflite_common_ffi for
/// PLAIN `test()` unit tests only (see test/local_db_test.dart) — it shares
/// the exact same Database interface that sqflite_sqlcipher uses in
/// production, so every query in local_db.dart runs unmodified against it.
///
/// `singleInstance: false` is required: sqflite caches opened databases by
/// path, and every call here uses the same `inMemoryDatabasePath` string —
/// without this, every test after the first would silently reuse the first
/// test's connection (and its data), since the cache never sees a "new"
/// path to open. This was a real bug caught by running the full suite: two
/// tests failed with leftover rows from an earlier test until this was
/// added.
///
/// Do NOT use this inside `testWidgets`: real sqflite I/O does not resolve
/// correctly inside flutter_test's fake-async pump zone (verified directly —
/// it hangs rather than failing fast). Widget tests use FakeLocalDatabase
/// (fake_local_db.dart) instead.
Future<SqlLocalDatabase> openTestLocalDatabase() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      singleInstance: false,
      version: SqlLocalDatabase.schemaVersion,
      onCreate: (db, version) => SqlLocalDatabase.createSchema(db),
    ),
  );
  return SqlLocalDatabase(db);
}
