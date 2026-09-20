/// PostgreSQL-based read model storage for libspiffy.
///
/// Implements the ReadModelStorage interface using PostgreSQL for
/// server-side deployments.
library;

import 'dart:convert';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:postgres/postgres.dart';
import 'package:spiffynode/spiffy_node.dart';

import '../../actors/invoice_messages.dart' show InvoiceStatus;
import '../../models/bitcoin_utxo.dart';
import '../../models/bitcoin_transaction.dart';
import '../../models/address_metadata.dart';
import '../../models/transaction_address_link.dart';
import '../../models/invoice_output_spec.dart';
import '../../models/invoice_read_model.dart';
import '../../models/payment_channel.dart';
import '../../services/watch_only_funds.dart' show splitBalanceUtxos;
import '../read_model_storage.dart';
import '../merkle_proof_rows.dart';
import '../transaction_row_rules.dart';
import '../wallet_row_rules.dart';
import 'postgres_config.dart';

/// PostgreSQL implementation of ReadModelStorage.
///
/// Provides read model storage for wallets, UTXOs, transactions, addresses,
/// invoices, payment channels, and SPV data (block headers, merkle proofs).
class PostgresWalletStorage implements ReadModelStorage {
  final _log = Logger('PostgresWalletStorage');
  final PostgresConfig _config;
  Pool? _pool;
  bool _isInitialized = false;

  /// Creates a new PostgresWalletStorage with the given configuration.
  ///
  /// Call [initialize] before using the storage.
  PostgresWalletStorage(this._config);

  /// Headers per multi-row INSERT in [storeBlockHeadersBulk]. Eight bind
  /// parameters per header: 1000 stays far below the protocol's 65535.
  @visibleForTesting
  int headerInsertChunkSize = 1000;

  /// Called with the row count of each INSERT [storeBlockHeadersBulk] sends.
  @visibleForTesting
  void Function(int rows)? onHeaderInsertStatement;

  /// Initializes the storage by creating the connection pool.
  Future<void> initialize() async {
    if (_isInitialized) return;
    _pool = await _config.createPool();
    _isInitialized = true;
  }

  /// Closes the storage and releases resources.
  Future<void> close() async {
    await _pool?.close();
    _pool = null;
    _isInitialized = false;
  }

  void _ensureInitialized() {
    if (!_isInitialized || _pool == null) {
      throw StateError(
        'PostgresWalletStorage not initialized. Call initialize() first.',
      );
    }
  }

  // ============================================================================
  // Wallet Metadata
  // ============================================================================

  @override
  Future<void> storeWallet(
    String walletId,
    String name, {
    String? rootAddress,
    String? networkType,
    Map<String, dynamic>? metadata,
  }) async {
    _ensureInitialized();
    // Typed values converted or rejected before anything is written, as on
    // every backend (bead libspiffy-k7na).
    metadata = WalletRowRules.normalizeMetadata(metadata);

    await _pool!.execute(
      Sql.named('''
        INSERT INTO wallet_metadata (
          wallet_id, name, wallet_type, network, root_address,
          derivation_index, is_created, created_at, last_accessed_at,
          metadata_json, aggregate_version, confirmed_balance, unconfirmed_balance
        ) VALUES (
          @walletId, @name, 'hd',
          COALESCE(@network::text, @defaultNetwork::text), @rootAddress,
          0, true, @now, @now, @metadataJson, 0, 0, 0
        )
        ON CONFLICT (wallet_id) DO UPDATE SET
          name = @name,
          root_address = COALESCE(@rootAddress, wallet_metadata.root_address),
          network = COALESCE(@network, wallet_metadata.network),
          -- A JSON document is merged, not replaced: a caller that resupplies
          -- only the keys it changed keeps the rest, as every backend does
          -- (read_model_storage.dart, bead libspiffy-1kaz). The scalars above
          -- are COALESCEd because they are scalars; this one is not.
          metadata_json = CASE
            WHEN @metadataJson::jsonb IS NULL THEN wallet_metadata.metadata_json
            ELSE COALESCE(wallet_metadata.metadata_json, '{}'::jsonb)
                 || @metadataJson::jsonb
          END,
          last_accessed_at = @now
      '''),
      parameters: {
        'walletId': walletId,
        'name': name,
        'rootAddress': rootAddress,
        // Canonicalised, and a null must reach the COALESCE above: otherwise
        // every balance update rewrote the network to the default.
        'network': WalletRowRules.canonicalNetwork(networkType),
        // What a row created without a network gets, the same on every
        // backend (bead libspiffy-sxk5).
        'defaultNetwork': WalletRowRules.defaultNetwork,
        'metadataJson': metadata != null ? jsonEncode(metadata) : null,
        'now': DateTime.now(),
      },
    );
  }

  @override
  Future<Map<String, dynamic>?> getWallet(String walletId) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT wallet_id, name, wallet_type, network, root_address,
               derivation_index, is_created, created_at, last_accessed_at,
               metadata_json, aggregate_version, confirmed_balance, unconfirmed_balance
        FROM wallet_metadata
        WHERE wallet_id = @walletId
      '''),
      parameters: {'walletId': walletId},
    );

    if (result.isEmpty) return null;

    final row = result.first;
    return {
      'walletId': row[0],
      'name': row[1],
      'walletType': row[2],
      'network': row[3],
      'rootAddress': row[4],
      'derivationIndex': row[5],
      'isCreated': row[6],
      'createdAt': (row[7] as DateTime).toIso8601String(),
      'lastAccessedAt': (row[8] as DateTime).toIso8601String(),
      'metadata': _parseJsonMap(row[9]) ?? <String, dynamic>{},
      'aggregateVersion': row[10],
      'confirmedBalance': (row[11] as num).toString(),
      'unconfirmedBalance': (row[12] as num).toString(),
    };
  }

  @override
  Future<List<String>> listWallets() async {
    _ensureInitialized();

    // Newest first, as every backend (audit S-19).
    final result = await _pool!.execute(
      'SELECT wallet_id FROM wallet_metadata ORDER BY created_at DESC, id DESC',
    );

    return result.map((row) => row[0] as String).toList();
  }

  @override
  Future<List<String>> getWalletAddresses(String walletId) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT address FROM addresses
        WHERE wallet_id = @walletId
        ORDER BY derivation_index
      '''),
      parameters: {'walletId': walletId},
    );

    return result.map((row) => row[0] as String).toList();
  }

  // ============================================================================
  // Address Management
  // ============================================================================

  @override
  Future<bool> isWalletAddress(String walletId, String address) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT 1 FROM addresses
        WHERE wallet_id = @walletId AND address = @address
        LIMIT 1
      '''),
      parameters: {'walletId': walletId, 'address': address},
    );

    return result.isNotEmpty;
  }

  @override
  Future<AddressMetadata?> getAddressMetadata(
    String walletId,
    String address,
  ) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT address, script_type, derivation_path, derivation_index,
               is_change, label, purpose, first_used_at, last_used_at,
               usage_count, balance, is_watched, created_at
        FROM addresses
        WHERE wallet_id = @walletId AND address = @address
      '''),
      parameters: {'walletId': walletId, 'address': address},
    );

    if (result.isEmpty) return null;

    return _rowToAddressMetadata(result.first);
  }

  @override
  Future<Map<String, bool>> checkAddresses(
    String walletId,
    List<String> addresses,
  ) async {
    if (addresses.isEmpty) return {};

    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT address FROM addresses
        WHERE wallet_id = @walletId AND address = ANY(@addresses)
      '''),
      parameters: {
        'walletId': walletId,
        'addresses': addresses,
      },
    );

    final found = result.map((row) => row[0] as String).toSet();
    return {for (final addr in addresses) addr: found.contains(addr)};
  }

  @override
  Future<List<AddressMetadata>> getAddressesWithMetadata(
    String walletId, {
    bool? includeUnused,
    bool? isChange,
    int? limit,
    int? offset,
  }) async {
    _ensureInitialized();

    var sql = '''
      SELECT address, script_type, derivation_path, derivation_index,
             is_change, label, purpose, first_used_at, last_used_at,
             usage_count, balance, is_watched, created_at
      FROM addresses
      WHERE wallet_id = @walletId
    ''';

    final params = <String, dynamic>{'walletId': walletId};

    if (includeUnused == false) {
      sql += ' AND usage_count > 0';
    }
    if (isChange != null) {
      sql += ' AND is_change = @isChange';
      params['isChange'] = isChange;
    }

    // Newest first by the stored createdAt, as every backend (audit S-19).
    sql += ' ORDER BY created_at DESC, id';

    if (limit != null) {
      sql += ' LIMIT @limit';
      params['limit'] = limit;
    }
    if (offset != null) {
      sql += ' OFFSET @offset';
      params['offset'] = offset;
    }

    final result = await _pool!.execute(Sql.named(sql), parameters: params);
    return result.map(_rowToAddressMetadata).toList();
  }

  @override
  Future<List<AddressMetadata>> getAddressRange(
    String walletId, {
    required int startIndex,
    required int count,
    bool isChange = false,
  }) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT address, script_type, derivation_path, derivation_index,
               is_change, label, purpose, first_used_at, last_used_at,
               usage_count, balance, is_watched, created_at
        FROM addresses
        WHERE wallet_id = @walletId
          AND is_change = @isChange
          AND derivation_index >= @startIndex
          AND derivation_index < @endIndex
        ORDER BY derivation_index
      '''),
      parameters: {
        'walletId': walletId,
        'isChange': isChange,
        'startIndex': startIndex,
        'endIndex': startIndex + count,
      },
    );

    return result.map(_rowToAddressMetadata).toList();
  }

  @override
  Future<List<AddressMetadata>> getAddressesByPurpose(String walletId, String purpose) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT address, script_type, derivation_path, derivation_index,
               is_change, label, purpose, first_used_at, last_used_at,
               usage_count, balance, is_watched, created_at
        FROM addresses
        WHERE wallet_id = @walletId
          AND purpose = @purpose
      '''),
      parameters: {'walletId': walletId, 'purpose': purpose},
    );

    return result.map(_rowToAddressMetadata).toList();
  }

  @override
  Future<void> upsertAddress(String walletId, AddressMetadata metadata) async {
    _ensureInitialized();

    await _pool!.execute(
      Sql.named('''
        INSERT INTO addresses (
          wallet_id, address, script_type, derivation_path, derivation_index,
          is_change, label, purpose, first_used_at, last_used_at,
          usage_count, balance, created_at, is_watched
        ) VALUES (
          @walletId, @address, @scriptType, @derivationPath, @derivationIndex,
          @isChange, @label, @purpose, @firstUsedAt, @lastUsedAt,
          @usageCount, @balance, @createdAt, @isWatched
        )
        ON CONFLICT (wallet_id, address) DO UPDATE SET
          script_type = COALESCE(@scriptType, addresses.script_type),
          derivation_path = COALESCE(@derivationPath, addresses.derivation_path),
          derivation_index = COALESCE(@derivationIndex, addresses.derivation_index),
          is_change = @isChange,
          label = @label,
          purpose = @purpose,
          first_used_at = COALESCE(addresses.first_used_at, @firstUsedAt),
          last_used_at = @lastUsedAt,
          usage_count = @usageCount,
          balance = @balance,
          is_watched = @isWatched
      '''),
      parameters: {
        'walletId': walletId,
        'address': metadata.address,
        'scriptType': metadata.scriptType,
        'derivationPath': metadata.derivationPath,
        'derivationIndex': metadata.derivationIndex,
        'isChange': metadata.isChange,
        'label': metadata.label,
        'purpose': metadata.purpose,
        'firstUsedAt': metadata.firstUsedAt,
        'lastUsedAt': metadata.lastUsedAt,
        'usageCount': metadata.usageCount,
        'balance': metadata.balance.toInt(),
        // The address's own creation time (it used to be the store time),
        // so the newest-first order matches the other backends.
        'createdAt': metadata.createdAt,
        'isWatched': metadata.isWatched,
      },
    );
  }

  @override
  Future<int> getAddressCount(String walletId) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('SELECT COUNT(*) FROM addresses WHERE wallet_id = @walletId'),
      parameters: {'walletId': walletId},
    );

    return result.first[0] as int;
  }

  @override
  Future<void> updateAddressUsage(
    String walletId,
    String address, {
    DateTime? usedAt,
    BigInt? balanceDelta,
  }) async {
    _ensureInitialized();

    // Only a use (usedAt) counts towards usage_count, as on Isar: the
    // projection's spend path passes a balance delta alone and used to
    // bump the count on every spend.
    final sets = <String>[];
    final params = <String, dynamic>{
      'walletId': walletId,
      'address': address,
    };

    if (usedAt != null) {
      sets.add('usage_count = usage_count + 1');
      sets.add('last_used_at = @usedAt');
      sets.add('first_used_at = COALESCE(first_used_at, @usedAt)');
      params['usedAt'] = usedAt;
    }

    if (balanceDelta != null) {
      sets.add('balance = balance + @balanceDelta');
      params['balanceDelta'] = balanceDelta.toInt();
    }

    if (sets.isEmpty) return;

    final sql = 'UPDATE addresses SET ${sets.join(', ')} '
        'WHERE wallet_id = @walletId AND address = @address';

    await _pool!.execute(Sql.named(sql), parameters: params);
  }

  AddressMetadata _rowToAddressMetadata(ResultRow row) {
    return AddressMetadata(
      address: row[0] as String,
      scriptType: row[1] as String,
      derivationPath: row[2] as String?,
      derivationIndex: row[3] as int?,
      isChange: row[4] as bool,
      label: row[5] as String?,
      purpose: row[6] as String, // purpose is a String, not an enum
      firstUsedAt: row[7] as DateTime?,
      lastUsedAt: row[8] as DateTime?,
      usageCount: row[9] as int,
      balance: BigInt.from(row[10] as num),
      createdAt: row[12] as DateTime, // Need createdAt for constructor
      isWatched: row[11] as bool,
    );
  }

  // ============================================================================
  // Transaction-Address Junction
  // ============================================================================

  @override
  Future<void> storeTransactionAddresses(
    String walletId,
    String txid,
    List<TransactionAddressLink> links,
  ) async {
    _ensureInitialized();

    // Replace this transaction's rows atomically. The table has no unique
    // key, so the former `ON CONFLICT DO NOTHING` inserted a second set on
    // every projection replay (audit S-17).
    final now = DateTime.now();
    await _pool!.runTx((session) async {
      await session.execute(
        Sql.named('''
          DELETE FROM transaction_addresses
          WHERE wallet_id = @walletId AND txid = @txid
        '''),
        parameters: {'walletId': walletId, 'txid': txid},
      );
      for (final link in links) {
        await session.execute(
          Sql.named('''
            INSERT INTO transaction_addresses (
              wallet_id, txid, address, direction, amount, vout, vin, created_at
            ) VALUES (
              @walletId, @txid, @address, @direction, @amount, @vout, @vin, @now
            )
          '''),
          parameters: {
            'walletId': walletId,
            'txid': txid,
            'address': link.address,
            'direction': link.direction,
            'amount': link.amount.toInt(),
            'vout': link.vout,
            'vin': link.vin,
            'now': now,
          },
        );
      }
    });
  }

  @override
  Future<List<String>> getTransactionsByAddress(
    String walletId,
    String address, {
    String? direction,
    int? limit,
    int? offset,
  }) async {
    _ensureInitialized();

    var sql = '''
      SELECT txid FROM transaction_addresses
      WHERE wallet_id = @walletId AND address = @address
    ''';

    final params = <String, dynamic>{
      'walletId': walletId,
      'address': address,
    };

    if (direction != null) {
      sql += ' AND direction = @direction';
      params['direction'] = direction;
    }

    // Newest first, as every backend (audit S-19; it was txid order).
    sql += ' GROUP BY txid ORDER BY MAX(created_at) DESC, MAX(id) DESC';

    if (limit != null) {
      sql += ' LIMIT @limit';
      params['limit'] = limit;
    }
    if (offset != null) {
      sql += ' OFFSET @offset';
      params['offset'] = offset;
    }

    final result = await _pool!.execute(Sql.named(sql), parameters: params);
    return result.map((row) => row[0] as String).toList();
  }

  @override
  Future<TransactionAddresses> getTransactionAddresses(
    String walletId,
    String txid,
  ) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT address, direction, amount, vout, vin
        FROM transaction_addresses
        WHERE wallet_id = @walletId AND txid = @txid
      '''),
      parameters: {'walletId': walletId, 'txid': txid},
    );

    final inputs = <TransactionAddressLink>[];
    final outputs = <TransactionAddressLink>[];

    for (final row in result) {
      final direction = row[1] as String;
      final link = TransactionAddressLink(
        address: row[0] as String,
        direction: direction, // direction is a String ('input' or 'output')
        amount: BigInt.from(row[2] as num),
        vout: row[3] as int?,
        vin: row[4] as int?,
      );

      if (direction == 'input') {
        inputs.add(link);
      } else {
        outputs.add(link);
      }
    }

    return TransactionAddresses(inputs: inputs, outputs: outputs);
  }

  @override
  Future<int> getAddressTransactionCount(
    String walletId,
    String address,
  ) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT COUNT(DISTINCT txid) FROM transaction_addresses
        WHERE wallet_id = @walletId AND address = @address
      '''),
      parameters: {'walletId': walletId, 'address': address},
    );

    return result.first[0] as int;
  }

  // ============================================================================
  // UTXO Queries
  // ============================================================================

  @override
  Future<List<BitcoinUtxo>> getUTXOs(
    String walletId, {
    bool includeSpent = false,
  }) async {
    _ensureInitialized();

    var sql = '''
      SELECT $_utxoColumns
      FROM bitcoin_utxos
      WHERE wallet_id = @walletId
    ''';

    if (!includeSpent) {
      sql += " AND status != 'spent'";
    }

    sql += ' ORDER BY created_at DESC, id';

    final result = await _pool!.execute(
      Sql.named(sql),
      parameters: {'walletId': walletId},
    );

    return result.map(_rowToUtxo).toList();
  }

  @override
  Future<BitcoinUtxo?> getUTXO(String walletId, String txid, int vout) async {
    _ensureInitialized();

    // The uk_utxo (wallet_id, txid, vout) unique constraint v001 created:
    // an exact match on the whole key, whatever the wallet's spend history
    // (bead libspiffy-36jt).
    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_utxoColumns
        FROM bitcoin_utxos
        WHERE wallet_id = @walletId AND txid = @txid AND vout = @vout
      '''),
      parameters: {'walletId': walletId, 'txid': txid, 'vout': vout},
    );

    return result.isEmpty ? null : _rowToUtxo(result.first);
  }

  @override
  Future<List<BitcoinUtxo>> getUTXOsByTxid(String walletId, String txid,
      {bool includeSpent = false}) async {
    _ensureInitialized();

    // The (wallet_id, txid) prefix of the same constraint.
    var sql = '''
      SELECT $_utxoColumns
      FROM bitcoin_utxos
      WHERE wallet_id = @walletId AND txid = @txid
    ''';
    if (!includeSpent) {
      sql += " AND status != 'spent'";
    }
    sql += ' ORDER BY created_at DESC, id';

    final result = await _pool!.execute(
      Sql.named(sql),
      parameters: {'walletId': walletId, 'txid': txid},
    );

    return result.map(_rowToUtxo).toList();
  }

  @override
  Future<int> countSpentUTXOs(String walletId) async {
    _ensureInitialized();

    // idx_utxos_wallet_status: counted, never read (bead libspiffy-36jt).
    final result = await _pool!.execute(
      Sql.named('''
        SELECT COUNT(*) FROM bitcoin_utxos
        WHERE wallet_id = @walletId AND status = 'spent'
      '''),
      parameters: {'walletId': walletId},
    );

    return result.first[0] as int;
  }

  @override
  Future<List<BitcoinUtxo>> getAvailableUTXOs(String walletId) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_utxoColumns
        FROM bitcoin_utxos
        WHERE wallet_id = @walletId AND status = 'available'
        ORDER BY satoshis DESC
      '''),
      parameters: {'walletId': walletId},
    );

    return result.map(_rowToUtxo).toList();
  }

  /// Inserts or updates the ([walletId], txid, vout) row.
  ///
  /// `updated_at` is the UTXO's [BitcoinUtxo.updatedAt]; `is_available`
  /// follows the status (available only) and says nothing more than that —
  /// it was called `is_spendable` until migration v024 (bead
  /// libspiffy-p8qc), a name that promised `WalletBalances.isSpendable`, a
  /// rule over the whole wallet state that no per-row column can hold. The spend history is only ever
  /// added to (audit S-20, data retention): `spent_at` records the first
  /// store as spent and is never cleared, and `spent_in_tx_id` is never
  /// overwritten once set. A block height, plugin metadata or derivation
  /// index the update lacks keeps the stored value. The reservation columns
  /// follow the UTXO (a release clears them; bead libspiffy-viy).
  @override
  Future<void> upsertUTXO(String walletId, BitcoinUtxo utxo) async {
    _ensureInitialized();

    final spent = utxo.status == UTXOStatus.spent;
    await _pool!.execute(
      Sql.named('''
        INSERT INTO bitcoin_utxos (
          wallet_id, txid, vout, utxo_key, satoshis, script_pub_key, address,
          block_height, confirmations, status, created_at, updated_at, spent_at,
          spent_in_tx_id, script_type, is_available, category, plugin_metadata,
          derivation_index, reserved_by_tx_id, reservation_reason,
          reservation_expires_at, reservation_priority, status_before_reservation
        ) VALUES (
          @walletId, @txid, @vout, @utxoKey, @satoshis, @scriptPubKey, @address,
          @blockHeight, @confirmations, @status, @createdAt, @updatedAt, @spentAt,
          @spentInTxId, @scriptType, @isAvailable, @category,
          CAST(@pluginMetadata AS JSONB),
          @derivationIndex, @reservedByTxId, @reservationReason,
          @reservationExpiresAt, @reservationPriority, @statusBeforeReservation
        )
        ON CONFLICT (wallet_id, txid, vout) DO UPDATE SET
          satoshis = EXCLUDED.satoshis,
          script_pub_key = EXCLUDED.script_pub_key,
          address = EXCLUDED.address,
          -- A zero-confirmation update (reorg, audit 3b0) clears the height.
          block_height = CASE WHEN EXCLUDED.confirmations > 0
              THEN COALESCE(EXCLUDED.block_height, bitcoin_utxos.block_height)
              ELSE EXCLUDED.block_height END,
          confirmations = EXCLUDED.confirmations,
          status = EXCLUDED.status,
          updated_at = EXCLUDED.updated_at,
          spent_at = COALESCE(bitcoin_utxos.spent_at, EXCLUDED.spent_at),
          is_available = EXCLUDED.is_available,
          plugin_metadata = COALESCE(EXCLUDED.plugin_metadata, bitcoin_utxos.plugin_metadata),
          spent_in_tx_id = COALESCE(bitcoin_utxos.spent_in_tx_id, EXCLUDED.spent_in_tx_id),
          derivation_index = COALESCE(EXCLUDED.derivation_index, bitcoin_utxos.derivation_index),
          reserved_by_tx_id = EXCLUDED.reserved_by_tx_id,
          reservation_reason = EXCLUDED.reservation_reason,
          reservation_expires_at = EXCLUDED.reservation_expires_at,
          reservation_priority = EXCLUDED.reservation_priority,
          status_before_reservation = EXCLUDED.status_before_reservation
      '''),
      parameters: {
        'walletId': walletId,
        'txid': utxo.txid,
        'vout': utxo.vout,
        'utxoKey': '${utxo.txid}:${utxo.vout}',
        'satoshis': utxo.satoshis.toInt(),
        'scriptPubKey': utxo.scriptPubKey,
        'address': utxo.address,
        'blockHeight': utxo.blockHeight,
        'confirmations': utxo.confirmations ?? 0,
        'status': utxo.status.name,
        'createdAt': utxo.createdAt,
        'updatedAt': utxo.updatedAt,
        'spentAt': spent ? utxo.updatedAt : null,
        'scriptType': 'p2pkh',
        'isAvailable': utxo.status == UTXOStatus.available,
        'category': 'funding',
        'pluginMetadata': utxo.pluginMetadata == null
            ? null
            : jsonEncode(utxo.pluginMetadata),
        'spentInTxId': utxo.spentInTxId,
        'derivationIndex': utxo.derivationIndex,
        'reservedByTxId': utxo.reservedByTxId,
        'reservationReason': utxo.reservationReason,
        'reservationExpiresAt': utxo.reservationExpiresAt,
        'reservationPriority': utxo.reservationPriority,
        'statusBeforeReservation': utxo.statusBeforeReservation?.name,
      },
    );
  }

  @override
  Future<void> deleteUTXO(String walletId, String txid, int vout) async {
    _ensureInitialized();

    await _pool!.execute(
      Sql.named('''
        DELETE FROM bitcoin_utxos
        WHERE wallet_id = @walletId AND txid = @txid AND vout = @vout
      '''),
      parameters: {'walletId': walletId, 'txid': txid, 'vout': vout},
    );
  }

  @override
  Future<List<BitcoinUtxo>> getPaymentUTXOs(String walletId) async {
    _ensureInitialized();

    // Same rule as the Isar backend: a UTXO belongs to a plugin (and is not
    // spendable as plain funding) when its metadata names a pluginId.
    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_utxoColumns
        FROM bitcoin_utxos
        WHERE wallet_id = @walletId
          AND status = 'available'
          AND (plugin_metadata IS NULL OR plugin_metadata->>'pluginId' IS NULL)
        ORDER BY satoshis DESC
      '''),
      parameters: {'walletId': walletId},
    );

    return result.map(_rowToUtxo).toList();
  }

  @override
  Future<List<BitcoinUtxo>> getUTXOsByPlugin(
    String walletId,
    String pluginId, {
    Map<String, dynamic>? metadataFilter,
  }) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_utxoColumns
        FROM bitcoin_utxos
        WHERE wallet_id = @walletId
          AND status != 'spent'
          AND plugin_metadata->>'pluginId' = @pluginId
        ORDER BY created_at DESC, id
      '''),
      parameters: {'walletId': walletId, 'pluginId': pluginId},
    );

    return result.map(_rowToUtxo).where((utxo) {
      final meta = utxo.pluginMetadata;
      if (meta == null) return false;
      if (metadataFilter != null) {
        for (final entry in metadataFilter.entries) {
          if (meta[entry.key] != entry.value) return false;
        }
      }
      return true;
    }).toList();
  }

  /// [ReadModelStorage.getBalance]: [splitBalanceUtxos] over
  /// [getPaymentUTXOs] (plugin-managed UTXOs left out in SQL), as on every
  /// backend.
  @override
  Future<BigInt> getBalance(String walletId) async =>
      (await splitBalanceUtxos(this, walletId, await getPaymentUTXOs(walletId))).spendableSatoshis;

  @override
  Future<BigInt> getWatchOnlyBalance(String walletId) async =>
      (await splitBalanceUtxos(this, walletId, await getPaymentUTXOs(walletId))).watchOnlySatoshis;

  /// Columns [_rowToUtxo] reads, in its order.
  static const _utxoColumns = '''
        txid, vout, satoshis, script_pub_key, address, block_height,
        confirmations, status, created_at, spent_at, spent_in_tx_id,
        script_type, is_available, category, plugin_metadata, updated_at,
        derivation_index, reserved_by_tx_id, reservation_reason,
        reservation_expires_at, reservation_priority, status_before_reservation''';

  BitcoinUtxo _rowToUtxo(ResultRow row) {
    final now = DateTime.now();
    final createdAt = row[8] as DateTime? ?? now;
    return BitcoinUtxo(
      txid: row[0] as String,
      vout: row[1] as int,
      value: dartsv.Coin.ofSat(BigInt.from(row[2] as num)),
      scriptPubKey: row[3] as String,
      address: row[4] as String? ?? '', // address is required in BitcoinUtxo
      blockHeight: row[5] as int?,
      confirmations: row[6] as int,
      status: UTXOStatus.values.firstWhere(
        (e) => e.name == (row[7] as String),
        orElse: () => UTXOStatus.available,
      ),
      createdAt: createdAt,
      // Rows written before v006 have no updated_at.
      updatedAt: row[15] as DateTime? ?? createdAt,
      pluginMetadata: _parseJsonMap(row[14]),
      spentInTxId: row[10] as String?,
      // v011 columns (bead libspiffy-viy); null on rows written before.
      derivationIndex: row[16] as int?,
      reservedByTxId: row[17] as String?,
      reservationReason: row[18] as String?,
      reservationExpiresAt: row[19] as DateTime?,
      reservationPriority: row[20] as int?,
      statusBeforeReservation: UTXOStatus.values
          .where((s) => s.name == row[21])
          .firstOrNull,
    );
  }

  // ============================================================================
  // Transaction History
  // ============================================================================

  @override
  Future<List<BitcoinTransaction>> getTransactionHistory(
    String walletId, {
    int? limit,
    int? offset,
  }) async {
    _ensureInitialized();

    var sql = '''
      SELECT $_transactionColumns
      FROM bitcoin_transactions
      WHERE wallet_id = @walletId
      ORDER BY created_at DESC, id
    ''';

    final params = <String, dynamic>{'walletId': walletId};

    if (limit != null) {
      sql += ' LIMIT @limit';
      params['limit'] = limit;
    }
    if (offset != null) {
      sql += ' OFFSET @offset';
      params['offset'] = offset;
    }

    final result = await _pool!.execute(Sql.named(sql), parameters: params);
    return result.map(_rowToTransaction).toList();
  }

  @override
  Future<BitcoinTransaction?> getTransaction(String txid, {String? walletId}) async {
    _ensureInitialized();

    // Rows are keyed by (wallet_id, txid) since v005. Without a wallet id
    // the first-stored row is returned.
    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_transactionColumns
        FROM bitcoin_transactions
        WHERE txid = @txid
          ${walletId == null ? '' : 'AND wallet_id = @walletId'}
        ORDER BY id
        LIMIT 1
      '''),
      parameters: {
        'txid': txid,
        if (walletId != null) 'walletId': walletId,
      },
    );

    if (result.isEmpty) return null;
    return _rowToTransaction(result.first);
  }

  @override
  Future<Map<String, BitcoinTransaction>> getTransactionsBatch(List<String> txids) async {
    if (txids.isEmpty) return {};
    _ensureInitialized();

    // Build parameterized IN clause
    final params = <String, dynamic>{};
    final placeholders = <String>[];
    for (int i = 0; i < txids.length; i++) {
      params['txid$i'] = txids[i];
      placeholders.add('@txid$i');
    }

    final result = await _pool!.execute(
      // One row per txid: the first-stored, as getTransaction.
      Sql.named('''
        SELECT DISTINCT ON (txid) $_transactionColumns
        FROM bitcoin_transactions
        WHERE txid IN (${placeholders.join(', ')})
        ORDER BY txid, id
      '''),
      parameters: params,
    );

    final map = <String, BitcoinTransaction>{};
    for (final row in result) {
      final tx = _rowToTransaction(row);
      map[tx.txid] = tx;
    }
    return map;
  }

  @override
  Future<List<BitcoinTransaction>> getTransactionsByStatus(
    TransactionStatus status, {
    String? walletId,
  }) async {
    _ensureInitialized();

    var sql = '''
      SELECT $_transactionColumns
      FROM bitcoin_transactions
      WHERE status = @status
    ''';

    final params = <String, dynamic>{'status': status.name};

    if (walletId != null) {
      sql += ' AND wallet_id = @walletId';
      params['walletId'] = walletId;
    }

    sql += ' ORDER BY created_at DESC, id';

    final result = await _pool!.execute(Sql.named(sql), parameters: params);
    return result.map(_rowToTransaction).toList();
  }

  @override
  Future<List<BitcoinTransaction>> getTransactionsByStatusSince(
    TransactionStatus status,
    DateTime since, {
    int limit = 100,
  }) async {
    if (limit <= 0) return const [];
    _ensureInitialized();

    // idx_transactions_status_updated (v019): the rows of [status] updated
    // in the window, newest first, capped (bead libspiffy-5bju). Rows older
    // than the window are never read.
    final params = <String, dynamic>{'status': status.name, 'since': since.toUtc(), 'rowLimit': limit};
    final sql = '''
      SELECT $_transactionColumns
      FROM bitcoin_transactions
      WHERE status = @status AND updated_at >= @since
      ORDER BY updated_at DESC, id DESC
      LIMIT @rowLimit
    ''';
    onTransactionLookupQuery?.call(sql, params);
    final result = await _pool!.execute(Sql.named(sql), parameters: params);
    return result.map(_rowToTransaction).toList();
  }

  /// Set by tests: receives the SQL and parameters of each
  /// [getTransactionsByTxids], [getConfirmedTransactionsFromHeight] and
  /// [getTransactionsByStatusSince] query.
  @visibleForTesting
  void Function(String sql, Map<String, dynamic> parameters)? onTransactionLookupQuery;

  @override
  Future<List<BitcoinTransaction>> getTransactionsByTxids(List<String> txids) async {
    final wanted = txids.toSet().toList();
    if (wanted.isEmpty) return [];
    _ensureInitialized();

    // idx_transactions_txid: every wallet's row of each txid (ctkm).
    final params = <String, dynamic>{
      for (var i = 0; i < wanted.length; i++) 'txid$i': wanted[i],
    };
    final sql = '''
      SELECT $_transactionColumns
      FROM bitcoin_transactions
      WHERE txid IN (${[for (var i = 0; i < wanted.length; i++) '@txid$i'].join(', ')})
      ORDER BY created_at DESC, id
    ''';
    onTransactionLookupQuery?.call(sql, params);
    final result = await _pool!.execute(Sql.named(sql), parameters: params);
    return result.map(_rowToTransaction).toList();
  }

  @override
  Future<List<BitcoinTransaction>> getConfirmedTransactionsFromHeight(
    int minHeight, {
    bool includeWithoutHeight = false,
  }) async {
    _ensureInitialized();

    // idx_transactions_confirmed_height (v014, partial on status =
    // 'confirmed'): the literal status lets the planner match the index
    // predicate (ctkm).
    final params = <String, dynamic>{'minHeight': minHeight};
    final sql = '''
      SELECT $_transactionColumns
      FROM bitcoin_transactions
      WHERE status = 'confirmed'
        AND (block_height >= @minHeight${includeWithoutHeight ? ' OR block_height IS NULL' : ''})
      ORDER BY created_at DESC, id
    ''';
    onTransactionLookupQuery?.call(sql, params);
    final result = await _pool!.execute(Sql.named(sql), parameters: params);
    return result.map(_rowToTransaction).toList();
  }

  @override
  Future<void> storeTransaction(
    String walletId,
    BitcoinTransaction transaction,
  ) =>
      _storeTransaction(walletId, transaction, reverting: false);

  @override
  Future<void> storeRevertedTransaction(String walletId, BitcoinTransaction transaction) =>
      _storeTransaction(walletId, transaction, reverting: true);

  /// An update whose status [TransactionRowRules.setsStatus] refuses keeps
  /// the stored status, block height, block hash and confirmations (7dj),
  /// unless [reverting]. The opaque counterparty marker (v021, bead
  /// libspiffy-cq16) is set once, by the first record that carries one, and
  /// no update blanks it or replaces it
  /// ([TransactionRowRules.counterpartyMarkerAfter]).
  Future<void> _storeTransaction(
    String walletId,
    BitcoinTransaction transaction, {
    required bool reverting,
  }) async {
    _ensureInitialized();

    // Whether the update sets the status, on the stored row (every SET
    // expression reads the row as it was). The status names are enum
    // names, never user input.
    final setsStatus = reverting
        ? 'TRUE'
        : 'bitcoin_transactions.status IN (${[
            for (final s in TransactionRowRules.statusesSetBy(transaction.status)) "'${s.name}'"
          ].join(', ')})';
    final counterparty = TransactionRowRules.primaryCounterpartyOf(transaction);
    final intrinsics = TransactionRowRules.intrinsicsOf(transaction);

    await _pool!.execute(
      Sql.named('''
        INSERT INTO bitcoin_transactions (
          wallet_id, txid, raw_hex, block_height, block_hash, confirmations,
          total_input, total_output, fee, net_amount, is_incoming, is_outgoing,
          status, created_at, confirmed_at, broadcast_at, counterparty, notes,
          receiving_addresses, sending_addresses, primary_counterparty, updated_at,
          counterparty_marker, lock_time, tx_version
        ) VALUES (
          @walletId, @txid, @rawHex, @blockHeight, @blockHash, @confirmations,
          @totalInput, @totalOutput, @fee, @netAmount, @isIncoming, @isOutgoing,
          @status, @createdAt, @confirmedAt, @broadcastAt, @counterparty, @notes,
          @receivingAddresses, @sendingAddresses, @primaryCounterparty, @updatedAt,
          @counterpartyMarker, @lockTime, @txVersion
        )
        ON CONFLICT (wallet_id, txid) DO UPDATE SET
          -- An update without the raw transaction keeps the stored bytes: an
          -- SPV wallet cannot fetch them again.
          raw_hex = COALESCE(NULLIF(EXCLUDED.raw_hex, ''), bitcoin_transactions.raw_hex),
          updated_at = EXCLUDED.updated_at,
          -- A refused status keeps the stored status, height and
          -- confirmations (7dj). A confirmed update without a height keeps
          -- the stored one; a non-confirmed update clears it (reorg, 3b0).
          block_height = CASE WHEN NOT ($setsStatus) THEN bitcoin_transactions.block_height
              WHEN EXCLUDED.status = 'confirmed'
              THEN COALESCE(EXCLUDED.block_height, bitcoin_transactions.block_height)
              ELSE EXCLUDED.block_height END,
          block_hash = CASE WHEN NOT ($setsStatus) THEN bitcoin_transactions.block_hash
              WHEN EXCLUDED.status = 'confirmed'
              THEN COALESCE(EXCLUDED.block_hash, bitcoin_transactions.block_hash)
              ELSE EXCLUDED.block_hash END,
          confirmations = CASE WHEN $setsStatus THEN EXCLUDED.confirmations
              ELSE bitcoin_transactions.confirmations END,
          total_input = @totalInput,
          total_output = @totalOutput,
          fee = @fee,
          net_amount = @netAmount,
          is_incoming = @isIncoming,
          is_outgoing = @isOutgoing,
          status = CASE WHEN $setsStatus THEN EXCLUDED.status ELSE bitcoin_transactions.status END,
          -- TransactionRowRules.confirmedAtAfter (hccp): set when the update
          -- confirms a row that is not confirmed (new, pending, reverted),
          -- kept otherwise; a confirmed row without one gets it.
          confirmed_at = CASE
              WHEN ($setsStatus) AND EXCLUDED.status = 'confirmed'
                  AND bitcoin_transactions.status <> 'confirmed'
              THEN EXCLUDED.confirmed_at
              WHEN ($setsStatus) AND EXCLUDED.status = 'confirmed'
              THEN COALESCE(bitcoin_transactions.confirmed_at, EXCLUDED.confirmed_at)
              ELSE bitcoin_transactions.confirmed_at END,
          notes = @notes,
          receiving_addresses = @receivingAddresses,
          sending_addresses = @sendingAddresses,
          primary_counterparty = @primaryCounterparty,
          -- The opaque marker (cq16): set once, by the first record that
          -- carries one. A record without one keeps the stored marker; a
          -- record naming somebody else never replaces it. Nothing, a
          -- revert included, blanks it.
          counterparty_marker =
              COALESCE(bitcoin_transactions.counterparty_marker, NULLIF(EXCLUDED.counterparty_marker, '')),
          -- Consensus fields the txid commits to (zpu7): set once, by the
          -- first record that carries them. A later record naming none says
          -- nothing about them and never blanks them; one naming something
          -- else is describing a different transaction.
          lock_time = COALESCE(bitcoin_transactions.lock_time, EXCLUDED.lock_time),
          tx_version = COALESCE(bitcoin_transactions.tx_version, EXCLUDED.tx_version)
      '''),
      parameters: {
        'walletId': walletId,
        'txid': transaction.txid,
        'rawHex': transaction.rawHex,
        'blockHeight': transaction.blockHeight,
        'blockHash': null,
        'confirmations': transaction.confirmations ?? 0,
        'totalInput': transaction.inputValue.toInt(),
        'totalOutput': transaction.outputValue.toInt(),
        'fee': transaction.fee.toInt(),
        'netAmount': transaction.netAmount.toInt(),
        'isIncoming': transaction.netAmount > BigInt.zero,
        'isOutgoing': transaction.netAmount < BigInt.zero,
        'status': transaction.status.name,
        'createdAt': transaction.createdAt,
        'updatedAt': transaction.updatedAt,
        // The confirming record's own time, as on Isar: a replay stores the
        // same value.
        'confirmedAt': transaction.status == TransactionStatus.confirmed
            ? transaction.updatedAt
            : null,
        'broadcastAt': null,
        // Set once, on insert, as the Isar backend does.
        'counterparty': counterparty,
        'notes': transaction.memo,
        'receivingAddresses': jsonEncode(transaction.receivingAddresses),
        'sendingAddresses': jsonEncode(transaction.sendingAddresses),
        // The rule every backend shares (7dj): the first receiving address
        // was stored for incoming transactions too (our own address).
        'primaryCounterparty': counterparty,
        // Not an address (cq16): the app's opaque identity marker, stored
        // verbatim and never interpreted.
        'counterpartyMarker': transaction.counterpartyMarker,
        // The record's own nLockTime and version, or the ones its raw hex
        // carries when it has none (zpu7). Null only when neither exists:
        // no reading is invented for a row with no evidence.
        'lockTime': intrinsics.lockTime,
        'txVersion': intrinsics.version,
      },
    );
  }

  /// Columns [_rowToTransaction] reads, in its order.
  static const _transactionColumns = '''
        txid, raw_hex, block_height, block_hash, confirmations,
        total_input, total_output, fee, net_amount, is_incoming,
        is_outgoing, status, created_at, confirmed_at, broadcast_at,
        counterparty, notes, receiving_addresses, sending_addresses,
        wallet_id, updated_at, counterparty_marker, lock_time, tx_version''';

  BitcoinTransaction _rowToTransaction(ResultRow row) {
    final now = DateTime.now();
    final createdAt = row[12] as DateTime? ?? now;
    final recovered = (row[22] == null || row[23] == null)
        ? TransactionRowRules.intrinsicsOfRawHex(row[1] as String)
        : null;
    return BitcoinTransaction(
      walletId: row[19] as String,
      txid: row[0] as String,
      rawHex: row[1] as String,
      blockHeight: row[2] as int?,
      confirmations: row[4] as int,
      inputValue: BigInt.from(row[5] as num),
      outputValue: BigInt.from(row[6] as num),
      fee: BigInt.from(row[7] as num),
      netAmount: BigInt.from(row[8] as num), // net_amount column
      status: TransactionStatus.values.firstWhere(
        (e) => e.name == (row[11] as String),
        orElse: () => TransactionStatus.pending,
      ),
      createdAt: createdAt,
      // Rows written before v006 have no updated_at.
      updatedAt: row[20] as DateTime? ?? createdAt,
      receivingAddresses: _parseJsonList(row[17]),
      sendingAddresses: _parseJsonList(row[18]),
      memo: row[16] as String?,
      // The app's opaque counterparty marker (v021, cq16); null on rows
      // stored before the column existed.
      counterpartyMarker: row[21] as String?,
      // The consensus fields the txid commits to (v023, zpu7). Rows written
      // before the columns existed were backfilled from their raw hex by the
      // migration; one whose hex cannot be read as a transaction keeps a
      // null here rather than the 0/1 this used to answer, which said
      // "spendable now" about a locked refund.
      lockTime: (row[22] as int?) ?? recovered?.lockTime,
      version: (row[23] as int?) ?? recovered?.version,
    );
  }

  List<String> _parseJsonList(dynamic value) {
    if (value == null) return [];
    // Handle already-decoded lists (postgres package auto-decodes JSONB)
    if (value is List) {
      return value.cast<String>();
    }
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is List) {
          return decoded.cast<String>();
        }
      } catch (e) {
        _log.warning('Failed to parse JSON string list: $e');
      }
    }
    return [];
  }

  Map<String, dynamic>? _parseJsonMap(dynamic value) {
    if (value == null) return null;
    // Handle already-decoded maps (postgres package auto-decodes JSONB)
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (e) {
        _log.warning('Failed to parse JSON map: $e');
      }
    }
    return null;
  }

  // ============================================================================
  // Block Header Storage (SPV)
  // ============================================================================

  @override
  Future<void> storeBlockHeader(BlockHeader header, int height) async {
    _ensureInitialized();

    await _pool!.execute(
      Sql.named('''
        INSERT INTO block_headers (
          height, hash, prev_block_hash, merkle_root, timestamp,
          version, bits, nonce, is_orphaned, stored_at
        ) VALUES (
          @height, @hash, @prevBlockHash, @merkleRoot, @timestamp,
          @version, @bits, @nonce, false, @now
        )
        ON CONFLICT (hash) DO UPDATE SET
          is_orphaned = false,
          height = EXCLUDED.height
      '''),
      parameters: {
        'height': height,
        'hash': header.blockHash().toString(),
        'prevBlockHash': header.prevBlock.toString(),
        'merkleRoot': header.merkleRoot.toString(),
        'timestamp': header.timestamp.millisecondsSinceEpoch ~/ 1000,
        'version': header.version,
        'bits': header.bits,
        'nonce': header.nonce,
        'now': DateTime.now(),
      },
    );
  }

  @override
  Future<void> storeBlockHeadersBulk(List<(BlockHeader, int)> headers) async {
    _ensureInitialized();
    if (headers.isEmpty) return;

    final now = DateTime.now();

    // One upsert row per hash; the last occurrence wins. A multi-row
    // ON CONFLICT DO UPDATE may not touch the same row twice.
    final byHash = <String, (BlockHeader, int)>{};
    for (final entry in headers) {
      byHash[entry.$1.blockHash().toString()] = entry;
    }
    final rows = byHash.entries.toList();
    final chunkSize = headerInsertChunkSize < 1 ? 1 : headerInsertChunkSize;

    // One transaction per batch (a failure leaves no partial chain) and one
    // multi-row INSERT per chunk: a CDN sync was one round-trip per header
    // (audit S-08). Upsert semantics as storeBlockHeader (S-12).
    await _pool!.runTx((session) async {
      for (var start = 0; start < rows.length; start += chunkSize) {
        final chunk = rows.sublist(start, (start + chunkSize).clamp(0, rows.length));
        final values = <String>[];
        final params = <String, dynamic>{'storedAt': now};
        for (var i = 0; i < chunk.length; i++) {
          final hash = chunk[i].key;
          final (header, height) = chunk[i].value;
          values.add('(@h$i, @hash$i, @prev$i, @merkle$i, @ts$i, '
              '@version$i, @bits$i, @nonce$i, false, @storedAt)');
          params['h$i'] = height;
          params['hash$i'] = hash;
          params['prev$i'] = header.prevBlock.toString();
          params['merkle$i'] = header.merkleRoot.toString();
          params['ts$i'] = header.timestamp.millisecondsSinceEpoch ~/ 1000;
          params['version$i'] = header.version;
          params['bits$i'] = header.bits;
          params['nonce$i'] = header.nonce;
        }
        await session.execute(
          Sql.named('''
            INSERT INTO block_headers (
              height, hash, prev_block_hash, merkle_root, timestamp,
              version, bits, nonce, is_orphaned, stored_at
            ) VALUES ${values.join(', ')}
            ON CONFLICT (hash) DO UPDATE SET
              is_orphaned = false,
              height = EXCLUDED.height
          '''),
          parameters: params,
        );
        onHeaderInsertStatement?.call(chunk.length);
      }
    });
  }

  @override
  Future<BlockHeader?> getBlockHeaderByHash(String hash) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT hash, prev_block_hash, merkle_root, timestamp,
               version, bits, nonce
        FROM block_headers
        WHERE hash = @hash AND is_orphaned = false
      '''),
      parameters: {'hash': hash},
    );

    if (result.isEmpty) return null;
    return _rowToBlockHeader(result.first);
  }

  @override
  Future<BlockHeader?> getBlockHeaderByHeight(int height) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT hash, prev_block_hash, merkle_root, timestamp,
               version, bits, nonce
        FROM block_headers
        WHERE height = @height AND is_orphaned = false
      '''),
      parameters: {'height': height},
    );

    if (result.isEmpty) return null;
    return _rowToBlockHeader(result.first);
  }

  @override
  Future<int?> getHeightByBlockHash(String hash) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT height FROM block_headers
        WHERE hash = @hash AND is_orphaned = false
      '''),
      parameters: {'hash': hash},
    );

    if (result.isEmpty) return null;
    return result.first[0] as int;
  }

  @override
  Future<List<BlockHeader>> getBlockHeaderRange(
    int fromHeight,
    int toHeight,
  ) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT hash, prev_block_hash, merkle_root, timestamp,
               version, bits, nonce
        FROM block_headers
        WHERE height >= @fromHeight AND height <= @toHeight
          AND is_orphaned = false
        ORDER BY height ASC
      '''),
      parameters: {'fromHeight': fromHeight, 'toHeight': toHeight},
    );

    return result.map(_rowToBlockHeader).toList();
  }

  @override
  Future<void> markHeaderAsOrphaned(String hash) async {
    _ensureInitialized();

    await _pool!.execute(
      Sql.named('UPDATE block_headers SET is_orphaned = true WHERE hash = @hash'),
      parameters: {'hash': hash},
    );
  }

  @override
  Future<BlockHeader?> getChainTip() async {
    _ensureInitialized();

    final result = await _pool!.execute('''
      SELECT hash, prev_block_hash, merkle_root, timestamp,
             version, bits, nonce
      FROM block_headers
      WHERE is_orphaned = false
      ORDER BY height DESC
      LIMIT 1
    ''');

    if (result.isEmpty) return null;
    return _rowToBlockHeader(result.first);
  }

  @override
  Future<int> getBestHeight() async {
    _ensureInitialized();

    final result = await _pool!.execute('''
      SELECT COALESCE(MAX(height), 0) FROM block_headers
      WHERE is_orphaned = false
    ''');

    return result.first[0] as int;
  }

  @override
  Future<List<BlockHeader>> getRecentHeaders(int count) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT hash, prev_block_hash, merkle_root, timestamp,
               version, bits, nonce
        FROM block_headers
        WHERE is_orphaned = false
        ORDER BY height DESC
        LIMIT @count
      '''),
      parameters: {'count': count},
    );

    return result.map(_rowToBlockHeader).toList();
  }

  BlockHeader _rowToBlockHeader(ResultRow row) {
    // Convert stored string hashes back to Hash objects
    // Note: Hash.fromHex expects the hash in display order (reversed from internal)
    return BlockHeader(
      version: row[4] as int,
      prevBlock: Hash.fromHex(row[1] as String),
      merkleRoot: Hash.fromHex(row[2] as String),
      timestamp: DateTime.fromMillisecondsSinceEpoch((row[3] as int) * 1000),
      bits: row[5] as int,
      nonce: row[6] as int,
    );
  }

  // ============================================================================
  // Merkle Proof Storage (SPV)
  // ============================================================================

  /// Columns [_rowToMerkleProof] reads, in order.
  static const _merkleProofColumns =
      'block_hash, txid, merkle_proof_json, position, block_height, created_at, status, status_changed_at';

  /// Rows are only added or updated (bead mny; v009 enforces one row per
  /// (txid, block hash) and v012 one current (verified or pendingHeader) row
  /// per txid). The rows of
  /// [txid] are read and written in one transaction holding a per-txid
  /// advisory lock; see [ReadModelStorage.storeMerkleProof] and
  /// `planMerkleProofStore`.
  @override
  Future<void> storeMerkleProof(String txid, MerkleProof proof) async {
    _ensureInitialized();

    await _pool!.runTx((session) async {
      final (ids, rows) = await _lockMerkleProofRows(session, txid);
      final plan = planMerkleProofStore(rows, txid, proof);
      for (final i in plan.orphan) {
        await session.execute(
          Sql.named('''
            UPDATE merkle_proofs SET status = 'orphaned', status_changed_at = @at
            WHERE id = @id
          '''),
          parameters: {'id': ids[i], 'at': plan.orphanedAt},
        );
      }
      final row = plan.row;
      final values = {
        'blockHash': row.blockHash,
        'blockHeight': row.blockHeight,
        'position': row.position,
        'merkleProofJson': row.merkleProof.join(','),
        'status': row.status.name,
        'statusChangedAt': row.statusChangedAt,
      };
      final target = plan.target;
      if (target == null) {
        await session.execute(
          Sql.named('''
            INSERT INTO merkle_proofs (
              txid, block_hash, block_height, position, merkle_proof_json, created_at,
              status, status_changed_at
            ) VALUES (
              @txid, @blockHash, @blockHeight, @position, @merkleProofJson, @createdAt,
              @status, @statusChangedAt
            )
          '''),
          parameters: {...values, 'txid': txid, 'createdAt': row.createdAt},
        );
      } else {
        await session.execute(
          Sql.named('''
            UPDATE merkle_proofs SET
              block_hash = @blockHash,
              block_height = @blockHeight,
              position = @position,
              merkle_proof_json = @merkleProofJson,
              status = @status,
              status_changed_at = @statusChangedAt
            WHERE id = @id
          '''),
          parameters: {...values, 'id': ids[target]},
        );
      }
    });
  }

  @override
  Future<bool> markMerkleProofOrphaned(
    String txid, {
    String? blockHash,
    List<String>? onlyIfMerkleProof,
    DateTime? at,
  }) async {
    _ensureInitialized();

    return _pool!.runTx((session) async {
      final (ids, rows) = await _lockMerkleProofRows(session, txid);
      final plan = planMerkleProofOrphan(rows,
          blockHash: blockHash, onlyIfMerkleProof: onlyIfMerkleProof, at: at ?? DateTime.now());
      if (plan == null) return false;
      await session.execute(
        Sql.named('''
          UPDATE merkle_proofs SET status = 'orphaned', status_changed_at = @at, block_hash = @blockHash
          WHERE id = @id
        '''),
        parameters: {'id': ids[plan.index], 'at': plan.row.statusChangedAt, 'blockHash': plan.row.blockHash},
      );
      return true;
    });
  }

  /// Every row of [txid] (ids and proofs, oldest first), after taking a
  /// transaction-scoped advisory lock on [txid] so concurrent writers of
  /// the same txid run one after the other.
  Future<(List<int>, List<MerkleProof>)> _lockMerkleProofRows(Session session, String txid) async {
    await session.execute(
      Sql.named('SELECT 1 FROM pg_advisory_xact_lock(hashtext(@key))'),
      parameters: {'key': 'merkle_proofs:$txid'},
    );
    final result = await session.execute(
      Sql.named('''
        SELECT $_merkleProofColumns, id
        FROM merkle_proofs
        WHERE txid = @txid
        ORDER BY id
      '''),
      parameters: {'txid': txid},
    );
    return (
      [for (final row in result) row[8] as int],
      [for (final row in result) _rowToMerkleProof(row)],
    );
  }

  @override
  Future<MerkleProof?> getMerkleProof(String txid) async {
    _ensureInitialized();

    // uk_merkle_proofs_txid_current (v012 predicate): at most one such row.
    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_merkleProofColumns
        FROM merkle_proofs
        WHERE txid = @txid AND status IN ('verified', 'pendingHeader')
        LIMIT 1
      '''),
      parameters: {'txid': txid},
    );

    if (result.isEmpty) return null;
    return _rowToMerkleProof(result.first);
  }

  @override
  Future<List<MerkleProof>> getMerkleProofHistory(String txid) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_merkleProofColumns
        FROM merkle_proofs
        WHERE txid = @txid
        ORDER BY id
      '''),
      parameters: {'txid': txid},
    );
    return result.map(_rowToMerkleProof).toList();
  }

  @override
  Future<List<MerkleProof>> getMerkleProofsByStatus(MerkleProofStatus status) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_merkleProofColumns
        FROM merkle_proofs
        WHERE status = @status
        ORDER BY id
      '''),
      parameters: {'status': status.name},
    );
    return result.map(_rowToMerkleProof).toList();
  }

  /// `idx_merkle_proofs_status_height` (v016): the rows of [status] at
  /// those heights only (bead hg0).
  @override
  Future<List<MerkleProof>> getMerkleProofsByStatusBetweenHeights(
    MerkleProofStatus status,
    int fromHeight,
    int toHeight,
  ) async {
    _ensureInitialized();
    if (toHeight < fromHeight) return [];

    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_merkleProofColumns
        FROM merkle_proofs
        WHERE status = @status AND block_height BETWEEN @fromHeight AND @toHeight
        ORDER BY id
      '''),
      parameters: {'status': status.name, 'fromHeight': fromHeight, 'toHeight': toHeight},
    );
    return result.map(_rowToMerkleProof).toList();
  }

  /// `idx_merkle_proofs_status_changed` (v018): the rows of [status] changed
  /// at or after [since] only (bead hccp).
  @override
  Future<List<MerkleProof>> getMerkleProofsByStatusChangedSince(MerkleProofStatus status, DateTime since) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_merkleProofColumns
        FROM merkle_proofs
        WHERE status = @status AND status_changed_at >= @since
        ORDER BY id
      '''),
      parameters: {'status': status.name, 'since': since.toUtc()},
    );
    return result.map(_rowToMerkleProof).toList();
  }

  @override
  Future<Map<String, MerkleProof>> getMerkleProofsBatch(List<String> txids) async {
    if (txids.isEmpty) return {};
    _ensureInitialized();

    final params = <String, dynamic>{};
    final placeholders = <String>[];
    for (int i = 0; i < txids.length; i++) {
      params['txid$i'] = txids[i];
      placeholders.add('@txid$i');
    }

    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_merkleProofColumns
        FROM merkle_proofs
        WHERE txid IN (${placeholders.join(', ')}) AND status IN ('verified', 'pendingHeader')
      '''),
      parameters: params,
    );

    final map = <String, MerkleProof>{};
    for (final row in result) {
      final proof = _rowToMerkleProof(row);
      map[proof.txid] = proof;
    }
    return map;
  }

  @override
  Future<List<MerkleProof>> getMerkleProofsForBlock(String blockHash) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_merkleProofColumns
        FROM merkle_proofs
        WHERE block_hash = @blockHash AND status IN ('verified', 'pendingHeader')
      '''),
      parameters: {'blockHash': blockHash},
    );

    return result.map(_rowToMerkleProof).toList();
  }

  // ========================================
  // Ancestor Transactions (bead zsh)
  // ========================================

  @override
  Future<void> storeAncestorTransaction(String txid, String rawHex) async {
    _ensureInitialized();
    await _pool!.execute(
      Sql.named('''
        INSERT INTO ancestor_transactions (txid, raw_hex)
        VALUES (@txid, @rawHex)
        ON CONFLICT (txid) DO NOTHING
      '''),
      parameters: {'txid': txid, 'rawHex': rawHex},
    );
  }

  @override
  Future<Map<String, String>> getAncestorTransactionsBatch(List<String> txids) async {
    if (txids.isEmpty) return {};
    _ensureInitialized();
    final params = <String, dynamic>{};
    final placeholders = <String>[];
    for (int i = 0; i < txids.length; i++) {
      params['txid$i'] = txids[i];
      placeholders.add('@txid$i');
    }
    final result = await _pool!.execute(
      Sql.named('''
        SELECT txid, raw_hex FROM ancestor_transactions
        WHERE txid IN (${placeholders.join(', ')})
      '''),
      parameters: params,
    );
    return {for (final row in result) row[0] as String: row[1] as String};
  }

  @override
  Future<List<OutputAwaitingProof>> getOutputsAwaitingAncestorProof(
    String walletId, {
    int maxDepth = 20,
  }) =>
      outputsAwaitingAncestorProof(this, walletId, maxDepth: maxDepth);

  // ============================================================================
  // Parked receives (bead libspiffy-vfai, migration v020)
  // ============================================================================

  static const _pendingReceiveColumns = '''
    wallet_id, txid, beef_hex, from_counterparty, invoice_id, needed_height,
    created_at, updated_at, resolved_at, resolution
  ''';

  static PendingReceive _pendingReceiveOf(List<dynamic> row) => PendingReceive(
        walletId: row[0] as String,
        txid: row[1] as String,
        beefHex: row[2] as String,
        fromCounterparty: row[3] as String,
        invoiceId: row[4] as String?,
        neededHeight: (row[5] as num).toInt(),
        createdAt: row[6] as DateTime,
        updatedAt: row[7] as DateTime,
        resolvedAt: row[8] as DateTime?,
        resolution: row[9] as String?,
      );

  @override
  Future<void> storePendingReceive(PendingReceive receive) async {
    _ensureInitialized();
    await _pool!.execute(
      Sql.named('''
        INSERT INTO pending_receives ($_pendingReceiveColumns)
        VALUES (
          @walletId, @txid, @beefHex, @fromCounterparty, @invoiceId, @neededHeight,
          @createdAt, @updatedAt, @resolvedAt, @resolution
        )
        ON CONFLICT (wallet_id, txid) DO UPDATE SET
          beef_hex = EXCLUDED.beef_hex,
          from_counterparty = EXCLUDED.from_counterparty,
          invoice_id = EXCLUDED.invoice_id,
          needed_height = EXCLUDED.needed_height,
          updated_at = EXCLUDED.updated_at,
          resolved_at = EXCLUDED.resolved_at,
          resolution = EXCLUDED.resolution
      '''),
      parameters: {
        'walletId': receive.walletId,
        'txid': receive.txid,
        'beefHex': receive.beefHex,
        'fromCounterparty': receive.fromCounterparty,
        'invoiceId': receive.invoiceId,
        'neededHeight': receive.neededHeight,
        'createdAt': receive.createdAt.toUtc(),
        'updatedAt': receive.updatedAt.toUtc(),
        'resolvedAt': receive.resolvedAt?.toUtc(),
        'resolution': receive.resolution,
      },
    );
  }

  @override
  Future<PendingReceive?> getPendingReceive(String walletId, String txid) async {
    _ensureInitialized();
    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_pendingReceiveColumns FROM pending_receives
        WHERE wallet_id = @walletId AND txid = @txid
      '''),
      parameters: {'walletId': walletId, 'txid': txid},
    );
    return result.isEmpty ? null : _pendingReceiveOf(result.first);
  }

  /// Reads `idx_pending_receives_waiting` (v020): only the waiting rows at or
  /// below [height], oldest first, capped at [limit].
  @override
  Future<List<PendingReceive>> getPendingReceivesUpToHeight(int height, {int limit = 64}) async {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit', 'must be positive');
    _ensureInitialized();
    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_pendingReceiveColumns FROM pending_receives
        WHERE resolved_at IS NULL AND needed_height <= @height
        ORDER BY created_at ASC, txid ASC
        LIMIT @limit
      '''),
      parameters: {'height': height, 'limit': limit},
    );
    return [for (final row in result) _pendingReceiveOf(row)];
  }

  @override
  Future<bool> resolvePendingReceive(String walletId, String txid, String resolution,
      {DateTime? at}) async {
    _ensureInitialized();
    final now = (at ?? DateTime.now()).toUtc();
    final result = await _pool!.execute(
      Sql.named('''
        UPDATE pending_receives
        SET resolved_at = @at, resolution = @resolution, updated_at = @at
        WHERE wallet_id = @walletId AND txid = @txid AND resolved_at IS NULL
      '''),
      parameters: {'walletId': walletId, 'txid': txid, 'resolution': resolution, 'at': now},
    );
    return result.affectedRows > 0;
  }

  // ============================================================================
  // Deferred payments (bead libspiffy-7p2, migration v013)
  // ============================================================================

  static const _deferredPaymentColumns = '''
    wallet_id, txid, state, created_at, updated_at, invoice_id, purpose,
    recipient_addresses, amount, fee, held_inputs, last_network_status,
    last_network_status_source, last_checked_at, resolved_at,
    resolution_reason, inferred, competing_txids
  ''';

  /// Set by tests: receives the SQL and parameters of each
  /// [listDeferredPayments] query.
  @visibleForTesting
  void Function(String sql, Map<String, dynamic> parameters)? onDeferredPaymentQuery;

  @override
  Future<void> storeDeferredPayment(DeferredPayment payment) async {
    _ensureInitialized();
    await _pool!.execute(
      Sql.named('''
        INSERT INTO deferred_payments ($_deferredPaymentColumns)
        VALUES (
          @walletId, @txid, @state, @createdAt, @updatedAt, @invoiceId, @purpose,
          CAST(@recipients AS JSONB), @amount, @fee, CAST(@heldInputs AS JSONB),
          @lastNetworkStatus, @lastNetworkStatusSource, @lastCheckedAt,
          @resolvedAt, @resolutionReason, @inferred, CAST(@competingTxids AS JSONB)
        )
        ON CONFLICT (wallet_id, txid) DO UPDATE SET
          state = EXCLUDED.state,
          updated_at = EXCLUDED.updated_at,
          invoice_id = EXCLUDED.invoice_id,
          purpose = EXCLUDED.purpose,
          recipient_addresses = EXCLUDED.recipient_addresses,
          amount = EXCLUDED.amount,
          fee = EXCLUDED.fee,
          held_inputs = EXCLUDED.held_inputs,
          last_network_status = EXCLUDED.last_network_status,
          last_network_status_source = EXCLUDED.last_network_status_source,
          last_checked_at = EXCLUDED.last_checked_at,
          resolved_at = EXCLUDED.resolved_at,
          resolution_reason = EXCLUDED.resolution_reason,
          inferred = EXCLUDED.inferred,
          competing_txids = EXCLUDED.competing_txids
      '''),
      parameters: {
        'walletId': payment.walletId,
        'txid': payment.txid,
        'state': payment.state.name,
        'createdAt': payment.createdAt.toUtc(),
        'updatedAt': payment.updatedAt.toUtc(),
        'invoiceId': payment.invoiceId,
        'purpose': payment.purpose,
        'recipients': jsonEncode(payment.recipientAddresses),
        'amount': payment.amount.toInt(),
        'fee': payment.fee.toInt(),
        'heldInputs': payment.heldInputsJson,
        'lastNetworkStatus': payment.lastNetworkStatus,
        'lastNetworkStatusSource': payment.lastNetworkStatusSource,
        'lastCheckedAt': payment.lastCheckedAt?.toUtc(),
        'resolvedAt': payment.resolvedAt?.toUtc(),
        'resolutionReason': payment.resolutionReason,
        'inferred': payment.inferred,
        'competingTxids': jsonEncode(payment.competingTxids),
      },
    );
  }

  @override
  Future<DeferredPayment?> getDeferredPayment(String walletId, String txid) async {
    _ensureInitialized();
    final result = await _pool!.execute(
      Sql.named('SELECT $_deferredPaymentColumns FROM deferred_payments '
          'WHERE wallet_id = @walletId AND txid = @txid'),
      parameters: {'walletId': walletId, 'txid': txid},
    );
    return result.isEmpty ? null : _deferredPaymentFromRow(result.first);
  }

  @override
  Future<DeferredPaymentPage> listDeferredPayments(
    String walletId, {
    DeferredPaymentQuery query = const DeferredPaymentQuery(),
  }) async {
    _ensureInitialized();
    final cursor = DeferredPaymentQuery.decodeCursor(query.cursor);
    if (query.states.isEmpty) return const DeferredPaymentPage(payments: []);
    final params = <String, dynamic>{'walletId': walletId};
    final where = <String>['wallet_id = @walletId'];

    final states = query.states.toList();
    final statePlaceholders = <String>[];
    for (var i = 0; i < states.length; i++) {
      statePlaceholders.add('@state$i');
      params['state$i'] = states[i].name;
    }
    where.add('state IN (${statePlaceholders.join(', ')})');
    if (query.createdBefore != null) {
      where.add('created_at < @createdBefore');
      params['createdBefore'] = query.createdBefore!.toUtc();
    }
    if (query.createdAfter != null) {
      where.add('created_at >= @createdAfter');
      params['createdAfter'] = query.createdAfter!.toUtc();
    }
    final statuses = query.lastNetworkStatuses?.toList();
    if (statuses != null) {
      if (statuses.isEmpty) return const DeferredPaymentPage(payments: []);
      final statusPlaceholders = <String>[];
      for (var i = 0; i < statuses.length; i++) {
        statusPlaceholders.add('@status$i');
        params['status$i'] = statuses[i];
      }
      params['unchecked'] = DeferredNetworkStatus.unchecked;
      where.add('COALESCE(last_network_status, @unchecked) IN (${statusPlaceholders.join(', ')})');
    }
    if (query.invoiceId != null) {
      where.add('invoice_id = @invoiceId');
      params['invoiceId'] = query.invoiceId;
    }
    if (query.recipientAddress != null) {
      where.add('jsonb_exists(recipient_addresses, @recipient)');
      params['recipient'] = query.recipientAddress;
    }
    if (cursor != null) {
      where.add(query.oldestFirst
          ? '(created_at, txid) > (@cursorAt, @cursorTxid)'
          : '(created_at, txid) < (@cursorAt, @cursorTxid)');
      params['cursorAt'] = DateTime.fromMicrosecondsSinceEpoch(cursor.$1, isUtc: true);
      params['cursorTxid'] = cursor.$2;
    }
    final direction = query.oldestFirst ? 'ASC' : 'DESC';
    final limit = query.effectiveLimit;
    final sql = 'SELECT $_deferredPaymentColumns FROM deferred_payments '
        'WHERE ${where.join(' AND ')} '
        'ORDER BY created_at $direction, txid $direction '
        'LIMIT ${limit + 1}';
    onDeferredPaymentQuery?.call(sql, params);
    final result = await _pool!.execute(Sql.named(sql), parameters: params);
    final rows = [for (final row in result) _deferredPaymentFromRow(row)];
    final hasMore = rows.length > limit;
    final payments = hasMore ? rows.sublist(0, limit) : rows;
    return DeferredPaymentPage(
      payments: payments,
      nextCursor: hasMore ? DeferredPaymentQuery.cursorAfter(payments.last) : null,
    );
  }

  DeferredPayment _deferredPaymentFromRow(ResultRow row) {
    List<String> strings(Object? cell) {
      final decoded = cell is String ? jsonDecode(cell) : cell;
      return decoded is List ? [for (final e in decoded) e.toString()] : const [];
    }

    final held = row[10];
    return DeferredPayment(
      walletId: row[0] as String,
      txid: row[1] as String,
      state: DeferredPayment.stateFromName(row[2] as String),
      createdAt: (row[3] as DateTime).toUtc(),
      updatedAt: (row[4] as DateTime).toUtc(),
      invoiceId: row[5] as String?,
      purpose: row[6] as String?,
      recipientAddresses: strings(row[7]),
      amount: BigInt.from(row[8] as int),
      fee: BigInt.from(row[9] as int),
      heldInputs: held is String
          ? DeferredPayment.heldInputsFromJson(held)
          : [
              if (held is List)
                for (final e in held)
                  if (e is Map) DeferredPaymentInput.fromMap(e),
            ],
      lastNetworkStatus: row[11] as String?,
      lastNetworkStatusSource: row[12] as String?,
      lastCheckedAt: (row[13] as DateTime?)?.toUtc(),
      resolvedAt: (row[14] as DateTime?)?.toUtc(),
      resolutionReason: row[15] as String?,
      inferred: row[16] as bool,
      competingTxids: strings(row[17]),
    );
  }

  @override
  Future<int> getMerkleProofCount({String? walletId}) async {
    _ensureInitialized();

    final result = await _pool!.execute('SELECT COUNT(*) FROM merkle_proofs');
    return result.first[0] as int;
  }

  MerkleProof _rowToMerkleProof(ResultRow row) {
    final merkleProofStr = row[2] as String;
    return MerkleProof(
      blockHash: row[0] as String?,
      txid: row[1] as String,
      merkleProof: merkleProofStr.split(',').where((s) => s.isNotEmpty).toList(),
      position: row[3] as int,
      blockHeight: row[4] as int,
      createdAt: row[5] as DateTime,
      status: MerkleProofStatus.values.byName(row[6] as String),
      statusChangedAt: row[7] as DateTime?,
    );
  }

  // ============================================================================
  // Wallet Management
  // ============================================================================

  @override
  Future<List<String>> getWalletIds() async {
    return listWallets();
  }

  @override
  Future<bool> walletExists(String walletId) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('SELECT 1 FROM wallet_metadata WHERE wallet_id = @walletId LIMIT 1'),
      parameters: {'walletId': walletId},
    );

    return result.isNotEmpty;
  }

  @override
  Future<void> deleteWallet(String walletId) async {
    _ensureInitialized();

    // Delete in order of foreign key constraints
    await _pool!.runTx((session) async {
      await session.execute(
        Sql.named('DELETE FROM transaction_addresses WHERE wallet_id = @walletId'),
        parameters: {'walletId': walletId},
      );
      await session.execute(
        Sql.named('DELETE FROM bitcoin_utxos WHERE wallet_id = @walletId'),
        parameters: {'walletId': walletId},
      );
      await session.execute(
        Sql.named('DELETE FROM bitcoin_transactions WHERE wallet_id = @walletId'),
        parameters: {'walletId': walletId},
      );
      await session.execute(
        Sql.named('DELETE FROM addresses WHERE wallet_id = @walletId'),
        parameters: {'walletId': walletId},
      );
      await session.execute(
        Sql.named('DELETE FROM invoices WHERE wallet_id = @walletId'),
        parameters: {'walletId': walletId},
      );
      await session.execute(
        Sql.named('DELETE FROM payment_channels WHERE wallet_id = @walletId'),
        parameters: {'walletId': walletId},
      );
      await session.execute(
        Sql.named('DELETE FROM deferred_payments WHERE wallet_id = @walletId'),
        parameters: {'walletId': walletId},
      );
      await session.execute(
        Sql.named('DELETE FROM pending_receives WHERE wallet_id = @walletId'),
        parameters: {'walletId': walletId},
      );
      await session.execute(
        Sql.named('DELETE FROM wallet_metadata WHERE wallet_id = @walletId'),
        parameters: {'walletId': walletId},
      );
    });
  }

  // ============================================================================
  // Invoice Operations
  // ============================================================================

  static const _invoiceColumns = '''
        invoice_id, wallet_id, addresses_json, amount, description,
        status, created_at, expires_at, paid_at, payment_txid,
        amount_received, metadata_json, outputs_json''';

  @override
  Future<void> storeInvoice(InvoiceReadModel invoice) async {
    _ensureInitialized();

    await _pool!.execute(
      Sql.named('''
        INSERT INTO invoices (
          invoice_id, wallet_id, addresses_json, amount, description,
          status, created_at, expires_at, paid_at, payment_txid,
          amount_received, metadata_json, outputs_json
        ) VALUES (
          @invoiceId, @walletId, @addressesJson, @amount, @description,
          @status, @createdAt, @expiresAt, @paidAt, @paymentTxid,
          @amountReceived, CAST(@metadataJson AS JSONB),
          CAST(@outputsJson AS JSONB)
        )
        ON CONFLICT (invoice_id) DO UPDATE SET
          wallet_id = EXCLUDED.wallet_id,
          addresses_json = EXCLUDED.addresses_json,
          amount = EXCLUDED.amount,
          description = EXCLUDED.description,
          status = EXCLUDED.status,
          expires_at = EXCLUDED.expires_at,
          paid_at = EXCLUDED.paid_at,
          payment_txid = EXCLUDED.payment_txid,
          amount_received = EXCLUDED.amount_received,
          metadata_json = EXCLUDED.metadata_json,
          outputs_json = EXCLUDED.outputs_json
      '''),
      parameters: {
        'invoiceId': invoice.invoiceId,
        'walletId': invoice.walletId,
        'addressesJson': jsonEncode(invoice.addresses),
        'amount': invoice.amount.toInt(),
        'description': invoice.description,
        'status': invoice.status.name,
        'createdAt': invoice.createdAt,
        'expiresAt': invoice.expiresAt,
        'paidAt': invoice.paidAt,
        'paymentTxid': invoice.paymentTxid,
        'amountReceived': invoice.amountReceived?.toInt(),
        'metadataJson': jsonEncode(invoice.metadata),
        'outputsJson': invoice.outputs == null
            ? null
            : jsonEncode(invoice.outputs!.map((o) => o.toMap()).toList()),
      },
    );
  }

  @override
  Future<InvoiceReadModel?> getInvoice(String invoiceId) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_invoiceColumns
        FROM invoices
        WHERE invoice_id = @invoiceId
      '''),
      parameters: {'invoiceId': invoiceId},
    );

    if (result.isEmpty) return null;
    return _rowToInvoice(result.first);
  }

  @override
  Future<List<InvoiceReadModel>> listInvoices({
    String? walletId,
    InvoiceStatus? status,
  }) async {
    _ensureInitialized();

    final conditions = <String>[];
    final params = <String, dynamic>{};
    if (walletId != null) {
      conditions.add('wallet_id = @walletId');
      params['walletId'] = walletId;
    }
    if (status != null) {
      conditions.add('status = @status');
      params['status'] = status.name;
    }
    final where =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_invoiceColumns
        FROM invoices
        $where
        ORDER BY created_at DESC
      '''),
      parameters: params,
    );

    return result.map(_rowToInvoice).toList();
  }

  @override
  Future<List<InvoiceReadModel>> getInvoicesByWallet(String walletId) =>
      listInvoices(walletId: walletId);

  @override
  Future<List<InvoiceReadModel>> getInvoicesByStatus(
    InvoiceStatus status, {
    String? walletId,
  }) =>
      listInvoices(walletId: walletId, status: status);

  @override
  Future<void> updateInvoiceStatus(
    String invoiceId,
    InvoiceStatus status, {
    String? txid,
    BigInt? amountReceived,
    DateTime? paidAt,
  }) async {
    _ensureInitialized();

    await _pool!.execute(
      Sql.named('''
        UPDATE invoices SET
          status = @status,
          payment_txid = COALESCE(@txid, payment_txid),
          amount_received = COALESCE(@amountReceived, amount_received),
          paid_at = COALESCE(@paidAt, paid_at)
        WHERE invoice_id = @invoiceId
      '''),
      parameters: {
        'invoiceId': invoiceId,
        'status': status.name,
        'txid': txid,
        'amountReceived': amountReceived?.toInt(),
        'paidAt': paidAt,
      },
    );
  }

  InvoiceReadModel _rowToInvoice(ResultRow row) {
    final createdAt = row[6] as DateTime;
    final paidAt = row[8] as DateTime?;
    return InvoiceReadModel(
      invoiceId: row[0] as String,
      walletId: row[1] as String,
      addresses: _parseJsonList(row[2]),
      amount: BigInt.from(row[3] as num),
      description: row[4] as String?,
      status: InvoiceStatus.values.firstWhere(
        (e) => e.name == (row[5] as String),
        orElse: () => InvoiceStatus.pending,
      ),
      createdAt: createdAt,
      expiresAt: row[7] as DateTime?,
      paidAt: paidAt,
      paymentTxid: row[9] as String?,
      amountReceived: row[10] != null ? BigInt.from(row[10] as num) : null,
      lastUpdated: paidAt ?? createdAt,
      metadata: _parseJsonMap(row[11]) ?? <String, dynamic>{},
      outputs: _parseOutputs(row[12]),
    );
  }

  /// Decodes an `outputs_json` cell (JSONB: already a List, or a JSON
  /// string) into output specs. Null when the invoice has no outputs.
  List<InvoiceOutputSpec>? _parseOutputs(dynamic value) {
    if (value == null) return null;
    final decoded = value is String ? jsonDecode(value) : value;
    if (decoded is! List) return null;
    return decoded
        .map((o) =>
            InvoiceOutputSpec.fromMap(Map<String, dynamic>.from(o as Map)))
        .toList();
  }

  // ============================================================================
  // Payment Channel Storage
  // ============================================================================

  static const _channelColumns = '''
        channel_id, wallet_id, role, client_peer_id, server_peer_id,
        funding_tx_id, funding_tx_hex, funding_output_index, funding_amount_sats,
        client_pub_key_hex, server_pub_key_hex, client_address_b58, server_address_b58,
        lock_time_unix, state, client_balance_sats, server_balance_sats,
        latest_sequence_number, latest_payment_tx_hex, refund_tx_hex,
        refund_client_sig_hex, refund_server_sig_hex, funding_ancestor_txids,
        context, created_at, closed_at, has_funding_merkle_proof,
        latest_payment_tx_id, settlement_tx_id, error_message''';

  @override
  Future<void> storePaymentChannel(PaymentChannel channel) async {
    _ensureInitialized();

    // Every column except the key and created_at is replaced on conflict:
    // the projection re-stores the whole channel after each event.
    await _pool!.execute(
      Sql.named('''
        INSERT INTO payment_channels (
          channel_id, wallet_id, role, client_peer_id, server_peer_id,
          funding_tx_id, funding_tx_hex, funding_output_index, funding_amount_sats,
          client_pub_key_hex, server_pub_key_hex, client_address_b58, server_address_b58,
          lock_time_unix, state, client_balance_sats, server_balance_sats,
          latest_sequence_number, latest_payment_tx_hex, refund_tx_hex,
          refund_client_sig_hex, refund_server_sig_hex, funding_ancestor_txids,
          context, created_at, closed_at, has_funding_merkle_proof,
          latest_payment_tx_id, settlement_tx_id, error_message
        ) VALUES (
          @channelId, @walletId, @role, @clientPeerId, @serverPeerId,
          @fundingTxId, @fundingTxHex, @fundingOutputIndex, @fundingAmountSats,
          @clientPubKeyHex, @serverPubKeyHex, @clientAddressB58, @serverAddressB58,
          @lockTimeUnix, @state, @clientBalanceSats, @serverBalanceSats,
          @latestSequenceNumber, @latestPaymentTxHex, @refundTxHex,
          @refundClientSigHex, @refundServerSigHex,
          CAST(@fundingAncestorTxids AS JSONB),
          @context, @createdAt, @closedAt, @hasFundingMerkleProof,
          @latestPaymentTxId, @settlementTxId, @errorMessage
        )
        ON CONFLICT (channel_id) DO UPDATE SET
          wallet_id = EXCLUDED.wallet_id,
          role = EXCLUDED.role,
          client_peer_id = EXCLUDED.client_peer_id,
          server_peer_id = EXCLUDED.server_peer_id,
          funding_tx_id = EXCLUDED.funding_tx_id,
          funding_tx_hex = EXCLUDED.funding_tx_hex,
          funding_output_index = EXCLUDED.funding_output_index,
          funding_amount_sats = EXCLUDED.funding_amount_sats,
          client_pub_key_hex = EXCLUDED.client_pub_key_hex,
          server_pub_key_hex = EXCLUDED.server_pub_key_hex,
          client_address_b58 = EXCLUDED.client_address_b58,
          server_address_b58 = EXCLUDED.server_address_b58,
          lock_time_unix = EXCLUDED.lock_time_unix,
          state = EXCLUDED.state,
          client_balance_sats = EXCLUDED.client_balance_sats,
          server_balance_sats = EXCLUDED.server_balance_sats,
          latest_sequence_number = EXCLUDED.latest_sequence_number,
          latest_payment_tx_hex = EXCLUDED.latest_payment_tx_hex,
          refund_tx_hex = EXCLUDED.refund_tx_hex,
          refund_client_sig_hex = EXCLUDED.refund_client_sig_hex,
          refund_server_sig_hex = EXCLUDED.refund_server_sig_hex,
          funding_ancestor_txids = EXCLUDED.funding_ancestor_txids,
          context = EXCLUDED.context,
          closed_at = EXCLUDED.closed_at,
          has_funding_merkle_proof = EXCLUDED.has_funding_merkle_proof,
          latest_payment_tx_id = EXCLUDED.latest_payment_tx_id,
          settlement_tx_id = EXCLUDED.settlement_tx_id,
          error_message = EXCLUDED.error_message
      '''),
      parameters: {
        'channelId': channel.channelId,
        'walletId': channel.walletId,
        'role': channel.role.name,
        'clientPeerId': channel.clientPeerId,
        'serverPeerId': channel.serverPeerId,
        'fundingTxId': channel.fundingTxId,
        'fundingTxHex': channel.fundingTxHex,
        'fundingOutputIndex': channel.fundingOutputIndex,
        'fundingAmountSats': channel.fundingAmountSats.toInt(),
        'clientPubKeyHex': channel.clientPubKeyHex,
        'serverPubKeyHex': channel.serverPubKeyHex,
        'clientAddressB58': channel.clientAddressB58,
        'serverAddressB58': channel.serverAddressB58,
        'lockTimeUnix': channel.lockTimeUnix,
        'state': channel.state.name,
        'clientBalanceSats': channel.clientBalanceSats.toInt(),
        'serverBalanceSats': channel.serverBalanceSats.toInt(),
        'latestSequenceNumber': channel.latestSequenceNumber,
        'latestPaymentTxHex': channel.latestPaymentTxHex,
        'refundTxHex': channel.refundTxHex,
        'refundClientSigHex': channel.refundClientSigHex,
        'refundServerSigHex': channel.refundServerSigHex,
        'fundingAncestorTxids': jsonEncode(channel.fundingAncestorTxids),
        'context': channel.context,
        'createdAt': channel.createdAt,
        'closedAt': channel.closedAt,
        'hasFundingMerkleProof': channel.hasFundingMerkleProof,
        'latestPaymentTxId': channel.latestPaymentTxId,
        'settlementTxId': channel.settlementTxId,
        'errorMessage': channel.errorMessage,
      },
    );
  }

  @override
  Future<PaymentChannel?> getPaymentChannel(String channelId) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_channelColumns
        FROM payment_channels
        WHERE channel_id = @channelId
      '''),
      parameters: {'channelId': channelId},
    );

    if (result.isEmpty) return null;
    return _rowToPaymentChannel(result.first);
  }

  @override
  Future<List<PaymentChannel>> getPaymentChannelsForWallet(
    String walletId,
  ) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT $_channelColumns
        FROM payment_channels
        WHERE wallet_id = @walletId
        ORDER BY created_at DESC
      '''),
      parameters: {'walletId': walletId},
    );

    return result.map(_rowToPaymentChannel).toList();
  }

  @override
  Future<void> updatePaymentChannelState(
    String channelId,
    String state,
  ) async {
    _ensureInitialized();

    await _pool!.execute(
      Sql.named('''
        UPDATE payment_channels SET state = @state
        WHERE channel_id = @channelId
      '''),
      parameters: {'channelId': channelId, 'state': state},
    );
  }

  @override
  Future<void> updatePaymentChannelBalance(
    String channelId,
    BigInt clientBalance,
    BigInt serverBalance,
  ) async {
    _ensureInitialized();

    await _pool!.execute(
      Sql.named('''
        UPDATE payment_channels SET
          client_balance_sats = @clientBalance,
          server_balance_sats = @serverBalance
        WHERE channel_id = @channelId
      '''),
      parameters: {
        'channelId': channelId,
        'clientBalance': clientBalance.toInt(),
        'serverBalance': serverBalance.toInt(),
      },
    );
  }

  @override
  Future<void> deletePaymentChannel(String channelId) async {
    _ensureInitialized();

    await _pool!.execute(
      Sql.named('DELETE FROM payment_channels WHERE channel_id = @channelId'),
      parameters: {'channelId': channelId},
    );
  }

  PaymentChannel _rowToPaymentChannel(ResultRow row) {
    return PaymentChannel(
      channelId: row[0] as String,
      walletId: row[1] as String,
      role: PaymentChannelRole.fromJson(row[2] as String),
      clientPeerId: row[3] as String,
      serverPeerId: row[4] as String,
      fundingTxId: row[5] as String?,
      fundingTxHex: row[6] as String?,
      fundingOutputIndex: row[7] as int?,
      fundingAmountSats: BigInt.from(row[8] as num),
      clientPubKeyHex: row[9] as String,
      serverPubKeyHex: row[10] as String?, // '' (pre-v007 rows) reads as null
      clientAddressB58: row[11] as String?,
      serverAddressB58: row[12] as String?,
      lockTimeUnix: row[13] as int,
      state: PaymentChannelState.fromJson(row[14] as String),
      clientBalanceSats: BigInt.from(row[15] as num),
      serverBalanceSats: BigInt.from(row[16] as num),
      latestSequenceNumber: row[17] as int,
      latestPaymentTxHex: row[18] as String?,
      refundTxHex: row[19] as String?,
      refundClientSigHex: row[20] as String?,
      refundServerSigHex: row[21] as String?,
      fundingAncestorTxids: _parseJsonList(row[22]),
      context: row[23] as String?,
      createdAt: row[24] as DateTime,
      closedAt: row[25] as DateTime?,
      hasFundingMerkleProof: row[26] as bool? ?? false,
      latestPaymentTxId: row[27] as String?,
      settlementTxId: row[28] as String?,
      errorMessage: row[29] as String?,
    );
  }
}
