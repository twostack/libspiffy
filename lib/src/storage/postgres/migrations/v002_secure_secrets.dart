/// Migration for secure secrets table.
///
/// Creates the `secure_secrets` table for storing encrypted sensitive data
/// such as xpubs for watch-only wallets.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Migration that creates the secure_secrets table for encrypted storage.
///
/// This table stores encrypted sensitive data with:
/// - Application-level AES-256-GCM encryption
/// - Per-secret HKDF-derived keys
/// - Unique nonce per encryption operation
/// - Key versioning for rotation support
class V002SecureSecrets extends Migration {
  @override
  int get version => 2;

  @override
  String get name => 'secure_secrets';

  @override
  Future<void> up(Session conn) async {
    // Create secure_secrets table for encrypted storage
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS secure_secrets (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        key_name VARCHAR(255) UNIQUE NOT NULL,
        encrypted_value BYTEA NOT NULL,
        nonce BYTEA NOT NULL,
        key_version INTEGER NOT NULL DEFAULT 1,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');

    // Index on key_name for fast lookups
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_secure_secrets_key_name
      ON secure_secrets(key_name)
    ''');

    // Index on key_version for rotation queries
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_secure_secrets_key_version
      ON secure_secrets(key_version)
    ''');
  }

  @override
  Future<void> down(Session conn) async {
    await conn.execute('DROP TABLE IF EXISTS secure_secrets CASCADE');
  }
}