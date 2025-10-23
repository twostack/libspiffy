import 'package:eventador/eventador.dart';
import '../core/wallet_events.dart';
import '../models/wallet_event.dart';
import '../models/wallet_read_model.dart';
import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../storage/read_model_storage.dart';

/// Wallet projection that builds read models from wallet events
/// 
/// This projection subscribes to wallet events from the EventStore and
/// maintains denormalized read models in Isar for fast queries.
/// Separates write concerns (aggregate) from read concerns (queries).
class WalletProjection extends Projection<WalletReadModel> {
  final ReadModelStorage _storage;
  final String _projectionId;
  late WalletReadModel _readModel;
  int _checkpoint = 0;
  
  // Track UTXO statistics for the read model
  final Map<String, BitcoinUtxo> _utxos = {};
  final Set<String> _addresses = {};
  
  WalletProjection({
    required String projectionId,
    required EventStore eventStore,
    required ReadModelStorage storage,
  })  : _storage = storage,
        _projectionId = projectionId,
        super() {
    _readModel = WalletReadModel.empty(projectionId);
  }
  
  @override
  String get projectionId => _projectionId;
  
  @override
  WalletReadModel get readModel => _readModel;
  
  @override
  List<Type> get interestedEventTypes => [
        WalletCreatedEvent,
        WalletConfigurationUpdatedEvent,
        AddressGeneratedEvent,
        AddressLabelUpdatedEvent,
        UTXOReceivedEvent,
        UTXOSpentEvent,
        UTXOConfirmationUpdatedEvent,
        UTXOReservedEvent,
        UTXOReleasedEvent,
        UTXOReservationRenewedEvent,
        TransactionImportedEvent,
        TransactionCreatedEvent,
      ];
  
  @override
  Future<int> getCheckpoint() async {
    return _checkpoint;
  }
  
  @override
  Future<void> updateCheckpoint(int checkpoint) async {
    _checkpoint = checkpoint;
  }
  
  @override
  Future<void> rebuild() async {
    await reset();
    // Projection manager will replay events after rebuild
  }
  
  @override
  Future<bool> handle(Event event) async {
    if (event is! WalletEvent) return false;
    
    try {
      switch (event.runtimeType) {
        case WalletCreatedEvent:
          await _handleWalletCreated(event as WalletCreatedEvent);
          return true;
        case WalletConfigurationUpdatedEvent:
          await _handleWalletConfigurationUpdated(event as WalletConfigurationUpdatedEvent);
          return true;
        case AddressGeneratedEvent:
          await _handleAddressGenerated(event as AddressGeneratedEvent);
          return true;
        case AddressLabelUpdatedEvent:
          // Label updates don't affect read model statistics
          return true;
        case UTXOReceivedEvent:
          await _handleUTXOReceived(event as UTXOReceivedEvent);
          return true;
        case UTXOSpentEvent:
          await _handleUTXOSpent(event as UTXOSpentEvent);
          return true;
        case UTXOConfirmationUpdatedEvent:
          await _handleUTXOConfirmationUpdated(event as UTXOConfirmationUpdatedEvent);
          return true;
        case UTXOReservedEvent:
          await _handleUTXOReserved(event as UTXOReservedEvent);
          return true;
        case UTXOReleasedEvent:
          await _handleUTXOReleased(event as UTXOReleasedEvent);
          return true;
        case UTXOReservationRenewedEvent:
          // Renewal doesn't change statistics
          return true;
        case TransactionImportedEvent:
          await _handleTransactionImported(event as TransactionImportedEvent);
          return true;
        case TransactionCreatedEvent:
          await _handleTransactionCreated(event as TransactionCreatedEvent);
          return true;
        default:
          return false;
      }
    } catch (e) {
      print('Error handling event ${event.runtimeType} in WalletProjection: $e');
      rethrow;
    }
  }
  
  Future<void> _handleWalletCreated(WalletCreatedEvent event) async {
    _readModel = WalletReadModel(
      walletId: event.walletId,
      name: event.walletName,
      rootAddress: event.rootAddress,
      networkType: event.walletMetadata?['network'] as String? ?? 'mainnet',
      createdAt: event.timestamp,
      lastUpdated: event.timestamp,
      confirmedBalance: BigInt.zero,
      unconfirmedBalance: BigInt.zero,
      reservedBalance: BigInt.zero,
      totalBalance: BigInt.zero,
      addressCount: 0,
      utxoCount: 0,
      availableUtxoCount: 0,
      reservedUtxoCount: 0,
      spentUtxoCount: 0,
      metadata: event.walletMetadata ?? {},
    );
    
    // Persist to storage
    await _persistReadModel();
  }
  
  Future<void> _handleWalletConfigurationUpdated(WalletConfigurationUpdatedEvent event) async {
    _readModel = _readModel.copyWith(
      name: event.newName,
      metadata: event.newMetadata != null
          ? {..._readModel.metadata, ...event.newMetadata!}
          : _readModel.metadata,
      lastUpdated: event.timestamp,
    );
    
    await _persistReadModel();
  }
  
  Future<void> _handleAddressGenerated(AddressGeneratedEvent event) async {
    _addresses.add(event.address);
    
    _readModel = _readModel.copyWith(
      addressCount: _addresses.length,
      lastUpdated: event.timestamp,
    );
    
    await _persistReadModel();
  }
  
  Future<void> _handleUTXOReceived(UTXOReceivedEvent event) async {
    print('[WalletProjection] 📥 Processing UTXOReceivedEvent: ${event.txid}:${event.vout} (${event.satoshis} sats)');
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = BitcoinUtxo.create(
      txid: event.txid,
      vout: event.vout,
      satoshis: BigInt.from(event.satoshis),
      scriptPubKey: event.scriptPubKey,
      address: event.address,
      blockHeight: event.blockHeight,
      confirmations: event.confirmations ?? 0,
    );
    
    _utxos[utxoKey] = utxo;
    print('[WalletProjection]    → UTXO added to in-memory cache, total UTXOs: ${_utxos.length}');
    await _recalculateAndPersist(event.timestamp);
    print('[WalletProjection]    ✅ UTXO persisted to Isar');
  }
  
  Future<void> _handleUTXOSpent(UTXOSpentEvent event) async {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = _utxos[utxoKey];
    
    if (utxo != null) {
      _utxos[utxoKey] = utxo.markSpent();
      await _recalculateAndPersist(event.timestamp);
    }
  }
  
  Future<void> _handleUTXOConfirmationUpdated(UTXOConfirmationUpdatedEvent event) async {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = _utxos[utxoKey];
    
    if (utxo != null) {
      _utxos[utxoKey] = utxo.updateConfirmations(
        blockHeight: event.blockHeight,
        confirmations: event.confirmations,
      );
      await _recalculateAndPersist(event.timestamp);
    }
  }
  
  Future<void> _handleUTXOReserved(UTXOReservedEvent event) async {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = _utxos[utxoKey];
    
    if (utxo != null) {
      _utxos[utxoKey] = utxo.copyWith(
        status: UTXOStatus.reserved,
        reservedByTxId: event.reservedByTxId,
        reservationExpiresAt: event.expiresAt,
        reservationPriority: event.priority,
        reservationReason: event.reservationReason,
        updatedAt: event.timestamp,
      );
      await _recalculateAndPersist(event.timestamp);
    }
  }
  
  Future<void> _handleUTXOReleased(UTXOReleasedEvent event) async {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = _utxos[utxoKey];
    
    if (utxo != null && utxo.status == UTXOStatus.reserved) {
      _utxos[utxoKey] = utxo.releaseReservation();
      await _recalculateAndPersist(event.timestamp);
    }
  }
  
  /// Recalculate statistics and persist
  Future<void> _recalculateAndPersist(DateTime timestamp) async {
    BigInt confirmed = BigInt.zero;
    BigInt unconfirmed = BigInt.zero;
    BigInt reserved = BigInt.zero;
    int available = 0;
    int reservedCount = 0;
    int spentCount = 0;
    
    for (final utxo in _utxos.values) {
      if (utxo.status == UTXOStatus.spent) {
        spentCount++;
        continue;
      }
      
      if (utxo.status == UTXOStatus.reserved) {
        reserved += utxo.satoshis;
        reservedCount++;
      } else if ((utxo.confirmations ?? 0) >= 6) {
        confirmed += utxo.satoshis;
        available++;
      } else {
        unconfirmed += utxo.satoshis;
        available++;
      }
    }
    
    final total = confirmed + unconfirmed;
    
    _readModel = _readModel.copyWith(
      confirmedBalance: confirmed,
      unconfirmedBalance: unconfirmed,
      reservedBalance: reserved,
      totalBalance: total,
      utxoCount: _utxos.length,
      availableUtxoCount: available,
      reservedUtxoCount: reservedCount,
      spentUtxoCount: spentCount,
      lastUpdated: timestamp,
    );
    
    await _persistReadModel();
  }
  
  /// Persist read model to storage (Isar)
  Future<void> _persistReadModel() async {
    try {
      // Store wallet metadata in read model storage
      await _storage.storeWallet(
        _readModel.walletId,
        _readModel.name,
        rootAddress: _readModel.rootAddress,
        networkType: _readModel.networkType,
        metadata: _readModel.metadata,
      );
      
      // Persist all UTXOs to storage
      for (final utxo in _utxos.values) {
        await _storage.upsertUTXO(_readModel.walletId, utxo);
      }
    } catch (e) {
      print('Error persisting wallet read model: $e');
      rethrow;
    }
  }
  
  Future<void> _handleTransactionImported(TransactionImportedEvent event) async {
    print('[WalletProjection] 📥 Processing TransactionImportedEvent: ${event.txid}');
    
    try {
      // Use pre-calculated values from BEEF import (no need to re-parse!)
      final totalOutput = BigInt.from(event.totalOutputSats);
      final totalInput = BigInt.from(event.totalInputSats);
      final walletReceivedSats = BigInt.from(event.walletReceivedSats);
      
      print('[WalletProjection]    → Transaction data from BEEF:');
      print('[WalletProjection]       Inputs: ${event.numInputs}, Outputs: ${event.numOutputs}');
      print('[WalletProjection]       Total input: $totalInput sats (${event.sendingAddresses.length} sending addresses)');
      print('[WalletProjection]       Total output: $totalOutput sats');
      print('[WalletProjection]       Wallet received: $walletReceivedSats sats from ${event.walletReceivingAddresses.length} addresses');
      print('[WalletProjection]       Receiving addresses: ${event.walletReceivingAddresses.join(", ")}');
      print('[WalletProjection]       Sending addresses: ${event.sendingAddresses.join(", ")}');
      print('[WalletProjection]       Version: ${event.txVersion}, LockTime: ${event.txLockTime}');
      
      // Calculate fee from actual input/output values (if inputs are available)
      final fee = totalInput > BigInt.zero ? totalInput - totalOutput : BigInt.zero;
      
      // Determine if this is incoming or outgoing
      // If we received funds, it's incoming; if we spent, it's outgoing
      // For imported transactions, we're typically importing receives
      final isIncoming = walletReceivedSats > BigInt.zero;
      // Note: isOutgoing would need to check if inputs are from our wallet
      
      // Net amount: positive for receives, negative for sends
      final netAmount = walletReceivedSats; // For receives this is positive
      
      // Create BitcoinTransaction with complete wallet-aware data from BEEF
      final transaction = BitcoinTransaction(
        txid: event.txid,
        rawHex: event.rawHex,
        status: TransactionStatus.confirmed,
        blockHeight: event.blockHeight,
        confirmations: 6, // Assume sufficient confirmations for imported txs
        inputValue: totalInput,
        outputValue: totalOutput,
        fee: fee,
        receivingAddresses: event.walletReceivingAddresses, // Our addresses that received
        sendingAddresses: event.sendingAddresses, // Addresses from parent tx outputs (BEEF)
        netAmount: netAmount,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        lockTime: event.txLockTime,
        version: event.txVersion,
      );
      
      print('[WalletProjection]    → Storing transaction in Isar (block: ${event.blockHeight})');
      print('[WalletProjection]       Net amount for wallet: ${netAmount} sats (${isIncoming ? "INCOMING" : "OUTGOING"})');
      await _storage.storeTransaction(_readModel.walletId, transaction);
      print('[WalletProjection]    ✅ Transaction persisted to Isar');
    } catch (e, stackTrace) {
      print('[WalletProjection]    ❌ Failed to store transaction: $e');
      print('[WalletProjection]    Stack trace: $stackTrace');
      rethrow;
    }
  }
  
  Future<void> _handleTransactionCreated(TransactionCreatedEvent event) async {
    print('[WalletProjection] 📥 Processing TransactionCreatedEvent: ${event.txid}');
    
    try {
      // Use pre-calculated values from the event (no need to re-parse!)
      final totalInput = BigInt.from(event.totalInput);
      final totalOutput = BigInt.from(event.totalOutput);
      final fee = BigInt.from(event.fee);
      
      print('[WalletProjection]    → Transaction data from event:');
      print('[WalletProjection]       Total input: $totalInput sats');
      print('[WalletProjection]       Total output: $totalOutput sats');
      print('[WalletProjection]       Fee: $fee sats');
      print('[WalletProjection]       Direction: ${event.isIncoming ? "INCOMING" : ""} ${event.isOutgoing ? "OUTGOING" : ""}');
      
      // Use pre-calculated addresses from event (no parsing needed!)
      print('[WalletProjection]       Receiving addresses (${event.receivingAddresses.length}): ${event.receivingAddresses.join(", ")}');
      print('[WalletProjection]       Sending addresses (${event.sendingAddresses.length}): ${event.sendingAddresses.join(", ")}');
      print('[WalletProjection]       Version: ${event.txVersion}, LockTime: ${event.txLockTime}');
      
      // Net amount calculation:
      // - For outgoing: we're spending, so negative (we lose the inputs we spent)
      // - For incoming: we're receiving, so positive
      // Note: The aggregate should calculate this, but for created txs it's typically outgoing
      final netAmount = event.isOutgoing 
          ? -(totalInput - totalOutput) // We spent totalInput, got totalOutput change back (if any)
          : totalOutput; // We received
      
      // Create BitcoinTransaction with complete data from event (no parsing!)
      final transaction = BitcoinTransaction(
        txid: event.txid,
        rawHex: event.rawHex,
        status: TransactionStatus.pending,
        blockHeight: null, // Created transactions are unconfirmed
        confirmations: 0,
        inputValue: totalInput,
        outputValue: totalOutput,
        fee: fee,
        receivingAddresses: event.receivingAddresses, // From event
        sendingAddresses: event.sendingAddresses, // From event
        netAmount: netAmount,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        lockTime: event.txLockTime, // From event
        version: event.txVersion, // From event
      );
      
      print('[WalletProjection]    → Storing transaction in Isar (unconfirmed)');
      print('[WalletProjection]       Net amount for wallet: $netAmount sats (${event.isOutgoing ? "SENT" : "RECEIVED"})');
      await _storage.storeTransaction(_readModel.walletId, transaction);
      print('[WalletProjection]    ✅ Transaction persisted to Isar');
    } catch (e, stackTrace) {
      print('[WalletProjection]    ❌ Failed to store transaction: $e');
      print('[WalletProjection]    Stack trace: $stackTrace');
      rethrow;
    }
  }
  
  @override
  Future<void> reset() async {
    _readModel = WalletReadModel.empty(projectionId);
    _utxos.clear();
    _addresses.clear();
  }
}

