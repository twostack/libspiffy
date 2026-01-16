/// PostgreSQL schema migration infrastructure for libspiffy.
///
/// Provides a simple migration system for evolving the database schema
/// over time while maintaining backwards compatibility.
library;

import 'package:postgres/postgres.dart';

import 'postgres_config.dart';
import 'migrations/v001_initial_schema.dart';

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
  final PostgresConfig _config;
  Pool? _pool;

  /// All registered migrations, in version order.
  final List<Migration> _migrations = [
    V001InitialSchema(),
  ];

  /// Creates a new migration manager with the given configuration.
  PostgresMigrations(this._config);

  /// Creates a migration manager using an existing connection pool.
  PostgresMigrations.withPool(this._pool) : _config = PostgresConfig(host: '', database: '');

  /// Runs all pending migrations.
  Future<void> migrate() async {
    final pool = _pool ?? await _config.createPool();
    final ownPool = _pool == null;

    try {
      // Create migrations table if it doesn't exist
      await pool.execute('''
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version INTEGER PRIMARY KEY,
          name VARCHAR(255) NOT NULL,
          applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
      ''');

      // Get current version
      final result = await pool.execute(
        'SELECT COALESCE(MAX(version), 0) as v FROM schema_migrations',
      );
      final currentVersion = result.first[0] as int;

      // Apply pending migrations
      for (final migration in _migrations) {
        if (migration.version > currentVersion) {
          print('Applying migration ${migration.version}: ${migration.name}');

          // Run migration in a transaction
          await pool.runTx((session) async {
            // Apply the migration
            await migration.up(session);

            // Record the migration
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

          print('Migration ${migration.version} applied successfully');
        }
      }
    } finally {
      if (ownPool) {
        await pool.close();
      }
    }
  }

  /// Rolls back the most recent migration.
  Future<bool> rollback() async {
    final pool = _pool ?? await _config.createPool();
    final ownPool = _pool == null;

    try {
      // Get current version
      final result = await pool.execute(
        'SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1',
      );

      if (result.isEmpty) {
        print('No migrations to roll back');
        return false;
      }

      final currentVersion = result.first[0] as int;

      // Find the migration to roll back
      final migration = _migrations.firstWhere(
        (m) => m.version == currentVersion,
        orElse: () => throw StateError(
          'Migration version $currentVersion not found in registered migrations',
        ),
      );

      print('Rolling back migration ${migration.version}: ${migration.name}');

      // Run rollback in a transaction
      await pool.runTx((session) async {
        // Roll back the migration
        await migration.down(session);

        // Remove the migration record
        await session.execute(
          Sql.named('DELETE FROM schema_migrations WHERE version = @version'),
          parameters: {'version': migration.version},
        );
      });

      print('Migration ${migration.version} rolled back successfully');
      return true;
    } finally {
      if (ownPool) {
        await pool.close();
      }
    }
  }

  /// Rolls back all migrations.
  Future<void> reset() async {
    while (await rollback()) {}
  }

  /// Gets the current schema version.
  Future<int> getCurrentVersion() async {
    final pool = _pool ?? await _config.createPool();
    final ownPool = _pool == null;

    try {
      final result = await pool.execute(
        'SELECT COALESCE(MAX(version), 0) as v FROM schema_migrations',
      );
      return result.first[0] as int;
    } catch (e) {
      return 0;
    } finally {
      if (ownPool) {
        await pool.close();
      }
    }
  }

  /// Gets a list of applied migrations.
  Future<List<({int version, String name, DateTime appliedAt})>>
      getAppliedMigrations() async {
    final pool = _pool ?? await _config.createPool();
    final ownPool = _pool == null;

    try {
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
    } catch (e) {
      return [];
    } finally {
      if (ownPool) {
        await pool.close();
      }
    }
  }

  /// Gets a list of pending migrations.
  Future<List<Migration>> getPendingMigrations() async {
    final currentVersion = await getCurrentVersion();
    return _migrations.where((m) => m.version > currentVersion).toList();
  }
}
