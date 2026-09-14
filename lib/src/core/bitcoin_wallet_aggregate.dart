
import 'package:convert/convert.dart';
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:dactor/dactor.dart';

import '../models/wallet_event.dart';
import '../models/wallet_state.dart';
import '../models/bitcoin_utxo.dart';
import '../models/wallet_type.dart';
import '../services/crypto_service.dart';
import '../plugin/plugin_registry.dart';
import '../services/script_type_registry.dart';
import '../storage/secure_storage.dart';
import '../actors/wallet_messages.dart';
import 'wallet_commands.dart';
import 'wallet_events.dart';
import '../utils/network_name.dart';

/// Bitcoin wallet aggregate root implementing event sourcing
/// 
/// This aggregate manages all wallet state changes through events,
/// ensuring consistency and providing full audit trail for all operations.
/// Follows the Eventador AggregateRoot pattern with functional state management.
class BitcoinWalletAggregate extends AggregateRoot<WalletState> {
  final _log = Logger('BitcoinWalletAggregate');
  final CryptoService cryptoService;
  final SecureStorage secureStorage;

  BitcoinWalletAggregate({
    required String aggregateId,
    required String aggregateType,
    required EventStore eventStore,
    required this.cryptoService,
    required this.secureStorage,
  }) : super(aggregateId: aggregateId, aggregateType: aggregateType, eventStore: eventStore) {
    // Register handlers immediately upon construction
    registerHandlers();
  }
  
  // Capture sender at start of message processing for use in onCommandProcessed
  // This is needed because context.sender can be cleared by the time async processing completes
  // Use a Map keyed by command ID to handle concurrent message processing
  final Map<String, ActorRef> _capturedSenders = {};

  /// Command ids whose failure reply has been sent. Eventador calls
  /// [onCommandFailure] twice for one failed command when the aggregate runs
  /// as an actor (from AggregateRoot.commandHandler and again from
  /// PersistentActor's command loop); without this the caller got every
  /// failure reply twice.
  final Set<String> _failureReplied = {};
  
  @override
  Future<void> preStart() async {
    await super.preStart();
  }
  
  @override
  Future<void> onRecoveryComplete() async {
    await super.onRecoveryComplete();
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
        
        // Check if this is a duplicate command
        if (message is CreateWalletCommand) {
          try {
            if (currentState.isCreated) {
              // Answer deterministically instead of dropping the message:
              // a silent drop left an asking caller to time out.
              final sender = commandKey == null ? null : _capturedSenders[commandKey];
              sender?.tell(WalletCreatedResponse(
                walletId: message.walletId,
                rootAddress: currentState.rootAddress ?? '',
                success: false,
                error: 'Wallet ${message.walletId} already exists',
              ));
              return;
            }
          } catch (e) {
            _log.warning('Failed to check duplicate CreateWalletCommand: $e');
          }
        }
      } else {
      }
      await super.onMessage(message);
    } catch (e, stack) {
      rethrow;
    } finally {
      // Clean up the captured sender for this specific command
      if (commandKey != null) {
        _capturedSenders.remove(commandKey);
        _failureReplied.remove(commandKey);
      }
    }
  }

  /// Create initial empty wallet state
  @override
  WalletState createInitialState() {
    return WalletState.empty(aggregateId);
  }

  // ==========================================================================
  // SNAPSHOTS (audit 2026-09-14 M6)
  // ==========================================================================
  //
  // The snapshot is WalletState.toMap() (the base getSnapshotState). Restoring
  // it must yield the state a full replay would: the round-trip tests in
  // test/core/aggregate_snapshot_restore_test.dart compare the two.

  /// Rebuilds the wallet state from a snapshot written by [getSnapshotState]
  /// (after the event store's CBOR round trip).
  @override
  Future<WalletState> restoreStateFromMap(Map<String, dynamic> map, int sequenceNumber) async {
    final state = WalletState.fromMap(map);
    if (state.walletId != aggregateId) {
      throw StateError('Snapshot at $sequenceNumber belongs to wallet ${state.walletId}, '
          'not $aggregateId');
    }
    // The round trip hands back untyped maps; the derivation records are
    // read as typed maps.
    state.metadata[_addressIndicesKey] = _typedEntries<int>(state.metadata[_addressIndicesKey]);
    state.metadata[_addressChainsKey] = _typedEntries<bool>(state.metadata[_addressChainsKey]);
    // Balances are derived data: recompute them once from the restored UTXOs
    // rather than trusting the cached values in the snapshot.
    _setFullBalances(state);
    return state;
  }

  /// A snapshot that cannot be restored must fail recovery. Eventador's
  /// default falls back to the empty state and then replays only the events
  /// after the snapshot, silently dropping the wallet's history.
  @override
  Future<void> onSnapshotRestorationFailure(
      dynamic snapshotData, int sequenceNumber, dynamic error) async {
    _log.severe('Wallet $aggregateId: snapshot at $sequenceNumber cannot be restored: $error');
    throw StateError('Wallet $aggregateId: snapshot at $sequenceNumber cannot be restored '
        '(refusing to recover from the events after it alone): $error');
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

    // A reply prepared by the command handler (signed or funding
    // transaction) is released only now that its events are journaled.
    final awaitingPersist = _repliesAwaitingPersist.remove(command.commandId);

    // Send actor system responses. Key material is already in secure storage:
    // _handleCreateWallet writes it before the event is persisted (audit H4).
    if (_isInActorSystem()) {
      final sender = _capturedSenders[command.commandId];
      if (sender != null) {
        if (awaitingPersist != null) {
          sender.tell(awaitingPersist);
        }
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
              publicKeyHex: event.publicKeyHex,
              metadata: event.metadata,
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
          } else if (event is UTXOReservedEvent) {
            sender.tell(UTXOReservedResponse(
              walletId: event.walletId,
              utxoKey: '${event.txid}:${event.vout}',
              reservedByTxId: event.reservedByTxId,
              success: true,
            ));
          }
        }
      }
    }

    // The WalletCreatedEvent is journaled, so the key material written in
    // _handleCreateWallet is now committed: stop tracking it for rollback.
    if (command is CreateWalletCommand) {
      _keyMaterialAwaitingPersist.remove(command.commandId);
    }
  }

  /// Success replies whose payload exists only once the command's events are
  /// persisted, keyed by command id: the signed transaction
  /// ([TransactionSignedResponse]) and the funding transaction
  /// ([FundingTransactionBuiltResponse]). [onCommandProcessed] sends them;
  /// [onCommandFailure] discards them, so a failed persist never hands the
  /// caller a transaction the journal did not record (audit 2026-09-14 M5).
  final Map<String, Message> _repliesAwaitingPersist = {};

  /// Wallet ids whose key material has been written to secure storage for a
  /// CreateWalletCommand (keyed by command id) whose WalletCreatedEvent has
  /// not yet been persisted. If persistence fails the secrets are removed
  /// again so a retried CreateWalletCommand starts from a clean slate.
  final Map<String, String> _keyMaterialAwaitingPersist = {};

  /// Every secure-storage key that [_storeKeyMaterial] may write for a wallet.
  static List<String> _keyMaterialKeys(String walletId) => [
        'wallet_wif_$walletId',
        'wallet_xpriv_$walletId',
        'wallet_xpub_$walletId',
        'wallet_mnemonic_$walletId',
        _passphraseKey(walletId),
        _hdPubKeyKey(walletId),
      ];

  /// Store key material in secure storage BEFORE the WalletCreatedEvent is
  /// persisted (audit 2026-09-14 H4). Writing the secrets after the event
  /// (and after the success reply) meant a failed secure-storage write left
  /// a wallet whose events exist but that can never sign. Now a failed write
  /// fails the command with no event journaled, and a failed persist removes
  /// the secrets again (see [onCommandFailure]).
  Future<void> _storeKeyMaterial(CreateWalletCommand command, String? hdPublicKeyXpub) async {
    final walletId = command.walletId;

    if (command.wif != null && command.wif!.isNotEmpty) {
      await secureStorage.setWIF(walletId, command.wif!);
    } else if (command.xpriv != null && command.xpriv!.isNotEmpty) {
      await secureStorage.setXPriv(walletId, command.xpriv!);
      if (hdPublicKeyXpub != null) {
        await secureStorage.setString(_hdPubKeyKey(walletId), hdPublicKeyXpub);
      }
    } else if (command.xpub != null && command.xpub!.isNotEmpty) {
      await secureStorage.setXPub(walletId, command.xpub!);
      await secureStorage.setString(_hdPubKeyKey(walletId), command.xpub!);
    } else if (command.mnemonic != null && command.mnemonic!.isNotEmpty) {
      await secureStorage.setMnemonic(walletId, command.mnemonic!);
      // The passphrase is part of the seed: addresses were derived with it
      // at creation, so signing must use it too or the keys will not match.
      if (command.passphrase != null && command.passphrase!.isNotEmpty) {
        await secureStorage.setString(
          _passphraseKey(walletId),
          command.passphrase!,
        );
      }
      if (hdPublicKeyXpub != null) {
        await secureStorage.setString(_hdPubKeyKey(walletId), hdPublicKeyXpub);
      }
    }
  }

  /// Best-effort removal of everything [_storeKeyMaterial] wrote for
  /// [walletId]. Failures are logged, never thrown: this runs on an error
  /// path and the original error must reach the caller.
  Future<void> _removeKeyMaterial(String walletId, {required Object cause}) async {
    for (final key in _keyMaterialKeys(walletId)) {
      try {
        await secureStorage.delete(key);
      } catch (e) {
        _log.severe(
            'Wallet $walletId: could not remove $key from secure storage after '
            'creation failed ($cause); remove it manually before retrying: $e');
      }
    }
  }

  static String _passphraseKey(String walletId) => 'wallet_passphrase_$walletId';
  static String _hdPubKeyKey(String walletId) => 'wallet_hdpubkey_$walletId';

  /// BIP39 passphrase recorded at creation, or '' when none was given.
  Future<String> _mnemonicPassphrase(String walletId) async =>
      await secureStorage.getString(_passphraseKey(walletId)) ?? '';

  /// Send error responses when command processing fails
  /// Only active when aggregate is used as an actor in the actor system
  @override
  Future<void> onCommandFailure(Command command, dynamic error) async {
    await super.onCommandFailure(command, error);

    // The events behind a prepared success reply were not journaled.
    _repliesAwaitingPersist.remove(command.commandId);

    // Key material was written before the WalletCreatedEvent; if the event
    // could not be persisted, take the secrets back out (best effort).
    final pendingWalletId = _keyMaterialAwaitingPersist.remove(command.commandId);
    if (pendingWalletId != null) {
      _log.warning('Wallet $pendingWalletId: creation failed after key material '
          'was stored; removing it again: $error');
      await _removeKeyMaterial(pendingWalletId, cause: error ?? 'unknown');
    }

    // Only send responses if we're running in an actor system
    if (!_isInActorSystem()) {
      return;
    }
    
    // Use captured sender keyed by command ID (same reasoning as onCommandProcessed)
    final sender = _capturedSenders[command.commandId];
    if (sender == null) {
      return;
    }
    if (!_failureReplied.add(command.commandId)) {
      return;
    }

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
    } else if (command is ReserveUTXOCommand) {
      sender.tell(UTXOReservedResponse(
        walletId: command.walletId,
        utxoKey: command.utxoKey,
        reservedByTxId: command.reservedByTxId,
        success: false,
        error: errorMessage,
      ));
    } else if (command is ReserveUTXOsCommand) {
      sender.tell(UTXOReservedResponse(
        walletId: command.walletId,
        utxoKey: command.utxoKeys.join(','),
        reservedByTxId: command.reservationId,
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
    } else if (command is SignTransactionCommand) {
      sender.tell(TransactionSignedResponse(
        walletId: command.walletId,
        txid: command.transactionId,
        signedHex: '',
        success: false,
        error: errorMessage,
      ));
    } else if (command is SignMultisigTransactionCommand) {
      sender.tell(MultisigTransactionSignedResponse(
        walletId: command.walletId,
        txid: '',
        originalTransactionId: command.transactionId,
        signedHex: '',
        signatureHex: '',
        success: false,
        error: errorMessage,
      ));
    } else if (command is SignInputCommand) {
      sender.tell(InputSignedResponse(
        walletId: command.walletId,
        commandId: command.commandId,
        inputIndex: command.inputIndex,
        signatureHex: '',
        publicKeyHex: '',
        success: false,
        error: errorMessage,
      ));
    } else if (command is SplitUTXOsToBenfordCommand) {
      sender.tell(SplitUTXOsResponse(
        walletId: command.walletId,
        success: false,
        error: errorMessage,
      ));
    } else {
      // Fallback for any unhandled command - send a generic error response
      sender.tell(LocalMessage(
        payload: {
          'error': errorMessage,
          'command': command.runtimeType.toString(),
        },
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
    // DEBUG: Log command routing information
    
    switch (command.runtimeType) {
      case CreateWalletCommand:
        return await _handleCreateWallet(currentState, command as CreateWalletCommand);
      case DeleteWalletCommand:
        return _handleDeleteWallet(currentState, command as DeleteWalletCommand);
      case UpdateWalletConfigurationCommand:
        return _handleUpdateConfiguration(currentState, command as UpdateWalletConfigurationCommand);
      case GenerateAddressCommand:
        return await _handleGenerateAddress(currentState, command as GenerateAddressCommand);
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
      case UpdateTransactionStatusCommand:
        return _handleUpdateTransactionStatus(currentState, command as UpdateTransactionStatusCommand);
      case RevertTransactionConfirmationCommand:
        return _handleRevertTransactionConfirmation(currentState, command as RevertTransactionConfirmationCommand);
      case SpendUTXOCommand:
        return _handleSpendUTXO(currentState, command as SpendUTXOCommand);
      case UpdateUTXOConfirmationsCommand:
        return _handleUpdateUTXOConfirmations(currentState, command as UpdateUTXOConfirmationsCommand);
      case SignTransactionCommand:
        return await _handleSignTransaction(currentState, command as SignTransactionCommand);
      case SignMultisigTransactionCommand:
        return await _handleSignMultisigTransaction(currentState, command as SignMultisigTransactionCommand);
      case SignInputCommand:
        return await _handleSignInput(currentState, command as SignInputCommand);
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
      case WalletDeletedEvent:
        _applyWalletDeleted(event as WalletDeletedEvent);
        break;
      case WalletConfigurationUpdatedEvent:
        _applyWalletConfigurationUpdated(event as WalletConfigurationUpdatedEvent);
        break;
      case AddressGeneratedEvent:
        _applyAddressGenerated(event as AddressGeneratedEvent);
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
      case TransactionStatusUpdatedEvent:
        // Status update is projection-only — no aggregate state change needed
        break;
      case TransactionConfirmationRevertedEvent:
        _applyTransactionConfirmationReverted(event as TransactionConfirmationRevertedEvent);
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
    
    // Business rule: Cannot create wallet that already exists
    if (currentState.isCreated) {
      throw StateError('Wallet ${command.walletId} already exists');
    }

    // Determine wallet type and extract/generate keys
    final WalletType walletType;
    final String rootAddress;
    
    // Extract network type from metadata
    final metadata = command.walletMetadata ?? {};
    // Accept 'main'/'mainnet' (and 'test'/'testnet'); persist the canonical
    // spelling so every later reader resolves the same network.
    final networkTypeStr = NetworkName.canonical(metadata['network'] as String?);
    final networkType = NetworkName.toDartsv(networkTypeStr);

    // Account xpub: goes to secure storage only, never into the event (KM-8)
    String? hdPublicKeyXpub;

    if (command.wif != null && command.wif!.isNotEmpty) {
      // WIF WALLET: Single address from private key
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

    } else if (command.xpriv != null && command.xpriv!.isNotEmpty) {
      // XPRIV WALLET: HD derivation from extended private key
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
      hdPublicKeyXpub = hdPublicKey.xpubkey;

      // Generate root address (first receiving address at index 0)
      rootAddress = cryptoService.generateReceivingAddress(
        hdPublicKey,
        0,
        network: networkType,
      );

    } else if (command.xpub != null && command.xpub!.isNotEmpty) {
      // XPUB WALLET: Watch-only from extended public key
      walletType = WalletType.xpub;

      // Parse and validate XPUB
      final hdPublicKey = dartsv.HDPublicKey.fromXpub(command.xpub!);

      // Verify network type matches
      if (hdPublicKey.networkType != networkType) {
        throw ArgumentError(
          'XPUB network type does not match wallet network type'
        );
      }

      // Generate root address
      rootAddress = cryptoService.generateReceivingAddress(
        hdPublicKey,
        0,
        network: networkType,
      );

      // For XPUB wallets, the xpub itself is the HD public key
      hdPublicKeyXpub = command.xpub!;

    } else {
      // HD WALLET: Generate or validate mnemonic
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
      hdPublicKeyXpub = hdPublicKey.xpubkey;

      // Generate root address
      rootAddress = cryptoService.generateReceivingAddress(
        hdPublicKey,
        0,
        network: networkType,
      );

    }

    // Store the secrets BEFORE the event is persisted. If this throws the
    // command fails and nothing is journaled; if the later persist fails,
    // onCommandFailure removes what was written here.
    _keyMaterialAwaitingPersist[command.commandId] = command.walletId;
    try {
      await _storeKeyMaterial(command, hdPublicKeyXpub);
    } catch (e) {
      // A partial write (e.g. mnemonic stored, passphrase not) must not
      // survive: onCommandFailure removes it via the tracking entry.
      _log.severe('Wallet ${command.walletId}: secure storage write failed; '
          'wallet not created: $e');
      rethrow;
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
      
      
      // Get public key if requested
      String? publicKeyHex;
      if (command.includePublicKey) {
        final wif = await secureStorage.getWIF(command.walletId);
        if (wif == null) {
          throw StateError('WIF not found for wallet ${command.walletId}');
        }
        final privateKey = dartsv.SVPrivateKey.fromWIF(wif);
        publicKeyHex = privateKey.publicKey.toHex();
      }
      
      // Return AddressGeneratedEvent with same address and index 0
      final event = AddressGeneratedEvent(
        walletId: command.walletId,
        address: currentState.rootAddress!,
        derivationIndex: 0,
        label: command.label,
        purpose: command.purpose,
        publicKeyHex: publicKeyHex,
        correlationId: command.getCorrelationId(),
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
    final networkType = NetworkName.toDartsv(currentState.networkType);

    // Reconstruct HD public key from xpubkey
    final hdPublicKey = dartsv.HDPublicKey.fromXpub(xpubkey);

    // Generate address based on purpose
    final String address;
    final int derivationPath; // 0 for receiving, 1 for change
    if (command.purpose == changePurpose) {
      address = cryptoService.generateChangeAddress(
        hdPublicKey,
        derivationIndex,
        network: networkType,
      );
      derivationPath = 1;
    } else {
      // Default to receiving address
      address = cryptoService.generateReceivingAddress(
        hdPublicKey,
        derivationIndex,
        network: networkType,
      );
      derivationPath = 0;
    }

    // Derive public key if requested
    String? publicKeyHex;
    if (command.includePublicKey) {
      final childKey = hdPublicKey.deriveChildKey("m/$derivationPath/$derivationIndex");
      publicKeyHex = childKey.publicKey.toHex();
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
      publicKeyHex: publicKeyHex,
      correlationId: command.getCorrelationId(),
      metadata: command.metadata, // Preserve metadata (e.g., invoiceId from coordinator)
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
    
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot register discovered address for non-existent wallet');
    }

    // If address already exists in state, this is idempotent (no-op)
    if (currentState.addresses.containsKey(command.address)) {
      return [];
    }

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

    // Use the initialStatus provided by the caller (defaults to pending)
    // The caller (e.g., wallet_manager_actor for SPV-validated UTXOs) is responsible
    // for determining the appropriate status based on merkle proof verification
    final initialStatus = command.initialStatus;

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
      derivationIndex: command.derivationIndex,
      pluginMetadata: command.pluginMetadata,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  List<Event> _handleMarkUTXOAvailable(WalletState currentState, MarkUTXOAvailableCommand command) {
    
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot mark UTXO available for non-existent wallet');
    }
    
    final utxoKey = '${command.txid}:${command.vout}';
    final utxo = currentState.utxos[utxoKey];
    
    if (utxo == null) {
      throw StateError('UTXO $utxoKey not found');
    }
    
    // A pending UTXO that is reserved still needs the promotion: the
    // reservation stays, and its release then restores `available` (M4).
    final pendingUnderReservation = utxo.status == UTXOStatus.reserved &&
        utxo.statusBeforeReservation == UTXOStatus.pending;
    if (utxo.status != UTXOStatus.pending && !pendingUnderReservation) {
      // Already available or spent, no-op
      return [];
    }
    
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

    // A spend supersedes a reservation: the payment coordinator reserves the
    // inputs, records the transaction with deferSpend, and ARC marks them
    // spent once the transaction is seen on the network. Rejecting reserved
    // UTXOs here meant that spend never applied, and the reservation expiry
    // later returned an on-chain-spent coin to `available`.
    final spendable = utxo.status == UTXOStatus.available ||
        (utxo.status == UTXOStatus.reserved &&
            (utxo.reservedByTxId == null ||
                utxo.reservedByTxId == command.spendingTxId));
    if (!spendable) {
      throw StateError('UTXO ${command.utxoKey} is not available for spending (status: ${utxo.status}, reservedBy: ${utxo.reservedByTxId})');
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
    
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot record transaction for non-existent wallet');
    }

    
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
    
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot record outgoing transaction for non-existent wallet');
    }

    final events = <Event>[];

    // Phase 4: when the TX was signed externally (plugin's
    // CallbackTransactionSigner or similar), emit a TransactionSignedEvent
    // here to fill the audit-trail gap. Wallet-internal flows that came
    // through SignTransactionCommand already emitted this event; plugin
    // flows had no canonical signing record until now.
    if (command.preSigned) {
      events.add(TransactionSignedEvent(
        walletId: command.walletId,
        txid: command.txid,
        signedRawHex: command.rawHex,
        version: currentState.version + events.length + 1,
        timestamp: DateTime.now(),
        metadata: command.signerMetadata,
      ));
    }

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
      version: currentState.version + events.length + 1,
      timestamp: DateTime.now(),
    );
    events.add(transactionEvent);

    // Mark spent UTXOs — unless deferSpend is true (UTXOs stay reserved,
    // ARCActor will issue SpendUTXOCommand when tx reaches SEEN_ON_NETWORK)
    if (command.deferSpend) {
      _log.fine('Deferred spend for ${command.txid}: ${command.spentUtxoKeys.length} UTXO(s) stay reserved');
    }
    for (final utxoKey in command.deferSpend ? <String>[] : command.spentUtxoKeys) {
      final parts = utxoKey.split(':');
      if (parts.length != 2) {
        continue;
      }
      final utxoTxid = parts[0];
      final utxoVout = int.tryParse(parts[1]);
      if (utxoVout == null) {
        continue;
      }
      
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

    // SCAN ALL OUTPUTS: Create UTXOs for any outputs that belong to wallet addresses
    // This handles change outputs, settlement outputs, self-transfers, and any other
    // scenario where transaction outputs belong to this wallet
    try {
      final tx = dartsv.Transaction.fromHex(command.rawHex);
      final walletAddresses = currentState.addresses.keys.toSet();
      final network = NetworkName.toDartsv(currentState.networkType);
      
      
      // Use ScriptTypeRegistry to identify output types and extract addresses
      final scriptRegistry = ScriptTypeRegistry(networkType: network);
      
      for (int i = 0; i < tx.outputs.length; i++) {
        final output = tx.outputs[i];
        final satoshis = output.satoshis.toInt();
        
        if (satoshis <= 0) {
          continue;
        }
        
        // Identify script type
        final scriptType = scriptRegistry.identifyScriptType(output.script)?.toLowerCase() ?? 'unknown';

        String? outputAddress;
        bool belongsToWallet = false;
        Map<String, dynamic>? outputPluginMetadata;

        // Extract address based on script type
        switch (scriptType) {
          case 'p2pkh':
            try {
              final locker = dartsv.P2PKHLockBuilder.fromScript(output.script, networkType: network);
              outputAddress = locker.address?.toBase58();
              if (outputAddress != null && walletAddresses.contains(outputAddress)) {
                belongsToWallet = true;
              }
            } catch (e) {
              _log.warning('Failed to extract P2PKH address from output: $e');
            }
            break;
            
          case 'p2pk':
            try {
              final scriptInfo = scriptRegistry.extractScriptMetadata(output.script);
              final pubkeyHex = scriptInfo?['pubKey'] ?? scriptInfo?['publicKey'];
              if (pubkeyHex != null) {
                final pubKeyObj = dartsv.SVPublicKey.fromHex(pubkeyHex);
                outputAddress = dartsv.Address.fromPublicKey(pubKeyObj, network).toBase58();
                if (walletAddresses.contains(outputAddress)) {
                  belongsToWallet = true;
                }
              }
            } catch (e) {
              _log.warning('Failed to extract P2PK address from output: $e');
            }
            break;

          case 'p2ms':
            // For P2MS (multisig), check if any of the public keys belong to wallet addresses
            try {
              final scriptInfo = scriptRegistry.extractScriptMetadata(output.script);
              final pubKeys = scriptInfo?['publicKeys'] as List?;
              if (pubKeys != null) {
                for (final pubKeyHex in pubKeys) {
                  try {
                    final pubKey = dartsv.SVPublicKey.fromHex(pubKeyHex.toString());
                    final derivedAddress = dartsv.Address.fromPublicKey(pubKey, network).toBase58();
                    if (walletAddresses.contains(derivedAddress)) {
                      belongsToWallet = true;
                      outputAddress = derivedAddress; // Use the first matching address
                      break;
                    }
                  } catch (e) {
                    _log.warning('Failed to derive P2MS address from public key: $e');
                  }
                }
              }
            } catch (e) {
              _log.warning('Failed to extract P2MS script metadata: $e');
            }
            break;
            
          case 'opreturn':
          case 'op_return':
            // OP_RETURN outputs don't belong to anyone
            continue;

          default:
            // Plugin-aware fallback: ScriptTypeRegistry.identifyScriptType
            // already consulted PluginRegistry for unknown templates and
            // returned `pluginId:scriptType` when a plugin claimed the script.
            // Mirror the SPV inbound path (spv_actor.dart:504-525) so the
            // aggregate that *built* a plugin-locked output represents it
            // immediately, without waiting for SPV rediscovery.
            if (scriptType.contains(':')) {
              final pluginId = scriptType.split(':').first;
              final plugin = PluginRegistry().getPlugin(pluginId);
              final metadata = plugin?.extractMetadata(output.script);
              final ownerAddress = metadata?['ownerAddress'] as String?;
              if (ownerAddress != null && walletAddresses.contains(ownerAddress)) {
                outputAddress = ownerAddress;
                belongsToWallet = true;
                outputPluginMetadata = metadata;
              }
            }
            break;
        }
        
        // An output the wallet already holds (the transaction was recorded
        // before, or the UTXO arrived another way) keeps its current state:
        // re-emitting UTXOReceivedEvent reset its status (audit M9).
        if (belongsToWallet && currentState.utxos.containsKey('${command.txid}:$i')) {
          continue;
        }

        // If output belongs to wallet, create a UTXO for it
        if (belongsToWallet && outputAddress != null) {
          
          final utxoEvent = UTXOReceivedEvent(
            walletId: command.walletId,
            txid: command.txid,
            vout: i,
            satoshis: satoshis,
            scriptPubKey: output.script.toHex(),
            address: outputAddress,
            blockHeight: null, // Not confirmed yet
            confirmations: 0,
            initialStatus: UTXOStatus.pending, // Starts as pending until confirmed
            pluginMetadata: outputPluginMetadata,
            version: currentState.version + events.length + 1,
            timestamp: DateTime.now(),
          );
          events.add(utxoEvent);
        } else {
        }
      }
      
      final walletOutputsCount = events.length - 1 - command.spentUtxoKeys.length;
      
    } catch (e, stackTrace) {
      // Continue without creating UTXOs - better than crashing
    }

    return events;
  }

  /// Handle confirming a pending transaction
  List<Event> _handleConfirmTransaction(WalletState currentState, ConfirmTransactionCommand command) {
    
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot confirm transaction for non-existent wallet');
    }

    
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

  /// Take back a confirmation whose block left the active chain or whose
  /// proof does not match its block header (audit 3b0).
  List<Event> _handleRevertTransactionConfirmation(
      WalletState currentState, RevertTransactionConfirmationCommand command) {
    if (!currentState.isCreated) {
      throw StateError('Cannot revert a confirmation for non-existent wallet');
    }
    return [TransactionConfirmationRevertedEvent(
      walletId: command.walletId,
      txid: command.txid,
      blockHeight: command.blockHeight,
      blockHash: command.blockHash,
      merkleProof: command.merkleProof,
      reason: command.reason,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    )];
  }

  List<Event> _handleUpdateTransactionStatus(WalletState currentState, UpdateTransactionStatusCommand command) {
    if (!currentState.isCreated) {
      throw StateError('Cannot update transaction status for non-existent wallet');
    }

    return [TransactionStatusUpdatedEvent(
      walletId: command.walletId,
      txid: command.txid,
      newStatus: command.newStatus,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    )];
  }

  // ==========================================================================
  // TRANSACTION MANAGEMENT COMMAND HANDLERS
  // ==========================================================================

  /// Retrieve the private key for a given address from secure storage
  /// Supports WIF, XPRIV, and HD wallets.
  ///
  /// [derivationIndex] and [isChange] let a caller that holds the derivation
  /// path (e.g. from the read model) supply it directly. When [isChange] is
  /// null the chain is resolved from the aggregate's own address records,
  /// which is correct for every address the aggregate generated or
  /// discovered; unknown addresses default to the receive chain.
  Future<dartsv.SVPrivateKey> _getPrivateKeyForAddress(
    String address,
    String walletId,
    WalletState currentState, {
    int? derivationIndex,
    bool? isChange,
  }) async {
    if (currentState.walletType == WalletType.wif) {
      // WIF wallet: single private key
      final wif = await secureStorage.getWIF(walletId);
      if (wif == null) {
        throw StateError('WIF not found for wallet $walletId');
      }
      return dartsv.SVPrivateKey.fromWIF(wif);
    } else if (currentState.walletType == WalletType.xpub) {
      throw StateError('Cannot retrieve private key: Wallet is watch-only (XPUB)');
    } else if (currentState.walletType == WalletType.xpriv || 
               currentState.walletType == WalletType.hd) {
      // HD/XPRIV wallet: derive key for specific address
      int effectiveIndex;

      if (derivationIndex != null) {
        // Use caller-provided index (from read model — avoids write/read model split)
        effectiveIndex = derivationIndex;
      } else if (address == currentState.rootAddress) {
        effectiveIndex = 0; // Root address is always at index 0
      } else {
        // Fall back to aggregate state lookup
        // `addresses` maps address -> optional label, so presence must be
        // checked with containsKey: an unlabelled address has a null value.
        if (!currentState.addresses.containsKey(address)) {
          throw StateError('Address $address not found in wallet state');
        }
        effectiveIndex = _addressIndices()[address] ?? 0;
      }

      // The chain: caller-supplied, else whatever the aggregate recorded when
      // it generated/discovered the address (receive for the root address and
      // for journals written before the chain was recorded).
      final effectiveIsChange = isChange ?? _isChangeAddress(address);

      return _getPrivateKeyAtIndex(
        walletId,
        effectiveIndex,
        currentState,
        isChange: effectiveIsChange,
      );
    } else {
      throw StateError('Unsupported wallet type: ${currentState.walletType}');
    }
  }

  Future<List<Event>> _handleSignTransaction(
    WalletState currentState,
    SignTransactionCommand command,
  ) async {
    dartsv.Transaction? signedTx;

    _log.info('Signing tx ${command.transactionId} with ${command.utxoKeys.length} UTXOs, walletType=${currentState.walletType}');

    try {
      // Business rule: Wallet must exist
      if (!currentState.isCreated) {
        throw StateError('Cannot sign transaction for non-existent wallet');
      }

      // Business rule: Watch-only wallets cannot sign
      if (currentState.walletType == WalletType.xpub) {
        throw StateError('Signing not supported for watch-only wallets');
      }

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
        // Use command-provided derivation index if available (from read model)
        final cmdDerivationIndex = (i < command.derivationIndices.length)
            ? command.derivationIndices[i]
            : null;
        // Chain flag is optional: absent means "resolve from aggregate state".
        final cmdIsChange = (i < command.isChangeFlags.length)
            ? command.isChangeFlags[i]
            : null;
        final privateKey = await _getPrivateKeyForAddress(
          utxo.address,
          command.walletId,
          currentState,
          derivationIndex: cmdDerivationIndex,
          isChange: cmdIsChange,
        );
        
        // Create TransactionOutput for the UTXO being spent
        final lockingScript = dartsv.SVScript.fromHex(utxo.scriptPubKey);
        final utxoOutput = dartsv.TransactionOutput(
          utxo.value.getValue(),
          lockingScript,
        );

        //Create the placeholder Tx Input that will hold the signature

        // ScriptTypeRegistry is a singleton pinned to the first network it
        // is built with; the default (testnet) threw for mainnet wallets
        // once output scanning had initialised it for mainnet.
        final registry = ScriptTypeRegistry(
          networkType: NetworkName.toDartsv(currentState.networkType),
        );

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
        final signer = dartsv.DefaultTransactionSigner(
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
        // Verify the input we just signed. With SIGHASH_FORKID the signature
        // commits to this input's own subscript and amount, so checking
        // input 0 against every UTXO (the previous behaviour) rejected any
        // multi-input transaction whose inputs differ in script or amount.
        final inputIndex = i;
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
      
      // Return TransactionSignedEvent
      final event = TransactionSignedEvent(
        walletId: command.walletId,
        txid: signedTxid, // Use signed txid, not unsigned command.transactionId
        signedRawHex: signedHex,
        version: currentState.version + 1,
        timestamp: DateTime.now(),
      );

      // The success reply goes out from onCommandProcessed, once the event
      // is journaled (audit M5).
      final sender = _capturedSenders[command.commandId];
      if (_isInActorSystem() && sender != null) {
        _repliesAwaitingPersist[command.commandId] = TransactionSignedResponse(
          walletId: command.walletId,
          txid: signedTxid, // Use signed txid, not unsigned command.transactionId
          signedHex: signedHex,
          success: true,
        );
      }

      return [event];
    } catch (e, stackTrace) {
      _repliesAwaitingPersist.remove(command.commandId);
      _log.warning('Sign transaction failed for ${command.transactionId}: $e');

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
        // Return empty list - we've already sent the error response
        // Don't rethrow or onCommandFailure will send a duplicate response
        return [];
      }

      // Only rethrow if not in actor system (for unit tests that expect exceptions)
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
    try {
      // Business rule: Wallet must exist
      if (!currentState.isCreated) {
        throw StateError('Cannot sign multisig transaction for non-existent wallet');
      }

      // Business rule: Watch-only wallets cannot sign
      if (currentState.walletType == WalletType.xpub) {
        throw StateError('Signing not supported for watch-only wallets');
      }

      
      // Parse the transaction to sign
      final txToSign = dartsv.Transaction.fromHex(command.rawTransaction);
      
      // Get private key at the specified derivation index and chain
      final privateKey = await _getPrivateKeyAtIndex(
        command.walletId,
        command.derivationIndex,
        currentState,
        isChange: command.isChange,
      );
      
      // Parse the redeem script (2-of-2 multisig locking script)
      final redeemScript = dartsv.SVScript.fromHex(command.redeemScriptHex);
      
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
      final signer = dartsv.DefaultTransactionSigner(command.sighashType, privateKey);
      signer.sign(txToSign, utxo, command.inputIndex); // Signature added to unlockBuilder
      
      // Extract our signature from the unlock builder (TransactionSigner added it there)
      if (unlockBuilder.signatures.isEmpty) {
        throw StateError('No signature added by TransactionSigner');
      }
      
      final ourSignature = unlockBuilder.signatures.last;
      final signatureHex = ourSignature.toTxFormat();
      
      
      // NOTE: Individual signature verification is not possible here because:
      // - The signature is created for a 2-of-2 multisig (sighash includes full redeem script)
      // - A 1-of-1 test would use a different sighash and always fail
      // The full 2-of-2 verification happens in PaymentChannelCoordinator after both signatures
      // are combined using Interpreter.correctlySpends()
      
      
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
        // Return empty list - we've already sent the error response
        // Don't rethrow or onCommandFailure will send a duplicate response
        return [];
      }
      
      // Only rethrow if not in actor system (for unit tests that expect exceptions)
      throw StateError('Failed to sign multisig transaction: $e');
    }
  }

  /// Signs one input of [SignInputCommand.rawTransaction] against a
  /// caller-supplied subscript and amount with the key at an explicit path,
  /// and replies [InputSignedResponse] with the signature and that key's
  /// public key.
  ///
  /// The per-input signing primitive for plugin-built transactions
  /// (AggregateSigningClient). Nothing is journaled: signing changes no
  /// wallet state, so the reply is sent directly (the reply-after-persist
  /// rule of audit M5 concerns commands that emit events).
  Future<List<Event>> _handleSignInput(WalletState currentState, SignInputCommand command) async {
    final sender = _capturedSenders[command.commandId];
    final replyTo = _isInActorSystem() ? sender : null;
    try {
      if (!currentState.isCreated) {
        throw StateError('Cannot sign an input for non-existent wallet ${command.walletId}');
      }
      if (currentState.walletType == WalletType.xpub) {
        throw StateError('Signing not supported for watch-only wallets');
      }

      final tx = dartsv.Transaction.fromHex(command.rawTransaction);
      if (command.inputIndex < 0 || command.inputIndex >= tx.inputs.length) {
        throw ArgumentError('Input index ${command.inputIndex} out of range '
            '(transaction has ${tx.inputs.length} inputs)');
      }
      if (command.satoshis < BigInt.zero) {
        throw ArgumentError('Spent amount must not be negative');
      }

      final privateKey = await _getPrivateKeyAtIndex(
        command.walletId,
        command.derivationIndex,
        currentState,
        isChange: command.isChange,
      );

      // What dartsv's DefaultTransactionSigner does, without needing an
      // unlocking-script builder on the input.
      final digest = dartsv.Sighash().hash(
        tx,
        command.sighashType,
        command.inputIndex,
        dartsv.SVScript.fromHex(command.subscriptHex),
        command.satoshis,
      );
      final signature = dartsv.SVSignature.fromPrivateKey(privateKey)
        ..nhashtype = command.sighashType;
      signature.sign(hex.encode(hex.decode(digest).reversed.toList()));

      replyTo?.tell(InputSignedResponse(
        walletId: command.walletId,
        commandId: command.commandId,
        inputIndex: command.inputIndex,
        signatureHex: signature.toTxFormat(),
        publicKeyHex: privateKey.publicKey.toHex(),
        success: true,
      ));
      return [];
    } catch (e) {
      _log.warning('Sign input ${command.inputIndex} failed for wallet ${command.walletId}: $e');
      if (replyTo != null) {
        replyTo.tell(InputSignedResponse(
          walletId: command.walletId,
          commandId: command.commandId,
          inputIndex: command.inputIndex,
          signatureHex: '',
          publicKeyHex: '',
          success: false,
          error: e.toString(),
        ));
        // Answered; returning normally keeps onCommandFailure from replying twice.
        return [];
      }
      throw StateError('Failed to sign input ${command.inputIndex}: $e');
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
    try {
      if (!currentState.isCreated) {
        throw StateError('Cannot build funding transaction for non-existent wallet');
      }

      // Business rule: Watch-only wallets cannot sign
      if (currentState.walletType == WalletType.xpub) {
        throw StateError('Signing (funding) not supported for watch-only wallets');
      }

      
      // Parse public keys
      final clientPubKey = dartsv.SVPublicKey.fromHex(command.clientPubKeyHex);
      final serverPubKey = dartsv.SVPublicKey.fromHex(command.serverPubKeyHex);
      final changeAddress = dartsv.Address.fromBase58(command.changeAddressBase58);
      
      // Get available UTXOs and sort by value descending (largest first for efficient selection)
      final availableUtxos = currentState.utxos.values
          .where((u) => u.isAvailable && !u.isSpent && !u.isReserved)
          .toList()
        ..sort((a, b) => b.value.getValue().compareTo(a.value.getValue()));
      
      
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
        
        // Get the correct private key for THIS specific UTXO's address. The
        // UTXO carries only the index; the chain comes from the aggregate's
        // address records (change-chain UTXOs were unsignable before H3).
        final utxoPrivateKey = await _getPrivateKeyForAddress(
          utxo.address,
          command.walletId,
          currentState,
          derivationIndex: utxo.derivationIndex,
        );
        
        final signer = dartsv.DefaultTransactionSigner(sighashType, utxoPrivateKey);
        
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

      final fundingTxId = signedTx.id;
      
      
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
      
      
      // CRITICAL: Find the actual multisig output index
      // TransactionBuilder.sendChangeToPKH() puts change at index 0. The
      // multisig output is located by its locking script, never by amount:
      // the change can carry the same amount (audit SPV-13).
      final multisigScriptHex = msLockBuilder.getScriptPubkey().toHex();
      final multisigOutputIndex = signedTx.outputs
          .indexWhere((o) => o.script.toHex() == multisigScriptHex);
      if (multisigOutputIndex == -1) {
        throw StateError('Could not find multisig output in funding transaction');
      }
      int? actualChangeOutputIdx;
      for (int i = 0; i < signedTx.outputs.length; i++) {
        if (i != multisigOutputIndex) actualChangeOutputIdx = i;
      }
      
      // Determine if change output was actually added (above dust threshold)
      final hasChange = changeAmount > BigInt.from(546);
      final actualChangeAmount = hasChange ? changeAmount.toInt() : 0;
      
      // Calculate totals
      final totalInputSats = selectedTotal.toInt();
      final totalOutputSats = fundingAmount.toInt() + actualChangeAmount;
      
      // Response with full transaction details for wallet bookkeeping. It is
      // sent from onCommandProcessed once the reservations are journaled
      // (audit M5).
      final sender = _capturedSenders[command.commandId];
      if (_isInActorSystem() && sender != null) {
        _repliesAwaitingPersist[command.commandId] = FundingTransactionBuiltResponse(
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
        );
      }
      
      // Return reservation events to prevent double-spend of selected UTXOs
      // The coordinator will mark as spent after broadcast via RecordOutgoingTransactionCommand
      return reserveEvents;
      
    } catch (e, stackTrace) {
      _repliesAwaitingPersist.remove(command.commandId);

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
        // Return empty list - we've already sent the error response
        // Don't rethrow or onCommandFailure will send a duplicate response
        return [];
      }
      
      // Only rethrow if not in actor system (for unit tests that expect exceptions)
      throw StateError('Failed to build funding transaction: $e');
    }
  }

  /// Get private key at a specific derivation index on the receive
  /// ([isChange] false, m/0/{index}) or change ([isChange] true, m/1/{index})
  /// chain. Used for multisig signing where we know the exact path, and by
  /// [_getPrivateKeyForAddress] once it has resolved the path.
  Future<dartsv.SVPrivateKey> _getPrivateKeyAtIndex(
    String walletId,
    int derivationIndex,
    WalletState currentState, {
    bool isChange = false,
  }) async {
    final networkType = NetworkName.toDartsv(currentState.networkType);

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
        // m/{chain}/{index}: chain 0 = receive, 1 = change
        return await cryptoService.derivePrivateKey(
          hdPrivateKey,
          0, // accountIndex
          derivationIndex, // addressIndex
          isChange: isChange,
        );
      }

      // Try mnemonic if xpriv not found
      final mnemonic = await secureStorage.getMnemonic(walletId);
      if (mnemonic != null) {
        final hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(
          mnemonic,
          passphrase: await _mnemonicPassphrase(walletId),
          network: networkType,
        );
        // m/{chain}/{index}: chain 0 = receive, 1 = change
        return await cryptoService.derivePrivateKey(
          hdPrivateKey,
          0, // accountIndex
          derivationIndex, // addressIndex
          isChange: isChange,
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

  /// Reserve every UTXO in [ReserveUTXOsCommand.utxoKeys] for
  /// [ReserveUTXOsCommand.reservationId], under the same rules as
  /// [ReserveUTXOCommand] (priority 0). All-or-nothing: if any key cannot be
  /// reserved the command fails and nothing is reserved. Emits one
  /// [UTXOReservedEvent] per UTXO so the aggregate and the read model both
  /// see the reservation (audit 2026-09-14 M3: this used to emit a
  /// [UTXOReservationPlacedEvent] that nothing applied).
  List<Event> _handleReserveUTXOs(WalletState currentState, ReserveUTXOsCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot reserve UTXOs for non-existent wallet');
    }

    final duration = command.reservationDuration ?? const Duration(minutes: 30);
    final events = <Event>[];
    for (final utxoKey in command.utxoKeys.toSet()) {
      events.add(_reservationEvent(
        currentState,
        walletId: command.walletId,
        utxoKey: utxoKey,
        reservedByTxId: command.reservationId,
        reservationReason: 'Reservation ${command.reservationId}',
        duration: duration,
        priority: 0,
        version: currentState.version + events.length + 1,
      ));
    }
    return events;
  }

  /// Release every UTXO currently reserved by
  /// [ReleaseUTXOsCommand.reservationId] (whether it was reserved with
  /// [ReserveUTXOsCommand], [ReserveUTXOCommand] or a funding build), each
  /// back to the status it had before the reservation. The coordinators send
  /// this to clean up abandoned payments; a reservation with no reserved
  /// UTXOs left is a no-op (audit 2026-09-14 M3: this used to emit a
  /// [UTXOReservationReleasedEvent] that released nothing).
  List<Event> _handleReleaseUTXOs(WalletState currentState, ReleaseUTXOsCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot release UTXOs for non-existent wallet');
    }

    final events = <Event>[];
    for (final utxo in currentState.utxos.values) {
      if (utxo.status != UTXOStatus.reserved || utxo.reservedByTxId != command.reservationId) {
        continue;
      }
      events.add(UTXOReleasedEvent(
        walletId: command.walletId,
        txid: utxo.txid,
        vout: utxo.vout,
        releaseReason: 'Reservation ${command.reservationId} released',
        wasExpired: utxo.isReservationExpired,
        restoredStatus: utxo.statusToRestoreOnRelease,
        version: currentState.version + events.length + 1,
        timestamp: DateTime.now(),
      ));
    }
    return events;
  }

  /// A [UTXOReservedEvent] for [utxoKey], enforcing the reservation rules:
  /// the UTXO exists, is not spent, and is not held by a live reservation of
  /// equal or higher priority.
  UTXOReservedEvent _reservationEvent(
    WalletState currentState, {
    required String walletId,
    required String utxoKey,
    required String reservedByTxId,
    required String? reservationReason,
    required Duration duration,
    required int priority,
    required int version,
  }) {
    final utxo = currentState.utxos[utxoKey];
    if (utxo == null) {
      throw StateError('UTXO $utxoKey not found in wallet');
    }

    if (utxo.status == UTXOStatus.spent) {
      throw StateError('Cannot reserve spent UTXO $utxoKey');
    }

    if (utxo.status == UTXOStatus.reserved && !utxo.isReservationExpired) {
      // Check priority - higher priority can override lower priority
      final currentPriority = utxo.reservationPriority ?? 0;
      if (priority <= currentPriority) {
        throw StateError('UTXO $utxoKey is already reserved with higher or equal priority');
      }
    }

    return UTXOReservedEvent(
      walletId: walletId,
      txid: utxo.txid,
      vout: utxo.vout,
      reservedByTxId: reservedByTxId,
      reservationReason: reservationReason,
      expiresAt: DateTime.now().add(duration),
      priority: priority,
      version: version,
      timestamp: DateTime.now(),
    );
  }

  List<Event> _handleReserveUTXO(WalletState currentState, ReserveUTXOCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot reserve UTXO for non-existent wallet');
    }

    return [
      _reservationEvent(
        currentState,
        walletId: command.walletId,
        utxoKey: command.utxoKey,
        reservedByTxId: command.reservedByTxId,
        reservationReason: command.reservationReason,
        duration: command.reservationDuration ?? const Duration(minutes: 30),
        priority: command.priority,
        version: currentState.version + 1,
      ),
    ];
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
      restoredStatus: utxo.statusToRestoreOnRelease,
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
          restoredStatus: utxo.statusToRestoreOnRelease,
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

  // ==========================================================================
  // ADDRESS DERIVATION RECORDS
  // ==========================================================================
  //
  // Every address the aggregate generates or discovers is recorded with its
  // derivation index (metadata['address_indices']: address -> int) AND its
  // chain (metadata['address_chains']: address -> bool, true = change chain
  // m/1/i, false = receive chain m/0/i). Both are rebuilt from the journal:
  // AddressGeneratedEvent.purpose == 'change' and AddressDiscoveredEvent
  // .isChange carry the chain; events without either are receive-chain.
  // Before the 2026-09 audit (H3) only the index was kept and every signing
  // path derived m/0/i, so change outputs were unspendable.

  static const String _addressIndicesKey = 'address_indices';
  static const String _addressChainsKey = 'address_chains';

  /// Chain discriminator on [AddressGeneratedEvent.purpose] /
  /// [GenerateAddressCommand.purpose].
  static const String changePurpose = 'change';

  Map<String, int> _addressIndices() {
    final existing = currentState.metadata[_addressIndicesKey];
    if (existing is Map<String, int>) return existing;
    // A snapshot round-trip can hand back an untyped map; normalise it.
    final map = <String, int>{};
    if (existing is Map) {
      existing.forEach((k, v) {
        if (v is int) map[k.toString()] = v;
      });
    }
    currentState.metadata[_addressIndicesKey] = map;
    return map;
  }

  Map<String, bool> _addressChains() {
    final existing = currentState.metadata[_addressChainsKey];
    if (existing is Map<String, bool>) return existing;
    final map = <String, bool>{};
    if (existing is Map) {
      existing.forEach((k, v) {
        if (v is bool) map[k.toString()] = v;
      });
    }
    currentState.metadata[_addressChainsKey] = map;
    return map;
  }

  void _recordAddressDerivation(String address, int index, {required bool isChange}) {
    _addressIndices()[address] = index;
    _addressChains()[address] = isChange;
  }

  /// Whether [address] was derived on the change chain. Unknown addresses
  /// (and the root address) are receive-chain, matching every journal
  /// written before the chain was recorded.
  bool _isChangeAddress(String address) => _addressChains()[address] ?? false;

  void _applyWalletCreated(WalletCreatedEvent event) {
    currentState.isCreated = true;
    currentState.name = event.walletName;
    currentState.rootAddress = event.rootAddress;
    currentState.walletType = event.walletType;
    currentState.networkType = NetworkName.canonical(event.walletMetadata?['network'] as String?);
    currentState.timestamp = event.timestamp;
    currentState.nextDerivationIndex = 1; // Root address is index 0
    currentState.metadata.clear();
    if (event.walletMetadata != null) {
      currentState.metadata.addAll(event.walletMetadata!);
    }

    // Initialize the derivation records
    _addressIndices();
    _addressChains();

    currentState.version = event.version;
    currentState.lastModified = event.timestamp;

    // Add root address to addresses map with derivation index 0 (receive chain)
    if (event.rootAddress.isNotEmpty) {
      currentState.addresses[event.rootAddress] = null;
      _recordAddressDerivation(event.rootAddress, 0, isChange: false);
    }
  }

  List<Event> _handleDeleteWallet(WalletState currentState, DeleteWalletCommand command) {
    if (!currentState.isCreated) {
      throw StateError('Cannot delete wallet ${command.walletId}: wallet does not exist');
    }
    if (currentState.isDeleted) {
      throw StateError('Wallet ${command.walletId} is already deleted');
    }

    return [
      WalletDeletedEvent(
        walletId: command.walletId,
        reason: command.reason,
        version: currentState.version + 1,
        timestamp: DateTime.now(),
      ),
    ];
  }

  void _applyWalletDeleted(WalletDeletedEvent event) {
    currentState.isDeleted = true;
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
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

    // Store the derivation index and chain for key derivation during signing
    _recordAddressDerivation(
      event.address,
      event.derivationIndex,
      isChange: event.purpose == changePurpose,
    );

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
    if (currentState.utxos.containsKey(utxoKey)) {
      // First receipt wins (audit 2026-09-14 M9). The command handlers no
      // longer emit a second UTXOReceivedEvent for a known outpoint, but
      // journals written before the fix can hold one (the outgoing-tx
      // scanner re-emitted it); overwriting would reset the UTXO's status
      // and drop its reservation or spent mark. Replay must not throw.
      _log.fine('Ignoring UTXOReceivedEvent for known outpoint $utxoKey');
      currentState.version = event.version;
      currentState.lastModified = event.timestamp;
      return;
    }
    final utxo = BitcoinUtxo.create(
      txid: event.txid,
      vout: event.vout,
      satoshis: BigInt.from(event.satoshis),
      scriptPubKey: event.scriptPubKey,
      address: event.address,
      blockHeight: event.blockHeight,
      confirmations: event.confirmations ?? 0,
      status: event.initialStatus, // Use the status from the event
      derivationIndex: event.derivationIndex,
      pluginMetadata: event.pluginMetadata,
      createdAt: event.timestamp,
    );

    _putUtxo(utxoKey, utxo);
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyUTXOMarkedAvailable(UTXOMarkedAvailableEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = currentState.utxos[utxoKey];
    
    if (utxo != null) {
      _putUtxo(
        utxoKey,
        utxo.status == UTXOStatus.reserved
            ? utxo.copyWith(statusBeforeReservation: UTXOStatus.available, updatedAt: event.timestamp)
            : utxo.markAvailable(timestamp: event.timestamp),
      );
      currentState.version = event.version;
      currentState.lastModified = event.timestamp;
    }
  }

  void _applyUTXOSpent(UTXOSpentEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = currentState.utxos[utxoKey];
    if (utxo != null) {
      _putUtxo(
        utxoKey,
        utxo.markSpent(timestamp: event.timestamp, spentInTxId: event.spentInTxId),
      );
    }
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyUTXOConfirmationUpdated(UTXOConfirmationUpdatedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = currentState.utxos[utxoKey];
    if (utxo != null) {
      _putUtxo(
        utxoKey,
        utxo.updateConfirmations(
          blockHeight: event.blockHeight,
          confirmations: event.confirmations,
          timestamp: event.timestamp,
        ),
      );
    }
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
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
        statusBeforeReservation: utxo.statusToRestoreOnRelease,
        reservedByTxId: event.reservedByTxId,
        reservationExpiresAt: event.expiresAt,
        reservationPriority: event.priority,
        reservationReason: event.reservationReason,
        updatedAt: event.timestamp,
      );

      _putUtxo(utxoKey, reservedUtxo);
    }
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyUTXOReleased(UTXOReleasedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = currentState.utxos[utxoKey];
    
    if (utxo != null && utxo.status == UTXOStatus.reserved) {
      // Events journaled before restoredStatus existed released to
      // available; replay them that way.
      final releasedUtxo = utxo.releaseReservation(
        restoreStatus: event.restoredStatus ?? UTXOStatus.available,
        timestamp: event.timestamp,
      );
      _putUtxo(utxoKey, releasedUtxo);
    }
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyUTXOReservationRenewed(UTXOReservationRenewedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = currentState.utxos[utxoKey];
    
    if (utxo != null && utxo.status == UTXOStatus.reserved) {
      // The event carries the new expiry; recomputing it from the state
      // (extension added to the current expiry, or to "now" when there was
      // none) made the result depend on when the event was applied (L1).
      // Renewal moves no amount between balances.
      currentState.utxos[utxoKey] = utxo.copyWith(
        reservationExpiresAt: event.newExpiresAt,
        reservationReason: event.renewalReason ?? utxo.reservationReason,
        updatedAt: event.timestamp,
      );
    }
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  // ==========================================================================
  // WALLET IMPORT EVENT HANDLERS
  // ==========================================================================

  void _applyAddressDiscovered(AddressDiscoveredEvent event) {
    // Add discovered address to wallet
    currentState.addresses[event.address] = 'Imported (${event.isChange ? 'change' : 'receive'} #${event.derivationIndex})';

    // Store the derivation index and chain for key derivation during signing
    _recordAddressDerivation(event.address, event.derivationIndex, isChange: event.isChange);
    
    // Update next derivation index if this is higher
    if (event.derivationIndex >= currentState.nextDerivationIndex) {
      currentState.nextDerivationIndex = event.derivationIndex + 1;
    }
    
    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  static const String _importedTransactionsKey = 'importedTransactions';
  static const String _outgoingTransactionsKey = 'outgoingTransactions';

  /// The transaction records under metadata[[key]], keyed by txid (audit
  /// 2026-09-14 M7: they were lists appended on every event and searched
  /// linearly). A list-shaped value (state built before the change) is
  /// converted once.
  Map<String, dynamic> _transactionRecords(String key) {
    final existing = currentState.metadata[key];
    if (existing is Map<String, dynamic>) return existing;
    final records = <String, dynamic>{};
    if (existing is Map) {
      existing.forEach((txid, record) => records[txid.toString()] = record);
    } else if (existing is List) {
      for (final record in existing) {
        if (record is Map && record['txid'] != null) {
          records[record['txid'].toString()] = Map<String, dynamic>.from(record);
        }
      }
    }
    currentState.metadata[key] = records;
    return records;
  }

  void _applyTransactionImported(TransactionImportedEvent event) {
    // Store imported transaction in metadata (for audit/history). Records
    // keep first-import order. A repeated import of the same txid keeps the
    // first import time and takes the latest block height.
    final records = _transactionRecords(_importedTransactionsKey);
    final existing = records[event.txid];
    if (existing is Map) {
      existing['blockHeight'] = event.blockHeight;
      existing['lastImportedAt'] = event.timestamp.toIso8601String();
    } else {
      records[event.txid] = <String, dynamic>{
        'txid': event.txid,
        'blockHeight': event.blockHeight,
        'importedAt': event.timestamp.toIso8601String(),
      };
    }

    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyTransactionRecorded(TransactionRecordedEvent event) {
    // Store outgoing transaction in metadata (for audit/history)
    // Status starts as PENDING - will be updated to CONFIRMED when recipient accepts
    final records = _transactionRecords(_outgoingTransactionsKey);
    final details = <String, dynamic>{
      'txid': event.txid,
      'recipientAddresses': event.recipientAddresses,
      'paymentAmount': event.paymentAmount,
      'fee': event.fee,
      'recordedAt': event.timestamp.toIso8601String(),
    };
    final existing = records[event.txid];
    if (existing is Map) {
      // Recorded again: refresh the details; keep the first record time and
      // any confirmation.
      existing.addAll(<String, dynamic>{
        ...details,
        'recordedAt': existing['recordedAt'] ?? details['recordedAt'],
      });
    } else {
      records[event.txid] = <String, dynamic>{...details, 'status': 'pending'};
    }

    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  /// The transaction is no longer confirmed: back to pending in the
  /// transaction metadata, and its UTXOs lose their confirmations. A UTXO
  /// that was spendable because of the proof becomes pending (a reserved one
  /// returns to pending on release); spent UTXOs are left alone.
  void _applyTransactionConfirmationReverted(TransactionConfirmationRevertedEvent event) {
    final record = _transactionRecords(_outgoingTransactionsKey)[event.txid];
    if (record is Map && record['status'] == 'confirmed') {
      record['status'] = 'pending';
      record.remove('blockHeight');
      record.remove('blockHash');
      record.remove('confirmedAt');
    }

    for (final entry in currentState.utxos.entries.toList()) {
      final utxo = entry.value;
      if (utxo.txid != event.txid || utxo.status == UTXOStatus.spent) continue;
      _putUtxo(entry.key, BitcoinUtxo(
        txid: utxo.txid,
        vout: utxo.vout,
        value: utxo.value,
        scriptPubKey: utxo.scriptPubKey,
        address: utxo.address,
        status: utxo.status == UTXOStatus.available ? UTXOStatus.pending : utxo.status,
        blockHeight: null,
        confirmations: 0,
        createdAt: utxo.createdAt,
        updatedAt: event.timestamp,
        reservedByTxId: utxo.reservedByTxId,
        reservationExpiresAt: utxo.reservationExpiresAt,
        reservationPriority: utxo.reservationPriority,
        reservationReason: utxo.reservationReason,
        derivationIndex: utxo.derivationIndex,
        pluginMetadata: utxo.pluginMetadata,
        statusBeforeReservation: utxo.statusBeforeReservation == UTXOStatus.available
            ? UTXOStatus.pending
            : utxo.statusBeforeReservation,
        spentInTxId: utxo.spentInTxId,
      ));
    }

    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  void _applyTransactionConfirmed(TransactionConfirmedEvent event) {
    // Update transaction status from PENDING to CONFIRMED
    final record = _transactionRecords(_outgoingTransactionsKey)[event.txid];
    if (record is Map) {
      record['status'] = 'confirmed';
      record['blockHeight'] = event.blockHeight;
      record['blockHash'] = event.blockHash;
      record['confirmedAt'] = event.timestamp.toIso8601String();
    }

    currentState.version = event.version;
    currentState.lastModified = event.timestamp;
  }

  
  // ==========================================================================
  // BALANCES (audit 2026-09-14 M7)
  // ==========================================================================
  //
  // Balances are kept incrementally: every UTXO transition goes through
  // [_putUtxo], which moves only that UTXO's amount between the balance
  // buckets. Recomputing from every UTXO on each event (the previous
  // behaviour) made recovery O(N^2) in the number of UTXO events. The rule
  // matches WalletState.recalculateBalances(); tests compare the two over
  // randomized command sequences.

  /// Stores [utxo] under [key] and moves its amount from the bucket of the
  /// UTXO it replaces (if any) to its own bucket.
  void _putUtxo(String key, BitcoinUtxo utxo) {
    final previous = currentState.utxos[key];
    if (previous != null) _addToBalances(currentState, previous, negate: true);
    currentState.utxos[key] = utxo;
    _addToBalances(currentState, utxo);
  }

  /// Adds (or with [negate], removes) [utxo]'s amount to its balance bucket:
  /// nothing when spent, reserved when reserved, confirmed with 6 or more
  /// confirmations, unconfirmed otherwise.
  static void _addToBalances(WalletState state, BitcoinUtxo utxo, {bool negate = false}) {
    if (utxo.status == UTXOStatus.spent) return;
    final amount = negate ? -utxo.satoshis : utxo.satoshis;
    if (utxo.status == UTXOStatus.reserved) {
      state.reservedBalance = dartsv.Coin.ofSat(state.reservedBalance.getValue() + amount);
    } else if ((utxo.confirmations ?? 0) >= 6) {
      state.confirmedBalance = dartsv.Coin.ofSat(state.confirmedBalance.getValue() + amount);
    } else {
      state.unconfirmedBalance = dartsv.Coin.ofSat(state.unconfirmedBalance.getValue() + amount);
    }
  }

  /// Sets [state]'s balances from all of its UTXOs (once per snapshot
  /// restore; event application is incremental).
  static void _setFullBalances(WalletState state) {
    state.confirmedBalance = dartsv.Coin.ofSat(BigInt.zero);
    state.unconfirmedBalance = dartsv.Coin.ofSat(BigInt.zero);
    state.reservedBalance = dartsv.Coin.ofSat(BigInt.zero);
    for (final utxo in state.utxos.values) {
      _addToBalances(state, utxo);
    }
  }

  /// A `Map<String, T>` of the entries of [value] whose values are [T]
  /// (snapshot data arrives as untyped maps).
  static Map<String, T> _typedEntries<T>(Object? value) {
    if (value is Map<String, T>) return value;
    final map = <String, T>{};
    if (value is Map) {
      value.forEach((k, v) {
        if (v is T) map[k.toString()] = v;
      });
    }
    return map;
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

  /// Get available UTXOs for spending (excludes plugin-managed UTXOs like tokens)
  List<BitcoinUtxo> getAvailableUTXOs(WalletState state) {
    return state.utxos.values
        .where((utxo) => utxo.status == UTXOStatus.available && !utxo.hasPluginMetadata)
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
    
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot split UTXOs for non-existent wallet');
    }

    // Business rule: Watch-only wallets cannot sign
    if (currentState.walletType == WalletType.xpub) {
      throw StateError('Signing (split) not supported for watch-only wallets');
    }

    // Get all available UTXOs
    final availableUtxos = getAvailableUTXOs(currentState);
    if (availableUtxos.isEmpty) {
      throw StateError('No available UTXOs to split');
    }


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