/// PostgreSQL schema migration infrastructure for libspiffy.
///
/// Provides a simple migration system for evolving the database schema
/// over time while maintaining backwards compatibility.
library;

import 'package:meta/meta.dart';
import 'package:postgres/postgres.dart';

import 'postgres_config.dart';
import 'migrations/v001_initial_schema.dart';
import 'migrations/v002_secure_secrets.dart';
import 'migrations/v003_header_ints_and_plugin_metadata.dart';
import 'migrations/v004_channel_columns_and_invoice_outputs.dart';
import 'migrations/v005_wallet_scoped_keys_and_unique_proofs.dart';
import 'migrations/v006_list_indexes_and_updated_at.dart';
import 'migrations/v007_nullable_channel_server_key.dart';
import 'migrations/v008_journal_tx_id.dart';
import 'migrations/v009_merkle_proof_status.dart';
import 'migrations/v010_ancestor_transactions.dart';
import 'migrations/v011_utxo_reservation_columns.dart';
import 'migrations/v012_merkle_proof_rejected_status.dart';
import 'migrations/v013_deferred_payments.dart';

/// Base class for database migrations.
///
/// Each migration should extend this class and implement the [up] and [down]
/// methods to apply and rollback schema changes.
abstract class Migration {
  /// The version number of this migration.
  int get version;

  /// A descriptive name for this migration.
  String get name;

  /// Applies the migration.
  Future<void> up(Session conn);

  /// Rolls back the migration.
  Future<void> down(Session conn);
}

/// Manages database migrations for PostgreSQL.
class PostgresMigrations {
  final PostgresConfig? _config;
  final Pool? _pool;

  /// All registered migrations, in version order.
  final List<Migration> _migrations = [
    V001InitialSchema(),
    V002SecureSecrets(),
    V003HeaderIntsAndPluginMetadata(),
    V004ChannelColumnsAndInvoiceOutputs(),
    V005WalletScopedKeysAndUniqueProofs(),
    V006ListIndexesAndUpdatedAt(),
    V007NullableChannelServerKey(),
    V008JournalTxId(),
    V009MerkleProofStatus(),
    V010AncestorTransactions(),
    V011UtxoReservationColumns(),
    V012MerkleProofRejectedStatus(),
    V013DeferredPayments(),
  ];

  /// Test hook awaited by [migrate] right after it reads the current schema
  /// version, before any migration is applied. Lets a test hold one instance
  /// at the point where a concurrent instance used to read the same version.
  /// Never set in production.
  @visibleForTesting
  Future<void> Function(int currentVersion)? afterVersionRead;

  /// Session advisory lock key serialising schema changes across instances
  /// ('libspify'). Single-key form, so it never collides with the event
  /// store's two-key append locks.
  static const int _migrationLockKey = 0x6c69627370696679;

  /// Creates a new migration manager with the given configuration.
  ///
  /// Each operation opens its own pool from [config] and closes it afterwards.
  PostgresMigrations(PostgresConfig config)
      : _config = config,
        _pool = null;

  /// Creates a migration manager using an existing connection pool.
  ///
  /// The pool stays owned by the caller and is never closed here.
  PostgresMigrations.withPool(Pool pool)
      : _pool = pool,
        _config = null;

  /// Runs [fn] with the caller's pool, or with a pool of its own that is
  /// closed afterwards.
  Future<T> _withPool<T>(Future<T> Function(Pool pool) fn) async {
    final pool = _pool ?? await _config!.createPool();
    try {
      return await fn(pool);
    } finally {
      if (_pool == null) await pool.close();
    }
  }

  /// Runs [fn] on one connection holding the migration advisory lock.
  ///
  /// Two instances starting together would otherwise both read the same
  /// version and both apply the same migrations; the second then fails on
  /// `schema_migrations`' primary key (or on a concurrent CREATE TABLE) and
  /// aborts its startup. Under the lock the second waits, then reads the
  /// version the first committed and has nothing left to do.
  Future<T> _withMigrationLock<T>(
    Future<T> Function(Connection conn) fn,
  ) {
    return _withPool((pool) => pool.withConnection((conn) async {
          await conn.execute('SELECT pg_advisory_lock($_migrationLockKey)');
          try {
            return await fn(conn);
          } finally {
            try {
              await conn.execute(
                  'SELECT pg_advisory_unlock($_migrationLockKey)');
            } catch (_) {
              // The session is unusable; closing it releases the lock.
              await conn.close(force: true);
            }
          }
        }));
  }

  /// Whether `schema_migrations` exists (a fresh database has none).
  static Future<bool> _hasMigrationsTable(Session session) async {
    final result = await session.execute(
      "SELECT to_regclass('schema_migrations') IS NOT NULL",
    );
    return result.first[0] as bool;
  }

  /// Runs all pending migrations.
  ///
  /// Safe to call from several instances at once: they are serialised on a
  /// database advisory lock.
  Future<void> migrate() {
    return _withMigrationLock((conn) async {
      await conn.execute('''
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version INTEGER PRIMARY KEY,
          name VARCHAR(255) NOT NULL,
          applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
      ''');

      final result = await conn.execute(
        'SELECT COALESCE(MAX(version), 0) as v FROM schema_migrations',
      );
      final currentVersion = result.first[0] as int;
      await afterVersionRead?.call(currentVersion);

      for (final migration in _migrations) {
        if (migration.version <= currentVersion) continue;
        // Each migration and its record commit together.
        await conn.runTx((session) async {
          await migration.up(session);
          await session.execute(
            Sql.named('''
              INSERT INTO schema_migrations (version, name)
              VALUES (@version, @name)
            '''),
            parameters: {
              'version': migration.version,
              'name': migration.name,
            },
          );
        });
      }
    });
  }

  /// Rolls back the most recent migration.
  ///
  /// Returns false when there is nothing to roll back, including on a
  /// database that has never been migrated (no `schema_migrations` table).
  Future<bool> rollback() {
    return _withMigrationLock((conn) async {
      if (!await _hasMigrationsTable(conn)) return false;

      final result = await conn.execute(
        'SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1',
      );
      if (result.isEmpty) return false;

      final currentVersion = result.first[0] as int;
      final migration = _migrations.firstWhere(
        (m) => m.version == currentVersion,
        orElse: () => throw StateError(
          'Migration version $currentVersion not found in registered migrations',
        ),
      );

      await conn.runTx((session) async {
        await migration.down(session);
        await session.execute(
          Sql.named('DELETE FROM schema_migrations WHERE version = @version'),
          parameters: {'version': migration.version},
        );
      });
      return true;
    });
  }

  /// Rolls back all migrations.
  Future<void> reset() async {
    while (await rollback()) {}
  }

  /// Gets the current schema version (0 on a never-migrated database).
  ///
  /// Connection and query errors propagate; they are not reported as 0.
  Future<int> getCurrentVersion() {
    return _withPool((pool) async {
      if (!await _hasMigrationsTable(pool)) return 0;
      final result = await pool.execute(
        'SELECT COALESCE(MAX(version), 0) as v FROM schema_migrations',
      );
      return result.first[0] as int;
    });
  }

  /// Gets a list of applied migrations (empty on a never-migrated database).
  ///
  /// Connection and query errors propagate; they are not reported as empty.
  Future<List<({int version, String name, DateTime appliedAt})>>
      getAppliedMigrations() {
    return _withPool((pool) async {
      if (!await _hasMigrationsTable(pool)) return [];
      final result = await pool.execute(
        'SELECT version, name, applied_at FROM schema_migrations ORDER BY version',
      );
      return result.map((row) {
        return (
          version: row[0] as int,
          name: row[1] as String,
          appliedAt: row[2] as DateTime,
        );
      }).toList();
    });
  }

  /// Gets a list of pending migrations.
  Future<List<Migration>> getPendingMigrations() async {
    final currentVersion = await getCurrentVersion();
    return _migrations.where((m) => m.version > currentVersion).toList();
  }
}
