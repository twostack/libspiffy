/// Initial PostgreSQL schema for libspiffy.
///
/// Creates all tables required for:
/// - Event sourcing (event envelopes, snapshots, saga state)
/// - Read models (wallets, UTXOs, transactions, addresses)
/// - SPV support (block headers, merkle proofs)
/// - Payment features (invoices, payment channels)
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Initial schema migration creating all libspiffy tables.
class V001InitialSchema extends Migration {
  @override
  int get version => 1;

  @override
  String get name => 'initial_schema';

  @override
  Future<void> up(Session conn) async {
    // ========================================
    // Event Store Tables
    // ========================================

    // Event envelopes - core event storage
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS event_envelopes (
        id BIGSERIAL PRIMARY KEY,
        persistence_id VARCHAR(255) NOT NULL,
        sequence_number INTEGER NOT NULL,
        event_data BYTEA NOT NULL,
        event_type VARCHAR(255) NOT NULL,
        timestamp TIMESTAMPTZ NOT NULL,
        metadata_data BYTEA,
        event_id VARCHAR(255) NOT NULL UNIQUE,
        schema_version INTEGER NOT NULL DEFAULT 1,
        created_at TIMESTAMPTZ DEFAULT NOW(),

        CONSTRAINT uk_persistence_sequence UNIQUE (persistence_id, sequence_number)
      )
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_event_envelopes_persistence_id
      ON event_envelopes(persistence_id)
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_event_envelopes_event_type
      ON event_envelopes(event_type)
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_event_envelopes_timestamp
      ON event_envelopes(timestamp)
    ''');

    // Snapshot envelopes - aggregate state snapshots
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS snapshot_envelopes (
        id BIGSERIAL PRIMARY KEY,
        persistence_id VARCHAR(255) NOT NULL UNIQUE,
        sequence_number INTEGER NOT NULL,
        snapshot_data BYTEA NOT NULL,
        timestamp TIMESTAMPTZ NOT NULL,
        state_type VARCHAR(255) NOT NULL,
        schema_version INTEGER NOT NULL DEFAULT 1,
        size_bytes INTEGER NOT NULL,
        metadata_data BYTEA,
        created_at TIMESTAMPTZ DEFAULT NOW()
      )
    ''');

    // Saga state envelopes - long-running process state
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS saga_state_envelopes (
        id BIGSERIAL PRIMARY KEY,
        persistence_id VARCHAR(255) NOT NULL UNIQUE,
        state_data BYTEA NOT NULL,
        state_type VARCHAR(255) NOT NULL,
        status VARCHAR(50) NOT NULL,
        last_updated_at TIMESTAMPTZ NOT NULL
      )
    ''');

    // Projection checkpoints - tracking projection progress
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS projection_checkpoints (
        id BIGSERIAL PRIMARY KEY,
        projection_id VARCHAR(255) NOT NULL UNIQUE,
        last_processed_sequence BIGINT NOT NULL DEFAULT 0,
        last_updated TIMESTAMPTZ NOT NULL,
        events_processed BIGINT NOT NULL DEFAULT 0
      )
    ''');

    // ========================================
    // Read Model Tables
    // ========================================

    // Wallet metadata
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS wallet_metadata (
        id BIGSERIAL PRIMARY KEY,
        wallet_id VARCHAR(255) NOT NULL UNIQUE,
        name VARCHAR(255) NOT NULL,
        wallet_type VARCHAR(50) NOT NULL,
        network VARCHAR(50) NOT NULL,
        root_address VARCHAR(255),
        derivation_index INTEGER NOT NULL DEFAULT 0,
        is_created BOOLEAN NOT NULL DEFAULT TRUE,
        created_at TIMESTAMPTZ NOT NULL,
        last_accessed_at TIMESTAMPTZ NOT NULL,
        metadata_json JSONB,
        aggregate_version INTEGER NOT NULL DEFAULT 0,
        confirmed_balance BIGINT NOT NULL DEFAULT 0,
        unconfirmed_balance BIGINT NOT NULL DEFAULT 0,
        addresses_json TEXT,
        public_keys_json TEXT
      )
    ''');

    // Bitcoin UTXOs - native BIGINT for satoshis
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS bitcoin_utxos (
        id BIGSERIAL PRIMARY KEY,
        wallet_id VARCHAR(255) NOT NULL,
        txid VARCHAR(64) NOT NULL,
        vout INTEGER NOT NULL,
        utxo_key VARCHAR(100) NOT NULL UNIQUE,
        satoshis BIGINT NOT NULL,
        script_pub_key TEXT NOT NULL,
        address VARCHAR(255),
        block_height INTEGER,
        confirmations INTEGER NOT NULL DEFAULT 0,
        status VARCHAR(50) NOT NULL,
        created_at TIMESTAMPTZ NOT NULL,
        spent_at TIMESTAMPTZ,
        spent_in_tx_id VARCHAR(64),
        script_type VARCHAR(50) NOT NULL DEFAULT 'p2pkh',
        is_spendable BOOLEAN NOT NULL DEFAULT TRUE,
        category VARCHAR(50) NOT NULL DEFAULT 'funding',

        CONSTRAINT uk_utxo UNIQUE (wallet_id, txid, vout)
      )
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_utxos_wallet_id
      ON bitcoin_utxos(wallet_id)
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_utxos_status
      ON bitcoin_utxos(status)
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_utxos_wallet_status
      ON bitcoin_utxos(wallet_id, status)
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_utxos_address
      ON bitcoin_utxos(address)
    ''');

    // Bitcoin transactions
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS bitcoin_transactions (
        id BIGSERIAL PRIMARY KEY,
        wallet_id VARCHAR(255) NOT NULL,
        txid VARCHAR(64) NOT NULL UNIQUE,
        raw_hex TEXT NOT NULL,
        block_height INTEGER,
        block_hash VARCHAR(64),
        confirmations INTEGER NOT NULL DEFAULT 0,
        total_input BIGINT NOT NULL,
        total_output BIGINT NOT NULL,
        fee BIGINT NOT NULL,
        net_amount BIGINT NOT NULL,
        is_incoming BOOLEAN NOT NULL,
        is_outgoing BOOLEAN NOT NULL,
        status VARCHAR(50) NOT NULL,
        created_at TIMESTAMPTZ NOT NULL,
        confirmed_at TIMESTAMPTZ,
        broadcast_at TIMESTAMPTZ,
        counterparty VARCHAR(255),
        notes TEXT,
        receiving_addresses JSONB,
        sending_addresses JSONB,
        primary_counterparty VARCHAR(255)
      )
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_transactions_wallet_id
      ON bitcoin_transactions(wallet_id)
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_transactions_status
      ON bitcoin_transactions(status)
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_transactions_created_at
      ON bitcoin_transactions(created_at DESC)
    ''');

    // Addresses
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS addresses (
        id BIGSERIAL PRIMARY KEY,
        wallet_id VARCHAR(255) NOT NULL,
        address VARCHAR(255) NOT NULL,
        script_type VARCHAR(50) NOT NULL,
        derivation_path VARCHAR(255),
        derivation_index INTEGER,
        is_change BOOLEAN NOT NULL DEFAULT FALSE,
        label VARCHAR(255),
        purpose VARCHAR(50) NOT NULL,
        first_used_at TIMESTAMPTZ,
        last_used_at TIMESTAMPTZ,
        usage_count INTEGER NOT NULL DEFAULT 0,
        balance BIGINT NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ NOT NULL,
        is_watched BOOLEAN NOT NULL DEFAULT TRUE,

        CONSTRAINT uk_wallet_address UNIQUE (wallet_id, address)
      )
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_addresses_wallet_id
      ON addresses(wallet_id)
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_addresses_address
      ON addresses(address)
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_addresses_derivation
      ON addresses(wallet_id, derivation_index, is_change)
    ''');

    // Transaction-Address junction table
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS transaction_addresses (
        id BIGSERIAL PRIMARY KEY,
        wallet_id VARCHAR(255) NOT NULL,
        txid VARCHAR(64) NOT NULL,
        address VARCHAR(255) NOT NULL,
        direction VARCHAR(10) NOT NULL,
        amount BIGINT NOT NULL,
        vout INTEGER,
        vin INTEGER,
        created_at TIMESTAMPTZ NOT NULL
      )
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_tx_addr_wallet_address
      ON transaction_addresses(wallet_id, address)
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_tx_addr_wallet_txid
      ON transaction_addresses(wallet_id, txid)
    ''');

    // ========================================
    // SPV Tables
    // ========================================

    // Block headers
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS block_headers (
        id BIGSERIAL PRIMARY KEY,
        height INTEGER NOT NULL,
        hash VARCHAR(64) NOT NULL UNIQUE,
        prev_block_hash VARCHAR(64) NOT NULL,
        merkle_root VARCHAR(64) NOT NULL,
        timestamp INTEGER NOT NULL,
        version INTEGER NOT NULL,
        bits INTEGER NOT NULL,
        nonce INTEGER NOT NULL,
        is_orphaned BOOLEAN NOT NULL DEFAULT FALSE,
        stored_at TIMESTAMPTZ NOT NULL
      )
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_headers_height
      ON block_headers(height)
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_headers_orphaned
      ON block_headers(is_orphaned)
    ''');

    // Merkle proofs
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS merkle_proofs (
        id BIGSERIAL PRIMARY KEY,
        txid VARCHAR(64) NOT NULL,
        block_hash VARCHAR(64) NOT NULL,
        block_height INTEGER NOT NULL,
        position INTEGER NOT NULL,
        merkle_proof_json TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL
      )
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_merkle_proofs_txid
      ON merkle_proofs(txid)
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_merkle_proofs_block_hash
      ON merkle_proofs(block_hash)
    ''');

    // ========================================
    // Payment Feature Tables
    // ========================================

    // Invoices
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS invoices (
        id BIGSERIAL PRIMARY KEY,
        invoice_id VARCHAR(255) NOT NULL UNIQUE,
        wallet_id VARCHAR(255) NOT NULL,
        addresses_json TEXT NOT NULL,
        amount BIGINT NOT NULL,
        description TEXT,
        status VARCHAR(50) NOT NULL,
        created_at TIMESTAMPTZ NOT NULL,
        expires_at TIMESTAMPTZ,
        paid_at TIMESTAMPTZ,
        payment_txid VARCHAR(64),
        amount_received BIGINT,
        metadata_json JSONB
      )
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_invoices_wallet_id
      ON invoices(wallet_id)
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_invoices_status
      ON invoices(status)
    ''');

    // Payment channels
    await conn.execute('''
      CREATE TABLE IF NOT EXISTS payment_channels (
        id BIGSERIAL PRIMARY KEY,
        channel_id VARCHAR(255) NOT NULL UNIQUE,
        wallet_id VARCHAR(255) NOT NULL,
        role VARCHAR(50) NOT NULL,
        client_peer_id VARCHAR(255) NOT NULL,
        server_peer_id VARCHAR(255) NOT NULL,
        funding_tx_id VARCHAR(64) NOT NULL,
        funding_tx_hex TEXT NOT NULL,
        funding_output_index INTEGER NOT NULL,
        funding_amount_sats BIGINT NOT NULL,
        client_pub_key_hex VARCHAR(66) NOT NULL,
        server_pub_key_hex VARCHAR(66) NOT NULL,
        client_address_b58 VARCHAR(255) NOT NULL,
        server_address_b58 VARCHAR(255) NOT NULL,
        lock_time_unix INTEGER NOT NULL,
        state VARCHAR(50) NOT NULL,
        client_balance_sats BIGINT NOT NULL,
        server_balance_sats BIGINT NOT NULL,
        latest_sequence_number INTEGER NOT NULL DEFAULT 0,
        latest_payment_tx_hex TEXT,
        refund_tx_hex TEXT,
        refund_client_sig_hex TEXT,
        refund_server_sig_hex TEXT,
        funding_ancestor_txids JSONB,
        context TEXT,
        created_at TIMESTAMPTZ NOT NULL,
        closed_at TIMESTAMPTZ,
        has_funding_merkle_proof BOOLEAN NOT NULL DEFAULT FALSE
      )
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_channels_wallet_id
      ON payment_channels(wallet_id)
    ''');

    await conn.execute('''
      CREATE INDEX IF NOT EXISTS idx_channels_state
      ON payment_channels(state)
    ''');
  }

  @override
  Future<void> down(Session conn) async {
    // Drop tables in reverse order of creation (respecting dependencies)
    await conn.execute('DROP TABLE IF EXISTS payment_channels CASCADE');
    await conn.execute('DROP TABLE IF EXISTS invoices CASCADE');
    await conn.execute('DROP TABLE IF EXISTS merkle_proofs CASCADE');
    await conn.execute('DROP TABLE IF EXISTS block_headers CASCADE');
    await conn.execute('DROP TABLE IF EXISTS transaction_addresses CASCADE');
    await conn.execute('DROP TABLE IF EXISTS addresses CASCADE');
    await conn.execute('DROP TABLE IF EXISTS bitcoin_transactions CASCADE');
    await conn.execute('DROP TABLE IF EXISTS bitcoin_utxos CASCADE');
    await conn.execute('DROP TABLE IF EXISTS wallet_metadata CASCADE');
    await conn.execute('DROP TABLE IF EXISTS projection_checkpoints CASCADE');
    await conn.execute('DROP TABLE IF EXISTS saga_state_envelopes CASCADE');
    await conn.execute('DROP TABLE IF EXISTS snapshot_envelopes CASCADE');
    await conn.execute('DROP TABLE IF EXISTS event_envelopes CASCADE');
  }
}
