// An actor reaching its own context is the intended use of dactor's
// @internal `Actor.context`.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';

import '../core/wallet_commands.dart';
import '../core/wallet_events.dart';
import '../models/bitcoin_utxo.dart';
import '../models/wallet_type.dart';
import '../storage/secure_storage.dart';
import '../services/watch_only_funds.dart';
import '../storage/read_model_storage.dart';
import '../utils/benford_distribution.dart';
import 'aggregate_signing_client.dart';
import 'wallet_messages.dart';

/// Coordinator actor for Benford UTXO splitting operations
///
/// This actor handles the orchestration of splitting UTXOs according to
/// Benford's Law distribution. For each UTXO to split it:
/// 1. Asks the wallet aggregate (through WalletManagerActor) for the wallet
///    type and the UTXOs it can spend now
/// 2. Reserves the source UTXO and generates new addresses for outputs
/// 3. Calculates Benford-distributed amounts, builds the transaction and has
///    the wallet aggregate sign it
/// 4. Records the transaction with a deferred spend and waits until the
///    wallet has journaled it
/// 5. Broadcasts it via ARCActor
///
/// The split is a deferred payment like any other (bead libspiffy-ypp): the
/// wallet holds its source until ARC reports it on the network (the spend
/// applies, V-16) or rejected (the source is released), or the user cancels
/// it. It is never broadcast before it is recorded, so a split that reaches
/// miners always has its record in the journal.
class BenfordCoordinatorActor extends Actor {
  final _log = Logger('BenfordCoordinatorActor');
  final ActorRef _walletManager;
  final ActorRef _arcActor;
  final ReadModelStorage _storage;
  final Duration _signingReplyTimeout;
  final Duration _walletReplyTimeout;

  /// [secureStorage] is no longer used: split transactions are signed by the
  /// wallet aggregate, which alone reads key material (audit A-H8).
  BenfordCoordinatorActor({
    required ActorRef walletManager,
    required ActorRef arcActor,
    @Deprecated('Unused: signing is delegated to the wallet aggregate')
    SecureStorage? secureStorage,
    required ReadModelStorage storage,
    Duration signingReplyTimeout = const Duration(seconds: 20),
    Duration walletReplyTimeout = const Duration(seconds: 30),
  })  : _walletManager = walletManager,
        _arcActor = arcActor,
        _storage = storage,
        _signingReplyTimeout = signingReplyTimeout,
        _walletReplyTimeout = walletReplyTimeout;

  @override
  void preStart() {
  }

  @override
  Future<void> onMessage(dynamic message) async {
    try {
      if (message is UTXOSplitInitiatedEvent) {
        await _handleSplitInitiated(message);
      } else if (message is SplitUTXOsToBenfordCommand) {
        // Command can be sent directly to coordinator
        await _handleSplitCommand(message);
      } else {
      }
    } catch (e, stackTrace) {
      _log.warning('Failed to handle message: $e', e, stackTrace);
      if (message is SplitUTXOsToBenfordCommand) {
        _sendErrorResponse(message, 'Split failed: $e');
      }
    }
  }

  /// The wallet's type and spendable UTXOs, from its aggregate (bead
  /// libspiffy-ypp): the read model lags the journal, so a wallet created or
  /// funded moments earlier looked unknown or empty there.
  Future<WalletSpendableUtxosResponse> _walletSpendableUtxos(String walletId) async {
    try {
      return await _walletManager.ask<WalletSpendableUtxosResponse>(
        WalletSpendableUtxosQuery(walletId: walletId),
        _walletReplyTimeout,
      );
    } catch (e) {
      return WalletSpendableUtxosResponse(
        walletId: walletId,
        walletFound: false,
        error: 'The wallet did not answer: $e',
      );
    }
  }

  /// Handle SplitUTXOsToBenfordCommand sent directly to coordinator
  Future<void> _handleSplitCommand(SplitUTXOsToBenfordCommand command) async {
    final sender = context.sender;

    final wallet = await _walletSpendableUtxos(command.walletId);
    if (!wallet.walletFound) {
      _reply(sender, command, error: 'Wallet not found: ${command.walletId}'
          '${wallet.error != null ? ' (${wallet.error})' : ''}');
      return;
    }

    // Business rule: Watch-only (xpub) wallets cannot sign transactions
    if (wallet.walletType == WalletType.xpub) {
      _reply(sender, command, error: 'Signing (split) not supported for watch-only wallets');
      return;
    }

    // Available UTXOs the wallet can sign for: watch-only UTXOs at watch
    // addresses are left out, the wallet holds no key for them (bead
    // libspiffy-87a2).
    final availableUtxos = wallet.spendable;
    if (availableUtxos.isEmpty) {
      _reply(sender, command,
          error: 'No available UTXOs to split${SignableUtxos(const [], wallet.watchOnly).watchOnlyNote}');
      return;
    }

    // Determine how many UTXOs to split
    final utxosToSplit = command.maxUtxosToSplit != null
        ? availableUtxos.take(command.maxUtxosToSplit!).toList()
        : availableUtxos;

    // Process each UTXO and track results
    final txids = <String>[];
    int successfulSplits = 0;

    for (final sourceUtxo in utxosToSplit) {
      final txid = await _splitSingleUtxo(
        walletId: command.walletId,
        walletType: wallet.walletType!,
        sourceUtxo: sourceUtxo,
        targetCount: command.targetUtxoCount,
        feeRate: command.feeRate ?? BigInt.one,
      );

      if (txid != null) {
        txids.add(txid);
        successfulSplits++;
      }
    }

    sender?.tell(SplitUTXOsResponse(
      walletId: command.walletId,
      success: true,
      splitCount: successfulSplits * command.targetUtxoCount,
      txids: txids,
    ));
  }

  /// Handle UTXOSplitInitiatedEvent from aggregate
  Future<void> _handleSplitInitiated(UTXOSplitInitiatedEvent event) async {
    final wallet = await _walletSpendableUtxos(event.walletId);
    if (!wallet.walletFound || wallet.walletType == null) {
      _log.warning('Split of wallet ${event.walletId} not started: ${wallet.error}');
      return;
    }
    final utxoMap = {for (final u in wallet.spendable) u.key: u};

    // Process each UTXO key
    for (final utxoKey in event.utxoKeysToSplit) {
      final sourceUtxo = utxoMap[utxoKey];
      if (sourceUtxo == null) {
        continue;
      }

      await _splitSingleUtxo(
        walletId: event.walletId,
        walletType: wallet.walletType!,
        sourceUtxo: sourceUtxo,
        targetCount: event.targetUtxoCount,
        feeRate: event.feeRate,
      );
    }
  }

  /// Split a single UTXO into multiple outputs following Benford distribution
  /// Returns the transaction ID if successful, null otherwise
  Future<String?> _splitSingleUtxo({
    required String walletId,
    required WalletType walletType,
    required BitcoinUtxo sourceUtxo,
    required int targetCount,
    required BigInt feeRate,
  }) async {
    // 1. Estimate fee (before reservation to avoid reserving UTXOs we can't use)
    final estimatedTxSize = 180 + (targetCount * 34) + 10;
    final estimatedFee = feeRate * BigInt.from(estimatedTxSize);

    // Check if UTXO is large enough
    final minTotalNeeded = BigInt.from(targetCount) + estimatedFee;
    if (sourceUtxo.satoshis < minTotalNeeded) {
      return null;
    }

    // 2. Reserve the source UTXO to prevent double-spending
    final reservationId = 'benford-split-${sourceUtxo.key}-${DateTime.now().millisecondsSinceEpoch}';
    final reserved = await _reserveUTXO(walletId, sourceUtxo, reservationId);
    if (!reserved) {
      _log.info('UTXO ${sourceUtxo.key} could not be reserved, skipping');
      return null;
    }

    try {
      // 3. Calculate Benford distribution
      final amountToDistribute = sourceUtxo.satoshis - estimatedFee;
      final outputAmounts = BenfordDistribution.distribute(
        amountToDistribute,
        targetCount,
      );

      // 4. Generate new addresses
      final outputAddresses = await _generateAddresses(
        walletId: walletId,
        walletType: walletType,
        count: targetCount,
        sourceAddress: sourceUtxo.address,
      );

      // 5. Build and sign transaction
      final txResult = await _buildAndSignTransaction(
        walletId: walletId,
        sourceUtxo: sourceUtxo,
        outputAddresses: outputAddresses,
        outputAmounts: outputAmounts,
        feeRate: feeRate,
      );

      if (txResult == null) {
        _releaseReservation(walletId: walletId, reservationId: reservationId);
        return null;
      }

      final txid = txResult['txid'] as String;
      final txHex = txResult['txHex'] as String;
      final actualFee = txResult['actualFee'] as BigInt;
      final totalOutput = outputAmounts.fold<BigInt>(BigInt.zero, (sum, amount) => sum + amount);

      // 6. Record the split before anything else learns of it (bead
      // libspiffy-ypp). deferSpend: the wallet holds the source (the hold
      // supersedes the reservation) until ARC reports the split on the
      // network (the spend applies), or rejected (the source is released).
      // The aggregate registers the outputs paying its own addresses as
      // pending UTXOs from the recorded transaction.
      final recordError = await _recordSplit(RecordOutgoingTransactionCommand(
        walletId: walletId,
        txid: txid,
        rawHex: txHex,
        totalInputSats: sourceUtxo.satoshis.toInt(),
        totalOutputSats: totalOutput.toInt(),
        fee: actualFee.toInt(),
        numInputs: 1,
        numOutputs: outputAmounts.length,
        txVersion: 2,
        txLockTime: 0,
        spentUtxoKeys: [sourceUtxo.key],
        recipientAddresses: outputAddresses,
        paymentAmount: totalOutput,
        deferSpend: true,
        purpose: 'benford-split',
      ));
      if (recordError != null) {
        // Not broadcast: nothing reached the network. A recording that was
        // journaled after all holds the source by the txid; releasing the
        // reservation id does not touch that hold.
        _log.warning('Benford split $txid of ${sourceUtxo.key} not recorded, not broadcast: $recordError');
        _releaseReservation(walletId: walletId, reservationId: reservationId);
        return null;
      }

      // 7. Broadcast via ARCActor. Its answer settles the hold; a failed
      // submission is retried from ARCActor's queue.
      _arcActor.tell(BroadcastTransactionMessage(
        walletId,
        txHex,
        txid,
      ));

      return txid;

    } catch (e) {
      _log.warning('Failed to build or record Benford split transaction: $e');
      _releaseReservation(walletId: walletId, reservationId: reservationId);
      return null;
    }
  }

  /// Sends [command] to the wallet and waits until it is journaled. Returns
  /// null once it is, or why it is not (refused, or no answer).
  Future<String?> _recordSplit(RecordOutgoingTransactionCommand command) async {
    final completer = Completer<String?>();
    final receiver = await context.system.spawn(
      'benford-record-${command.txid}-${DateTime.now().microsecondsSinceEpoch}',
      () => _RecordingReceiverActor(command.txid, completer),
    );
    try {
      _walletManager.tell(WalletCommandMessage(command.walletId, command), sender: receiver);
      return await completer.future.timeout(_walletReplyTimeout,
          onTimeout: () => 'no answer from the wallet within $_walletReplyTimeout');
    } finally {
      await context.system.stop(receiver);
    }
  }

  /// Generate N new addresses for the wallet
  /// 
  /// For HD wallets, this waits for address persistence before returning
  /// to ensure addresses are in the database before transactions are broadcast.
  Future<List<String>> _generateAddresses({
    required String walletId,
    required WalletType walletType,
    required int count,
    required String sourceAddress,
  }) async {
    final addresses = <String>[];

    // A WIF wallet has a single key and therefore a single address, the one
    // the source UTXO sits on: all outputs go back to it.
    if (walletType == WalletType.wif) {
      for (int i = 0; i < count; i++) {
        addresses.add(sourceAddress);
      }
      return addresses;
    }

    // For HD wallets, generate addresses and WAIT for persistence
    final futures = <Future<String>>[];
    final receivers = <ActorRef>[];

    for (int i = 0; i < count; i++) {
      final completer = Completer<String>();

      // Spawn temporary actor to receive response
      final receiverName = 'benford-addr-receiver-$i-${DateTime.now().millisecondsSinceEpoch}';
      final receiver = await context.system.spawn(
        receiverName,
        () => _AddressReceiverActor(completer),
      );
      receivers.add(receiver);

      // Create command with UNIQUE commandId to prevent sender overwriting
      // Each command needs its own ID so BitcoinWalletAggregate can track senders separately
      final command = GenerateAddressCommand(
        walletId: walletId,
        commandId: 'benford-addr-gen-$i-${DateTime.now().microsecondsSinceEpoch}',
      );

      // Send command WITH sender for response routing
      _walletManager.tell(
        WalletCommandMessage(walletId, command),
        sender: receiver,
      );

      futures.add(completer.future);

      // Small delay to ensure unique timestamps for commandId
      await Future.delayed(const Duration(microseconds: 10));
    }

    // Wait for ALL addresses to be generated and persisted
    try {
      final generatedAddresses = await Future.wait(futures)
          .timeout(const Duration(seconds: 30));
      addresses.addAll(generatedAddresses);
    } on TimeoutException {
      throw StateError('Address generation timed out after 30 seconds');
    } catch (e) {
      rethrow;
    } finally {
      // Clean up temporary receiver actors to prevent resource leaks
      for (final receiver in receivers) {
        await context.system.stop(receiver);
      }
    }

    return addresses;
  }

  /// Build a split transaction and have the wallet aggregate sign it.
  Future<Map<String, dynamic>?> _buildAndSignTransaction({
    required String walletId,
    required BitcoinUtxo sourceUtxo,
    required List<String> outputAddresses,
    required List<BigInt> outputAmounts,
    required BigInt feeRate,
  }) async {
    try {
      // Build the unsigned transaction. The wallet aggregate, which alone
      // holds key material (audit A-H8), fills in the signature and public
      // key for the input, using the derivation path (index and chain) the
      // read model records for the source address.
      final txBuilder = dartsv.TransactionBuilder();

      final lockedAddress = dartsv.Address.fromBase58(sourceUtxo.address);
      final lockingScript = dartsv.P2PKHLockBuilder.fromAddress(lockedAddress)
          .getScriptPubkey();
      final outpoint = dartsv.TransactionOutpoint(
        sourceUtxo.txid,
        sourceUtxo.vout,
        sourceUtxo.satoshis,
        lockingScript,
      );
      txBuilder.spendFromOutpoint(
        outpoint,
        dartsv.TransactionInput.MAX_SEQ_NUMBER,
        dartsv.P2PKHUnlockBuilder(null),
      );

      // Add outputs
      for (int i = 0; i < outputAmounts.length; i++) {
        final address = dartsv.Address.fromBase58(outputAddresses[i]);
        txBuilder.spendToPKH(address, outputAmounts[i]);
      }

      // Set fee rate and build
      txBuilder
          .withFeePerKb(feeRate.toInt())
          .withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);

      final unsignedTx = txBuilder.build(false); // Skip sanity checks

      final signedHex = await AggregateSigningClient(
        system: context.system,
        walletManager: _walletManager,
        storage: _storage,
        replyTimeout: _signingReplyTimeout,
      ).signTransaction(
        walletId: walletId,
        transactionId: unsignedTx.id,
        unsignedTxHex: unsignedTx.serialize(),
        utxos: [sourceUtxo],
      );
      final signedTx = dartsv.Transaction.fromHex(signedHex);

      // Calculate actual fee
      final actualFee = sourceUtxo.satoshis - outputAmounts.fold<BigInt>(
        BigInt.zero,
        (sum, amount) => sum + amount,
      );

      return {
        'txid': signedTx.id,
        'txHex': signedHex,
        'actualFee': actualFee,
      };
    } catch (e) {
      _log.warning('Failed to build or sign the split of ${sourceUtxo.key}: $e');
      return null;
    }
  }

  /// Reserve a single UTXO via the wallet aggregate.
  ///
  /// The aggregate replies with [UTXOReservedResponse] on success and on
  /// failure; no reply within the timeout is a failure.
  Future<bool> _reserveUTXO(String walletId, BitcoinUtxo utxo, String reservationId) async {
    final completer = Completer<void>();
    final receiverName = 'reserve-receiver-${utxo.key.replaceAll(':', '-')}-${DateTime.now().microsecondsSinceEpoch}';
    final receiver = await context.system.spawn(
      receiverName,
      () => _ReservationReceiverActor(completer),
    );

    try {
      _walletManager.tell(
        WalletCommandMessage(
          walletId,
          ReserveUTXOCommand(
            walletId: walletId,
            utxoKey: utxo.key,
            reservedByTxId: reservationId,
            reservationReason: 'benford-split',
            reservationDuration: const Duration(minutes: 2),
          ),
        ),
        sender: receiver,
      );

      await completer.future.timeout(const Duration(seconds: 10));
      return true;
    } on TimeoutException {
      _log.warning('No reply to reservation of ${utxo.key}; treating as failed');
      return false;
    } on StateError catch (e) {
      _log.info('UTXO reservation failed for ${utxo.key}: $e');
      return false;
    } catch (e) {
      _log.warning('UTXO reservation unexpected error for ${utxo.key}: $e');
      return false;
    } finally {
      await context.system.stop(receiver);
    }
  }

  /// Release a UTXO reservation (fire-and-forget).
  /// The 2-minute expiry is a safety net if this fails.
  void _releaseReservation({required String walletId, required String reservationId}) {
    _walletManager.tell(WalletCommandMessage(
      walletId,
      ReleaseUTXOsCommand(
        walletId: walletId,
        reservationId: reservationId,
      ),
    ));
  }

  /// Send error response back to the sender
  void _sendErrorResponse(SplitUTXOsToBenfordCommand command, String error) =>
      _reply(context.sender, command, error: error);

  /// Answers [sender] that [command] failed with [error].
  void _reply(ActorRef? sender, SplitUTXOsToBenfordCommand command, {required String error}) {
    sender?.tell(SplitUTXOsResponse(
      walletId: command.walletId,
      success: false,
      error: error,
    ));
  }
}

/// Completes with null once the wallet acknowledges the recording of [txid]
/// ([TransactionRecordedResponse]), or with the wallet's refusal.
class _RecordingReceiverActor extends Actor {
  final String txid;
  final Completer<String?> completer;

  _RecordingReceiverActor(this.txid, this.completer);

  @override
  Future<void> onMessage(dynamic message) async {
    if (completer.isCompleted) return;
    if (message is TransactionRecordedResponse && message.txid == txid) {
      completer.complete(message.success ? null : (message.error ?? 'recording refused'));
      return;
    }
    // The aggregate's generic failure reply.
    final payload = message is LocalMessage ? message.payload : message;
    if (payload is Map && payload.containsKey('error')) {
      completer.complete(payload['error'].toString());
    }
  }
}

/// Helper actor to receive UTXO reservation error responses.
/// On success, the aggregate sends nothing — the completer times out (= success).
/// On failure, the aggregate sends a LocalMessage with an error payload.
class _ReservationReceiverActor extends Actor {
  final Completer<void> completer;

  _ReservationReceiverActor(this.completer);

  @override
  Future<void> onMessage(dynamic message) async {
    if (completer.isCompleted) return;
    if (message is UTXOReservedResponse) {
      if (message.success) {
        completer.complete();
      } else {
        completer.completeError(StateError(message.error ?? 'reservation rejected'));
      }
      return;
    }
    // Legacy shape: the aggregate's generic failure reply.
    final payload = message is LocalMessage ? message.payload : message;
    if (payload is Map && payload.containsKey('error')) {
      completer.completeError(StateError(payload['error'].toString()));
    }
  }
}

/// Helper actor to receive address generation responses
class _AddressReceiverActor extends Actor {
  final Completer<String> completer;

  _AddressReceiverActor(this.completer);
  
  @override
  void preStart() {
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is AddressGeneratedResponse && !completer.isCompleted) {
      if (message.success) {
        completer.complete(message.address);
      } else {
        completer.completeError(
          Exception(message.error ?? 'Address generation failed'),
        );
      }
    } else if (message is AddressGeneratedResponse) {
    } else {
    }
  }
}

