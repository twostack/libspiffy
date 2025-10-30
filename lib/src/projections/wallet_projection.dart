import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:eventador/eventador.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/services/script_type_registry.dart';
import '../core/wallet_events.dart';
import '../models/wallet_event.dart';
import '../models/wallet_read_model.dart';
import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../models/address_metadata.dart';
import '../models/transaction_address_link.dart';
import '../storage/read_model_storage.dart';
import '../utils/bump.dart';

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
        AddressDiscoveredEvent,
        AddressLabelUpdatedEvent,
        UTXOReceivedEvent,
        UTXOSpentEvent,
        UTXOConfirmationUpdatedEvent,
        UTXOReservedEvent,
        UTXOReleasedEvent,
        UTXOReservationRenewedEvent,
        TransactionImportedEvent,
        TransactionRecordedEvent,
        TransactionConfirmedEvent,
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
        case AddressDiscoveredEvent:
          await _handleAddressDiscovered(event as AddressDiscoveredEvent);
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
        case TransactionRecordedEvent:
          await _handleTransactionRecorded(event as TransactionRecordedEvent);
          return true;
        case TransactionConfirmedEvent:
          await _handleTransactionConfirmed(event as TransactionConfirmedEvent);
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
    print('[WalletProjection] 🆕 Processing WalletCreatedEvent: ${event.walletName}');
    print('[WalletProjection]    Wallet ID: ${event.walletId}');
    print('[WalletProjection]    Root address: ${event.rootAddress}');
    
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
    
    // CRITICAL: Persist the root address to AddressEntity
    // The root address is the first receiving address (m/0/0) and must be queryable
    print('[WalletProjection]    → Persisting root address to AddressEntity...');
    _addresses.add(event.rootAddress);
    
    final rootAddressMetadata = AddressMetadata(
      address: event.rootAddress,
      scriptType: 'p2pkh',
      derivationPath: 'm/0/0', // First receiving address
      derivationIndex: 0,
      isChange: false,
      label: 'Root address (m/0/0)',
      purpose: 'receive',
      firstUsedAt: null,
      lastUsedAt: null,
      usageCount: 0,
      balance: BigInt.zero,
      createdAt: event.timestamp,
      isWatched: true,
    );
    
    await _storage.upsertAddress(event.walletId, rootAddressMetadata);
    print('[WalletProjection]    ✅ Root address persisted to AddressEntity');
    
    // Update address count in read model
    _readModel = _readModel.copyWith(addressCount: 1);
    
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
    print('[WalletProjection] 📍 Processing AddressGeneratedEvent: ${event.address}');
    
    _addresses.add(event.address);
    
    // Store address in AddressEntity for efficient lookup
    final metadata = AddressMetadata(
      address: event.address,
      scriptType: 'p2pkh', // Standard HD wallet addresses are P2PKH
      derivationPath: null, // AddressGeneratedEvent doesn't include derivation path
      derivationIndex: event.derivationIndex,
      isChange: event.purpose == 'change',
      label: event.label,
      purpose: event.purpose ?? 'receive',
      firstUsedAt: null,
      lastUsedAt: null,
      usageCount: 0,
      balance: BigInt.zero,
      createdAt: event.timestamp,
      isWatched: true,
    );
    
    await _storage.upsertAddress(_readModel.walletId, metadata);
    print('[WalletProjection]    ✅ Address stored in AddressEntity');
    
    _readModel = _readModel.copyWith(
      addressCount: _addresses.length,
      lastUpdated: event.timestamp,
    );
    
    await _persistReadModel();
  }
  
  Future<void> _handleAddressDiscovered(AddressDiscoveredEvent event) async {
    print('[WalletProjection] 📍 Processing AddressDiscoveredEvent: ${event.address}');
    print('[WalletProjection]    Wallet: ${_readModel.walletId}');
    print('[WalletProjection]    Index: ${event.derivationIndex}, Change: ${event.isChange}, Txs: ${event.transactionCount}');
    
    _addresses.add(event.address);
    print('[WalletProjection]    → Address added to in-memory set (total: ${_addresses.length})');
    
    // Store discovered address in AddressEntity
    print('[WalletProjection]    → Creating AddressMetadata...');
    final metadata = AddressMetadata(
      address: event.address,
      scriptType: 'p2pkh', // Discovered addresses are typically P2PKH
      derivationPath: null,
      derivationIndex: event.derivationIndex,
      isChange: event.isChange,
      label: 'Imported (${event.isChange ? 'change' : 'receive'} #${event.derivationIndex})',
      purpose: event.isChange ? 'change' : 'receive',
      firstUsedAt: null,
      lastUsedAt: null,
      usageCount: event.transactionCount,
      balance: BigInt.zero,
      createdAt: event.timestamp,
      isWatched: true,
    );
    
    print('[WalletProjection]    → Calling storage.upsertAddress()...');
    await _storage.upsertAddress(_readModel.walletId, metadata);
    print('[WalletProjection]    ✅ Address persisted to AddressEntity in Isar');
    
    print('[WalletProjection]    → Updating read model (addressCount: ${_addresses.length})...');
    _readModel = _readModel.copyWith(
      addressCount: _addresses.length,
      lastUpdated: event.timestamp,
    );
    
    print('[WalletProjection]    → Persisting read model to WalletMetadataEntity...');
    await _persistReadModel();
    print('[WalletProjection]    ✅ AddressDiscoveredEvent processing complete!');
  }
  
  Future<void> _handleUTXOReceived(UTXOReceivedEvent event) async {
    print('[WalletProjection] 📥 Processing UTXOReceivedEvent: ${event.txid}:${event.vout} (${event.satoshis} sats)');
    print('[WalletProjection]    Wallet: ${_readModel.walletId}');
    print('[WalletProjection]    Address: ${event.address}');
    print('[WalletProjection]    Block Height: ${event.blockHeight}');
    
    // Update address usage statistics
    if (event.address.isNotEmpty) {
      await _storage.updateAddressUsage(
        _readModel.walletId,
        event.address,
        usedAt: event.timestamp,
        balanceDelta: BigInt.from(event.satoshis),
      );
      print('[WalletProjection]    ✅ Address usage updated: ${event.address}');
    }
    
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
    print('[WalletProjection]    → UTXO added to in-memory cache');
    print('[WalletProjection]    → Total UTXOs in cache: ${_utxos.length}');
    print('[WalletProjection]    → UTXO keys: ${_utxos.keys.toList()}');
    await _recalculateAndPersist(event.timestamp);
    print('[WalletProjection]    ✅ UTXO persist cycle complete');
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
      print('[WalletProjection] 💾 Persisting read model to Isar...');
      print('[WalletProjection]    Wallet: ${_readModel.walletId}');
      print('[WalletProjection]    Balance: ${_readModel.totalBalance} sats');
      print('[WalletProjection]    UTXO count to persist: ${_utxos.length}');
      
      // Store wallet metadata in read model storage
      await _storage.storeWallet(
        _readModel.walletId,
        _readModel.name,
        rootAddress: _readModel.rootAddress,
        networkType: _readModel.networkType,
        metadata: {
          ..._readModel.metadata,
          'confirmedBalance': _readModel.confirmedBalance.toString(),
          'unconfirmedBalance': _readModel.unconfirmedBalance.toString(),
          'totalBalance': _readModel.totalBalance.toString(),
          'addressCount': _readModel.addressCount,
          'utxoCount': _readModel.utxoCount,
          'availableUtxoCount': _readModel.availableUtxoCount,
        },
      );
      print('[WalletProjection]    ✅ Wallet metadata persisted');
      
      // Persist all UTXOs to storage
      for (final utxo in _utxos.values) {
        print('[WalletProjection]    → Persisting UTXO: ${utxo.txid}:${utxo.vout} (${utxo.satoshis} sats)');
        await _storage.upsertUTXO(_readModel.walletId, utxo);
      }
      print('[WalletProjection]    ✅ All ${_utxos.length} UTXOs persisted to Isar');
    } catch (e, stackTrace) {
      print('[WalletProjection] ❌ Error persisting wallet read model: $e');
      print('[WalletProjection] Stack trace: $stackTrace');
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

      // Store Merkle proof from BUMP
      if (event.bumpProof.isNotEmpty) {
        await _storeMerkleProofFromBump(event.txid, event.bumpProof, event.blockHeight);
      }
      
      // Create junction table records for efficient address-centric queries
      await _createTransactionAddressJunctions(
        event.txid,
        event.walletReceivingAddresses,
        event.sendingAddresses,
        transaction,
      );
    } catch (e, stackTrace) {
      print('[WalletProjection]    ❌ Failed to store transaction: $e');
      print('[WalletProjection]    Stack trace: $stackTrace');
      rethrow;
    }
  }
  
  Future<void> _handleTransactionRecorded(TransactionRecordedEvent event) async {
    print('[WalletProjection] 📤 Processing TransactionRecordedEvent: ${event.txid}');
    
    try {
      // For outgoing transactions, net amount should be:
      // -(payment amount + fee) because we're losing this amount from our wallet
      final paymentAmount = BigInt.parse(event.paymentAmount);
      final fee = BigInt.from(event.fee);
      final netAmount = -(paymentAmount + fee);
      
      // Create transaction record in PENDING state
      final transaction = BitcoinTransaction(
        txid: event.txid,
        rawHex: event.rawHex,
        status: TransactionStatus.pending, // Important: starts as PENDING
        blockHeight: null, // No block height yet
        confirmations: 0,
        inputValue: BigInt.from(event.totalInputSats),
        outputValue: BigInt.from(event.totalOutputSats),
        fee: fee,
        receivingAddresses: event.recipientAddresses,
        sendingAddresses: [], // Sender addresses will be from our wallet
        netAmount: netAmount, // Negative for outgoing
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        lockTime: event.txLockTime,
        version: event.txVersion,
      );
      
      print('[WalletProjection]    → Storing outgoing transaction (status: PENDING)');
      print('[WalletProjection]       Payment amount: ${event.paymentAmount} sats');
      print('[WalletProjection]       Fee: ${event.fee} sats');
      print('[WalletProjection]       Recipients: ${event.recipientAddresses.join(", ")}');
      
      await _storage.storeTransaction(event.walletId, transaction);
      print('[WalletProjection]    ✅ Outgoing transaction recorded (PENDING)');
    } catch (e, stackTrace) {
      print('[WalletProjection] ❌ Error processing TransactionRecordedEvent: $e');
      print('[WalletProjection] Stack trace: $stackTrace');
    }
  }

  Future<void> _handleTransactionConfirmed(TransactionConfirmedEvent event) async {
    print('[WalletProjection] ✅ Processing TransactionConfirmedEvent: ${event.txid}');
    
    try {
      // Update transaction status from PENDING to CONFIRMED
      // For now, just log it - full implementation would update the Isar record
      print('[WalletProjection]    → Transaction confirmed at block: ${event.blockHeight}');
      print('[WalletProjection]    → Block hash: ${event.blockHash}');
      
      // TODO: Implement status update in Isar
      // This would require fetching the transaction and updating its status
      print('[WalletProjection]    ⚠️  Status update not yet implemented');
    } catch (e, stackTrace) {
      print('[WalletProjection] ❌ Error processing TransactionConfirmedEvent: $e');
      print('[WalletProjection] Stack trace: $stackTrace');
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
      
      // Create junction table records
      await _createTransactionAddressJunctions(
        event.txid,
        event.receivingAddresses,
        event.sendingAddresses,
        transaction,
      );
    } catch (e, stackTrace) {
      print('[WalletProjection]    ❌ Failed to store transaction: $e');
      print('[WalletProjection]    Stack trace: $stackTrace');
      rethrow;
    }
  }

  Future<void> _createTransactionAddressJunctions(
    String txid,
    List<String> receivingAddresses,
    List<String> sendingAddresses,
    BitcoinTransaction transaction,
  ) async {
    final links = <TransactionAddressLink>[];
    
    // Create registry once for all outputs
    final scriptTypeRegistry = ScriptTypeRegistry();
    
    // Parse transaction to get exact amounts per address
    final parsedTx = dartsv.Transaction.fromHex(transaction.rawHex);
    
    // Add output links (receiving addresses)
    for (int i = 0; i < parsedTx.outputs.length; i++) {
      final output = parsedTx.outputs[i];
      
      try {
        final script = dartsv.SVScript.fromHex(output.script.toHex());
        
        // Use the registry to extract metadata for ANY script type
        final metadata = scriptTypeRegistry.extractScriptMetadata(script);
        
        if (metadata != null) {
          // Extract identifier and script type
          final destination = _extractPaymentDestination(metadata, script);
          
          if (destination != null) {
            final (outputDestination, scriptType) = destination;
            
            // Check if this destination is in our receiving addresses
            if (receivingAddresses.contains(outputDestination)) {
              links.add(TransactionAddressLink(
                address: outputDestination,
                direction: 'output',
                amount: output.satoshis,
                vout: i,
              ));
            }
          }
        }
      } catch (e) {
        print('[WalletProjection] Failed to extract destination from output $i: $e');
        continue;
      }
    }
    
    // Add input links (sending addresses)
    for (int i = 0; i < sendingAddresses.length && i < parsedTx.inputs.length; i++) {
      final sendingAddress = sendingAddresses[i];
      links.add(TransactionAddressLink(
        address: sendingAddress,
        direction: 'input',
        amount: BigInt.zero, // Would need parent tx to get exact amount
        vin: i,
      ));
    }
    
    await _storage.storeTransactionAddresses(_readModel.walletId, txid, links);
    print('[WalletProjection]    ✅ Created ${links.length} transaction-address junction records');
  }
  
  /// Extract a canonical payment destination identifier from script metadata
  /// Returns (identifier, scriptType) tuple or null if not extractable
  (String, String)? _extractPaymentDestination(
    Map<String, dynamic> metadata,
    dartsv.SVScript script,
  ) {
    final scriptType = metadata['scriptType'] as String?;
    
    switch (scriptType?.toLowerCase()) {
      case 'p2pkh':
      case 'p2pk':
        // These have standard addresses
        final address = metadata['address'] as String?;
        return address != null ? (address, scriptType!) : null;
        
      case 'p2ms':
        // Multisig: concatenate sorted public keys for deterministic identifier
        final publicKeys = metadata['publicKeys'] as List?;
        if (publicKeys != null && publicKeys.isNotEmpty) {
          final sortedKeys = (publicKeys.cast<String>()..sort());
          final identifier = 'multisig:${sortedKeys.join(':')}';
          return (identifier, 'p2ms');
        }
        return null;
        
      case 'p2sh':
        // P2SH: use script hash as identifier
        final scriptHash = metadata['scriptHash'] as String?;
        return scriptHash != null ? ('scripthash:$scriptHash', 'p2sh') : null;
        
      case 'opreturn':
      case 'op_return':
        // OP_RETURN outputs are not spendable, skip
        return null;
        
      default:
        // Unknown/custom script: use script hex hash
        final scriptHex = script.toHex();
        final identifier = 'script:${scriptHex.hashCode.toRadixString(16)}';
        return (identifier, 'custom');
    }
  }
  
  /// Convert hex-encoded BUMP data to MerkleProof and store it
  /// 
  /// This utility function:
  /// 1. Decodes the hex-encoded BUMP bytes
  /// 2. Parses the BUMP structure
  /// 3. Extracts transaction position from sibling offsets
  /// 4. Looks up the block hash from block headers (if available)
  /// 5. Creates and stores a MerkleProof object
  /// 
  /// Note: BUMP proofs only contain sibling hashes, not the txid itself.
  /// The transaction position is derived from the first level's sibling offset.
  Future<void> _storeMerkleProofFromBump(
    String txid,
    String bumpHex,
    int blockHeight,
  ) async {
    print('[WalletProjection]    → Storing Merkle proof for $txid');
    try {
      // Decode hex to bytes
      final bumpBytes = Uint8List.fromList(hex.decode(bumpHex));
      
      // Parse BUMP
      final bump = BUMP.fromBytes(bumpBytes);
      print('[WalletProjection]       BUMP parsed: height=${bump.blockHeight}, path length=${bump.path.length}');
      
      // CRITICAL: BUMP proofs only contain sibling hashes, not the txid
      // The transaction position must be derived from the sibling offset at level 0
      if (bump.path.isEmpty || bump.path[0].leaves.isEmpty) {
        throw Exception('BUMP has no leaves at level 0');
      }
      
      // Get the sibling offset from the first level
      final siblingOffset = bump.path[0].leaves[0].offset;
      
      // Derive transaction position from sibling offset
      // If sibling is even, tx is at sibling + 1 (tx on right)
      // If sibling is odd, tx is at sibling - 1 (tx on left)
      final txPosition = (siblingOffset % 2 == 0) ? siblingOffset + 1 : siblingOffset - 1;
      
      print('[WalletProjection]       Derived tx position: $txPosition (from sibling offset: $siblingOffset)');
      
      // Extract sibling hashes from BUMP path (all levels contain siblings)
      final siblingHashes = <String>[];
      for (int i = 0; i < bump.path.length; i++) {
        for (final leaf in bump.path[i].leaves) {
          if (!leaf.duplicate && leaf.hash != null) {
            // Convert hash bytes to hex (reversed for display format)
            final hashHex = leaf.hash!.reversed
                .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
                .join('');
            siblingHashes.add(hashHex);
          }
        }
      }
      
      print('[WalletProjection]       Position: $txPosition, Sibling hashes: ${siblingHashes.length}');
      
      // Look up block header to get block hash
      String blockHash = '';
      try {
        final blockHeader = await _storage.getBlockHeaderByHeight(blockHeight);
        if (blockHeader != null) {
          blockHash = blockHeader.blockHash().toString();
          print('[WalletProjection]       Block hash: $blockHash');
        } else {
          print('[WalletProjection]       ⚠️ Block header not found for height $blockHeight');
          // Use a placeholder - merkle proof can still be stored without block hash
          blockHash = 'pending'; // Placeholder until header is synced
        }
      } catch (e) {
        print('[WalletProjection]       ⚠️ Error fetching block header: $e');
        blockHash = 'pending';
      }
      
      // Create MerkleProof object
      final merkleProof = MerkleProof(
        txid: txid,
        blockHash: blockHash,
        blockHeight: bump.blockHeight,
        position: txPosition,
        merkleProof: siblingHashes,
      );
      
      // Store to database
      await _storage.storeMerkleProof(txid, merkleProof);
      print('[WalletProjection]    ✅ Merkle proof persisted');
      
    } catch (e, stackTrace) {
      print('[WalletProjection]    ⚠️ Failed to store Merkle proof: $e');
      print('[WalletProjection]    Stack trace: $stackTrace');
      // Don't rethrow - transaction is still valid without proof stored
    }
  }
  
  @override
  Future<void> reset() async {
    _readModel = WalletReadModel.empty(projectionId);
    _utxos.clear();
    _addresses.clear();
  }
}

