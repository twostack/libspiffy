import 'package:eventador/eventador.dart';
import 'package:uuid/uuid.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import '../models/wallet_event.dart';
import '../models/wallet_state.dart';
import '../models/bitcoin_utxo.dart';
import '../services/crypto_service.dart';
import '../storage/secure_storage.dart';
import '../services/transaction_builder_service.dart';
import '../actors/wallet_messages.dart';
import 'wallet_commands.dart';
import 'wallet_events.dart';

/// Bitcoin wallet aggregate root implementing event sourcing
/// 
/// This aggregate manages all wallet state changes through events,
/// ensuring consistency and providing full audit trail for all operations.
/// Follows the Eventador AggregateRoot pattern with functional state management.
class BitcoinWalletAggregate extends AggregateRoot<WalletState> {
  final CryptoService cryptoService;
  final SecureStorage secureStorage;
  final TransactionBuilderService? transactionBuilder;

  BitcoinWalletAggregate({
    required String aggregateId,
    required String aggregateType,
    required EventStore eventStore,
    required this.cryptoService,
    required this.secureStorage,
    this.transactionBuilder,
  }) : super(aggregateId: aggregateId, aggregateType: aggregateType, eventStore: eventStore) {
    // Register handlers immediately upon construction
    registerHandlers();
  }

  /// Create initial empty wallet state
  @override
  WalletState createInitialState() {
    return WalletState.empty(aggregateId);
  }

  /// Register command and event handlers
  /// 
  /// Note: This aggregate uses the override pattern for handleCommand() and applyEvent()
  /// instead of the registry pattern. Command and event handling is implemented via
  /// switch statements in the overridden methods (see lines 135-172 and 176-216).
  /// This approach provides better support for async operations and type-safe handling.
  @override
  void registerHandlers() {
    // Intentionally empty - using override pattern instead of registry pattern
  }

  /// Send response messages after successful command processing
  /// Only active when aggregate is used as an actor in the actor system
  @override
  Future<void> onCommandProcessed(Command command, List<Event> events) async {
    await super.onCommandProcessed(command, events);
    
    // Only send responses if we're running in an actor system
    // (context is initialized by the actor system when spawned)
    if (!_isInActorSystem()) return;
    
    if (context.sender == null) return;
    
    for (final event in events) {
      if (event is WalletCreatedEvent) {
        context.sender!.tell(WalletCreatedResponse(
          walletId: event.walletId,
          rootAddress: event.rootAddress,
          success: true,
        ));
      } else if (event is AddressGeneratedEvent) {
        context.sender!.tell(AddressGeneratedResponse(
          walletId: event.walletId,
          address: event.address,
          derivationIndex: event.derivationIndex,
          success: true,
        ));
      } else if (event is TransactionCreatedEvent) {
        context.sender!.tell(TransactionCreatedResponse(
          walletId: event.walletId,
          txid: event.txid,
          rawHex: event.rawHex,
          success: true,
        ));
      }
    }
  }

  /// Send error responses when command processing fails
  /// Only active when aggregate is used as an actor in the actor system
  @override
  Future<void> onCommandFailure(Command command, dynamic error) async {
    await super.onCommandFailure(command, error);
    
    // Only send responses if we're running in an actor system
    if (!_isInActorSystem()) return;
    
    if (context.sender == null) return;
    
    final errorMessage = error.toString();

    if (command is CreateWalletCommand) {
      context.sender!.tell(WalletCreatedResponse(
        walletId: command.walletId,
        rootAddress: '',
        success: false,
        error: errorMessage,
      ));
    } else if (command is GenerateAddressCommand) {
      context.sender!.tell(AddressGeneratedResponse(
        walletId: command.walletId,
        address: '',
        derivationIndex: 0,
        success: false,
        error: errorMessage,
      ));
    } else if (command is CreateTransactionCommand) {
      context.sender!.tell(TransactionCreatedResponse(
        walletId: command.walletId,
        txid: '',
        rawHex: '',
        success: false,
        error: errorMessage,
      ));
    }
  }

  /// Check if we're running in an actor system (vs. direct domain testing)
  bool _isInActorSystem() {
    try {
      // Try to access context - if it throws, we're not in an actor system
      final _ = context;
      return true;
    } catch (e) {
      // LateInitializationError means context not set - we're not in actor system
      return false;
    }
  }

  // ==========================================================================
  // EVENTADOR AGGREGATE ROOT IMPLEMENTATION
  // ==========================================================================

  /// Handle commands asynchronously and return events
  /// 
  /// This method supports async cryptographic operations and secure storage access
  /// required for wallet operations. All calling code must await this method.
  @override
  Future<List<Event>> handleCommand(WalletState currentState, Command command) async {
    switch (command.runtimeType) {
      case CreateWalletCommand:
        return await _handleCreateWallet(currentState, command as CreateWalletCommand);
      case UpdateWalletConfigurationCommand:
        return _handleUpdateConfiguration(currentState, command as UpdateWalletConfigurationCommand);
      case GenerateAddressCommand:
        return await _handleGenerateAddress(currentState, command as GenerateAddressCommand);
      case UpdateAddressLabelCommand:
        return _handleUpdateAddressLabel(currentState, command as UpdateAddressLabelCommand);
      case ReceiveUTXOCommand:
        return _handleReceiveUTXO(currentState, command as ReceiveUTXOCommand);
      case SpendUTXOCommand:
        return _handleSpendUTXO(currentState, command as SpendUTXOCommand);
      case UpdateUTXOConfirmationsCommand:
        return _handleUpdateUTXOConfirmations(currentState, command as UpdateUTXOConfirmationsCommand);
      case CreateTransactionCommand:
        return await _handleCreateTransaction(currentState, command as CreateTransactionCommand);
      case SignTransactionCommand:
        return _handleSignTransaction(currentState, command as SignTransactionCommand);
      case BroadcastTransactionCommand:
        return _handleBroadcastTransaction(currentState, command as BroadcastTransactionCommand);
      case ReserveUTXOsCommand:
        return _handleReserveUTXOs(currentState, command as ReserveUTXOsCommand);
      case ReleaseUTXOsCommand:
        return _handleReleaseUTXOs(currentState, command as ReleaseUTXOsCommand);
      case ReserveUTXOCommand:
        return _handleReserveUTXO(currentState, command as ReserveUTXOCommand);
      case ReleaseUTXOCommand:
        return _handleReleaseUTXO(currentState, command as ReleaseUTXOCommand);
      case RenewUTXOReservationCommand:
        return _handleRenewUTXOReservation(currentState, command as RenewUTXOReservationCommand);
      case CleanupExpiredReservationsCommand:
        return _handleCleanupExpiredReservations(currentState, command as CleanupExpiredReservationsCommand);
      default:
        throw ArgumentError('Unknown command type: ${command.runtimeType}');
    }
  }

  /// Apply events to state and return new state (Eventador pattern)
  @override
  WalletState applyEvent(WalletState currentState, Event event) {
    if (event is! WalletEvent) {
      throw ArgumentError('Expected WalletEvent, got ${event.runtimeType}');
    }

    switch (event.runtimeType) {
      case WalletCreatedEvent:
        return _applyWalletCreated(currentState, event as WalletCreatedEvent);
      case WalletConfigurationUpdatedEvent:
        return _applyWalletConfigurationUpdated(currentState, event as WalletConfigurationUpdatedEvent);
      case AddressGeneratedEvent:
        return _applyAddressGenerated(currentState, event as AddressGeneratedEvent);
      case AddressLabelUpdatedEvent:
        return _applyAddressLabelUpdated(currentState, event as AddressLabelUpdatedEvent);
      case UTXOReceivedEvent:
        return _applyUTXOReceived(currentState, event as UTXOReceivedEvent);
      case UTXOSpentEvent:
        return _applyUTXOSpent(currentState, event as UTXOSpentEvent);
      case UTXOConfirmationUpdatedEvent:
        return _applyUTXOConfirmationUpdated(currentState, event as UTXOConfirmationUpdatedEvent);
      case TransactionCreatedEvent:
        return _applyTransactionCreated(currentState, event as TransactionCreatedEvent);
      case TransactionSignedEvent:
        return _applyTransactionSigned(currentState, event as TransactionSignedEvent);
      case TransactionBroadcastEvent:
        return _applyTransactionBroadcast(currentState, event as TransactionBroadcastEvent);
      case UTXOReservationPlacedEvent:
        return _applyUTXOReservationPlaced(currentState, event as UTXOReservationPlacedEvent);
      case UTXOReservationReleasedEvent:
        return _applyUTXOReservationReleased(currentState, event as UTXOReservationReleasedEvent);
      case UTXOReservationExpiredEvent:
        return _applyUTXOReservationExpired(currentState, event as UTXOReservationExpiredEvent);
      case UTXOReservedEvent:
        return _applyUTXOReserved(currentState, event as UTXOReservedEvent);
      case UTXOReleasedEvent:
        return _applyUTXOReleased(currentState, event as UTXOReleasedEvent);
      case UTXOReservationRenewedEvent:
        return _applyUTXOReservationRenewed(currentState, event as UTXOReservationRenewedEvent);
      default:
        throw ArgumentError('Unknown event type: ${event.runtimeType}');
    }
  }

  // ==========================================================================
  // WALLET LIFECYCLE COMMAND HANDLERS
  // ==========================================================================

  Future<List<Event>> _handleCreateWallet(WalletState currentState, CreateWalletCommand command) async {
    // Business rule: Cannot create wallet that already exists
    if (currentState.isCreated) {
      throw StateError('Wallet ${command.walletId} already exists');
    }

    // Validate or generate mnemonic
    String mnemonic = command.mnemonic ?? '';
    if (mnemonic.isEmpty) {
      // Generate new mnemonic if not provided
      mnemonic = await cryptoService.generateMnemonic();
    } else {
      // Validate provided mnemonic
      final isValid = await cryptoService.validateMnemonic(mnemonic);
      if (!isValid) {
        throw ArgumentError('Invalid mnemonic phrase provided');
      }
    }

    // Determine network type from metadata or default to testnet
    final metadata = command.walletMetadata ?? {};
    final networkTypeStr = metadata['network'] as String? ?? 'testnet';
    final networkType = networkTypeStr == 'mainnet' ? dartsv.NetworkType.MAIN : dartsv.NetworkType.TEST;

    // Derive HD private key from mnemonic
    final hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(
      mnemonic,
      passphrase: command.passphrase ?? '',
      network: networkType,
    );

    // Derive HD public key for address generation
    final hdPublicKey = cryptoService.deriveHDPublicKey(hdPrivateKey);

    // Generate root address (first receiving address at index 0)
    final rootAddress = cryptoService.generateReceivingAddress(
      hdPublicKey,
      0,
      network: networkType,
    );

    // Store mnemonic and HD public key securely
    await secureStorage.setMnemonic(command.walletId, mnemonic);
    await secureStorage.setString('wallet_hdpubkey_${command.walletId}', hdPublicKey.xpubkey);

    final event = WalletCreatedEvent(
      walletId: command.walletId,
      walletName: command.walletName,
      rootAddress: rootAddress,
      walletMetadata: command.walletMetadata,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  List<Event> _handleUpdateConfiguration(WalletState currentState, UpdateWalletConfigurationCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot update configuration of non-existent wallet');
    }

    // Business rule: Must have something to update
    if (command.newName == null && command.newMetadata == null) {
      throw ArgumentError('Must specify newName or newMetadata to update');
    }

    final event = WalletConfigurationUpdatedEvent(
      eventId: const Uuid().v4(),
      walletId: command.walletId,
      timestamp: DateTime.now(),
      version: currentState.version + 1,
      newName: command.newName,
      newMetadata: command.newMetadata,
    );

    return [event];
  }

  // ==========================================================================
  // ADDRESS MANAGEMENT COMMAND HANDLERS
  // ==========================================================================

  Future<List<Event>> _handleGenerateAddress(WalletState currentState, GenerateAddressCommand command) async {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot generate address for non-existent wallet');
    }

    // Use next available derivation index
    final derivationIndex = currentState.nextDerivationIndex;

    // Retrieve HD public key from secure storage
    final xpubkey = await secureStorage.getString('wallet_hdpubkey_${command.walletId}');
    if (xpubkey == null) {
      throw StateError('HD public key not found for wallet ${command.walletId}');
    }

    // Determine network type
    final networkTypeStr = currentState.networkType;
    final networkType = networkTypeStr == 'mainnet' ? dartsv.NetworkType.MAIN : dartsv.NetworkType.TEST;

    // Reconstruct HD public key from xpubkey
    final hdPublicKey = dartsv.HDPublicKey.fromXpub(xpubkey);

    // Generate address based on purpose
    final String address;
    if (command.purpose == 'change') {
      address = cryptoService.generateChangeAddress(
        hdPublicKey,
        derivationIndex,
        network: networkType,
      );
    } else {
      // Default to receiving address
      address = cryptoService.generateReceivingAddress(
        hdPublicKey,
        derivationIndex,
        network: networkType,
      );
    }

    final event = AddressGeneratedEvent(
      eventId: const Uuid().v4(),
      walletId: command.walletId,
      timestamp: DateTime.now(),
      version: currentState.version + 1,
      address: address,
      derivationIndex: derivationIndex,
      label: command.label,
      purpose: command.purpose,
    );

    return [event];
  }

  List<Event> _handleUpdateAddressLabel(WalletState currentState, UpdateAddressLabelCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot update address label for non-existent wallet');
    }

    // Get current label for old value tracking
    final oldLabel = currentState.addresses[command.address];

    final event = AddressLabelUpdatedEvent(
      eventId: const Uuid().v4(),
      walletId: command.walletId,
      timestamp: DateTime.now(),
      version: currentState.version + 1,
      address: command.address,
      newLabel: command.newLabel,
      oldLabel: oldLabel,
    );

    return [event];
  }

  // ==========================================================================
  // UTXO LIFECYCLE COMMAND HANDLERS
  // ==========================================================================

  List<Event> _handleReceiveUTXO(WalletState currentState, ReceiveUTXOCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot receive UTXO for non-existent wallet');
    }

    final utxoKey = '${command.txid}:${command.vout}';

    // Business rule: Cannot receive duplicate UTXO
    if (currentState.utxos.containsKey(utxoKey)) {
      throw StateError('UTXO $utxoKey already exists in wallet');
    }

    // Business rule: Amount must be positive
    if (command.satoshis <= BigInt.zero) {
      throw ArgumentError('UTXO amount must be positive');
    }

    final event = UTXOReceivedEvent(
      walletId: command.walletId,
      txid: command.txid,
      vout: command.vout,
      satoshis: command.satoshis.toInt(),
      scriptPubKey: command.scriptPubKey,
      address: command.address,
      blockHeight: command.blockHeight,
      confirmations: command.confirmations,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  List<Event> _handleSpendUTXO(WalletState currentState, SpendUTXOCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot spend UTXO for non-existent wallet');
    }

    // Business rule: UTXO must exist and be available
    final utxo = currentState.utxos[command.utxoKey];
    if (utxo == null) {
      throw StateError('UTXO ${command.utxoKey} not found in wallet');
    }

    if (utxo.status != UTXOStatus.available) {
      throw StateError('UTXO ${command.utxoKey} is not available for spending (status: ${utxo.status})');
    }

    // Parse txid and vout from utxoKey
    final parts = command.utxoKey.split(':');
    final txid = parts[0];
    final vout = int.parse(parts[1]);

    final event = UTXOSpentEvent(
      walletId: command.walletId,
      txid: txid,
      vout: vout,
      spentInTxId: command.spendingTxId,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  List<Event> _handleUpdateUTXOConfirmations(WalletState currentState, UpdateUTXOConfirmationsCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot update UTXO confirmations for non-existent wallet');
    }

    // Business rule: UTXO must exist
    final utxo = currentState.utxos[command.utxoKey];
    if (utxo == null) {
      throw StateError('UTXO ${command.utxoKey} not found in wallet');
    }

    // Parse txid and vout from utxoKey
    final parts = command.utxoKey.split(':');
    final txid = parts[0];
    final vout = int.parse(parts[1]);

    // Business rule: Confirmations cannot decrease (except for reorgs)
    if (command.confirmations < (utxo.confirmations ?? 0) && command.confirmations > 0) {
      // This might be a reorg - allow it but log warning
      // TODO: Add proper logging in Phase 1D
    }

    final event = UTXOConfirmationUpdatedEvent(
      walletId: command.walletId,
      txid: txid,
      vout: vout,
      confirmations: command.confirmations,
      blockHeight: command.blockHeight ?? 0,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  // ==========================================================================
  // TRANSACTION MANAGEMENT COMMAND HANDLERS
  // ==========================================================================

  Future<List<Event>> _handleCreateTransaction(WalletState currentState, CreateTransactionCommand command) async {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot create transaction for non-existent wallet');
    }

    // Business rule: Must have outputs
    if (command.outputs.isEmpty) {
      throw ArgumentError('Transaction must have at least one output');
    }

    // Calculate total output amount
    final totalOutput = command.outputs.fold<BigInt>(
      BigInt.zero,
      (sum, output) => sum + output.satoshis,
    );

    // Get available UTXOs for spending
    final availableUtxos = currentState.utxos.values
        .where((utxo) => utxo.status == UTXOStatus.available)
        .toList();

    if (availableUtxos.isEmpty) {
      throw StateError('No available UTXOs for transaction');
    }

    // Simple UTXO selection: largest-first strategy
    availableUtxos.sort((a, b) => b.value.getValue().compareTo(a.value.getValue()));
    
    final selectedUtxos = <BitcoinUtxo>[];
    BigInt totalInput = BigInt.zero;
    final feeRate = command.feeRate ?? BigInt.one;
    
    // Estimate fee (approximately 180 bytes per input + 34 bytes per output + 10 bytes overhead)
    int estimatedSize() {
      return 10 + (selectedUtxos.length * 180) + (command.outputs.length * 34);
    }
    
    // Select UTXOs until we have enough to cover outputs + estimated fee
    for (final utxo in availableUtxos) {
      selectedUtxos.add(utxo);
      totalInput += utxo.value.getValue();
      
      final estimatedFee = feeRate * BigInt.from(estimatedSize());
      if (totalInput >= totalOutput + estimatedFee) {
        break;
      }
    }
    
    final fee = feeRate * BigInt.from(estimatedSize());
    
    // Check if we have enough to cover output + fee
    if (totalInput < totalOutput + fee) {
      throw StateError(
        'Insufficient funds: need ${totalOutput + fee} satoshis, have $totalInput satoshis'
      );
    }

    // For now, create a placeholder transaction hex
    // In a real implementation, this would use TransactionBuilder to build the unsigned transaction
    final rawTransaction = 'unsigned_tx_${command.transactionId}';

    // Reserve selected UTXOs
    final reserveEvents = selectedUtxos.map((utxo) {
      return UTXOReservedEvent(
        walletId: command.walletId,
        txid: utxo.txid,
        vout: utxo.vout,
        reservedByTxId: command.transactionId,
        reservationReason: 'Transaction creation',
        expiresAt: DateTime.now().add(Duration(hours: 1)),
        priority: 10, // High priority
        version: currentState.version + 1,
        timestamp: DateTime.now(),
      );
    }).toList();

    // Create transaction event
    final transactionEvent = TransactionCreatedEvent(
      walletId: command.walletId,
      txid: command.transactionId,
      rawHex: rawTransaction,
      totalInput: totalInput.toInt(),
      totalOutput: totalOutput.toInt(),
      fee: fee.toInt(),
      isIncoming: false, // Created transactions are outgoing
      isOutgoing: true,
      transactionMetadata: command.metadata,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    // Return both transaction creation and UTXO reservation events
    return [transactionEvent, ...reserveEvents];
  }

  List<Event> _handleSignTransaction(WalletState currentState, SignTransactionCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot sign transaction for non-existent wallet');
    }

    final event = TransactionSignedEvent(
      walletId: command.walletId,
      txid: command.transactionId,
      signedRawHex: command.rawTransaction, // This will be updated after signing
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  List<Event> _handleBroadcastTransaction(WalletState currentState, BroadcastTransactionCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot broadcast transaction for non-existent wallet');
    }

    final event = TransactionBroadcastEvent(
      walletId: command.walletId,
      txid: command.transactionId,
      broadcastResponse: 'broadcast_success', // Placeholder - will be set by ARC service
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  // ==========================================================================
  // UTXO RESERVATION COMMAND HANDLERS
  // ==========================================================================

  List<Event> _handleReserveUTXOs(WalletState currentState, ReserveUTXOsCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot reserve UTXOs for non-existent wallet');
    }

    // Convert utxoKeys to utxoIdentifiers format
    final utxoIdentifiers = command.utxoKeys.map((key) {
      final parts = key.split(':');
      return {'txid': parts[0], 'vout': int.parse(parts[1])};
    }).toList();

    final expiresAt = command.reservationDuration != null
        ? DateTime.now().add(command.reservationDuration!)
        : DateTime.now().add(Duration(minutes: 30));

    final event = UTXOReservationPlacedEvent(
      walletId: command.walletId,
      utxoIdentifiers: utxoIdentifiers,
      reservationId: command.reservationId,
      expiresAt: expiresAt,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  List<Event> _handleReleaseUTXOs(WalletState currentState, ReleaseUTXOsCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot release UTXOs for non-existent wallet');
    }

    // For now, create empty utxoIdentifiers since ReleaseUTXOsCommand only has reservationId
    // TODO: In Phase 1D, implement proper reservation tracking
    final utxoIdentifiers = <Map<String, dynamic>>[];

    final event = UTXOReservationReleasedEvent(
      walletId: command.walletId,
      reservationId: command.reservationId,
      utxoIdentifiers: utxoIdentifiers,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  List<Event> _handleReserveUTXO(WalletState currentState, ReserveUTXOCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot reserve UTXO for non-existent wallet');
    }

    // Business rule: UTXO must exist and be available (or have expired reservation)
    final utxo = currentState.utxos[command.utxoKey];
    if (utxo == null) {
      throw StateError('UTXO ${command.utxoKey} not found in wallet');
    }

    if (utxo.status == UTXOStatus.spent) {
      throw StateError('Cannot reserve spent UTXO ${command.utxoKey}');
    }

    if (utxo.status == UTXOStatus.reserved && !utxo.isReservationExpired) {
      // Check priority - higher priority can override lower priority
      final currentPriority = utxo.reservationPriority ?? 0;
      if (command.priority <= currentPriority) {
        throw StateError('UTXO ${command.utxoKey} is already reserved with higher or equal priority');
      }
    }

    // Parse txid and vout from utxoKey
    final parts = command.utxoKey.split(':');
    final txid = parts[0];
    final vout = int.parse(parts[1]);

    // Calculate expiration time
    final duration = command.reservationDuration ?? Duration(minutes: 30); // Default 30 minutes
    final expiresAt = DateTime.now().add(duration);

    final event = UTXOReservedEvent(
      walletId: command.walletId,
      txid: txid,
      vout: vout,
      reservedByTxId: command.reservedByTxId,
      reservationReason: command.reservationReason,
      expiresAt: expiresAt,
      priority: command.priority,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  List<Event> _handleReleaseUTXO(WalletState currentState, ReleaseUTXOCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot release UTXO for non-existent wallet');
    }

    // Business rule: UTXO must exist and be reserved
    final utxo = currentState.utxos[command.utxoKey];
    if (utxo == null) {
      throw StateError('UTXO ${command.utxoKey} not found in wallet');
    }

    if (utxo.status != UTXOStatus.reserved) {
      throw StateError('UTXO ${command.utxoKey} is not reserved and cannot be released');
    }

    // Parse txid and vout from utxoKey
    final parts = command.utxoKey.split(':');
    final txid = parts[0];
    final vout = int.parse(parts[1]);

    final event = UTXOReleasedEvent(
      walletId: command.walletId,
      txid: txid,
      vout: vout,
      releaseReason: command.releaseReason,
      wasExpired: utxo.isReservationExpired,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  List<Event> _handleRenewUTXOReservation(WalletState currentState, RenewUTXOReservationCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot renew UTXO reservation for non-existent wallet');
    }

    // Business rule: UTXO must exist and be reserved
    final utxo = currentState.utxos[command.utxoKey];
    if (utxo == null) {
      throw StateError('UTXO ${command.utxoKey} not found in wallet');
    }

    if (utxo.status != UTXOStatus.reserved) {
      throw StateError('UTXO ${command.utxoKey} is not reserved and cannot be renewed');
    }

    // Parse txid and vout from utxoKey
    final parts = command.utxoKey.split(':');
    final txid = parts[0];
    final vout = int.parse(parts[1]);

    final oldExpiresAt = utxo.reservationExpiresAt ?? DateTime.now();
    final newExpiresAt = oldExpiresAt.add(command.extensionDuration);

    final event = UTXOReservationRenewedEvent(
      walletId: command.walletId,
      txid: txid,
      vout: vout,
      newExpiresAt: newExpiresAt,
      oldExpiresAt: oldExpiresAt,
      renewalReason: command.renewalReason,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  List<Event> _handleCleanupExpiredReservations(WalletState currentState, CleanupExpiredReservationsCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot cleanup reservations for non-existent wallet');
    }

    final cutoffTime = command.cutoffTime ?? DateTime.now();
    final events = <Event>[];

    // Find expired reservations
    for (final utxo in currentState.utxos.values) {
      if (utxo.status == UTXOStatus.reserved && 
          utxo.reservationExpiresAt != null && 
          cutoffTime.isAfter(utxo.reservationExpiresAt!)) {
        
        // Create release event for expired reservation
        final event = UTXOReleasedEvent(
          walletId: command.walletId,
          txid: utxo.txid,
          vout: utxo.vout,
          releaseReason: 'Expired reservation cleanup',
          wasExpired: true,
          version: currentState.version + events.length + 1,
          timestamp: DateTime.now(),
        );
        
        events.add(event);
      }
    }

    return events;
  }

  // ==========================================================================
  // EVENT APPLICATION (FUNCTIONAL STATE TRANSITIONS)
  // ==========================================================================

  WalletState _applyWalletCreated(WalletState currentState, WalletCreatedEvent event) {
    return currentState.copyWithWallet(
      isCreated: true,
      name: event.walletName,
      rootAddress: event.rootAddress,
      metadata: event.walletMetadata ?? {},
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  WalletState _applyWalletConfigurationUpdated(WalletState currentState, WalletConfigurationUpdatedEvent event) {
    final newMetadata = Map<String, dynamic>.from(currentState.metadata);
    if (event.newMetadata != null) {
      newMetadata.addAll(event.newMetadata!);
    }

    return currentState.copyWithWallet(
      name: event.newName ?? currentState.name,
      metadata: newMetadata,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  WalletState _applyAddressGenerated(WalletState currentState, AddressGeneratedEvent event) {
    final newAddresses = Map<String, String?>.from(currentState.addresses);
    newAddresses[event.address] = event.label;

    return currentState.copyWithWallet(
      addresses: newAddresses,
      nextDerivationIndex: event.derivationIndex + 1,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  WalletState _applyAddressLabelUpdated(WalletState currentState, AddressLabelUpdatedEvent event) {
    final newAddresses = Map<String, String?>.from(currentState.addresses);
    newAddresses[event.address] = event.newLabel;

    return currentState.copyWithWallet(
      addresses: newAddresses,
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  WalletState _applyUTXOReceived(WalletState currentState, UTXOReceivedEvent event) {
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
    
    final newUtxos = Map<String, BitcoinUtxo>.from(currentState.utxos);
    newUtxos[utxoKey] = utxo;
    
    return currentState.copyWithWallet(
      utxos: newUtxos,
      version: event.version,
      lastModified: event.timestamp,
    ).recalculateBalances();
  }

  WalletState _applyUTXOSpent(WalletState currentState, UTXOSpentEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = currentState.utxos[utxoKey];
    if (utxo != null) {
      final spentUtxo = utxo.markSpent();
      final newUtxos = Map<String, BitcoinUtxo>.from(currentState.utxos);
      newUtxos[utxoKey] = spentUtxo;

      return currentState.copyWithWallet(
        utxos: newUtxos,
        version: event.version,
        lastModified: event.timestamp,
      ).recalculateBalances();
    }
    return currentState.copyWithWallet(version: event.version, lastModified: event.timestamp);
  }

  WalletState _applyUTXOConfirmationUpdated(WalletState currentState, UTXOConfirmationUpdatedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = currentState.utxos[utxoKey];
    if (utxo != null) {
      final updatedUtxo = utxo.updateConfirmations(
        blockHeight: event.blockHeight,
        confirmations: event.confirmations,
      );
      final newUtxos = Map<String, BitcoinUtxo>.from(currentState.utxos);
      newUtxos[utxoKey] = updatedUtxo;

      return currentState.copyWithWallet(
        utxos: newUtxos,
        version: event.version,
        lastModified: event.timestamp,
      ).recalculateBalances();
    }
    return currentState.copyWithWallet(version: event.version, lastModified: event.timestamp);
  }

  WalletState _applyTransactionCreated(WalletState currentState, TransactionCreatedEvent event) {
    // Transaction state is managed separately - just update version
    return currentState.copyWith(version: event.version);
  }

  WalletState _applyTransactionSigned(WalletState currentState, TransactionSignedEvent event) {
    // Transaction state is managed separately - just update version
    return currentState.copyWith(version: event.version);
  }

  WalletState _applyTransactionBroadcast(WalletState currentState, TransactionBroadcastEvent event) {
    // Transaction state is managed separately - just update version
    return currentState.copyWith(version: event.version);
  }

  WalletState _applyUTXOReservationPlaced(WalletState currentState, UTXOReservationPlacedEvent event) {
    // For now, simply update the state version - full reservation tracking in Phase 1D
    return currentState.copyWithWallet(
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  WalletState _applyUTXOReservationReleased(WalletState currentState, UTXOReservationReleasedEvent event) {
    // For now, simply update the state version - full reservation tracking in Phase 1D
    return currentState.copyWithWallet(
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  WalletState _applyUTXOReservationExpired(WalletState currentState, UTXOReservationExpiredEvent event) {
    // For now, simply update the state version - full reservation tracking in Phase 1D
    return currentState.copyWithWallet(
      version: event.version,
      lastModified: event.timestamp,
    );
  }

  WalletState _applyUTXOReserved(WalletState currentState, UTXOReservedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = currentState.utxos[utxoKey];
    
    if (utxo != null) {
      final reservedUtxo = utxo.copyWith(
        status: UTXOStatus.reserved,
        reservedByTxId: event.reservedByTxId,
        reservationExpiresAt: event.expiresAt,
        reservationPriority: event.priority,
        reservationReason: event.reservationReason,
        updatedAt: event.timestamp,
      );
      
      final newUtxos = Map<String, BitcoinUtxo>.from(currentState.utxos);
      newUtxos[utxoKey] = reservedUtxo;
      
      return currentState.copyWithWallet(
        utxos: newUtxos,
        version: event.version,
        lastModified: event.timestamp,
      ).recalculateBalances();
    }
    
    return currentState.copyWithWallet(version: event.version, lastModified: event.timestamp);
  }

  WalletState _applyUTXOReleased(WalletState currentState, UTXOReleasedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = currentState.utxos[utxoKey];
    
    if (utxo != null && utxo.status == UTXOStatus.reserved) {
      final releasedUtxo = utxo.releaseReservation();
      
      final newUtxos = Map<String, BitcoinUtxo>.from(currentState.utxos);
      newUtxos[utxoKey] = releasedUtxo;
      
      return currentState.copyWithWallet(
        utxos: newUtxos,
        version: event.version,
        lastModified: event.timestamp,
      ).recalculateBalances();
    }
    
    return currentState.copyWithWallet(version: event.version, lastModified: event.timestamp);
  }

  WalletState _applyUTXOReservationRenewed(WalletState currentState, UTXOReservationRenewedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = currentState.utxos[utxoKey];
    
    if (utxo != null && utxo.status == UTXOStatus.reserved) {
      final extensionDuration = event.newExpiresAt.difference(event.oldExpiresAt);
      final renewedUtxo = utxo.renewReservation(extensionDuration, reason: event.renewalReason);
      
      final newUtxos = Map<String, BitcoinUtxo>.from(currentState.utxos);
      newUtxos[utxoKey] = renewedUtxo;
      
      return currentState.copyWithWallet(
        utxos: newUtxos,
        version: event.version,
        lastModified: event.timestamp,
      ).recalculateBalances();
    }
    
    return currentState.copyWithWallet(version: event.version, lastModified: event.timestamp);
  }

  // ==========================================================================
  // BUSINESS RULE VALIDATION & UTILITY METHODS
  // ==========================================================================

  /// Check if UTXO can be spent (business rules)
  bool canSpendUTXO(WalletState state, String utxoKey) {
    final utxo = state.utxos[utxoKey];
    return utxo != null && utxo.status == UTXOStatus.available;
  }

  /// Check if UTXO can be reserved (business rules)
  bool canReserveUTXO(WalletState state, String utxoKey) {
    final utxo = state.utxos[utxoKey];
    return utxo != null && utxo.status == UTXOStatus.available;
  }

  /// Get available UTXOs for spending
  List<BitcoinUtxo> getAvailableUTXOs(WalletState state) {
    return state.utxos.values
        .where((utxo) => utxo.status == UTXOStatus.available)
        .toList();
  }

  /// Get UTXOs with specific reservation
  List<BitcoinUtxo> getReservedUTXOs(WalletState state, String reservationId) {
    return state.utxos.values
        .where((utxo) => utxo.reservedByTxId == reservationId)
        .toList();
  }

  /// Check if wallet has sufficient available balance
  bool hasSufficientBalance(WalletState state, BigInt requiredAmount) {
    return state.availableBalance >= requiredAmount;
  }

  /// Select UTXOs for a specific amount (simple first-fit algorithm)
  List<BitcoinUtxo> selectUTXOsForAmount(WalletState state, BigInt amount) {
    final availableUtxos = getAvailableUTXOs(state);
    availableUtxos.sort((a, b) => b.satoshis.compareTo(a.satoshis)); // Largest first

    final selected = <BitcoinUtxo>[];
    BigInt totalSelected = BigInt.zero;

    for (final utxo in availableUtxos) {
      selected.add(utxo);
      totalSelected += utxo.satoshis;
      
      if (totalSelected >= amount) {
        break;
      }
    }

    if (totalSelected < amount) {
      throw StateError('Insufficient funds: need $amount satoshis, have $totalSelected available');
    }

    return selected;
  }

} 