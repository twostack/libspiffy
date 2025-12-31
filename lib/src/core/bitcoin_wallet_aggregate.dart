
import 'package:eventador/eventador.dart';
import 'package:uuid/uuid.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:dactor/dactor.dart';

import '../models/wallet_event.dart';
import '../models/wallet_state.dart';
import '../models/bitcoin_utxo.dart';
import '../models/wallet_type.dart';
import '../services/crypto_service.dart';
import '../services/script_type_registry.dart';
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
    print('[BitcoinWalletAggregate] Constructor called for: $aggregateId');
    // Register handlers immediately upon construction
    registerHandlers();
  }
  
  // Capture sender at start of message processing for use in onCommandProcessed
  // This is needed because context.sender can be cleared by the time async processing completes
  // Use a Map keyed by command ID to handle concurrent message processing
  final Map<String, ActorRef> _capturedSenders = {};
  
  @override
  void preStart() {
    print('[BitcoinWalletAggregate] preStart() called for: $aggregateId');
    print('[BitcoinWalletAggregate]   Starting recovery process...');
    super.preStart();
    print('[BitcoinWalletAggregate]   preStart() completed (recovery is async)');
  }
  
  @override
  Future<void> onRecoveryComplete() async {
    await super.onRecoveryComplete();
    print('[BitcoinWalletAggregate] ✓ Recovery complete for: $aggregateId');
    print('[BitcoinWalletAggregate]   isInitialized: $isInitialized');
    print('[BitcoinWalletAggregate]   Ready to process commands');
  }
  
  @override
  Future<void> onMessage(dynamic message) async {
    // Capture sender at the START of message processing, keyed by command ID
    // This handles concurrent message processing where multiple commands
    // may be processed at the same time
    String? commandKey;
    if (message is Command && context.sender != null) {
      commandKey = message.commandId;
      _capturedSenders[commandKey] = context.sender!;
    }
    
    try {
      if (message is Command) {
        print('[BitcoinWalletAggregate] 📨 Command received: ${message.runtimeType}');
        print('   commandId: ${message.commandId}');
        print('   sender: ${context.sender?.toString() ?? "null"}');
        
        // Check if this is a duplicate command
        if (message is CreateWalletCommand) {
          print('   walletName: ${message.walletName}');
          print('   isInitialized: $isInitialized');
          try {
            print('   currentState.isCreated: ${currentState.isCreated}');
            print('   currentState.name: ${currentState.name}');
            if (currentState.isCreated) {
              print('   ⚠️  WARNING: Wallet already created, ignoring duplicate CreateWalletCommand');
              return;
            }
          } catch (e) {
            print('   ⚠️  Error accessing currentState: $e');
          }
        }
      } else {
        print('[BitcoinWalletAggregate] onMessage called: ${message.runtimeType}');
      }
      print('[BitcoinWalletAggregate] → Calling super.onMessage()...');
      await super.onMessage(message);
      print('[BitcoinWalletAggregate] ✓ super.onMessage() completed');
    } catch (e, stack) {
      print('[BitcoinWalletAggregate] ❌ FATAL ERROR in onMessage: $e');
      print('[BitcoinWalletAggregate] Stack trace: $stack');
      rethrow;
    } finally {
      // Clean up the captured sender for this specific command
      if (commandKey != null) {
        _capturedSenders.remove(commandKey);
      }
    }
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
    print('[BitcoinWalletAggregate] ✅ Command processed: ${command.runtimeType}');
    print('   Emitted ${events.length} event(s): ${events.map((e) => e.runtimeType).join(", ")}');
    await super.onCommandProcessed(command, events);
    
    // Only send responses if we're running in an actor system
    // (context is initialized by the actor system when spawned)
    if (!_isInActorSystem()) return;
    
    // Use captured sender (captured at start of onMessage) keyed by command ID
    // This handles concurrent message processing correctly
    final sender = _capturedSenders[command.commandId];
    if (sender == null) return;
    
    for (final event in events) {
      if (event is WalletCreatedEvent) {
        sender.tell(WalletCreatedResponse(
          walletId: event.walletId,
          rootAddress: event.rootAddress,
          success: true,
        ));
      } else if (event is AddressGeneratedEvent) {
        sender.tell(AddressGeneratedResponse(
          walletId: event.walletId,
          address: event.address,
          derivationIndex: event.derivationIndex,
          success: true,
          metadata: event.metadata, // Pass through metadata (e.g., invoiceId)
        ));
      } else if (event is ChannelAddressGeneratedEvent) {
        sender.tell(ChannelAddressGeneratedResponse(
          walletId: event.walletId,
          correlationId: event.correlationId,
          address: event.address,
          publicKey: event.publicKeyHex,
          derivationIndex: event.derivationIndex,
          success: true,
        ));
      } else if (event is TransactionCreatedEvent) {
        sender.tell(TransactionCreatedResponse(
          walletId: event.walletId,
          txid: event.txid,
          rawHex: event.rawHex,
          success: true,
        ));
      } else if (event is UTXOReceivedEvent) {
        sender.tell(UTXOReceivedResponse(
          walletId: event.walletId,
          txid: event.txid,
          vout: event.vout,
          success: true,
        ));
      } else if (event is TransactionImportedEvent) {
        sender.tell(TransactionRecordedResponse(
          walletId: event.walletId,
          txid: event.txid,
          success: true,
        ));
      }
    }
  }

  /// Send error responses when command processing fails
  /// Only active when aggregate is used as an actor in the actor system
  @override
  Future<void> onCommandFailure(Command command, dynamic error) async {
    print('[BitcoinWalletAggregate] ❌ Command failed: ${command.runtimeType}');
    print('   Error: $error');
    print('   Stack trace: ${StackTrace.current}');
    await super.onCommandFailure(command, error);
    
    // Only send responses if we're running in an actor system
    if (!_isInActorSystem()) return;
    
    // Use captured sender keyed by command ID (same reasoning as onCommandProcessed)
    final sender = _capturedSenders[command.commandId];
    if (sender == null) return;
    
    final errorMessage = error.toString();

    if (command is CreateWalletCommand) {
      sender.tell(WalletCreatedResponse(
        walletId: command.walletId,
        rootAddress: '',
        success: false,
        error: errorMessage,
      ));
    } else if (command is GenerateAddressCommand) {
      sender.tell(AddressGeneratedResponse(
        walletId: command.walletId,
        address: '',
        derivationIndex: 0,
        success: false,
        error: errorMessage,
        metadata: command.metadata, // Pass through metadata even on error
      ));
    } else if (command is GenerateChannelAddressCommand) {
      sender.tell(ChannelAddressGeneratedResponse(
        walletId: command.walletId,
        correlationId: command.correlationId,
        address: '',
        publicKey: '',
        derivationIndex: 0,
        success: false,
        error: errorMessage,
      ));
    } else if (command is CreateTransactionCommand) {
      sender.tell(TransactionCreatedResponse(
        walletId: command.walletId,
        txid: '',
        rawHex: '',
        success: false,
        error: errorMessage,
      ));
    } else if (command is BuildFundingTransactionCommand) {
      sender.tell(FundingTransactionBuiltResponse(
        walletId: command.walletId,
        correlationId: command.correlationId,
        channelId: command.channelId,
        fundingTxHex: '',
        fundingTxId: '',
        fundingOutputIndex: 0,
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
      case GenerateChannelAddressCommand:
        return await _handleGenerateChannelAddress(currentState, command as GenerateChannelAddressCommand);
      case UpdateAddressLabelCommand:
        return _handleUpdateAddressLabel(currentState, command as UpdateAddressLabelCommand);
      case RegisterDiscoveredAddressCommand:
        return _handleRegisterDiscoveredAddress(currentState, command as RegisterDiscoveredAddressCommand);
      case ReceiveUTXOCommand:
        return _handleReceiveUTXO(currentState, command as ReceiveUTXOCommand);
      case MarkUTXOAvailableCommand:
        return _handleMarkUTXOAvailable(currentState, command as MarkUTXOAvailableCommand);
      case RecordImportedTransactionCommand:
        return _handleRecordImportedTransaction(currentState, command as RecordImportedTransactionCommand);
      case RecordOutgoingTransactionCommand:
        return _handleRecordOutgoingTransaction(currentState, command as RecordOutgoingTransactionCommand);
      case ConfirmTransactionCommand:
        return _handleConfirmTransaction(currentState, command as ConfirmTransactionCommand);
      case SpendUTXOCommand:
        return _handleSpendUTXO(currentState, command as SpendUTXOCommand);
      case UpdateUTXOConfirmationsCommand:
        return _handleUpdateUTXOConfirmations(currentState, command as UpdateUTXOConfirmationsCommand);
      case CreateTransactionCommand:
        return await _handleCreateTransaction(currentState, command as CreateTransactionCommand);
      case SignTransactionCommand:
        return await _handleSignTransaction(currentState, command as SignTransactionCommand);
      case SignMultisigTransactionCommand:
        return await _handleSignMultisigTransaction(currentState, command as SignMultisigTransactionCommand);
      case BuildFundingTransactionCommand:
        return await _handleBuildFundingTransaction(currentState, command as BuildFundingTransactionCommand);
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
      case SplitUTXOsToBenfordCommand:
        return await _handleSplitUTXOsToBenford(currentState, command as SplitUTXOsToBenfordCommand);
      default:
        throw ArgumentError('Unknown command type: ${command.runtimeType}');
    }
  }

  /// Apply events to internal state (Eventador pattern)
  /// This method mutates _currentState directly as events are replayed or persisted.
  /// 
  /// Note: We override eventHandler instead of using the registry pattern.
  /// When overriding, we must call ensureStateInitialized() to replicate the base class
  /// initialization behavior that would normally happen before event application.
  @override
  void eventHandler(Event event) {
    // Ensure state is initialized before processing events
    // This is critical during recovery when the first event is replayed
    ensureStateInitialized();
    
    if (event is! WalletEvent) {
      throw ArgumentError('Expected WalletEvent, got ${event.runtimeType}');
    }

    switch (event.runtimeType) {
      case WalletCreatedEvent:
        _applyWalletCreated(event as WalletCreatedEvent);
        break;
      case WalletConfigurationUpdatedEvent:
        _applyWalletConfigurationUpdated(event as WalletConfigurationUpdatedEvent);
        break;
      case AddressGeneratedEvent:
        _applyAddressGenerated(event as AddressGeneratedEvent);
        break;
      case ChannelAddressGeneratedEvent:
        _applyChannelAddressGenerated(event as ChannelAddressGeneratedEvent);
        break;
      case AddressLabelUpdatedEvent:
        _applyAddressLabelUpdated(event as AddressLabelUpdatedEvent);
        break;
      case UTXOReceivedEvent:
        _applyUTXOReceived(event as UTXOReceivedEvent);
        break;
      case UTXOMarkedAvailableEvent:
        _applyUTXOMarkedAvailable(event as UTXOMarkedAvailableEvent);
        break;
      case UTXOSpentEvent:
        _applyUTXOSpent(event as UTXOSpentEvent);
        break;
      case UTXOConfirmationUpdatedEvent:
        _applyUTXOConfirmationUpdated(event as UTXOConfirmationUpdatedEvent);
        break;
      case TransactionCreatedEvent:
        _applyTransactionCreated(event as TransactionCreatedEvent);
        break;
      case TransactionSignedEvent:
        _applyTransactionSigned(event as TransactionSignedEvent);
        break;
      case TransactionBroadcastEvent:
        _applyTransactionBroadcast(event as TransactionBroadcastEvent);
        break;
      case UTXOReservationPlacedEvent:
        _applyUTXOReservationPlaced(event as UTXOReservationPlacedEvent);
        break;
      case UTXOReservationReleasedEvent:
        _applyUTXOReservationReleased(event as UTXOReservationReleasedEvent);
        break;
      case UTXOReservationExpiredEvent:
        _applyUTXOReservationExpired(event as UTXOReservationExpiredEvent);
        break;
      case UTXOReservedEvent:
        _applyUTXOReserved(event as UTXOReservedEvent);
        break;
      case UTXOReleasedEvent:
        _applyUTXOReleased(event as UTXOReleasedEvent);
        break;
      case UTXOReservationRenewedEvent:
        _applyUTXOReservationRenewed(event as UTXOReservationRenewedEvent);
        break;
      case WalletImportStartedEvent:
        _applyWalletImportStarted(event as WalletImportStartedEvent);
        break;
      case AddressDiscoveredEvent:
        _applyAddressDiscovered(event as AddressDiscoveredEvent);
        break;
      case TransactionImportedEvent:
        _applyTransactionImported(event as TransactionImportedEvent);
        break;
      case TransactionRecordedEvent:
        _applyTransactionRecorded(event as TransactionRecordedEvent);
        break;
      case TransactionConfirmedEvent:
        _applyTransactionConfirmed(event as TransactionConfirmedEvent);
        break;
      case WalletImportCompletedEvent:
        _applyWalletImportCompleted(event as WalletImportCompletedEvent);
        break;
      case WalletImportFailedEvent:
        _applyWalletImportFailed(event as WalletImportFailedEvent);
        break;
      case UTXOSplitInitiatedEvent:
        _applyUTXOSplitInitiated(event as UTXOSplitInitiatedEvent);
        break;
      case UTXOSplitCompletedEvent:
        _applyUTXOSplitCompleted(event as UTXOSplitCompletedEvent);
        break;
      case AllUTXOsSplitCompletedEvent:
        _applyAllUTXOsSplitCompleted(event as AllUTXOsSplitCompletedEvent);
        break;
      default:
        throw ArgumentError('Unknown event type: ${event.runtimeType}');
    }
  }

  // ==========================================================================
  // WALLET LIFECYCLE COMMAND HANDLERS
  // ==========================================================================

  Future<List<Event>> _handleCreateWallet(WalletState currentState, CreateWalletCommand command) async {
    print('[BitcoinWalletAggregate] _handleCreateWallet called for: ${command.walletId}');
    
    // Business rule: Cannot create wallet that already exists
    if (currentState.isCreated) {
      print('[BitcoinWalletAggregate]   ERROR: Wallet already exists');
      throw StateError('Wallet ${command.walletId} already exists');
    }

    // Determine wallet type and extract/generate keys
    final WalletType walletType;
    final String rootAddress;
    
    // Extract network type from metadata
    final metadata = command.walletMetadata ?? {};
    final networkTypeStr = metadata['network'] as String? ?? 'testnet';
    final networkType = networkTypeStr == 'mainnet' ? dartsv.NetworkType.MAIN : dartsv.NetworkType.TEST;

    if (command.wif != null && command.wif!.isNotEmpty) {
      // WIF WALLET: Single address from private key
      print('[BitcoinWalletAggregate]   Creating WIF wallet...');
      walletType = WalletType.wif;
      
      // Parse and validate WIF
      final privateKey = dartsv.SVPrivateKey.fromWIF(command.wif!);
      
      // Verify network type matches
      if (privateKey.networkType != networkType) {
        throw ArgumentError(
          'WIF network type does not match wallet network type'
        );
      }
      
      // Derive address from WIF key
      final publicKey = privateKey.publicKey;
      final address = publicKey.toAddress(networkType);
      rootAddress = address.toBase58();
      
      // Store WIF securely
      await secureStorage.setWIF(command.walletId, command.wif!);
      
      print('[BitcoinWalletAggregate]   ✓ WIF wallet created with address: $rootAddress');
      
    } else if (command.xpriv != null && command.xpriv!.isNotEmpty) {
      // XPRIV WALLET: HD derivation from extended private key
      print('[BitcoinWalletAggregate]   Creating XPRIV wallet...');
      walletType = WalletType.xpriv;
      
      // Parse and validate XPRIV
      final hdPrivateKey = dartsv.HDPrivateKey.fromXpriv(command.xpriv!);
      
      // Verify network type matches
      if (hdPrivateKey.networkType != networkType) {
        throw ArgumentError(
          'XPRIV network type does not match wallet network type'
        );
      }
      
      // Derive HD public key
      final hdPublicKey = cryptoService.deriveHDPublicKey(hdPrivateKey);
      
      // Generate root address (first receiving address at index 0)
      rootAddress = cryptoService.generateReceivingAddress(
        hdPublicKey,
        0,
        network: networkType,
      );
      
      // Store XPRIV and HD public key securely
      await secureStorage.setXPriv(command.walletId, command.xpriv!);
      await secureStorage.setString(
        'wallet_hdpubkey_${command.walletId}',
        hdPublicKey.xpubkey,
      );
      
      print('[BitcoinWalletAggregate]   ✓ XPRIV wallet created with root address: $rootAddress');
      
    } else {
      // HD WALLET: Generate or validate mnemonic
      print('[BitcoinWalletAggregate]   Creating HD wallet...');
      walletType = WalletType.hd;
      
      String mnemonic = command.mnemonic ?? '';

      //Force the caller to provide the mnemonic. Mnemonic validation
      //is responsibility of the caller.
      if (mnemonic.isEmpty) {
        throw ArgumentError('Invalid mnemonic phrase provided. Mnemonic is empty');
      }
      
      // Derive HD private key from mnemonic
      final hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(
        mnemonic,
        passphrase: command.passphrase ?? '',
        network: networkType,
      );
      
      // Derive HD public key
      final hdPublicKey = cryptoService.deriveHDPublicKey(hdPrivateKey);
      
      // Generate root address
      rootAddress = cryptoService.generateReceivingAddress(
        hdPublicKey,
        0,
        network: networkType,
      );
      
      // Store mnemonic and HD public key securely
      await secureStorage.setMnemonic(command.walletId, mnemonic);
      await secureStorage.setString(
        'wallet_hdpubkey_${command.walletId}',
        hdPublicKey.xpubkey,
      );
      
      print('[BitcoinWalletAggregate]   ✓ HD wallet created with root address: $rootAddress');
    }

    // Create WalletCreatedEvent with wallet type
    final event = WalletCreatedEvent(
      walletId: command.walletId,
      walletName: command.walletName,
      rootAddress: rootAddress,
      walletType: walletType,
      walletMetadata: {
        ...?command.walletMetadata,
        'network': networkTypeStr,
      },
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

    // For WIF wallets, always return the root address
    if (currentState.walletType == WalletType.wif) {
      // WIF wallets are single-address - return the existing address
      if (currentState.rootAddress == null) {
        throw StateError('WIF wallet has no root address');
      }
      
      print('[BitcoinWalletAggregate] WIF wallet - returning root address: ${currentState.rootAddress}');
      
      // Return AddressGeneratedEvent with same address and index 0
      final event = AddressGeneratedEvent(
        walletId: command.walletId,
        address: currentState.rootAddress!,
        derivationIndex: 0,
        label: command.label,
        purpose: command.purpose,
        metadata: command.metadata,
        timestamp: DateTime.now(),
        version: currentState.version + 1,
      );
      
      return [event];
    }

    // For HD and XPRIV wallets, derive new address
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
      metadata: command.metadata, // Preserve metadata (e.g., invoiceId from coordinator)
    );

    return [event];
  }

  /// Handle generating a channel address (includes public key)
  /// Used for payment channels which need both address and public key for multisig setup
  Future<List<Event>> _handleGenerateChannelAddress(
    WalletState currentState,
    GenerateChannelAddressCommand command,
  ) async {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot generate channel address for non-existent wallet');
    }

    // For WIF wallets, always return the root address
    if (currentState.walletType == WalletType.wif) {
      // WIF wallets are single-address - return the existing address
      if (currentState.rootAddress == null) {
        throw StateError('WIF wallet has no root address');
      }
      
      // Get public key for WIF wallet
      final wif = await secureStorage.getWIF(command.walletId);
      if (wif == null) {
        throw StateError('WIF not found for wallet ${command.walletId}');
      }
      final privateKey = dartsv.SVPrivateKey.fromWIF(wif);
      final publicKeyHex = privateKey.publicKey.toHex();
      
      print('[BitcoinWalletAggregate] WIF wallet - returning root address for channel: ${currentState.rootAddress}');
      
      // Return ChannelAddressGeneratedEvent with address + pubkey
      final event = ChannelAddressGeneratedEvent(
        walletId: command.walletId,
        correlationId: command.correlationId,
        address: currentState.rootAddress!,
        publicKeyHex: publicKeyHex,
        derivationIndex: 0,
        context: command.context,
        label: command.label,
        metadata: command.metadata,
        timestamp: DateTime.now(),
        version: currentState.version + 1,
      );
      
      return [event];
    }

    // For HD and XPRIV wallets, derive new address
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

    // Generate receiving address (channels always use receiving path m/0/{index})
    final address = cryptoService.generateReceivingAddress(
      hdPublicKey,
      derivationIndex,
      network: networkType,
    );

    // Derive the public key at this index
    final childKey = hdPublicKey.deriveChildKey("m/0/$derivationIndex");
    final publicKeyHex = childKey.publicKey.toHex();

    final event = ChannelAddressGeneratedEvent(
      eventId: const Uuid().v4(),
      walletId: command.walletId,
      correlationId: command.correlationId,
      timestamp: DateTime.now(),
      version: currentState.version + 1,
      address: address,
      publicKeyHex: publicKeyHex,
      derivationIndex: derivationIndex,
      context: command.context,
      label: command.label,
      metadata: command.metadata,
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

  List<Event> _handleRegisterDiscoveredAddress(WalletState currentState, RegisterDiscoveredAddressCommand command) {
    print('[BitcoinWalletAggregate] 📍 Handling RegisterDiscoveredAddressCommand for: ${command.address}');
    print('[BitcoinWalletAggregate]    Wallet: ${command.walletId}');
    print('[BitcoinWalletAggregate]    Index: ${command.derivationIndex}, Change: ${command.isChange}');
    
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      print('[BitcoinWalletAggregate]    ❌ ERROR: Wallet not created yet!');
      throw StateError('Cannot register discovered address for non-existent wallet');
    }

    // If address already exists in state, this is idempotent (no-op)
    if (currentState.addresses.containsKey(command.address)) {
      print('[BitcoinWalletAggregate]    ℹ️  Address ${command.address} already registered, skipping (idempotent)');
      return [];
    }

    print('[BitcoinWalletAggregate]    ✅ Creating AddressDiscoveredEvent...');
    final event = AddressDiscoveredEvent(
      eventId: const Uuid().v4(),
      walletId: command.walletId,
      timestamp: DateTime.now(),
      version: currentState.version + 1,
      address: command.address,
      derivationIndex: command.derivationIndex,
      isChange: command.isChange,
      transactionCount: command.transactionCount,
    );

    print('[BitcoinWalletAggregate]    ✅ AddressDiscoveredEvent created, returning to aggregate for persistence');
    return [event];
  }

  // ==========================================================================
  // UTXO LIFECYCLE COMMAND HANDLERS
  // ==========================================================================

  List<Event> _handleReceiveUTXO(WalletState currentState, ReceiveUTXOCommand command) {
    print('[BitcoinWalletAggregate] 📥 Handling ReceiveUTXOCommand: ${command.txid}:${command.vout} (${command.satoshis} sats)');

    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      print('[BitcoinWalletAggregate]    ❌ Wallet not created yet');
      throw StateError('Cannot receive UTXO for non-existent wallet');
    }

    final utxoKey = '${command.txid}:${command.vout}';

    // Business rule: Cannot receive duplicate UTXO
    if (currentState.utxos.containsKey(utxoKey)) {
      print('[BitcoinWalletAggregate]    ⚠️  UTXO $utxoKey already exists, skipping');
      throw StateError('UTXO $utxoKey already exists in wallet');
    }

    // Business rule: Amount must be positive
    if (command.satoshis <= BigInt.zero) {
      print('[BitcoinWalletAggregate]    ❌ Invalid amount: ${command.satoshis}');
      throw ArgumentError('UTXO amount must be positive');
    }

    // Use the initialStatus provided by the caller (defaults to pending)
    // The caller (e.g., wallet_manager_actor for SPV-validated UTXOs) is responsible
    // for determining the appropriate status based on merkle proof verification
    final initialStatus = command.initialStatus;

    print('[BitcoinWalletAggregate]    ✅ Creating UTXOReceivedEvent (status: $initialStatus, confirmations: ${command.confirmations})');
    final event = UTXOReceivedEvent(
      walletId: command.walletId,
      txid: command.txid,
      vout: command.vout,
      satoshis: command.satoshis.toInt(),
      scriptPubKey: command.scriptPubKey,
      address: command.address,
      initialStatus: initialStatus,
      blockHeight: command.blockHeight,
      confirmations: command.confirmations,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  List<Event> _handleMarkUTXOAvailable(WalletState currentState, MarkUTXOAvailableCommand command) {
    print('[BitcoinWalletAggregate] ✅ Handling MarkUTXOAvailableCommand: ${command.txid}:${command.vout}');
    
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot mark UTXO available for non-existent wallet');
    }
    
    final utxoKey = '${command.txid}:${command.vout}';
    final utxo = currentState.utxos[utxoKey];
    
    if (utxo == null) {
      throw StateError('UTXO $utxoKey not found');
    }
    
    if (utxo.status != UTXOStatus.pending) {
      // Already available or spent, no-op
      print('[BitcoinWalletAggregate]    ⚠️  UTXO $utxoKey is not pending (status: ${utxo.status}), skipping');
      return [];
    }
    
    print('[BitcoinWalletAggregate]    ✅ Creating UTXOMarkedAvailableEvent');
    return [UTXOMarkedAvailableEvent(
      walletId: command.walletId,
      txid: command.txid,
      vout: command.vout,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    )];
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

  List<Event> _handleRecordImportedTransaction(WalletState currentState, RecordImportedTransactionCommand command) {
    print('[BitcoinWalletAggregate] 📥 Handling RecordImportedTransactionCommand: ${command.txid}');
    
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot record transaction for non-existent wallet');
    }

    print('[BitcoinWalletAggregate]    ✅ Creating TransactionImportedEvent');
    
    // Emit TransactionImportedEvent with all the pre-calculated data from ImportActor
    final event = TransactionImportedEvent(
      walletId: command.walletId,
      txid: command.txid,
      rawHex: command.rawHex,
      blockHeight: command.blockHeight,
      bumpProof: command.bumpProofHex,
      totalOutputSats: command.totalOutputSats,
      numInputs: command.numInputs,
      numOutputs: command.numOutputs,
      txVersion: command.txVersion,
      txLockTime: command.txLockTime,
      walletReceivingAddresses: command.walletReceivingAddresses,
      walletReceivedSats: command.walletReceivedSats,
      totalInputSats: command.totalInputSats,
      sendingAddresses: command.sendingAddresses,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  /// Handle recording an outgoing transaction (payment created by this wallet)
  List<Event> _handleRecordOutgoingTransaction(WalletState currentState, RecordOutgoingTransactionCommand command) {
    print('[BitcoinWalletAggregate] 📤 Handling RecordOutgoingTransactionCommand: ${command.txid}');
    
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot record outgoing transaction for non-existent wallet');
    }

    final events = <Event>[];
    
    print('[BitcoinWalletAggregate]    ✅ Creating TransactionRecordedEvent (status: PENDING)');
    
    // Emit TransactionRecordedEvent
    final transactionEvent = TransactionRecordedEvent(
      walletId: command.walletId,
      txid: command.txid,
      rawHex: command.rawHex,
      totalInputSats: command.totalInputSats,
      totalOutputSats: command.totalOutputSats,
      fee: command.fee,
      numInputs: command.numInputs,
      numOutputs: command.numOutputs,
      txVersion: command.txVersion,
      txLockTime: command.txLockTime,
      spentUtxoKeys: command.spentUtxoKeys,
      recipientAddresses: command.recipientAddresses,
      paymentAmount: command.paymentAmount.toString(),
      changeAddress: command.changeAddress,
      changeAmount: command.changeAmount?.toString(),
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );
    events.add(transactionEvent);

    // CRITICAL: Mark all spent UTXOs as spent to prevent double-spending
    // This must happen when the outgoing transaction is recorded, not later
    print('[BitcoinWalletAggregate]    💸 Marking ${command.spentUtxoKeys.length} UTXOs as spent');
    for (final utxoKey in command.spentUtxoKeys) {
      final parts = utxoKey.split(':');
      if (parts.length != 2) {
        print('[BitcoinWalletAggregate]    ⚠️  Invalid UTXO key format: $utxoKey');
        continue;
      }
      final utxoTxid = parts[0];
      final utxoVout = int.tryParse(parts[1]);
      if (utxoVout == null) {
        print('[BitcoinWalletAggregate]    ⚠️  Invalid vout in UTXO key: $utxoKey');
        continue;
      }
      
      print('[BitcoinWalletAggregate]       → Emitting UTXOSpentEvent for $utxoKey');
      final spentEvent = UTXOSpentEvent(
        walletId: command.walletId,
        txid: utxoTxid,
        vout: utxoVout,
        spentInTxId: command.txid,
        version: currentState.version + events.length + 1,
        timestamp: DateTime.now(),
      );
      events.add(spentEvent);
    }
    print('[BitcoinWalletAggregate]    ✅ Emitted ${command.spentUtxoKeys.length} UTXOSpentEvent(s)');

    // If there's a change output, create a UTXO for it with pending status
    if (command.changeAddress != null && command.changeAmount != null && command.changeAmount! > BigInt.zero) {
      print('[BitcoinWalletAggregate]    💰 Change detected: ${command.changeAmount} sats to ${command.changeAddress}');
      
      // Parse transaction to find change output vout and scriptPubKey
      try {
        final tx = dartsv.Transaction.fromHex(command.rawHex);
        int? changeVout;
        String? changeScriptPubKey;
        
        // Find which output is the change (matches change address and amount)
        for (int i = 0; i < tx.outputs.length; i++) {
          final output = tx.outputs[i];
          if (output.satoshis == command.changeAmount) {
            // This might be the change output
            changeVout = i;
            changeScriptPubKey = output.script.toHex();
            print('[BitcoinWalletAggregate]       Found change at vout $i');
            break;
          }
        }
        
        if (changeVout != null && changeScriptPubKey != null) {
          print('[BitcoinWalletAggregate]    ✅ Creating UTXOReceivedEvent for change (status: PENDING)');
          final utxoEvent = UTXOReceivedEvent(
            walletId: command.walletId,
            txid: command.txid,
            vout: changeVout,
            satoshis: command.changeAmount!.toInt(),
            scriptPubKey: changeScriptPubKey,
            address: command.changeAddress!,
            blockHeight: null, // Not confirmed yet
            confirmations: 0,
            initialStatus: UTXOStatus.pending, // Change output starts as pending
            version: currentState.version + events.length + 1, // Dynamic version based on events count
            timestamp: DateTime.now(),
          );
          events.add(utxoEvent);
        } else {
          print('[BitcoinWalletAggregate]    ⚠️  Could not find change output in transaction');
        }
      } catch (e) {
        print('[BitcoinWalletAggregate]    ⚠️  Error parsing transaction for change output: $e');
      }
    }

    return events;
  }

  /// Handle confirming a pending transaction
  List<Event> _handleConfirmTransaction(WalletState currentState, ConfirmTransactionCommand command) {
    print('[BitcoinWalletAggregate] ✅ Handling ConfirmTransactionCommand: ${command.txid}');
    
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot confirm transaction for non-existent wallet');
    }

    print('[BitcoinWalletAggregate]    ✅ Creating TransactionConfirmedEvent');
    
    // Emit TransactionConfirmedEvent
    final event = TransactionConfirmedEvent(
      walletId: command.walletId,
      txid: command.txid,
      blockHeight: command.blockHeight,
      blockHash: command.blockHash,
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

    // Extract receiving addresses from outputs (where we're sending to)
    final receivingAddresses = command.outputs
        .map((output) => output.address)
        .toList();

    // Extract sending addresses from selected UTXOs (our addresses that we're spending from)
    final sendingAddresses = selectedUtxos
        .map((utxo) => utxo.address)
        .toList();

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

    // Create transaction event with all required fields
    final transactionEvent = TransactionCreatedEvent(
      walletId: command.walletId,
      txid: command.transactionId,
      rawHex: rawTransaction,
      totalInput: totalInput.toInt(),
      totalOutput: totalOutput.toInt(),
      fee: fee.toInt(),
      isIncoming: false, // Created transactions are outgoing
      isOutgoing: true,
      receivingAddresses: receivingAddresses, // Where we're sending to
      sendingAddresses: sendingAddresses, // Our addresses we're spending from
      txVersion: 1, // Standard Bitcoin transaction version
      txLockTime: 0, // No time lock by default
      transactionMetadata: command.metadata,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    // Return both transaction creation and UTXO reservation events
    return [transactionEvent, ...reserveEvents];
  }

  /// Retrieve the private key for a given address from secure storage
  /// Supports WIF, XPRIV, and HD wallets
  Future<dartsv.SVPrivateKey> _getPrivateKeyForAddress(
    String address,
    String walletId,
    WalletState currentState,
  ) async {
    final networkType = currentState.networkType == 'mainnet' 
        ? dartsv.NetworkType.MAIN 
        : dartsv.NetworkType.TEST;

    if (currentState.walletType == WalletType.wif) {
      // WIF wallet: single private key
      final wif = await secureStorage.getWIF(walletId);
      if (wif == null) {
        throw StateError('WIF not found for wallet $walletId');
      }
      return dartsv.SVPrivateKey.fromWIF(wif);
    } else if (currentState.walletType == WalletType.xpriv || 
               currentState.walletType == WalletType.hd) {
      // HD/XPRIV wallet: derive key for specific address
      int derivationIndex;
      
      // Check if this is the root address (m/0/0)
      if (address == currentState.rootAddress) {
        derivationIndex = 0; // Root address is always at index 0
      } else {
        // Find the derivation index for generated addresses
        final addressInfo = currentState.addresses[address];
        if (addressInfo == null) {
          throw StateError('Address $address not found in wallet state');
        }
        
        // Get derivation index from metadata (stored during address generation)
        derivationIndex = currentState.metadata['address_indices']?[address] ?? 0;
      }
      
      // Retrieve xpriv or mnemonic
      final xprivStr = await secureStorage.getXPriv(walletId);
      if (xprivStr != null) {
        final hdPrivateKey = dartsv.HDPrivateKey.fromXpriv(xprivStr);
        return await cryptoService.derivePrivateKey(
          hdPrivateKey,
          0, // account index
          derivationIndex,
          coinType: 236,
          isChange: false,
        );
      }
      
      // Try mnemonic if xpriv not available
      final mnemonic = await secureStorage.getMnemonic(walletId);
      if (mnemonic != null) {
        final hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(
          mnemonic,
          network: networkType,
        );
        return await cryptoService.derivePrivateKey(
          hdPrivateKey,
          0,
          derivationIndex,
          coinType: 236,
          isChange: false,
        );
      }
      
      throw StateError('No private key material found for wallet $walletId');
    } else {
      throw StateError('Unsupported wallet type: ${currentState.walletType}');
    }
  }

  Future<List<Event>> _handleSignTransaction(
    WalletState currentState,
    SignTransactionCommand command,
  ) async {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot sign transaction for non-existent wallet');
    }

    dartsv.Transaction? signedTx;

    try {
      // Parse unsigned transaction
      final unsignedTx = dartsv.Transaction.fromHex(command.rawTransaction);
      
      // For each UTXO being spent, sign the corresponding input
      for (int i = 0; i < command.utxoKeys.length; i++) {
        final utxoKey = command.utxoKeys[i];
        
        // Get UTXO details from state
        final utxo = currentState.utxos[utxoKey];
        if (utxo == null) {
          throw StateError('UTXO $utxoKey not found in wallet state');
        }
        
        // Get private key for this UTXO's address
        final privateKey = await _getPrivateKeyForAddress(
          utxo.address,
          command.walletId,
          currentState,
        );
        
        // Create TransactionOutput for the UTXO being spent
        final lockingScript = dartsv.SVScript.fromHex(utxo.scriptPubKey);
        final utxoOutput = dartsv.TransactionOutput(
          utxo.value.getValue(),
          lockingScript,
        );

        //Create the placeholder Tx Input that will hold the signature

        final registry = ScriptTypeRegistry();

        final utxoScript = dartsv.SVScript.fromHex(utxo.scriptPubKey);
        final scriptType = registry.identifyScriptType(utxoScript);

        if (scriptType?.toLowerCase() == 'p2pkh') {
          // Derive public key from the private key (no need to pass it in command)
          final publicKey = privateKey.publicKey;
          final unlocker = dartsv.P2PKHUnlockBuilder(publicKey);

          final txInput = dartsv.TransactionInput(
              utxo.txid,
              utxo.vout,
              dartsv.TransactionInput.MAX_SEQ_NUMBER,
              scriptBuilder: unlocker
          );

          //overwrite the input with our defined locking script builder
          unsignedTx.inputs[i] = txInput;
        }

        // Create signer and sign this input
        final signer = dartsv.TransactionSigner(
          dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value,
          privateKey,
        );

        // Sign the transaction at this input index
        signedTx = signer.sign(unsignedTx, utxoOutput, i);

        //perform a sanity check to see if we're correctly spending the utxo
        var scriptFlags = <dartsv.VerifyFlag>{}..addAll([
          dartsv.VerifyFlag.SIGHASH_FORKID,
          dartsv.VerifyFlag.UTXO_AFTER_GENESIS
        ]);
        final interpreter = dartsv.Interpreter();
        var inputIndex = 0;
        final scriptSig = signedTx.inputs[inputIndex].script;

        //run the input(s) through the interpreter to verify it
        interpreter.correctlySpends(
            scriptSig!, utxoScript, signedTx, inputIndex, scriptFlags,
            dartsv.Coin.ofSat(utxo.satoshis));
        /*end spend validation*/

      }



      if (signedTx == null ) {
        throw Exception("Failed to sign transaction");
      }
      
      // Serialize signed transaction
      final signedHex = signedTx.serialize();
      
      // IMPORTANT: Get the CORRECT txid from the signed transaction
      // The txid changes after signing because the scriptSig bytes are different
      final signedTxid = signedTx.id;
      
      // Send response if in actor system
      final sender = _capturedSenders[command.commandId];
      if (_isInActorSystem() && sender != null) {
        sender.tell(TransactionSignedResponse(
          walletId: command.walletId,
          txid: signedTxid, // Use signed txid, not unsigned command.transactionId
          signedHex: signedHex,
          success: true,
        ));
      }


      // Return TransactionSignedEvent
      final event = TransactionSignedEvent(
        walletId: command.walletId,
        txid: signedTxid, // Use signed txid, not unsigned command.transactionId
        signedRawHex: signedHex,
        version: currentState.version + 1,
        timestamp: DateTime.now(),
      );

      return [event];
    } catch (e, stackTrace) {
      print('Error signing transaction: $e');
      print('Stack trace: $stackTrace');
      
      // Send error response if in actor system
      final sender = _capturedSenders[command.commandId];
      if (_isInActorSystem() && sender != null) {
        sender.tell(TransactionSignedResponse(
          walletId: command.walletId,
          txid: command.transactionId,
          signedHex: '',
          success: false,
          error: e.toString(),
        ));
      }
      
      throw StateError('Failed to sign transaction: $e');
    }
  }

  /// Handle signing a multisig transaction input
  /// Used for payment channels where we sign one input of a 2-of-2 multisig
  /// 
  /// Uses dartsv's TransactionSigner which correctly handles sighash computation
  /// and ECDSA signing for multisig transactions.
  Future<List<Event>> _handleSignMultisigTransaction(
    WalletState currentState,
    SignMultisigTransactionCommand command,
  ) async {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot sign multisig transaction for non-existent wallet');
    }

    try {
      print('[BitcoinWalletAggregate] 🔏 Signing multisig transaction (using TransactionSigner)');
      print('[BitcoinWalletAggregate]    Input index: ${command.inputIndex}');
      print('[BitcoinWalletAggregate]    Prev out value: ${command.prevOutValue} sats');
      print('[BitcoinWalletAggregate]    Sighash type: 0x${command.sighashType.toRadixString(16)}');
      
      // Parse the transaction to sign
      final txToSign = dartsv.Transaction.fromHex(command.rawTransaction);
      print('[BitcoinWalletAggregate]    TX inputs: ${txToSign.inputs.length}');
      print('[BitcoinWalletAggregate]    TX outputs: ${txToSign.outputs.length}');
      print('[BitcoinWalletAggregate]    TX hex being signed: ${command.rawTransaction}');
      
      // Get private key at the specified derivation index
      final privateKey = await _getPrivateKeyAtIndex(
        command.walletId,
        command.derivationIndex,
        currentState,
      );
      print('[BitcoinWalletAggregate]    Private key derived at index ${command.derivationIndex}');
      print('[BitcoinWalletAggregate]    Public key: ${privateKey.publicKey.toHex()}');
      
      // Parse the redeem script (2-of-2 multisig locking script)
      final redeemScript = dartsv.SVScript.fromHex(command.redeemScriptHex);
      print('[BitcoinWalletAggregate]    Redeem script: ${command.redeemScriptHex}');
      
      // Create the UTXO that we're spending from (multisig output)
      final utxo = dartsv.TransactionOutput(
        BigInt.from(command.prevOutValue),
        redeemScript,
      );
      
      // IMPORTANT: Replace the input with one that has a P2MSUnlockBuilder
      // The default parser creates a DefaultUnlockBuilder which doesn't properly
      // build multisig scriptSigs from signatures.
      // (This is what TransactionBuilder.spendFromUtxoMap() does internally)
      final unlockBuilder = dartsv.P2MSUnlockBuilder();
      final originalInput = txToSign.inputs[command.inputIndex];
      final newInput = dartsv.TransactionInput(
        originalInput.prevTxnId,
        originalInput.prevTxnOutputIndex,
        originalInput.sequenceNumber,
        scriptBuilder: unlockBuilder,
      );
      txToSign.inputs[command.inputIndex] = newInput;
      
      // Use TransactionSigner - this handles sighash computation and signing correctly
      // This is the same method used in dartsv's multisig tests
      final signer = dartsv.TransactionSigner(command.sighashType, privateKey);
      signer.sign(txToSign, utxo, command.inputIndex); // Signature added to unlockBuilder
      
      // Extract our signature from the unlock builder (TransactionSigner added it there)
      if (unlockBuilder.signatures.isEmpty) {
        throw StateError('No signature added by TransactionSigner');
      }
      
      final ourSignature = unlockBuilder.signatures.last;
      final signatureHex = ourSignature.toTxFormat();
      
      print('[BitcoinWalletAggregate]    Signature (txFormat): $signatureHex');
      print('[BitcoinWalletAggregate]    Signature length: ${signatureHex.length ~/ 2} bytes');
      
      // NOTE: Individual signature verification is not possible here because:
      // - The signature is created for a 2-of-2 multisig (sighash includes full redeem script)
      // - A 1-of-1 test would use a different sighash and always fail
      // The full 2-of-2 verification happens in PaymentChannelCoordinator after both signatures
      // are combined using Interpreter.correctlySpends()
      
      print('[BitcoinWalletAggregate] ✅ Multisig signature created successfully');
      
      // Return the unsigned transaction hex (coordinator applies signatures)
      final txHex = dartsv.Transaction.fromHex(command.rawTransaction).serialize();
      final txid = dartsv.Transaction.fromHex(command.rawTransaction).id;
      
      // Send response if in actor system
      final sender = _capturedSenders[command.commandId];
      if (_isInActorSystem() && sender != null) {
        sender.tell(MultisigTransactionSignedResponse(
          walletId: command.walletId,
          txid: txid,
          originalTransactionId: command.transactionId, // Pass back for correlation
          signedHex: txHex,  // Return unsigned TX - coordinator applies signatures
          signatureHex: signatureHex,  // Our signature for the multisig
          success: true,
        ));
      }
      
      // Return empty event list - we don't need to persist multisig signatures
      // The channel coordinator tracks the transaction state
      return [];
      
    } catch (e, stackTrace) {
      print('[BitcoinWalletAggregate] ❌ Error signing multisig transaction: $e');
      print(stackTrace);
      
      // Send error response if in actor system
      final sender = _capturedSenders[command.commandId];
      if (_isInActorSystem() && sender != null) {
        sender.tell(MultisigTransactionSignedResponse(
          walletId: command.walletId,
          txid: command.transactionId,
          originalTransactionId: command.transactionId, // Pass back for correlation
          signedHex: '',
          signatureHex: '',
          success: false,
          error: e.toString(),
        ));
      }
      
      throw StateError('Failed to sign multisig transaction: $e');
    }
  }

  /// Handle building and signing a funding transaction for payment channels.
  /// 
  /// This creates a 2-of-2 multisig output funded by the client's P2PKH UTXOs.
  /// All signing happens within this aggregate, keeping private keys secure.
  Future<List<Event>> _handleBuildFundingTransaction(
    WalletState currentState,
    BuildFundingTransactionCommand command,
  ) async {
    if (!currentState.isCreated) {
      throw StateError('Cannot build funding transaction for non-existent wallet');
    }

    try {
      print('[BitcoinWalletAggregate] Building funding TX for channel ${command.channelId}');
      print('[BitcoinWalletAggregate]   UTXOs in wallet state: ${currentState.utxos.length}');
      
      // Parse public keys
      final clientPubKey = dartsv.SVPublicKey.fromHex(command.clientPubKeyHex);
      final serverPubKey = dartsv.SVPublicKey.fromHex(command.serverPubKeyHex);
      final changeAddress = dartsv.Address.fromBase58(command.changeAddressBase58);
      
      // Get available UTXOs and sort by value descending (largest first for efficient selection)
      final availableUtxos = currentState.utxos.values
          .where((u) => u.isAvailable && !u.isSpent && !u.isReserved)
          .toList()
        ..sort((a, b) => b.value.getValue().compareTo(a.value.getValue()));
      
      print('[BitcoinWalletAggregate]   Available UTXOs: ${availableUtxos.length}');
      
      if (availableUtxos.isEmpty) {
        throw StateError('No available UTXOs for funding');
      }
      
      final fundingAmount = BigInt.from(command.fundingAmountSats);
      
      // Fee estimation constants
      const txOverhead = 10;
      const p2pkhInputSize = 148;
      const p2pkhOutputSize = 34;
      const feePerKb = 100;
      
      // Select UTXOs using greedy algorithm (largest first)
      final selectedUtxos = <BitcoinUtxo>[];
      var selectedTotal = BigInt.zero;
      
      for (final utxo in availableUtxos) {
        selectedUtxos.add(utxo);
        selectedTotal += utxo.value.getValue();
        
        // Estimate fee for current selection
        final estimatedSize = txOverhead + 
            (selectedUtxos.length * p2pkhInputSize) + 
            p2pkhOutputSize + // multisig output
            p2pkhOutputSize;  // change output
        final estimatedFee = BigInt.from((estimatedSize * feePerKb) ~/ 1000);
        
        // Check if we have enough (with some buffer for fee variance)
        if (selectedTotal >= fundingAmount + estimatedFee) {
          break;
        }
      }
      
      // Final fee calculation with selected UTXOs
      final estimatedSize = txOverhead + 
          (selectedUtxos.length * p2pkhInputSize) + 
          p2pkhOutputSize + p2pkhOutputSize;
      final fee = BigInt.from((estimatedSize * feePerKb) ~/ 1000);
      
      if (selectedTotal < fundingAmount + fee) {
        throw StateError('Insufficient funds: need ${fundingAmount + fee}, have $selectedTotal');
      }
      
      print('[BitcoinWalletAggregate]   Selected ${selectedUtxos.length} UTXOs (total: $selectedTotal sats)');
      
      final changeAmount = selectedTotal - fundingAmount - fee;
      
      // Create 2-of-2 multisig locking script
      final msLockBuilder = dartsv.P2MSLockBuilder(
        [clientPubKey, serverPubKey],
        2,
        sorting: true,
      );
      
      // Build transaction using dartsv's TransactionBuilder API
      final txBuilder = dartsv.TransactionBuilder();
      
      // Add multisig output first (will be at index 0)
      txBuilder.spendToLockBuilder(msLockBuilder, fundingAmount);
      
      // Add change output if above dust threshold
      if (changeAmount > BigInt.from(546)) {
        txBuilder.sendChangeToPKH(changeAddress);
      }
      
      // Add inputs with signers
      // Each UTXO may be from a different address with a different derivation index,
      // so we need to get the correct private key for each input
      final sighashType = dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value;
      
      for (final utxo in selectedUtxos) {
        final utxoAddress = dartsv.Address.fromBase58(utxo.address);
        final lockingScript = dartsv.P2PKHLockBuilder.fromAddress(utxoAddress).getScriptPubkey();
        
        final outpoint = dartsv.TransactionOutpoint(
          utxo.txid,
          utxo.vout,
          utxo.value.getValue(),
          lockingScript,
        );
        
        // Get the correct private key for THIS specific UTXO's address
        final utxoPrivateKey = utxo.derivationIndex != null
            ? await _getPrivateKeyAtIndex(command.walletId, utxo.derivationIndex!, currentState)
            : await _getPrivateKeyForAddress(utxo.address, command.walletId, currentState);
        
        final signer = dartsv.TransactionSigner(sighashType, utxoPrivateKey);
        
        txBuilder.spendFromOutpointWithSigner(
          signer,
          outpoint,
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
          dartsv.P2PKHUnlockBuilder(utxoPrivateKey.publicKey),
        );
      }
      
      txBuilder
          .withFeePerKb(feePerKb)
          .withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);
      
      // Build (already signed via spendFromOutpointWithSigner)
      final signedTx = txBuilder.build(false);
      
      final fundingTxHex = signedTx.serialize();

      print('Funding TX Hex: $fundingTxHex');
      final fundingTxId = signedTx.id;
      
      print('[BitcoinWalletAggregate] Funding TX built: $fundingTxId');
      
      // Capture spent UTXO keys for proper wallet bookkeeping
      final spentUtxoKeys = selectedUtxos.map((u) => '${u.txid}:${u.vout}').toList();
      
      // CRITICAL: Reserve the selected UTXOs immediately to prevent double-spend
      // These will be marked as spent after broadcast, or released on failure
      var reserveVersion = currentState.version;
      final reserveEvents = selectedUtxos.map((utxo) {
        reserveVersion++;
        return UTXOReservedEvent(
          walletId: command.walletId,
          txid: utxo.txid,
          vout: utxo.vout,
          reservedByTxId: fundingTxId,
          reservationReason: 'Payment channel funding: ${command.channelId}',
          expiresAt: DateTime.now().add(Duration(hours: 1)),
          priority: 10, // High priority
          version: reserveVersion,
          timestamp: DateTime.now(),
        );
      }).toList();
      
      print('[BitcoinWalletAggregate]   Reserved ${reserveEvents.length} UTXOs for funding TX');
      
      // CRITICAL: Find the actual multisig output index
      // TransactionBuilder.sendChangeToPKH() may reorder outputs, putting change at index 0
      // We need to find where the multisig output actually ended up
      int multisigOutputIndex = -1;
      int? actualChangeOutputIdx;
      
      for (int i = 0; i < signedTx.outputs.length; i++) {
        final output = signedTx.outputs[i];
        if (output.satoshis == fundingAmount) {
          multisigOutputIndex = i;
          print('[BitcoinWalletAggregate]   Found multisig output at index $i (${output.satoshis} sats)');
        } else {
          actualChangeOutputIdx = i;
          print('[BitcoinWalletAggregate]   Found change output at index $i (${output.satoshis} sats)');
        }
      }
      
      if (multisigOutputIndex == -1) {
        throw StateError('Could not find multisig output in funding transaction');
      }
      
      // Determine if change output was actually added (above dust threshold)
      final hasChange = changeAmount > BigInt.from(546);
      final actualChangeAmount = hasChange ? changeAmount.toInt() : 0;
      
      // Calculate totals
      final totalInputSats = selectedTotal.toInt();
      final totalOutputSats = fundingAmount.toInt() + actualChangeAmount;
      
      // Send response with full transaction details for wallet bookkeeping
      final sender = _capturedSenders[command.commandId];
      if (_isInActorSystem() && sender != null) {
        sender.tell(FundingTransactionBuiltResponse(
          walletId: command.walletId,
          correlationId: command.correlationId,
          channelId: command.channelId,
          fundingTxHex: fundingTxHex,
          fundingTxId: fundingTxId,
          fundingOutputIndex: multisigOutputIndex,  // Use actual index, not hardcoded 0
          success: true,
          spentUtxoKeys: spentUtxoKeys,
          changeAddress: hasChange ? command.changeAddressBase58 : null,
          changeAmount: actualChangeAmount > 0 ? actualChangeAmount : null,
          changeOutputIndex: actualChangeOutputIdx,  // Use actual index found above
          fee: fee.toInt(),
          totalInputSats: totalInputSats,
          totalOutputSats: totalOutputSats,
        ));
      }
      
      // Return reservation events to prevent double-spend of selected UTXOs
      // The coordinator will mark as spent after broadcast via RecordOutgoingTransactionCommand
      return reserveEvents;
      
    } catch (e, stackTrace) {
      print('[BitcoinWalletAggregate] Error building funding transaction: $e');
      print(stackTrace);
      
      final sender = _capturedSenders[command.commandId];
      if (_isInActorSystem() && sender != null) {
        sender.tell(FundingTransactionBuiltResponse(
          walletId: command.walletId,
          correlationId: command.correlationId,
          channelId: command.channelId,
          fundingTxHex: '',
          fundingTxId: '',
          fundingOutputIndex: 0,
          success: false,
          error: e.toString(),
        ));
      }
      
      throw StateError('Failed to build funding transaction: $e');
    }
  }

  /// Get private key at a specific derivation index
  /// Used for multisig signing where we know the exact index
  Future<dartsv.SVPrivateKey> _getPrivateKeyAtIndex(
    String walletId,
    int derivationIndex,
    WalletState currentState,
  ) async {
    final networkType = currentState.networkType == 'mainnet' 
        ? dartsv.NetworkType.MAIN 
        : dartsv.NetworkType.TEST;

    if (currentState.walletType == WalletType.wif) {
      // WIF wallet: single private key
      final wif = await secureStorage.getWIF(walletId);
      if (wif == null) {
        throw StateError('WIF not found for wallet $walletId');
      }
      return dartsv.SVPrivateKey.fromWIF(wif);
    } else if (currentState.walletType == WalletType.xpriv || 
               currentState.walletType == WalletType.hd) {
      // HD/XPRIV wallet: derive key at specific index
      final xprivStr = await secureStorage.getXPriv(walletId);
      if (xprivStr != null) {
        final hdPrivateKey = dartsv.HDPrivateKey.fromXpriv(xprivStr);
        // Use simple m/0/{index} path: accountIndex=0, addressIndex=derivationIndex
        return await cryptoService.derivePrivateKey(
          hdPrivateKey,
          0, // accountIndex
          derivationIndex, // addressIndex
          isChange: false,
        );
      }

      // Try mnemonic if xpriv not found
      final mnemonic = await secureStorage.getMnemonic(walletId);
      if (mnemonic != null) {
        final hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(
          mnemonic,
          network: networkType,
        );
        // Use simple m/0/{index} path: accountIndex=0, addressIndex=derivationIndex
        return await cryptoService.derivePrivateKey(
          hdPrivateKey,
          0, // accountIndex
          derivationIndex, // addressIndex
          isChange: false,
        );
      }

      throw StateError('No xpriv or mnemonic found for wallet $walletId');
    } else {
      throw StateError('Unsupported wallet type: ${currentState.walletType}');
    }
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
    // Note: Automated cleanup runs every 5 minutes via WalletManagerActor timer
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
  // EVENT APPLICATION (IMPERATIVE STATE MUTATIONS)
  // ==========================================================================
  // These methods mutate _currentState directly as required by Eventador's eventHandler pattern

  void _applyWalletCreated(WalletCreatedEvent event) {
    currentState.isCreated = true;
    currentState.name = event.walletName;
    currentState.rootAddress = event.rootAddress;
    currentState.walletType = event.walletType;
    currentState.networkType = event.walletMetadata?['network'] ?? 'testnet';
    currentState.timestamp = event.timestamp;
    currentState.nextDerivationIndex = 1; // Root address is index 0
    currentState.metadata.clear();
    if (event.walletMetadata != null) {
      currentState.metadata.addAll(event.walletMetadata!);
    }
    
    // Initialize address_indices map for tracking derivation indices
    currentState.metadata['address_indices'] ??= <String, int>{};
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
    
    // Add root address to addresses map with derivation index 0
    if (event.rootAddress.isNotEmpty) {
      currentState.addresses[event.rootAddress] = null;
      (currentState.metadata['address_indices'] as Map<String, int>)[event.rootAddress] = 0;
    }
  }

  void _applyWalletConfigurationUpdated(WalletConfigurationUpdatedEvent event) {
    if (event.newName != null) {
      currentState.name = event.newName!;
    }
    if (event.newMetadata != null) {
      currentState.metadata.addAll(event.newMetadata!);
    }
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyAddressGenerated(AddressGeneratedEvent event) {
    currentState.addresses[event.address] = event.label;
    currentState.nextDerivationIndex = event.derivationIndex + 1;
    
    // Store the derivation index for key derivation during signing
    currentState.metadata['address_indices'] ??= <String, int>{};
    (currentState.metadata['address_indices'] as Map<String, int>)[event.address] = event.derivationIndex;
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyChannelAddressGenerated(ChannelAddressGeneratedEvent event) {
    // Store address and label
    currentState.addresses[event.address] = event.label;
    currentState.nextDerivationIndex = event.derivationIndex + 1;
    
    // Store the derivation index for key derivation during signing
    currentState.metadata['address_indices'] ??= <String, int>{};
    (currentState.metadata['address_indices'] as Map<String, int>)[event.address] = event.derivationIndex;
    
    // Store public key for channel operations (in metadata to avoid changing state schema)
    currentState.metadata['channel_pubkeys'] ??= <String, String>{};
    (currentState.metadata['channel_pubkeys'] as Map<String, String>)[event.address] = event.publicKeyHex;
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyAddressLabelUpdated(AddressLabelUpdatedEvent event) {
    currentState.addresses[event.address] = event.newLabel;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyUTXOReceived(UTXOReceivedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = BitcoinUtxo.create(
      txid: event.txid,
      vout: event.vout,
      satoshis: BigInt.from(event.satoshis),
      scriptPubKey: event.scriptPubKey,
      address: event.address,
      blockHeight: event.blockHeight,
      confirmations: event.confirmations ?? 0,
      status: event.initialStatus, // Use the status from the event
    );
    
    currentState.utxos[utxoKey] = utxo;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
    _recalculateBalances();
  }

  void _applyUTXOMarkedAvailable(UTXOMarkedAvailableEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = currentState.utxos[utxoKey];
    
    if (utxo != null) {
      currentState.utxos[utxoKey] = utxo.markAvailable();
      currentState.version = event.version;
      currentState.lastModified = event.timestamp;
      _recalculateBalances();
    }
  }

  void _applyUTXOSpent(UTXOSpentEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = currentState.utxos[utxoKey];
    if (utxo != null) {
      final spentUtxo = utxo.markSpent();
      currentState.utxos[utxoKey] = spentUtxo;
    }
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
    _recalculateBalances();
  }

  void _applyUTXOConfirmationUpdated(UTXOConfirmationUpdatedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = currentState.utxos[utxoKey];
    if (utxo != null) {
      final updatedUtxo = utxo.updateConfirmations(
        blockHeight: event.blockHeight,
        confirmations: event.confirmations,
      );
      currentState.utxos[utxoKey] = updatedUtxo;
    }
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
    _recalculateBalances();
  }

  void _applyTransactionCreated(TransactionCreatedEvent event) {
    // Transaction state is managed separately - just update version
    currentState.version = event.version;
  }

  void _applyTransactionSigned(TransactionSignedEvent event) {
    // Transaction state is managed separately - just update version
    currentState.version = event.version;
  }

  void _applyTransactionBroadcast(TransactionBroadcastEvent event) {
    // Transaction state is managed separately - just update version
    currentState.version = event.version;
  }

  void _applyUTXOReservationPlaced(UTXOReservationPlacedEvent event) {
    // For now, simply update the state version - full reservation tracking in Phase 1D
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyUTXOReservationReleased(UTXOReservationReleasedEvent event) {
    // For now, simply update the state version - full reservation tracking in Phase 1D
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyUTXOReservationExpired(UTXOReservationExpiredEvent event) {
    // For now, simply update the state version - full reservation tracking in Phase 1D
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyUTXOReserved(UTXOReservedEvent event) {
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
      
      currentState.utxos[utxoKey] = reservedUtxo;
      _recalculateBalances();
    }
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyUTXOReleased(UTXOReleasedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = currentState.utxos[utxoKey];
    
    if (utxo != null && utxo.status == UTXOStatus.reserved) {
      final releasedUtxo = utxo.releaseReservation();
      currentState.utxos[utxoKey] = releasedUtxo;
      _recalculateBalances();
    }
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyUTXOReservationRenewed(UTXOReservationRenewedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = currentState.utxos[utxoKey];
    
    if (utxo != null && utxo.status == UTXOStatus.reserved) {
      final extensionDuration = event.newExpiresAt.difference(event.oldExpiresAt);
      final renewedUtxo = utxo.renewReservation(extensionDuration, reason: event.renewalReason);
      currentState.utxos[utxoKey] = renewedUtxo;
      _recalculateBalances();
    }
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  // ==========================================================================
  // WALLET IMPORT EVENT HANDLERS
  // ==========================================================================

  void _applyWalletImportStarted(WalletImportStartedEvent event) {
    // Track import in metadata
    currentState.metadata['importInProgress'] = true;
    currentState.metadata['importStartedAt'] = event.timestamp.toIso8601String();
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyAddressDiscovered(AddressDiscoveredEvent event) {
    // Add discovered address to wallet
    currentState.addresses[event.address] = 'Imported (${event.isChange ? 'change' : 'receive'} #${event.derivationIndex})';
    
    // Store the derivation index for key derivation during signing
    currentState.metadata['address_indices'] ??= <String, int>{};
    (currentState.metadata['address_indices'] as Map<String, int>)[event.address] = event.derivationIndex;
    
    // Update next derivation index if this is higher
    if (event.derivationIndex >= currentState.nextDerivationIndex) {
      currentState.nextDerivationIndex = event.derivationIndex + 1;
    }
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyTransactionImported(TransactionImportedEvent event) {
    // Store imported transaction in metadata (for audit/history)
    final importedTxs = currentState.metadata['importedTransactions'] as List? ?? [];
    importedTxs.add({
      'txid': event.txid,
      'blockHeight': event.blockHeight,
      'importedAt': event.timestamp.toIso8601String(),
    });
    currentState.metadata['importedTransactions'] = importedTxs;
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyTransactionRecorded(TransactionRecordedEvent event) {
    // Store outgoing transaction in metadata (for audit/history)
    // Status starts as PENDING - will be updated to CONFIRMED when recipient accepts
    final outgoingTxs = currentState.metadata['outgoingTransactions'] as List? ?? [];
    outgoingTxs.add({
      'txid': event.txid,
      'status': 'pending',
      'recipientAddresses': event.recipientAddresses,
      'paymentAmount': event.paymentAmount,
      'fee': event.fee,
      'recordedAt': event.timestamp.toIso8601String(),
    });
    currentState.metadata['outgoingTransactions'] = outgoingTxs;
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyTransactionConfirmed(TransactionConfirmedEvent event) {
    // Update transaction status from PENDING to CONFIRMED
    final outgoingTxs = currentState.metadata['outgoingTransactions'] as List? ?? [];
    final txIndex = outgoingTxs.indexWhere((tx) => tx['txid'] == event.txid);
    if (txIndex >= 0) {
      outgoingTxs[txIndex]['status'] = 'confirmed';
      outgoingTxs[txIndex]['blockHeight'] = event.blockHeight;
      outgoingTxs[txIndex]['blockHash'] = event.blockHash;
      outgoingTxs[txIndex]['confirmedAt'] = event.timestamp.toIso8601String();
    }
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyWalletImportCompleted(WalletImportCompletedEvent event) {
    // Mark import as complete
    currentState.metadata['importInProgress'] = false;
    currentState.metadata['importCompletedAt'] = event.timestamp.toIso8601String();
    currentState.metadata['totalImportedAddresses'] = event.totalAddresses;
    currentState.metadata['totalImportedTransactions'] = event.totalTransactions;
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyWalletImportFailed(WalletImportFailedEvent event) {
    // Mark import as failed
    currentState.metadata['importInProgress'] = false;
    currentState.metadata['importFailedAt'] = event.timestamp.toIso8601String();
    currentState.metadata['importError'] = event.error;
    if (event.partialProgress != null) {
      currentState.metadata['importPartialProgress'] = event.partialProgress;
    }
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }
  
  /// Helper method to recalculate wallet balances after UTXO changes
  void _recalculateBalances() {
    BigInt confirmed = BigInt.zero;
    BigInt unconfirmed = BigInt.zero;
    BigInt reserved = BigInt.zero;

    for (final utxo in currentState.utxos.values) {
      if (utxo.status == UTXOStatus.spent) continue;

      if (utxo.status == UTXOStatus.reserved) {
        reserved += utxo.satoshis;
      } else if ((utxo.confirmations ?? 0) >= 6) {
        confirmed += utxo.satoshis;
      } else {
        unconfirmed += utxo.satoshis;
      }
    }

    currentState.confirmedBalance = dartsv.Coin.ofSat(confirmed);
    currentState.unconfirmedBalance = dartsv.Coin.ofSat(unconfirmed);
    currentState.reservedBalance = dartsv.Coin.ofSat(reserved);
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

  // ==========================================================================
  // PRIVACY FEATURE HANDLERS - Benford UTXO Splitting
  // ==========================================================================

  /// Handle command to split UTXOs according to Benford's Law distribution
  /// 
  /// This handler only validates the request and emits an event.
  /// The actual orchestration (transaction building, signing, broadcasting)
  /// is performed by BenfordCoordinatorActor, which listens to the
  /// UTXOSplitInitiatedEvent and handles all external service calls.
  Future<List<Event>> _handleSplitUTXOsToBenford(
    WalletState currentState,
    SplitUTXOsToBenfordCommand command,
  ) async {
    print('[BitcoinWalletAggregate] Handling SplitUTXOsToBenfordCommand');
    
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot split UTXOs for non-existent wallet');
    }

    // Get all available UTXOs
    final availableUtxos = getAvailableUTXOs(currentState);
    if (availableUtxos.isEmpty) {
      throw StateError('No available UTXOs to split');
    }

    print('[BitcoinWalletAggregate] Found ${availableUtxos.length} available UTXOs to split');

    // Emit single event - BenfordCoordinatorActor will handle orchestration
    return [
      UTXOSplitInitiatedEvent(
        walletId: command.walletId,
        utxoKeysToSplit: availableUtxos.map((u) => u.key).toList(),
        targetUtxoCount: command.targetUtxoCount,
        feeRate: command.feeRate ?? BigInt.one,
        version: currentState.version + 1,
        timestamp: DateTime.now(),
      ),
    ];
  }

  // ==========================================================================
  // EVENT APPLICATION METHODS - Benford Splitting
  // ==========================================================================

  void _applyUTXOSplitInitiated(UTXOSplitInitiatedEvent event) {
    // This event is informational - triggers BenfordCoordinatorActor orchestration
    // No direct state changes in the aggregate
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyUTXOSplitCompleted(UTXOSplitCompletedEvent event) {
    // State changes are handled by separate CQRS commands:
    // - SpendUTXOCommand marks source UTXO as spent
    // - ReceiveUTXOCommand adds new UTXOs
    // - RecordOutgoingTransactionCommand records transaction
    // This event is primarily for UI/reporting purposes
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyAllUTXOsSplitCompleted(AllUTXOsSplitCompletedEvent event) {
    // This event is informational - final summary
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

} 