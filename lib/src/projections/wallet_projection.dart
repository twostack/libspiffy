import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:eventador/eventador.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/services/script_type_registry.dart';
import 'package:logging/logging.dart';
import '../core/wallet_events.dart';
import '../models/wallet_event.dart';
import '../models/wallet_type.dart';
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
/// 
/// STATELESS DESIGN: This projection does NOT cache state in memory.
/// Storage (Isar) is the source of truth. Checkpoints track which events
/// have been processed, but all state is read from/written to storage.
/// This design survives app restarts correctly - no checkpoint/state mismatch.
class WalletProjection extends Projection<void> {
  final _log = Logger('WalletProjection');
  final ReadModelStorage _storage;
  final String _projectionId;
  int _checkpoint = 0;
  
  // NOTE: No in-memory state caching. Storage IS the read model.
  // This prevents checkpoint/state mismatch bugs on restart.
  
  WalletProjection({
    required String projectionId,
    required EventStore eventStore,
    required ReadModelStorage storage,
  })  : _storage = storage,
        _projectionId = projectionId,
        super();
  
  @override
  String get projectionId => _projectionId;
  
  @override
  void get readModel => null; // Storage is the read model, query it directly
  
  @override
  List<Type> get interestedEventTypes => [
        WalletCreatedEvent,
        WalletDeletedEvent,
        WalletConfigurationUpdatedEvent,
        AddressGeneratedEvent,
        AddressDiscoveredEvent,
        AddressLabelUpdatedEvent,
        UTXOReceivedEvent,
        UTXOMarkedAvailableEvent,
        UTXOSpentEvent,
        UTXOConfirmationUpdatedEvent,
        UTXOReservedEvent,
        UTXOReleasedEvent,
        UTXOReservationRenewedEvent,
        TransactionImportedEvent,
        TransactionRecordedEvent,
        TransactionConfirmedEvent,
        TransactionStatusUpdatedEvent,
      ];
  
  @override
  Future<int> getCheckpoint() async {
    // Checkpoint persistence is now handled automatically by ProjectionManager
    // This is only used as a fallback if ProjectionManager doesn't have Isar
    return _checkpoint;
  }
  
  @override
  Future<void> updateCheckpoint(int checkpoint) async {
    // Checkpoint persistence is now handled automatically by ProjectionManager
    // We just maintain an in-memory checkpoint for backward compatibility
    _checkpoint = checkpoint;
  }
  
  @override
  Future<void> rebuild() async {
    await reset();
    // Projection manager will replay events after rebuild
  }
  
  @override
  Future<bool> handle(Event event) async {
    if (event is! WalletEvent) {
      return false;
    }
    
    
    try {
      switch (event.runtimeType) {
        case WalletCreatedEvent:
          await _handleWalletCreated(event as WalletCreatedEvent);
          return true;
        case WalletDeletedEvent:
          await _handleWalletDeleted(event as WalletDeletedEvent);
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
        case UTXOMarkedAvailableEvent:
          await _handleUTXOMarkedAvailable(event as UTXOMarkedAvailableEvent);
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
        case TransactionStatusUpdatedEvent:
          await _handleTransactionStatusUpdated(event as TransactionStatusUpdatedEvent);
          return true;
        default:
          return false;
      }
    } catch (e) {
      rethrow;
    }
  }
  
  Future<void> _handleWalletCreated(WalletCreatedEvent event) async {
    
    // Persist root address to AddressEntity
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
    
    // Store wallet metadata directly to storage (no in-memory caching)
    await _storage.storeWallet(
      event.walletId,
      event.walletName,
      rootAddress: event.rootAddress,
      networkType: event.walletMetadata?['network'] as String? ?? 'mainnet',
      metadata: {
        ...event.walletMetadata ?? {},
        'walletType': event.walletType.toStorageString(),
        'confirmedBalance': '0',
        'unconfirmedBalance': '0',
        'totalBalance': '0',
        'addressCount': 1,
        'utxoCount': 0,
        'availableUtxoCount': 0,
        'lastUpdated': event.timestamp.toIso8601String(),
      },
    );
  }
  
  Future<void> _handleWalletDeleted(WalletDeletedEvent event) async {
    await _storage.deleteWallet(event.walletId);
  }

  Future<void> _handleWalletConfigurationUpdated(WalletConfigurationUpdatedEvent event) async {
    // Read current wallet from storage
    final existingWallet = await _storage.getWallet(event.walletId);
    if (existingWallet == null) {
      return;
    }
    
    // Update wallet metadata in storage
    final existingMetadata = existingWallet['metadata'] as Map<String, dynamic>? ?? {};
    await _storage.storeWallet(
      event.walletId,
      event.newName ?? existingWallet['name'] as String,
      rootAddress: existingWallet['root_address'] as String?,
      networkType: existingWallet['network_type'] as String?,
      metadata: {
        ...existingMetadata,
        if (event.newMetadata != null) ...event.newMetadata!,
        'lastUpdated': event.timestamp.toIso8601String(),
      },
    );
  }
  
  Future<void> _handleAddressGenerated(AddressGeneratedEvent event) async {
    
    // Store address in AddressEntity
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
    await _storage.upsertAddress(event.walletId, metadata);
    
    // Update wallet metadata with new address count (read from storage, update, write back)
    await _updateWalletAddressCount(event.walletId, event.timestamp);
  }
  
  Future<void> _handleAddressDiscovered(AddressDiscoveredEvent event) async {
    
    // Store discovered address in AddressEntity
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
    await _storage.upsertAddress(event.walletId, metadata);
    
    // Update wallet metadata with new address count (read from storage, update, write back)
    await _updateWalletAddressCount(event.walletId, event.timestamp);
  }
  
  /// Helper: Update wallet address count by reading current count from storage
  Future<void> _updateWalletAddressCount(String walletId, DateTime timestamp) async {
    final existingWallet = await _storage.getWallet(walletId);
    if (existingWallet == null) {
      return;
    }
    
    // Get actual address count from storage
    final addresses = await _storage.getWalletAddresses(walletId);
    final addressCount = addresses.length;
    
    // Update wallet metadata
    final existingMetadata = existingWallet['metadata'] as Map<String, dynamic>? ?? {};
    await _storage.storeWallet(
      walletId,
      existingWallet['name'] as String,
      rootAddress: existingWallet['root_address'] as String?,
      networkType: existingWallet['network_type'] as String?,
      metadata: {
        ...existingMetadata,
        'addressCount': addressCount,
        'lastUpdated': timestamp.toIso8601String(),
      },
    );
  }
  
  Future<void> _handleUTXOReceived(UTXOReceivedEvent event) async {
    
    // Look up derivation index from address metadata
    int? derivationIndex;
    Map<String, dynamic>? scriptMetadata;

    // Extract script metadata for all received UTXOs (needed for plugin UTXO storage)
    if (event.scriptPubKey.isNotEmpty) {
      try {
        final walletMeta = await _storage.getWallet(event.walletId);
        final networkTypeStr = walletMeta?['network_type'] as String? ?? 'test';
        final networkType = networkTypeStr == 'main'
            ? dartsv.NetworkType.MAIN
            : dartsv.NetworkType.TEST;

        final script = dartsv.SVScript.fromHex(event.scriptPubKey);
        final scriptRegistry = ScriptTypeRegistry(networkType: networkType);
        scriptMetadata = scriptRegistry.extractScriptMetadata(script);
      } catch (_) {}
    }

    if (event.address.isNotEmpty) {
      final addressMeta = await _storage.getAddressMetadata(event.walletId, event.address);
      if (addressMeta != null) {
        derivationIndex = addressMeta.derivationIndex;
      } else {
        // Address doesn't exist yet - create it!
        // This can happen for payment channel addresses or other externally generated addresses
        String scriptType = scriptMetadata?['scriptType'] as String? ?? 'unknown';

        final newAddressMeta = AddressMetadata(
          address: event.address,
          scriptType: scriptType,
          derivationPath: null,
          derivationIndex: null,
          isChange: false,
          label: 'Received UTXO ($scriptType)',
          purpose: 'receive',
          firstUsedAt: event.timestamp,
          lastUsedAt: event.timestamp,
          usageCount: 1,
          balance: BigInt.from(event.satoshis),
          createdAt: event.timestamp,
          isWatched: true,
        );
        await _storage.upsertAddress(event.walletId, newAddressMeta);

        // Update wallet address count since we just added a new address
        await _updateWalletAddressCount(event.walletId, event.timestamp);
      }
    }
    
    // Update address usage statistics
    if (event.address.isNotEmpty) {
      await _storage.updateAddressUsage(
        event.walletId,
        event.address,
        usedAt: event.timestamp,
        balanceDelta: BigInt.from(event.satoshis),
      );
    }
    
    // Create UTXO and persist directly to storage
    final utxo = BitcoinUtxo.create(
      txid: event.txid,
      vout: event.vout,
      satoshis: BigInt.from(event.satoshis),
      scriptPubKey: event.scriptPubKey,
      address: event.address,
      blockHeight: event.blockHeight,
      confirmations: event.confirmations ?? 0,
      status: event.initialStatus,
      derivationIndex: derivationIndex,
      pluginMetadata: scriptMetadata,
    );
    await _storage.upsertUTXO(event.walletId, utxo);
    
    // Recalculate and persist wallet metadata (balance, counts, etc.)
    await _recalculateAndPersistForWallet(event.walletId, event.timestamp);
  }
  
  Future<void> _handleUTXOMarkedAvailable(UTXOMarkedAvailableEvent event) async {
    
    // Get from storage
    final utxos = await _storage.getUTXOs(event.walletId, includeSpent: true);
    final utxo = utxos.firstWhere(
      (u) => u.txid == event.txid && u.vout == event.vout,
      orElse: () => throw StateError('UTXO not found'),
    );
    
    if (utxo.status == UTXOStatus.pending) {
      final updatedUtxo = utxo.markAvailable();
      await _storage.upsertUTXO(event.walletId, updatedUtxo);
      await _recalculateAndPersistForWallet(event.walletId, event.timestamp);
    } else {
    }
  }
  
  Future<void> _handleUTXOSpent(UTXOSpentEvent event) async {
    
    // Get the UTXO from storage
    final utxos = await _storage.getUTXOs(event.walletId, includeSpent: true);
    final utxo = utxos.firstWhere(
      (u) => u.txid == event.txid && u.vout == event.vout,
      orElse: () => throw StateError('UTXO not found for spending'),
    );
    
    // Mark as spent
    final spentUtxo = utxo.copyWith(
      status: UTXOStatus.spent,
      updatedAt: event.timestamp,
    );
    
    // Update in storage
    await _storage.upsertUTXO(event.walletId, spentUtxo);
    
    await _recalculateAndPersistForWallet(event.walletId, event.timestamp);
  }
  
  Future<void> _handleUTXOConfirmationUpdated(UTXOConfirmationUpdatedEvent event) async {
    // Get from storage
    final utxos = await _storage.getUTXOs(event.walletId, includeSpent: true);
    final utxo = utxos.firstWhere(
      (u) => u.txid == event.txid && u.vout == event.vout,
      orElse: () => throw StateError('UTXO not found'),
    );
    
    // Update confirmations and status
    // If confirmations > 0, mark as available (transition from pending)
    final updatedUtxo = utxo.updateConfirmations(
      blockHeight: event.blockHeight,
      confirmations: event.confirmations,
    ).copyWith(
      status: event.confirmations > 0 ? UTXOStatus.available : utxo.status,
    );
    
    await _storage.upsertUTXO(event.walletId, updatedUtxo);
    await _recalculateAndPersistForWallet(event.walletId, event.timestamp);
  }
  
  Future<void> _handleUTXOReserved(UTXOReservedEvent event) async {
    // Get from storage
    final utxos = await _storage.getUTXOs(event.walletId, includeSpent: true);
    final utxo = utxos.firstWhere(
      (u) => u.txid == event.txid && u.vout == event.vout,
      orElse: () => throw StateError('UTXO not found'),
    );
    
    final updatedUtxo = utxo.copyWith(
      status: UTXOStatus.reserved,
      reservedByTxId: event.reservedByTxId,
      reservationExpiresAt: event.expiresAt,
      reservationPriority: event.priority,
      reservationReason: event.reservationReason,
      updatedAt: event.timestamp,
    );
    await _storage.upsertUTXO(event.walletId, updatedUtxo);
    await _recalculateAndPersistForWallet(event.walletId, event.timestamp);
  }
  
  Future<void> _handleUTXOReleased(UTXOReleasedEvent event) async {
    // Get from storage
    final utxos = await _storage.getUTXOs(event.walletId, includeSpent: true);
    final utxo = utxos.firstWhere(
      (u) => u.txid == event.txid && u.vout == event.vout,
      orElse: () => throw StateError('UTXO not found'),
    );
    
    if (utxo.status == UTXOStatus.reserved) {
      final updatedUtxo = utxo.releaseReservation();
      await _storage.upsertUTXO(event.walletId, updatedUtxo);
      await _recalculateAndPersistForWallet(event.walletId, event.timestamp);
    }
  }
  
  /// Recalculate statistics and persist for a specific wallet
  Future<void> _recalculateAndPersistForWallet(String walletId, DateTime timestamp) async {
    // Get all UTXOs for this specific wallet from storage
    final walletUtxos = await _storage.getUTXOs(walletId, includeSpent: true);
    
    BigInt confirmed = BigInt.zero;
    BigInt unconfirmed = BigInt.zero;
    BigInt reserved = BigInt.zero;
    int available = 0;
    int reservedCount = 0;
    int spentCount = 0;
    
    for (final utxo in walletUtxos) {
      if (utxo.status == UTXOStatus.spent) {
        spentCount++;
        continue;
      }
      // Skip plugin-managed UTXOs (e.g. tokens) from balance calculation
      if (utxo.hasPluginMetadata) continue;

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
    
    // Get existing wallet metadata
    final existingWallet = await _storage.getWallet(walletId);
    if (existingWallet == null) {
      return;
    }
    
    // Update wallet metadata with new balances
    await _storage.storeWallet(
      walletId,
      existingWallet['name'] as String,
      rootAddress: existingWallet['root_address'] as String?,
      networkType: existingWallet['network_type'] as String?,
      metadata: {
        ...existingWallet['metadata'] as Map<String, dynamic>? ?? {},
        'confirmedBalance': confirmed.toString(),
        'unconfirmedBalance': unconfirmed.toString(),
        'reservedBalance': reserved.toString(),
        'totalBalance': total.toString(),
        'utxoCount': walletUtxos.length,
        'availableUtxoCount': available,
        'reservedUtxoCount': reservedCount,
        'spentUtxoCount': spentCount,
        'lastUpdated': timestamp.toIso8601String(),
      },
    );
    
  }
  
  Future<void> _handleTransactionImported(TransactionImportedEvent event) async {
    
    try {
      // Use pre-calculated values from BEEF import (no need to re-parse!)
      final totalOutput = BigInt.from(event.totalOutputSats);
      final totalInput = BigInt.from(event.totalInputSats);
      final walletReceivedSats = BigInt.from(event.walletReceivedSats);
      
      
      // Calculate fee from actual input/output values (if inputs are available)
      final fee = totalInput > BigInt.zero ? totalInput - totalOutput : BigInt.zero;
      
      // Determine if this is incoming or outgoing
      // If we received funds, it's incoming; if we spent, it's outgoing
      // For imported transactions, we're typically importing receives
      final isIncoming = walletReceivedSats > BigInt.zero;
      // Note: isOutgoing would need to check if inputs are from our wallet
      
      // Net amount: positive for receives, negative for sends
      final netAmount = walletReceivedSats; // For receives this is positive
      
      // CRITICAL: Determine status based on whether we have merkle proof in hand
      // If we have the proof, transaction is confirmed and can be trusted
      // If we don't have the proof yet, transaction is pending until proof is obtained
      final hasMerkleProof = event.bumpProof.isNotEmpty;
      final transactionStatus = hasMerkleProof ? TransactionStatus.confirmed : TransactionStatus.pending;
      
      
      // Create BitcoinTransaction with complete wallet-aware data from BEEF
      final transaction = BitcoinTransaction(
        txid: event.txid,
        rawHex: event.rawHex,
        status: transactionStatus,
        blockHeight: hasMerkleProof ? event.blockHeight : null,
        confirmations: hasMerkleProof ? 6 : 0, // Only confirmed if we have the proof
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
      
      await _storage.storeTransaction(event.walletId, transaction);

      // Store Merkle proof from BUMP
      if (event.bumpProof.isNotEmpty) {
        await _storeMerkleProofFromBump(event.txid, event.bumpProof, event.blockHeight);
      }
      
      // Create junction table records for efficient address-centric queries
      await _createTransactionAddressJunctions(
        event.walletId,
        event.txid,
        event.walletReceivingAddresses,
        event.sendingAddresses,
        transaction,
      );
    } catch (e, stackTrace) {
      rethrow;
    }
  }
  
  Future<void> _handleTransactionRecorded(TransactionRecordedEvent event) async {
    
    try {
      // For outgoing transactions, net amount should be:
      // -(payment amount + fee) because we're losing this amount from our wallet
      final paymentAmount = BigInt.parse(event.paymentAmount);
      final fee = BigInt.from(event.fee);
      final netAmount = -(paymentAmount + fee);
      
      // Create transaction record in PENDING state
      final transaction = BitcoinTransaction(
        walletId: event.walletId, // Include wallet ID for proper querying
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
      
      
      await _storage.storeTransaction(event.walletId, transaction);
    } catch (e, stackTrace) {
      _log.warning('Failed to handle transaction recorded event: $e');
    }
  }

  Future<void> _handleTransactionConfirmed(TransactionConfirmedEvent event) async {
    
    try {
      // Fetch the existing transaction from storage
      final existingTx = await _storage.getTransaction(event.txid);
      
      if (existingTx == null) {
        return;
      }
      
      // Update transaction status to confirmed
      final confirmedTx = existingTx.copyWith(
        status: TransactionStatus.confirmed,
        blockHeight: event.blockHeight,
        confirmations: 1, // Assume 1 confirmations when confirmed
        updatedAt: event.timestamp,
      );
      
      
      // Store the updated transaction
      await _storage.storeTransaction(event.walletId, confirmedTx);

    } catch (e, stackTrace) {
      _log.warning('Failed to handle transaction confirmed event: $e');
    }
  }

  Future<void> _handleTransactionStatusUpdated(TransactionStatusUpdatedEvent event) async {
    try {
      final existingTx = await _storage.getTransaction(event.txid);
      if (existingTx == null) {
        return;
      }

      final updatedTx = existingTx.copyWith(
        status: event.newStatus,
        updatedAt: event.timestamp,
      );

      await _storage.storeTransaction(event.walletId, updatedTx);
    } catch (e) {
      _log.warning('Failed to handle transaction status updated event: $e');
    }
  }

  Future<void> _createTransactionAddressJunctions(
    String walletId,
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
      } catch (e, stacktrace) {
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
    
    await _storage.storeTransactionAddresses(walletId, txid, links);
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
    try {
      // Decode hex to bytes
      final bumpBytes = Uint8List.fromList(hex.decode(bumpHex));
      
      // Parse BUMP
      final bump = BUMP.fromBytes(bumpBytes);
      
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
      
      
      // Look up block header to get block hash
      String blockHash = '';
      try {
        final blockHeader = await _storage.getBlockHeaderByHeight(blockHeight);
        if (blockHeader != null) {
          blockHash = blockHeader.blockHash().toString();
        } else {
          // Use a placeholder - merkle proof can still be stored without block hash
          blockHash = 'pending'; // Placeholder until header is synced
        }
      } catch (e) {
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
      
    } catch (e, stackTrace) {
      // Don't rethrow - transaction is still valid without proof stored
    }
  }
  
  @override
  Future<void> reset() async {
    // Stateless projection - no in-memory state to clear.
    // Storage is the source of truth and is not cleared here.
    // (If you need to rebuild, clear the storage separately.)
    _checkpoint = 0;
  }

  @override
  Future<void> onError(dynamic error, StackTrace stackTrace) async {
  }
}

