
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';
import 'package:dactor/dactor.dart';

import '../models/wallet_event.dart';
import '../models/wallet_state.dart';
import '../models/bitcoin_utxo.dart';
import '../services/crypto_service.dart';
import '../storage/secure_storage.dart';
import '../actors/wallet_messages.dart';
import 'wallet_commands.dart';
import 'wallet_events.dart';
import 'aggregate_command_failures.dart';
import 'wallet/address_book.dart';
import 'wallet/channel_funding.dart';
import 'wallet/deferred_payments.dart';
import 'wallet/outgoing_transactions.dart';
import 'wallet/transaction_signer.dart';
import 'wallet/utxo_ledger.dart';
import 'wallet/utxo_reservations.dart';
import 'wallet/wallet_keys.dart';
import 'wallet/wallet_lifecycle.dart';

/// Bitcoin wallet aggregate root implementing event sourcing
///
/// This aggregate manages all wallet state changes through events,
/// ensuring consistency and providing full audit trail for all operations.
/// Follows the Eventador AggregateRoot pattern with functional state management.
///
/// One aggregate (persistence id `BitcoinWallet_<walletId>`) holds the whole
/// wallet, so a command's checks (a spend checks the UTXO, its reservation
/// and deferred holds) see one consistent state. The aggregate itself is the
/// actor plumbing: command and event dispatch, replies, persistence
/// callbacks and queries. The wallet's rules live in collaborators under
/// `wallet/` (bead libspiffy-dp4), which work on the state they are given
/// and know nothing of actors or the journal:
///
/// * [WalletLifecycle]: creation, configuration, deletion.
/// * [AddressBook]: addresses, derivation records, watch addresses.
/// * [WalletKeys]: key material, root and address derivation, private keys.
/// * [UtxoLedger]: receiving, confirming and spending UTXOs, availability,
///   selection, the Benford split initiation.
/// * [UtxoReservations]: reserve, release, renew, expire.
/// * [DeferredPayments]: deferred payments and the holds on their inputs.
/// * [OutgoingTransactions]: imported and outgoing transaction records,
///   the wallet outputs they create, confirmations.
/// * [WalletTransactionSigner]: signing P2PKH, P2PK and multisig inputs.
/// * [ChannelFunding]: payment channel funding transactions.
/// * `WalletBalances` (models): the balance rule.
class BitcoinWalletAggregate extends AggregateRoot<WalletState>
    with CommandFailureContainment<WalletState> {
  final _log = Logger('BitcoinWalletAggregate');
  final CryptoService cryptoService;
  final SecureStorage secureStorage;

  late final WalletKeys _keys = WalletKeys(cryptoService: cryptoService, secureStorage: secureStorage);
  final DeferredPayments _deferred = DeferredPayments();
  late final UtxoReservations _reservations = UtxoReservations(_deferred);
  late final OutgoingTransactions _transactions = OutgoingTransactions(_deferred);
  late final WalletTransactionSigner _signer = WalletTransactionSigner(_keys);
  late final ChannelFunding _funding = ChannelFunding(_keys, _deferred);

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
      await super.onMessage(message);
    } finally {
      // Clean up the captured sender for this specific command
      if (commandKey != null) {
        _capturedSenders.remove(commandKey);
        _failureReplied.remove(commandKey);
      }
    }
  }

  /// Non-command messages. [WalletOwnershipQuery] is answered from this
  /// aggregate's state (bead libspiffy-29t): the mailbox is FIFO, so the
  /// answer reflects every command handled before it, including an address
  /// generation already acknowledged to its caller.
  @override
  Future<void> queryHandler(dynamic message) async {
    if (message is WalletOwnershipQuery) {
      // ignore: invalid_use_of_internal_member
      context.sender?.tell(_answerOwnership(message));
      return;
    }
    if (message is WalletSpendableUtxosQuery) {
      // ignore: invalid_use_of_internal_member
      context.sender?.tell(_answerSpendableUtxos(message));
      return;
    }
    await super.queryHandler(message);
  }

  /// Which of [query]'s addresses and outpoints are this wallet's own.
  ///
  /// An address is the wallet's when the wallet created, generated or
  /// discovered it, registered it as a watch address, or holds a UTXO at it:
  /// the addresses the read model's address rows are written from, taken
  /// here from the journal-backed state instead of the lagging projection.
  /// An outpoint is the wallet's when it is a UTXO the wallet has not spent.
  WalletOwnershipResponse _answerOwnership(WalletOwnershipQuery query) {
    if (!isInitialized || !currentState.isCreated || currentState.isDeleted) {
      return WalletOwnershipResponse(
        walletId: query.walletId,
        walletFound: false,
        error: 'Wallet ${query.walletId} does not exist',
      );
    }
    final state = currentState;
    Set<String>? utxoAddresses;
    bool owns(String address) {
      if (state.addresses.containsKey(address) || state.watchAddresses.containsKey(address)) return true;
      utxoAddresses ??= {for (final utxo in state.utxos.values) utxo.address};
      return utxoAddresses!.contains(address);
    }

    return WalletOwnershipResponse(
      walletId: query.walletId,
      walletFound: true,
      ownedAddresses: {for (final address in query.addresses) if (owns(address)) address},
      unspentOutpoints: {
        for (final key in query.outpoints)
          if (state.utxos[key] case final utxo? when utxo.status != UTXOStatus.spent) key,
      },
    );
  }

  /// This wallet's type and the UTXOs it can spend now (bead libspiffy-ypp).
  WalletSpendableUtxosResponse _answerSpendableUtxos(WalletSpendableUtxosQuery query) {
    if (!isInitialized || !currentState.isCreated || currentState.isDeleted) {
      return WalletSpendableUtxosResponse(
        walletId: query.walletId,
        walletFound: false,
        error: 'Wallet ${query.walletId} does not exist',
      );
    }
    final state = currentState;
    return WalletSpendableUtxosResponse(
      walletId: query.walletId,
      walletFound: true,
      walletType: state.walletType,
      spendable: UtxoLedger.available(state),
      watchOnly: [
        for (final utxo in state.utxos.values)
          if (utxo.status == UTXOStatus.available && !utxo.hasPluginMetadata && UtxoLedger.isWatchOnly(state, utxo))
            utxo,
      ],
    );
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
    final restored = WalletState.fromMap(map);
    if (restored.walletId != aggregateId) {
      throw StateError('Snapshot at $sequenceNumber belongs to wallet ${restored.walletId}, '
          'not $aggregateId');
    }
    final state = restored.toBuilder();
    // The round trip hands back untyped maps; the derivation records are
    // read as typed maps.
    AddressBook.typeRestoredDerivationRecords(state);
    UtxoLedger.namePluginsOfRestoredUtxos(state);
    // Balances are derived data: recompute them once from the restored UTXOs
    // rather than trusting the cached values in the snapshot.
    state.recomputeBalances();
    return state.build();
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
  /// Note: This aggregate uses the override pattern for handleCommand() and
  /// applyEvent() instead of the registry pattern: both dispatch with a
  /// switch over the command or event type (see [handleCommand] and
  /// [applyEvent]). This approach provides better support for async
  /// operations and type-safe handling.
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
          } else if (event is DeferredTransactionCancelledEvent) {
            sender.tell(DeferredSpendCancelledResponse(
              walletId: event.walletId,
              txid: event.txid,
              success: true,
              releasedUtxoKeys: [for (final r in event.releasedInputs) r.utxoKey],
            ));
          }
        }
        // The recording is journaled (or was already, bead libspiffy-viy):
        // a caller that must not act before it (BenfordCoordinatorActor
        // broadcasts only after this, bead libspiffy-ypp) waits for this.
        if (command is RecordOutgoingTransactionCommand) {
          sender.tell(TransactionRecordedResponse(
            walletId: command.walletId,
            txid: command.txid,
            success: true,
          ));
        }
        // Answered also when nothing was journaled (already watched or owned).
        if (command is AddWatchAddressCommand) {
          sender.tell(WatchAddressAddedResponse(
            walletId: command.walletId,
            address: command.address,
            success: true,
            journaled: events.isNotEmpty,
          ));
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
      await _keys.removeKeyMaterial(pendingWalletId, cause: error ?? 'unknown');
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
    } else if (command is CancelDeferredSpendCommand) {
      sender.tell(DeferredSpendCancelledResponse(
        walletId: command.walletId,
        txid: command.txid,
        success: false,
        error: errorMessage,
      ));
    } else if (command is SplitUTXOsToBenfordCommand) {
      sender.tell(SplitUTXOsResponse(
        walletId: command.walletId,
        success: false,
        error: errorMessage,
      ));
    } else if (command is AddWatchAddressCommand) {
      sender.tell(WatchAddressAddedResponse(
        walletId: command.walletId,
        address: command.address,
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
    switch (command) {
      case final CreateWalletCommand cmd:
        return await _handleCreateWallet(currentState, cmd);
      case final DeleteWalletCommand cmd:
        return WalletLifecycle.delete(currentState, cmd);
      case final UpdateWalletConfigurationCommand cmd:
        return WalletLifecycle.updateConfiguration(currentState, cmd);
      case final GenerateAddressCommand cmd:
        return await _keys.generateAddress(currentState, cmd);
      case final UpdateAddressLabelCommand cmd:
        return AddressBook.updateAddressLabel(currentState, cmd);
      case final RegisterDiscoveredAddressCommand cmd:
        return AddressBook.registerDiscoveredAddress(currentState, cmd);
      case final AddWatchAddressCommand cmd:
        return AddressBook.addWatchAddress(currentState, cmd);
      case final ReconcileWatchAddressesCommand cmd:
        return AddressBook.reconcileWatchAddresses(currentState, cmd);
      case final ReceiveUTXOCommand cmd:
        return UtxoLedger.receive(currentState, cmd);
      case final MarkUTXOAvailableCommand cmd:
        return UtxoLedger.markAvailable(currentState, cmd);
      case final RecordImportedTransactionCommand cmd:
        return OutgoingTransactions.recordImported(currentState, cmd);
      case final RecordOutgoingTransactionCommand cmd:
        return _transactions.recordOutgoing(currentState, cmd);
      case final ConfirmTransactionCommand cmd:
        return OutgoingTransactions.confirm(currentState, cmd);
      case final UpdateTransactionStatusCommand cmd:
        return OutgoingTransactions.updateStatus(currentState, cmd);
      case final RevertTransactionConfirmationCommand cmd:
        return OutgoingTransactions.revertConfirmation(currentState, cmd);
      case final SpendUTXOCommand cmd:
        return UtxoLedger.spend(currentState, cmd);
      case final UpdateUTXOConfirmationsCommand cmd:
        return UtxoLedger.updateConfirmations(currentState, cmd);
      case final SignTransactionCommand cmd:
        return await _handleSignTransaction(currentState, cmd);
      case final SignMultisigTransactionCommand cmd:
        return await _handleSignMultisigTransaction(currentState, cmd);
      case final SignInputCommand cmd:
        return await _handleSignInput(currentState, cmd);
      case final BuildFundingTransactionCommand cmd:
        return await _handleBuildFundingTransaction(currentState, cmd);
      case final BroadcastTransactionCommand cmd:
        return OutgoingTransactions.broadcast(currentState, cmd);
      case final ReserveUTXOsCommand cmd:
        return _reservations.reserveMany(currentState, cmd);
      case final ReleaseUTXOsCommand cmd:
        return _reservations.releaseMany(currentState, cmd);
      case final ReserveUTXOCommand cmd:
        return _reservations.reserve(currentState, cmd);
      case final ReleaseUTXOCommand cmd:
        return _reservations.release(currentState, cmd);
      case final RenewUTXOReservationCommand cmd:
        return _reservations.renew(currentState, cmd);
      case final CleanupExpiredReservationsCommand cmd:
        return _reservations.cleanupExpired(currentState, cmd);
      case final ReconcileDeferredSpendsCommand cmd:
        return _deferred.reconcile(currentState, cmd);
      case final RecordTransactionNetworkStatusCommand cmd:
        return _deferred.recordNetworkStatus(currentState, cmd);
      case final CancelDeferredSpendCommand cmd:
        return _deferred.cancel(currentState, cmd);
      case final SplitUTXOsToBenfordCommand cmd:
        return UtxoLedger.splitToBenford(currentState, cmd);
      default:
        throw ArgumentError('Unknown command type: ${command.runtimeType}');
    }
  }

  /// Applies [event] to [current] and returns the next state (Eventador
  /// pattern; bead libspiffy-mmb).
  ///
  /// [current] is never modified: the collaborators fill in a draft of it
  /// that shares every collection the event does not change, and eventador's
  /// `eventHandler` replaces the aggregate's state with the result only once
  /// the whole event has applied. A state handed out earlier (a query, a
  /// snapshot, a command handler) keeps its contents, and an event that fails
  /// midway changes nothing. The appliers replace the draft's immutable
  /// collections, never modify them, and never touch the aggregate's current
  /// state.
  @override
  WalletState applyEvent(WalletState current, Event event) {
    if (event is! WalletEvent) {
      throw ArgumentError('Expected WalletEvent, got ${event.runtimeType}');
    }
    final state = current.toBuilder();

    switch (event) {
      case final WalletCreatedEvent evt:
        WalletLifecycle.applyWalletCreated(state, evt);
      case final WalletDeletedEvent evt:
        WalletLifecycle.applyWalletDeleted(state, evt);
      case final WalletConfigurationUpdatedEvent evt:
        WalletLifecycle.applyWalletConfigurationUpdated(state, evt);
      case final AddressGeneratedEvent evt:
        AddressBook.applyAddressGenerated(state, evt);
      case final AddressLabelUpdatedEvent evt:
        AddressBook.applyAddressLabelUpdated(state, evt);
      case final WatchAddressAddedEvent evt:
        AddressBook.applyWatchAddressAdded(state, evt);
      case final UTXOReceivedEvent evt:
        UtxoLedger.applyReceived(state, evt);
      case final UTXOMarkedAvailableEvent evt:
        UtxoLedger.applyMarkedAvailable(state, evt);
      case final UTXOSpentEvent evt:
        UtxoLedger.applySpent(state, evt);
      case final UTXOConfirmationUpdatedEvent evt:
        UtxoLedger.applyConfirmationUpdated(state, evt);
      case TransactionSignedEvent() || TransactionBroadcastEvent():
        // Transaction state is managed separately - just update version
        state.version = event.version;
      case UTXOReservationPlacedEvent() || UTXOReservationReleasedEvent() || UTXOReservationExpiredEvent():
        // Not applied to UTXOs (UTXOReservedEvent and UTXOReleasedEvent are)
        _touch(state, event);
      case final UTXOReservedEvent evt:
        UtxoReservations.applyReserved(state, evt);
      case final UTXOReleasedEvent evt:
        UtxoReservations.applyReleased(state, evt);
      case final UTXOReservationRenewedEvent evt:
        UtxoReservations.applyRenewed(state, evt);
      case final AddressDiscoveredEvent evt:
        AddressBook.applyAddressDiscovered(state, evt);
      case final TransactionImportedEvent evt:
        OutgoingTransactions.applyImported(state, evt);
      case final TransactionRecordedEvent evt:
        OutgoingTransactions.applyRecorded(state, evt);
      case final TransactionConfirmedEvent evt:
        OutgoingTransactions.applyConfirmed(state, evt);
      case TransactionStatusUpdatedEvent():
        // Status update is projection-only — no aggregate state change needed
        break;
      case final TransactionConfirmationRevertedEvent evt:
        OutgoingTransactions.applyConfirmationReverted(state, evt);
      case UTXOSplitInitiatedEvent() || UTXOSplitCompletedEvent() || AllUTXOsSplitCompletedEvent():
        // Informational: BenfordCoordinatorActor orchestrates the split, and
        // its spends, receipts and records arrive as their own commands.
        _touch(state, event);
      case final TransactionSpendDeferredEvent evt:
        DeferredPayments.applySpendDeferred(state, evt);
      case final TransactionNetworkStatusCheckedEvent evt:
        DeferredPayments.applyNetworkStatusChecked(state, evt);
      case final DeferredTransactionFailedEvent failed:
        DeferredPayments.applyFailed(state, failed);
      case final DeferredTransactionCancelledEvent cancelled:
        DeferredPayments.applyCancelled(state, cancelled);
      default:
        throw ArgumentError('Unknown event type: ${event.runtimeType}');
    }
    final next = state.build();
    _deferred.stateApplied(current, next, event);
    return next;
  }

  /// An event that changes nothing but the state's version and time.
  static void _touch(WalletStateBuilder state, WalletEvent event) {
    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  /// Logged instead of eventador's print; the error is rethrown.
  @override
  void onEventApplicationFailure(Event event, dynamic error) {
    _log.warning('Wallet $aggregateId: ${event.runtimeType} could not be applied: $error');
  }

  // ==========================================================================
  // COMMANDS WITH REPLY PLUMBING
  // ==========================================================================

  Future<List<Event>> _handleCreateWallet(WalletState currentState, CreateWalletCommand command) async {
    WalletLifecycle.requireNotCreated(currentState, command);
    WalletLifecycle.requireHostCreationMetadata(command);
    final root = await _keys.walletRoot(command);

    // Store the secrets BEFORE the event is persisted. If this throws the
    // command fails and nothing is journaled; if the later persist fails,
    // onCommandFailure removes what was written here.
    _keyMaterialAwaitingPersist[command.commandId] = command.walletId;
    try {
      await _keys.storeKeyMaterial(command, root.hdPublicKeyXpub);
    } catch (e) {
      // A partial write (e.g. mnemonic stored, passphrase not) must not
      // survive: onCommandFailure removes it via the tracking entry.
      _log.severe('Wallet ${command.walletId}: secure storage write failed; '
          'wallet not created: $e');
      rethrow;
    }

    return [WalletLifecycle.created(currentState, command, root)];
  }

  /// The sender to answer [command] directly, when running in an actor
  /// system.
  ActorRef? _replyTo(Command command) {
    final sender = _capturedSenders[command.commandId];
    return _isInActorSystem() && sender != null ? sender : null;
  }

  Future<List<Event>> _handleSignTransaction(
    WalletState currentState,
    SignTransactionCommand command,
  ) async {
    _log.info('Signing tx ${command.transactionId} with ${command.utxoKeys.length} UTXOs, walletType=${currentState.walletType}');

    try {
      final signedTx = await _signer.signTransaction(currentState, command);

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
      if (_replyTo(command) != null) {
        _repliesAwaitingPersist[command.commandId] = TransactionSignedResponse(
          walletId: command.walletId,
          txid: signedTxid, // Use signed txid, not unsigned command.transactionId
          signedHex: signedHex,
          success: true,
        );
      }

      return [event];
    } catch (e) {
      _repliesAwaitingPersist.remove(command.commandId);
      _log.warning('Sign transaction failed for ${command.transactionId}: $e');

      // Send error response if in actor system
      final sender = _replyTo(command);
      if (sender != null) {
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
  Future<List<Event>> _handleSignMultisigTransaction(
    WalletState currentState,
    SignMultisigTransactionCommand command,
  ) async {
    try {
      final signed = await _signer.signMultisigInput(currentState, command);

      // Send response if in actor system
      _replyTo(command)?.tell(MultisigTransactionSignedResponse(
        walletId: command.walletId,
        txid: signed.txid,
        originalTransactionId: command.transactionId, // Pass back for correlation
        signedHex: signed.txHex, // Return unsigned TX - coordinator applies signatures
        signatureHex: signed.signatureHex, // Our signature for the multisig
        success: true,
      ));

      // Return empty event list - we don't need to persist multisig signatures
      // The channel coordinator tracks the transaction state
      return [];
    } catch (e) {
      // Send error response if in actor system
      final sender = _replyTo(command);
      if (sender != null) {
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

  /// Signs one input against a caller-supplied subscript and amount
  /// ([WalletTransactionSigner.signInput]) and replies [InputSignedResponse]
  /// with the signature and that key's public key.
  ///
  /// Nothing is journaled: signing changes no wallet state, so the reply is
  /// sent directly (the reply-after-persist rule of audit M5 concerns
  /// commands that emit events).
  Future<List<Event>> _handleSignInput(WalletState currentState, SignInputCommand command) async {
    final replyTo = _replyTo(command);
    try {
      final signed = await _signer.signInput(currentState, command);
      replyTo?.tell(InputSignedResponse(
        walletId: command.walletId,
        commandId: command.commandId,
        inputIndex: command.inputIndex,
        signatureHex: signed.signatureHex,
        publicKeyHex: signed.publicKeyHex,
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

  /// Handle building and signing a funding transaction for payment channels
  /// ([ChannelFunding.build]): its inputs' reservations are journaled, and
  /// the funding transaction is answered once they are.
  Future<List<Event>> _handleBuildFundingTransaction(
    WalletState currentState,
    BuildFundingTransactionCommand command,
  ) async {
    try {
      final built = await _funding.build(currentState, command);

      // Response with full transaction details for wallet bookkeeping. It is
      // sent from onCommandProcessed once the reservations are journaled
      // (audit M5).
      if (_replyTo(command) != null) {
        _repliesAwaitingPersist[command.commandId] = built.response;
      }

      // Return reservation events to prevent double-spend of selected UTXOs
      // The coordinator will mark as spent after broadcast via RecordOutgoingTransactionCommand
      return built.reservations;
    } catch (e) {
      _repliesAwaitingPersist.remove(command.commandId);

      final sender = _replyTo(command);
      if (sender != null) {
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

  // ==========================================================================
  // PUBLIC HELPERS (forwarded to the collaborators)
  // ==========================================================================

  /// Chain discriminator on [AddressGeneratedEvent.purpose] /
  /// [GenerateAddressCommand.purpose].
  static const String changePurpose = AddressBook.changePurpose;

  /// `reservationReason` of a held input.
  static const String deferredHoldReason = DeferredPayments.holdReason;

  /// `reservationPriority` of a held input. Informational: a hold is refused
  /// to every reservation by rule, not by priority.
  static const int deferredHoldPriority = DeferredPayments.holdPriority;

  /// Check if UTXO can be spent (business rules)
  bool canSpendUTXO(WalletState state, String utxoKey) => UtxoLedger.isAvailable(state, utxoKey);

  /// Check if UTXO can be reserved (business rules)
  bool canReserveUTXO(WalletState state, String utxoKey) => UtxoLedger.isAvailable(state, utxoKey);

  /// Get available UTXOs for spending (excludes plugin-managed UTXOs like
  /// tokens, and watch-only UTXOs at watch addresses, bead libspiffy-87a2)
  List<BitcoinUtxo> getAvailableUTXOs(WalletState state) => UtxoLedger.available(state);

  /// Get UTXOs with specific reservation
  List<BitcoinUtxo> getReservedUTXOs(WalletState state, String reservationId) =>
      UtxoLedger.reservedBy(state, reservationId);

  /// Whether [selectUTXOsForAmount] can cover [requiredAmount]:
  /// [WalletState.availableBalance], the total of the UTXOs it may select,
  /// is at least [requiredAmount]. Fees are the caller's to add.
  bool hasSufficientBalance(WalletState state, BigInt requiredAmount) {
    return state.availableBalance >= requiredAmount;
  }

  /// Select UTXOs for a specific amount (simple first-fit algorithm)
  List<BitcoinUtxo> selectUTXOsForAmount(WalletState state, BigInt amount) =>
      UtxoLedger.selectForAmount(state, amount);
}
