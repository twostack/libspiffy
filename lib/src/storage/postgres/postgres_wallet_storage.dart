/// PostgreSQL-based read model storage for libspiffy.
///
/// Implements the ReadModelStorage interface using PostgreSQL for
/// server-side deployments.
library;

import 'dart:convert';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:postgres/postgres.dart';
import 'package:spiffynode/spiffy_node.dart';

import '../../actors/invoice_messages.dart' show InvoiceStatus;
import '../../models/bitcoin_utxo.dart';
import '../../models/bitcoin_transaction.dart';
import '../../models/address_metadata.dart';
import '../../models/transaction_address_link.dart';
import '../../models/invoice_read_model.dart';
import '../../models/payment_channel.dart';
import '../read_model_storage.dart';
import 'postgres_config.dart';

/// PostgreSQL implementation of ReadModelStorage.
///
/// Provides read model storage for wallets, UTXOs, transactions, addresses,
/// invoices, payment channels, and SPV data (block headers, merkle proofs).
class PostgresWalletStorage implements ReadModelStorage {
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
          @walletId, @name, 'hd', @network, @rootAddress,
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
        'network': networkType ?? 'mainnet',
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

    var sql = 'UPDATE addresses SET usage_count = usage_count + 1';
    final params = <String, dynamic>{
      'walletId': walletId,
      'address': address,
    };

    if (usedAt != null) {
      sql += ', last_used_at = @usedAt';
      sql += ', first_used_at = COALESCE(first_used_at, @usedAt)';
      params['usedAt'] = usedAt;
    }

    if (balanceDelta != null) {
      sql += ', balance = balance + @balanceDelta';
      params['balanceDelta'] = balanceDelta.toInt();
    }

    sql += ' WHERE wallet_id = @walletId AND address = @address';

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

    for (final link in links) {
      await _pool!.execute(
        Sql.named('''
          INSERT INTO transaction_addresses (
            wallet_id, txid, address, direction, amount, vout, vin, created_at
          ) VALUES (
            @walletId, @txid, @address, @direction, @amount, @vout, @vin, @now
          )
          ON CONFLICT DO NOTHING
        '''),
        parameters: {
          'walletId': walletId,
          'txid': txid,
          'address': link.address,
          'direction': link.direction,
          'amount': link.amount.toInt(),
          'vout': link.vout,
          'vin': link.vin,
          'now': DateTime.now(),
        },
      );
    }
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
             script_type, is_spendable, category
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
               script_type, is_spendable, category
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
          spent_in_tx_id, script_type, is_spendable, category
        ) VALUES (
          @walletId, @txid, @vout, @utxoKey, @satoshis, @scriptPubKey, @address,
          @blockHeight, @confirmations, @status, @createdAt, @spentAt,
          @spentInTxId, @scriptType, @isSpendable, @category
        )
        ON CONFLICT (utxo_key) DO UPDATE SET
          satoshis = @satoshis,
          script_pub_key = @scriptPubKey,
          address = @address,
          block_height = @blockHeight,
          confirmations = @confirmations,
          status = @status,
          spent_at = @spentAt,
          spent_in_tx_id = @spentInTxId,
          is_spendable = @isSpendable
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
  Future<BigInt> getBalance(String walletId) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT COALESCE(SUM(satoshis), 0) as total
        FROM bitcoin_utxos
        WHERE wallet_id = @walletId AND status = 'available'
      '''),
      parameters: {'walletId': walletId},
    );

    final value = result.first[0];
    return value is num ? BigInt.from(value) : BigInt.parse(value.toString());
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
  Future<BitcoinTransaction?> getTransaction(String txid) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT txid, raw_hex, block_height, block_hash, confirmations,
               total_input, total_output, fee, net_amount, is_incoming,
               is_outgoing, status, created_at, confirmed_at, broadcast_at,
               counterparty, notes, receiving_addresses, sending_addresses
        FROM bitcoin_transactions
        WHERE txid = @txid
      '''),
      parameters: {'txid': txid},
    );

    if (result.isEmpty) return null;
    return _rowToTransaction(result.first);
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
        ON CONFLICT (txid) DO UPDATE SET
          raw_hex = COALESCE(@rawHex, bitcoin_transactions.raw_hex),
          block_height = COALESCE(@blockHeight, bitcoin_transactions.block_height),
          block_hash = COALESCE(@blockHash, bitcoin_transactions.block_hash),
          confirmations = @confirmations,
          status = @status,
          confirmed_at = COALESCE(@confirmedAt, bitcoin_transactions.confirmed_at)
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
      } catch (_) {}
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
      } catch (_) {}
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
        ON CONFLICT (hash) DO NOTHING
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
        ON CONFLICT DO NOTHING
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

  @override
  Future<void> storeInvoice(dynamic invoice) async {
    _ensureInitialized();

    final inv = invoice as InvoiceReadModel;

    await _pool!.execute(
      Sql.named('''
        INSERT INTO invoices (
          invoice_id, wallet_id, addresses_json, amount, description,
          status, created_at, expires_at, paid_at, payment_txid,
          amount_received, metadata_json
        ) VALUES (
          @invoiceId, @walletId, @addressesJson, @amount, @description,
          @status, @createdAt, @expiresAt, @paidAt, @paymentTxid,
          @amountReceived, @metadataJson
        )
        ON CONFLICT (invoice_id) DO UPDATE SET
          status = @status,
          paid_at = @paidAt,
          payment_txid = @paymentTxid,
          amount_received = @amountReceived
      '''),
      parameters: {
        'invoiceId': inv.invoiceId,
        'walletId': inv.walletId,
        'addressesJson': jsonEncode(inv.addresses),
        'amount': inv.amount.toInt(),
        'description': inv.description,
        'status': inv.status.name,
        'createdAt': inv.createdAt,
        'expiresAt': inv.expiresAt,
        'paidAt': inv.paidAt,
        'paymentTxid': inv.paymentTxid,
        'amountReceived': inv.amountReceived?.toInt(),
        'metadataJson': inv.metadata != null ? jsonEncode(inv.metadata) : null,
      },
    );
  }

  @override
  Future<dynamic> getInvoice(String invoiceId) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT invoice_id, wallet_id, addresses_json, amount, description,
               status, created_at, expires_at, paid_at, payment_txid,
               amount_received, metadata_json
        FROM invoices
        WHERE invoice_id = @invoiceId
      '''),
      parameters: {'invoiceId': invoiceId},
    );

    if (result.isEmpty) return null;
    return _rowToInvoice(result.first);
  }

  @override
  Future<List<dynamic>> getInvoicesByWallet(String walletId) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT invoice_id, wallet_id, addresses_json, amount, description,
               status, created_at, expires_at, paid_at, payment_txid,
               amount_received, metadata_json
        FROM invoices
        WHERE wallet_id = @walletId
        ORDER BY created_at DESC
      '''),
      parameters: {'walletId': walletId},
    );

    return result.map(_rowToInvoice).toList();
  }

  @override
  Future<List<dynamic>> getInvoicesByStatus(
    dynamic status, {
    String? walletId,
  }) async {
    _ensureInitialized();

    var sql = '''
      SELECT invoice_id, wallet_id, addresses_json, amount, description,
             status, created_at, expires_at, paid_at, payment_txid,
             amount_received, metadata_json
      FROM invoices
      WHERE status = @status
    ''';

    final params = <String, dynamic>{
      'status': (status as InvoiceStatus).name,
    };

    if (walletId != null) {
      sql += ' AND wallet_id = @walletId';
      params['walletId'] = walletId;
    }

    sql += ' ORDER BY created_at DESC';

    final result = await _pool!.execute(Sql.named(sql), parameters: params);
    return result.map(_rowToInvoice).toList();
  }

  @override
  Future<void> updateInvoiceStatus(
    String invoiceId,
    dynamic status, {
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
        'status': (status as InvoiceStatus).name,
        'txid': txid,
        'amountReceived': amountReceived?.toInt(),
        'paidAt': paidAt,
      },
    );
  }

  InvoiceReadModel _rowToInvoice(ResultRow row) {
    final createdAt = row[6] as DateTime? ?? DateTime.now();
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
      paidAt: row[8] as DateTime?,
      paymentTxid: row[9] as String?,
      amountReceived: row[10] != null ? BigInt.from(row[10] as num) : null,
      lastUpdated: createdAt, // Use createdAt as lastUpdated
      metadata: _parseJsonMap(row[11]) ?? <String, dynamic>{},
    );
  }

  // ============================================================================
  // Payment Channel Storage
  // ============================================================================

  @override
  Future<void> storePaymentChannel(dynamic channel) async {
    _ensureInitialized();

    final ch = channel as PaymentChannel;

    await _pool!.execute(
      Sql.named('''
        INSERT INTO payment_channels (
          channel_id, wallet_id, role, client_peer_id, server_peer_id,
          funding_tx_id, funding_tx_hex, funding_output_index, funding_amount_sats,
          client_pub_key_hex, server_pub_key_hex, client_address_b58, server_address_b58,
          lock_time_unix, state, client_balance_sats, server_balance_sats,
          latest_sequence_number, latest_payment_tx_hex, refund_tx_hex,
          refund_client_sig_hex, refund_server_sig_hex, funding_ancestor_txids,
          context, created_at, closed_at, has_funding_merkle_proof
        ) VALUES (
          @channelId, @walletId, @role, @clientPeerId, @serverPeerId,
          @fundingTxId, @fundingTxHex, @fundingOutputIndex, @fundingAmountSats,
          @clientPubKeyHex, @serverPubKeyHex, @clientAddressB58, @serverAddressB58,
          @lockTimeUnix, @state, @clientBalanceSats, @serverBalanceSats,
          @latestSequenceNumber, @latestPaymentTxHex, @refundTxHex,
          @refundClientSigHex, @refundServerSigHex, @fundingAncestorTxids,
          @context, @createdAt, @closedAt, @hasFundingMerkleProof
        )
        ON CONFLICT (channel_id) DO UPDATE SET
          state = @state,
          client_balance_sats = @clientBalanceSats,
          server_balance_sats = @serverBalanceSats,
          latest_sequence_number = @latestSequenceNumber,
          latest_payment_tx_hex = @latestPaymentTxHex,
          refund_tx_hex = @refundTxHex,
          refund_client_sig_hex = @refundClientSigHex,
          refund_server_sig_hex = @refundServerSigHex,
          closed_at = @closedAt,
          has_funding_merkle_proof = @hasFundingMerkleProof
      '''),
      parameters: {
        'channelId': ch.channelId,
        'walletId': ch.walletId,
        'role': ch.role.name,
        'clientPeerId': ch.clientPeerId,
        'serverPeerId': ch.serverPeerId,
        'fundingTxId': ch.fundingTxId,
        'fundingTxHex': ch.fundingTxHex,
        'fundingOutputIndex': ch.fundingOutputIndex,
        'fundingAmountSats': ch.fundingAmountSats.toInt(),
        'clientPubKeyHex': ch.clientPubKeyHex,
        'serverPubKeyHex': ch.serverPubKeyHex,
        'clientAddressB58': ch.clientAddressB58,
        'serverAddressB58': ch.serverAddressB58,
        'lockTimeUnix': ch.lockTimeUnix,
        'state': ch.state.name,
        'clientBalanceSats': ch.clientBalanceSats.toInt(),
        'serverBalanceSats': ch.serverBalanceSats.toInt(),
        'latestSequenceNumber': ch.latestSequenceNumber,
        'latestPaymentTxHex': ch.latestPaymentTxHex,
        'refundTxHex': ch.refundTxHex,
        'refundClientSigHex': ch.refundClientSigHex,
        'refundServerSigHex': ch.refundServerSigHex,
        'fundingAncestorTxids': jsonEncode(ch.fundingAncestorTxids),
        'context': ch.context,
        'createdAt': ch.createdAt,
        'closedAt': ch.closedAt,
        'hasFundingMerkleProof': ch.hasFundingMerkleProof,
      },
    );
  }

  @override
  Future<dynamic> getPaymentChannel(String channelId) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT channel_id, wallet_id, role, client_peer_id, server_peer_id,
               funding_tx_id, funding_tx_hex, funding_output_index, funding_amount_sats,
               client_pub_key_hex, server_pub_key_hex, client_address_b58, server_address_b58,
               lock_time_unix, state, client_balance_sats, server_balance_sats,
               latest_sequence_number, latest_payment_tx_hex, refund_tx_hex,
               refund_client_sig_hex, refund_server_sig_hex, funding_ancestor_txids,
               context, created_at, closed_at, has_funding_merkle_proof
        FROM payment_channels
        WHERE channel_id = @channelId
      '''),
      parameters: {'channelId': channelId},
    );

    if (result.isEmpty) return null;
    return _rowToPaymentChannel(result.first);
  }

  @override
  Future<List<dynamic>> getPaymentChannelsForWallet(String walletId) async {
    _ensureInitialized();

    final result = await _pool!.execute(
      Sql.named('''
        SELECT channel_id, wallet_id, role, client_peer_id, server_peer_id,
               funding_tx_id, funding_tx_hex, funding_output_index, funding_amount_sats,
               client_pub_key_hex, server_pub_key_hex, client_address_b58, server_address_b58,
               lock_time_unix, state, client_balance_sats, server_balance_sats,
               latest_sequence_number, latest_payment_tx_hex, refund_tx_hex,
               refund_client_sig_hex, refund_server_sig_hex, funding_ancestor_txids,
               context, created_at, closed_at, has_funding_merkle_proof
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
    final channel = PaymentChannel(
      channelId: row[0] as String,
      walletId: row[1] as String,
      role: PaymentChannelRole.values.firstWhere(
        (e) => e.name == (row[2] as String),
      ),
      clientPeerId: row[3] as String,
      serverPeerId: row[4] as String,
      fundingTxId: row[5] as String,
      fundingTxHex: row[6] as String,
      fundingOutputIndex: row[7] as int,
      fundingAmountSats: BigInt.from(row[8] as num),
      clientPubKeyHex: row[9] as String,
      serverPubKeyHex: row[10] as String,
      clientAddressB58: row[11] as String,
      serverAddressB58: row[12] as String,
      lockTimeUnix: row[13] as int,
      state: PaymentChannelState.values.firstWhere(
        (e) => e.name == (row[14] as String),
      ),
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
    );
    // hasFundingMerkleProof is a field, not a constructor parameter
    channel.hasFundingMerkleProof = row[26] as bool? ?? false;
    return channel;
  }
}
