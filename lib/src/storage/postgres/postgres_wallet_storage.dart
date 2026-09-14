/// PostgreSQL-based read model storage for libspiffy.
///
/// Implements the ReadModelStorage interface using PostgreSQL for
/// server-side deployments.
library;

import 'dart:convert';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';
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
import '../read_model_storage.dart';
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

    await _pool!.execute(
      Sql.named('''
        INSERT INTO wallet_metadata (
          wallet_id, name, wallet_type, network, root_address,
          derivation_index, is_created, created_at, last_accessed_at,
          metadata_json, aggregate_version, confirmed_balance, unconfirmed_balance
        ) VALUES (
          @walletId, @name, 'hd', COALESCE(@network, 'mainnet'), @rootAddress,
          0, true, @now, @now, @metadataJson, 0, 0, 0
        )
        ON CONFLICT (wallet_id) DO UPDATE SET
          name = @name,
          root_address = COALESCE(@rootAddress, wallet_metadata.root_address),
          network = COALESCE(@network, wallet_metadata.network),
          metadata_json = COALESCE(@metadataJson, wallet_metadata.metadata_json),
          last_accessed_at = @now
      '''),
      parameters: {
        'walletId': walletId,
        'name': name,
        'rootAddress': rootAddress,
        // Bound as-is: a null must reach the COALESCE above, otherwise every
        // balance update rewrote the network to the default.
        'network': networkType,
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
      'metadata': _parseJsonMap(row[9]),
      'aggregateVersion': row[10],
      'confirmedBalance': (row[11] as num).toString(),
      'unconfirmedBalance': (row[12] as num).toString(),
    };
  }

  @override
  Future<List<String>> listWallets() async {
    _ensureInitialized();

    final result = await _pool!.execute(
      'SELECT wallet_id FROM wallet_metadata ORDER BY created_at',
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

    sql += ' ORDER BY derivation_index';

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
          @usageCount, @balance, @now, @isWatched
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
        'now': DateTime.now(),
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
      SELECT DISTINCT txid FROM transaction_addresses
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

    sql += ' ORDER BY txid';

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
      SELECT txid, vout, satoshis, script_pub_key, address, block_height,
             confirmations, status, created_at, spent_at, spent_in_tx_id,
             script_type, is_spendable, category, plugin_metadata
      FROM bitcoin_utxos
      WHERE wallet_id = @walletId
    ''';

    if (!includeSpent) {
      sql += " AND status != 'spent'";
    }

    sql += ' ORDER BY created_at DESC';

    final result = await _pool!.execute(
      Sql.named(sql),
      parameters: {'walletId': walletId},
    );

    return result.map(_rowToUtxo).toList();
  }

  @override
  Future<List<BitcoinUtxo>> getAvailableUTXOs(String walletId) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT txid, vout, satoshis, script_pub_key, address, block_height,
               confirmations, status, created_at, spent_at, spent_in_tx_id,
               script_type, is_spendable, category, plugin_metadata
        FROM bitcoin_utxos
        WHERE wallet_id = @walletId AND status = 'available'
        ORDER BY satoshis DESC
      '''),
      parameters: {'walletId': walletId},
    );

    return result.map(_rowToUtxo).toList();
  }

  @override
  Future<void> upsertUTXO(String walletId, BitcoinUtxo utxo) async {
    _ensureInitialized();

    await _pool!.execute(
      Sql.named('''
        INSERT INTO bitcoin_utxos (
          wallet_id, txid, vout, utxo_key, satoshis, script_pub_key, address,
          block_height, confirmations, status, created_at, spent_at,
          spent_in_tx_id, script_type, is_spendable, category, plugin_metadata
        ) VALUES (
          @walletId, @txid, @vout, @utxoKey, @satoshis, @scriptPubKey, @address,
          @blockHeight, @confirmations, @status, @createdAt, @spentAt,
          @spentInTxId, @scriptType, @isSpendable, @category,
          CAST(@pluginMetadata AS JSONB)
        )
        ON CONFLICT (wallet_id, txid, vout) DO UPDATE SET
          satoshis = @satoshis,
          script_pub_key = @scriptPubKey,
          address = @address,
          block_height = @blockHeight,
          confirmations = @confirmations,
          status = @status,
          spent_at = @spentAt,
          spent_in_tx_id = @spentInTxId,
          is_spendable = @isSpendable,
          plugin_metadata = CAST(@pluginMetadata AS JSONB)
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
        'spentAt': null, // Set separately when spent
        'spentInTxId': null,
        'scriptType': 'p2pkh',
        'isSpendable': true,
        'category': 'funding',
        'pluginMetadata': utxo.pluginMetadata == null
            ? null
            : jsonEncode(utxo.pluginMetadata),
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
        SELECT txid, vout, satoshis, script_pub_key, address, block_height,
               confirmations, status, created_at, spent_at, spent_in_tx_id,
               script_type, is_spendable, category, plugin_metadata
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
        SELECT txid, vout, satoshis, script_pub_key, address, block_height,
               confirmations, status, created_at, spent_at, spent_in_tx_id,
               script_type, is_spendable, category, plugin_metadata
        FROM bitcoin_utxos
        WHERE wallet_id = @walletId
          AND status != 'spent'
          AND plugin_metadata->>'pluginId' = @pluginId
        ORDER BY created_at DESC
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

  @override
  Future<BigInt> getBalance(String walletId) async {
    // Use getPaymentUTXOs to exclude plugin-managed UTXOs from balance
    final utxos = await getPaymentUTXOs(walletId);
    return utxos.fold<BigInt>(BigInt.zero, (sum, utxo) => sum + utxo.satoshis);
  }

  BitcoinUtxo _rowToUtxo(ResultRow row) {
    final now = DateTime.now();
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
      createdAt: row[8] as DateTime? ?? now,
      updatedAt: row[8] as DateTime? ?? now, // Use same datetime for updatedAt
      pluginMetadata: row.length > 14 ? _parseJsonMap(row[14]) : null,
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
      SELECT txid, raw_hex, block_height, block_hash, confirmations,
             total_input, total_output, fee, net_amount, is_incoming,
             is_outgoing, status, created_at, confirmed_at, broadcast_at,
             counterparty, notes, receiving_addresses, sending_addresses
      FROM bitcoin_transactions
      WHERE wallet_id = @walletId
      ORDER BY created_at DESC
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
        SELECT txid, raw_hex, block_height, block_hash, confirmations,
               total_input, total_output, fee, net_amount, is_incoming,
               is_outgoing, status, created_at, confirmed_at, broadcast_at,
               counterparty, notes, receiving_addresses, sending_addresses
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
        SELECT DISTINCT ON (txid)
               txid, raw_hex, block_height, block_hash, confirmations,
               total_input, total_output, fee, net_amount, is_incoming,
               is_outgoing, status, created_at, confirmed_at, broadcast_at,
               counterparty, notes, receiving_addresses, sending_addresses
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
      SELECT txid, raw_hex, block_height, block_hash, confirmations,
             total_input, total_output, fee, net_amount, is_incoming,
             is_outgoing, status, created_at, confirmed_at, broadcast_at,
             counterparty, notes, receiving_addresses, sending_addresses
      FROM bitcoin_transactions
      WHERE status = @status
    ''';

    final params = <String, dynamic>{'status': status.name};

    if (walletId != null) {
      sql += ' AND wallet_id = @walletId';
      params['walletId'] = walletId;
    }

    sql += ' ORDER BY created_at DESC';

    final result = await _pool!.execute(Sql.named(sql), parameters: params);
    return result.map(_rowToTransaction).toList();
  }

  @override
  Future<void> storeTransaction(
    String walletId,
    BitcoinTransaction transaction,
  ) async {
    _ensureInitialized();

    await _pool!.execute(
      Sql.named('''
        INSERT INTO bitcoin_transactions (
          wallet_id, txid, raw_hex, block_height, block_hash, confirmations,
          total_input, total_output, fee, net_amount, is_incoming, is_outgoing,
          status, created_at, confirmed_at, broadcast_at, counterparty, notes,
          receiving_addresses, sending_addresses, primary_counterparty
        ) VALUES (
          @walletId, @txid, @rawHex, @blockHeight, @blockHash, @confirmations,
          @totalInput, @totalOutput, @fee, @netAmount, @isIncoming, @isOutgoing,
          @status, @createdAt, @confirmedAt, @broadcastAt, @counterparty, @notes,
          @receivingAddresses, @sendingAddresses, @primaryCounterparty
        )
        ON CONFLICT (wallet_id, txid) DO UPDATE SET
          raw_hex = COALESCE(@rawHex, bitcoin_transactions.raw_hex),
          block_height = COALESCE(@blockHeight, bitcoin_transactions.block_height),
          block_hash = COALESCE(@blockHash, bitcoin_transactions.block_hash),
          confirmations = @confirmations,
          total_input = @totalInput,
          total_output = @totalOutput,
          fee = @fee,
          net_amount = @netAmount,
          is_incoming = @isIncoming,
          is_outgoing = @isOutgoing,
          status = @status,
          confirmed_at = COALESCE(@confirmedAt, bitcoin_transactions.confirmed_at),
          notes = @notes,
          receiving_addresses = @receivingAddresses,
          sending_addresses = @sendingAddresses,
          primary_counterparty = @primaryCounterparty
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
        'confirmedAt': transaction.status == TransactionStatus.confirmed
            ? DateTime.now()
            : null,
        'broadcastAt': null,
        'counterparty': null,
        'notes': transaction.memo,
        'receivingAddresses': jsonEncode(transaction.receivingAddresses),
        'sendingAddresses': jsonEncode(transaction.sendingAddresses),
        'primaryCounterparty': transaction.receivingAddresses.isNotEmpty
            ? transaction.receivingAddresses.first
            : null,
      },
    );
  }

  BitcoinTransaction _rowToTransaction(ResultRow row) {
    final now = DateTime.now();
    return BitcoinTransaction(
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
      createdAt: row[12] as DateTime? ?? now,
      updatedAt: row[12] as DateTime? ?? now, // Use createdAt for updatedAt
      receivingAddresses: _parseJsonList(row[17]),
      sendingAddresses: _parseJsonList(row[18]),
      memo: row[16] as String?,
      lockTime: 0, // Not stored in DB, default to 0
      version: 1, // Not stored in DB, default to 1
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

    // One transaction per batch: a failure part-way no longer leaves a
    // partial chain behind, and the batch avoids per-row commits.
    await _pool!.runTx((session) async {
      for (final (header, height) in headers) {
        await session.execute(
          Sql.named('''
            INSERT INTO block_headers (
              height, hash, prev_block_hash, merkle_root, timestamp,
              version, bits, nonce, is_orphaned, stored_at
            ) VALUES (
              @height, @hash, @prevHash, @merkle, @ts,
              @version, @bits, @nonce, false, @storedAt
            ) ON CONFLICT (hash) DO UPDATE SET
              is_orphaned = false,
              height = EXCLUDED.height
          '''),
          parameters: {
            'height': height,
            'hash': header.blockHash().toString(),
            'prevHash': header.prevBlock.toString(),
            'merkle': header.merkleRoot.toString(),
            'ts': header.timestamp.millisecondsSinceEpoch ~/ 1000,
            'version': header.version,
            'bits': header.bits,
            'nonce': header.nonce,
            'storedAt': now,
          },
        );
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

  @override
  Future<void> storeMerkleProof(String txid, MerkleProof proof) async {
    _ensureInitialized();

    await _pool!.execute(
      Sql.named('''
        INSERT INTO merkle_proofs (
          txid, block_hash, block_height, position, merkle_proof_json, created_at
        ) VALUES (
          @txid, @blockHash, @blockHeight, @position, @merkleProofJson, @now
        )
        ON CONFLICT (txid) DO UPDATE SET
          block_hash = EXCLUDED.block_hash,
          block_height = EXCLUDED.block_height,
          position = EXCLUDED.position,
          merkle_proof_json = EXCLUDED.merkle_proof_json,
          created_at = EXCLUDED.created_at
      '''),
      parameters: {
        'txid': txid,
        'blockHash': proof.blockHash,
        'blockHeight': proof.blockHeight,
        'position': proof.position,
        'merkleProofJson': proof.merkleProof.join(','),
        'now': DateTime.now(),
      },
    );
  }

  @override
  Future<MerkleProof?> getMerkleProof(String txid) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT block_hash, txid, merkle_proof_json, position, block_height, created_at
        FROM merkle_proofs
        WHERE txid = @txid
        LIMIT 1
      '''),
      parameters: {'txid': txid},
    );

    if (result.isEmpty) return null;
    return _rowToMerkleProof(result.first);
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
        SELECT block_hash, txid, merkle_proof_json, position, block_height, created_at
        FROM merkle_proofs
        WHERE txid IN (${placeholders.join(', ')})
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
        SELECT block_hash, txid, merkle_proof_json, position, block_height, created_at
        FROM merkle_proofs
        WHERE block_hash = @blockHash
      '''),
      parameters: {'blockHash': blockHash},
    );

    return result.map(_rowToMerkleProof).toList();
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
      blockHash: row[0] as String,
      txid: row[1] as String,
      merkleProof: merkleProofStr.split(',').where((s) => s.isNotEmpty).toList(),
      position: row[3] as int,
      blockHeight: row[4] as int,
      createdAt: row[5] as DateTime,
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
      serverPubKeyHex: row[10] as String,
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
