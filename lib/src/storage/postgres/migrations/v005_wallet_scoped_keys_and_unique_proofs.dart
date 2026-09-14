/// Migration v005: key transactions and UTXOs per wallet, one merkle proof
/// per transaction.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Read-model keying defects found in the September 2026 audit:
///
/// * S-05: `bitcoin_transactions.txid` and `bitcoin_utxos.utxo_key` were
///   globally `UNIQUE`. When wallet A pays wallet B in the same store, B's
///   `storeTransaction` hit A's row (`ON CONFLICT (txid)`) and never got a
///   row of its own; B's UTXO at an outpoint A also held updated A's row.
///   Transactions become unique per `(wallet_id, txid)`; UTXOs keep the
///   `uk_utxo (wallet_id, txid, vout)` constraint v001 already created.
/// * S-13: `merkle_proofs` had no unique key, so `ON CONFLICT DO NOTHING`
///   never conflicted and every re-store (for example after a reorg) added
///   a row; lookups returned an arbitrary one. The newest row per txid is
///   kept and `txid` becomes unique.
/// * S-17: `transaction_addresses` rows were duplicated on projection
///   replay. Identical rows are collapsed here; the storage now replaces a
///   transaction's rows inside one transaction.
class V005WalletScopedKeysAndUniqueProofs extends Migration {
  @override
  int get version => 5;

  @override
  String get name => 'wallet_scoped_keys_and_unique_proofs';

  @override
  Future<void> up(Session conn) async {
    // --- S-05: transactions unique per wallet --------------------------
    await conn.execute('''
      ALTER TABLE bitcoin_transactions
      DROP CONSTRAINT IF EXISTS bitcoin_transactions_txid_key
    ''');
    await conn.execute('''
      ALTER TABLE bitcoin_transactions
      ADD CONSTRAINT uk_transaction_wallet_txid UNIQUE (wallet_id, txid)
    ''');
    // Wallet-independent lookups (getTransaction without a wallet id).
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_transactions_txid
      ON bitcoin_transactions(txid)
    ''');

    // --- S-05: UTXOs unique per wallet (uk_utxo remains) ----------------
    await conn.execute('''
      ALTER TABLE bitcoin_utxos
      DROP CONSTRAINT IF EXISTS bitcoin_utxos_utxo_key_key
    ''');

    // --- S-13: one proof per txid, newest wins --------------------------
    await conn.execute('''
      DELETE FROM merkle_proofs older
      USING merkle_proofs newer
      WHERE older.txid = newer.txid AND older.id < newer.id
    ''');
    await conn.execute('DROP INDEX IF EXISTS idx_merkle_proofs_txid');
    await conn.execute('''
      ALTER TABLE merkle_proofs
      ADD CONSTRAINT uk_merkle_proofs_txid UNIQUE (txid)
    ''');

    // --- S-17: collapse replayed junction rows --------------------------
    await conn.execute('''
      DELETE FROM transaction_addresses dup
      USING transaction_addresses keep
      WHERE dup.wallet_id = keep.wallet_id
        AND dup.txid = keep.txid
        AND dup.address = keep.address
        AND dup.direction = keep.direction
        AND dup.vout IS NOT DISTINCT FROM keep.vout
        AND dup.vin IS NOT DISTINCT FROM keep.vin
        AND dup.id > keep.id
    ''');
  }

  @override
  Future<void> down(Session conn) async {
    // Restoring the global unique keys requires one row per txid / outpoint:
    // rows of a second wallet for the same txid or outpoint are deleted
    // (the first-stored row is kept). This is the pre-v005 data model.
    await conn.execute('''
      DELETE FROM bitcoin_transactions later
      USING bitcoin_transactions first
      WHERE later.txid = first.txid AND later.id > first.id
    ''');
    await conn.execute('DROP INDEX IF EXISTS idx_transactions_txid');
    await conn.execute('''
      ALTER TABLE bitcoin_transactions
      DROP CONSTRAINT IF EXISTS uk_transaction_wallet_txid
    ''');
    await conn.execute('''
      ALTER TABLE bitcoin_transactions
      ADD CONSTRAINT bitcoin_transactions_txid_key UNIQUE (txid)
    ''');

    await conn.execute('''
      DELETE FROM bitcoin_utxos later
      USING bitcoin_utxos first
      WHERE later.utxo_key = first.utxo_key AND later.id > first.id
    ''');
    await conn.execute('''
      ALTER TABLE bitcoin_utxos
      ADD CONSTRAINT bitcoin_utxos_utxo_key_key UNIQUE (utxo_key)
    ''');

    await conn.execute('''
      ALTER TABLE merkle_proofs
      DROP CONSTRAINT IF EXISTS uk_merkle_proofs_txid
    ''');
    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_merkle_proofs_txid
      ON merkle_proofs(txid)
    ''');
    // The junction de-duplication is not reversed: duplicate rows carried
    // no information.
  }
}
