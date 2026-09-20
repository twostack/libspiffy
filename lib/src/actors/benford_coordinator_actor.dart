// An actor reaching its own context is the intended use of dactor's
// @internal `Actor.context`.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';

import '../core/wallet_commands.dart';
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
/// 5. Broadcasts it via ARCActor ([BroadcastDeferredPaymentMessage])
///
/// The split is a deferred payment like any other (bead libspiffy-ypp): the
/// wallet holds its source until ARC reports it on the network (the spend
/// applies, V-16) or rejected (the source is released), or the user cancels
/// it. It is never broadcast before it is recorded, so a split that reaches
/// miners always has its record in the journal.
///
/// The reply ([SplitUTXOsResponse]) follows ARC's answer to each broadcast
/// (bead libspiffy-wdch; [SplitTransactionStatus]): a split ARC accepted,
/// or could not reach and queued for a retry, succeeds; one ARC rejected or
/// reports contested (DOUBLE_SPEND_ATTEMPTED), or that was recorded but
/// neither broadcast nor queued, does not. ARC's answer is awaited outside
/// the mailbox and handed back through it, so the coordinator keeps serving
/// other requests meanwhile. A recording the wallet did not acknowledge in
/// time is not broadcast and is cancelled, so a recording journaled late
/// does not hold the source for a transaction nobody broadcasts.
class BenfordCoordinatorActor extends Actor {
  final _log = Logger('BenfordCoordinatorActor');
  final ActorRef _walletManager;
  final ActorRef _arcActor;
  final ReadModelStorage _storage;
  final Duration _signingReplyTimeout;
  final Duration _walletReplyTimeout;
  final Duration _broadcastReplyTimeout;

  /// Split requests waiting for ARC's answers, by request id.
  final Map<int, _PendingSplitReply> _pendingReplies = {};
  int _nextRequestId = 0;

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
    Duration broadcastReplyTimeout = const Duration(minutes: 2),
  })  : _walletManager = walletManager,
        _arcActor = arcActor,
        _storage = storage,
        _signingReplyTimeout = signingReplyTimeout,
        _walletReplyTimeout = walletReplyTimeout,
        _broadcastReplyTimeout = broadcastReplyTimeout;

  @override
  void preStart() {
  }

  @override
  Future<void> onMessage(dynamic message) async {
    try {
      if (message is SplitUTXOsToBenfordCommand) {
        // Command can be sent directly to coordinator
        await _handleSplitCommand(message);
      } else if (message is _SplitBroadcastOutcome) {
        _handleBroadcastOutcome(message);
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

    // Split each UTXO. A split that is recorded is broadcast; ARC's answer
    // comes back through the mailbox, and the reply waits for every one.
    final requestId = _nextRequestId++;
    final pending = _PendingSplitReply(sender, command);
    _pendingReplies[requestId] = pending;
    try {
      for (final sourceUtxo in utxosToSplit) {
        final attempt = await _splitSingleUtxo(
          walletId: command.walletId,
          walletType: wallet.walletType!,
          sourceUtxo: sourceUtxo,
          targetCount: command.targetUtxoCount,
          feeRate: command.feeRate ?? BigInt.one,
        );
        final index = pending.outcomes.length;
        pending.outcomes.add(attempt.settled);
        if (attempt.settled == null) {
          pending.awaiting++;
          unawaited(_awaitBroadcast(context.self, requestId, index, command.walletId, attempt));
        }
      }
    } catch (_) {
      _pendingReplies.remove(requestId);
      rethrow;
    }
    pending.allStarted = true;
    _replyIfSettled(requestId);
  }

  /// Runs outside the mailbox: broadcasts [split] through ARCActor, waits
  /// for its answer and hands it to the mailbox ([_SplitBroadcastOutcome]).
  Future<void> _awaitBroadcast(ActorRef self, int requestId, int index, String walletId, _SplitAttempt split) async {
    DeferredPaymentNetworkResult? result;
    String? failure;
    try {
      result = await _arcActor.ask<DeferredPaymentNetworkResult>(
        BroadcastDeferredPaymentMessage(
          walletId: walletId,
          // Only a recorded split is broadcast, and a recorded split has
          // both (`settled == null` is exactly that case).
          txid: split.txid!,
          rawTxHex: split.txHex!,
          via: DeferredPaymentNetworkSource.arc,
        ),
        _broadcastReplyTimeout,
      );
    } on TimeoutException {
      failure = 'ARC did not answer within $_broadcastReplyTimeout';
    } catch (e) {
      failure = 'ARC did not answer: $e';
    }
    try {
      self.tell(LocalMessage(payload: _SplitBroadcastOutcome(requestId, index, split, result, failure)));
    } catch (e) {
      _log.fine('Benford coordinator gone; dropping the broadcast outcome of ${split.txid}: $e');
    }
  }

  /// Mailbox half of a broadcast: records its outcome and replies once the
  /// request has none outstanding.
  void _handleBroadcastOutcome(_SplitBroadcastOutcome outcome) {
    final pending = _pendingReplies[outcome.requestId];
    if (pending == null) {
      _log.fine('Broadcast outcome of ${outcome.split.txid} answers no pending split request');
      return;
    }
    pending.outcomes[outcome.index] = _classify(outcome);
    pending.awaiting--;
    _replyIfSettled(outcome.requestId);
  }

  /// The status of the split [outcome] answers for.
  static SplitTransactionOutcome _classify(_SplitBroadcastOutcome outcome) {
    final split = outcome.split;
    final result = outcome.result;
    SplitTransactionOutcome of(SplitTransactionStatus status, {String? networkStatus, String? error}) =>
        SplitTransactionOutcome(
          txid: split.txid,
          sourceUtxoKey: split.sourceUtxoKey,
          status: status,
          networkStatus: networkStatus,
          error: error,
          feePaid: split.feePaid,
        );
    final name = 'Benford split ${split.txid} of ${split.sourceUtxoKey}';
    if (result == null) {
      return of(SplitTransactionStatus.unanswered,
          error: '$name: ${outcome.failure}; it is recorded and holds its source until its network status '
              'settles it (GetDeferredPaymentsQuery lists it)');
    }
    final status = result.networkStatus;
    if (!result.success) {
      if (result.willRetry) {
        return of(SplitTransactionStatus.queued, error: result.error);
      }
      return of(SplitTransactionStatus.notBroadcast,
          error: '$name is recorded and holds its source but was not broadcast (${result.error}); '
              'broadcast it with BroadcastDeferredPaymentCommand or cancel it with CancelDeferredPaymentCommand');
    }
    final reason = result.error ?? 'no reason given';
    if (DeferredNetworkStatus.isDefinitiveFailure(status)) {
      return of(SplitTransactionStatus.rejected,
          networkStatus: status, error: '$name rejected by ARC ($status: $reason); its source is released');
    }
    if (DeferredNetworkStatus.isContested(status)) {
      return of(SplitTransactionStatus.contested,
          networkStatus: status,
          error: '$name contested: ARC reports $status ($reason). A competing transaction spends its source, '
              'which stays held until ARC reports one of them mined or the split is cancelled '
              '(CancelDeferredPaymentCommand)');
    }
    // Any other status is one of a transaction ARC holds on its way to
    // miners (see DeferredNetworkStatus.allowsCancel).
    return of(SplitTransactionStatus.accepted, networkStatus: status);
  }

  /// Answers the request [requestId] once every source UTXO has been
  /// attempted and ARC has answered each broadcast.
  void _replyIfSettled(int requestId) {
    final pending = _pendingReplies[requestId];
    if (pending == null || !pending.allStarted || pending.awaiting > 0) return;
    _pendingReplies.remove(requestId);
    final outcomes = [for (final o in pending.outcomes) o!];
    final made = [for (final o in outcomes) if (o.isSuccess) o.txid!];
    final failed = [
      for (final o in outcomes)
        if (!o.isSuccess)
          o.error ?? '${o.txid ?? o.sourceUtxoKey}: ${o.status.name}'
    ];
    pending.sender?.tell(SplitUTXOsResponse(
      walletId: pending.command.walletId,
      success: failed.isEmpty,
      error: failed.isEmpty ? null : failed.join('; '),
      splitCount: made.length * pending.command.targetUtxoCount,
      txids: made,
      splits: outcomes,
    ));
  }

  /// Split a single UTXO into multiple outputs following Benford
  /// distribution.
  ///
  /// Always returns an attempt, so every source the caller asked about is
  /// accounted for in the reply. A source that built no transaction comes
  /// back as [_SplitAttempt.notBuilt] carrying the reason; before bead
  /// libspiffy-q28i these four paths returned null and the source vanished
  /// from the answer, which made a run where every source failed look like a
  /// success.
  Future<_SplitAttempt> _splitSingleUtxo({
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
      return _SplitAttempt.notBuilt(
          sourceUtxo.key,
          '${sourceUtxo.key} is too small to split into $targetCount outputs: '
          'it holds ${sourceUtxo.satoshis} satoshis and $minTotalNeeded are '
          'needed ($estimatedFee of fee at $feeRate sat/byte, and one '
          'satoshi per output). Nothing was reserved and the source is '
          'untouched.');
    }

    // 2. Reserve the source UTXO to prevent double-spending
    final reservationId = 'benford-split-${sourceUtxo.key}-${DateTime.now().millisecondsSinceEpoch}';
    final reserved = await _reserveUTXO(walletId, sourceUtxo, reservationId);
    if (!reserved) {
      _log.info('UTXO ${sourceUtxo.key} could not be reserved, skipping');
      return _SplitAttempt.notBuilt(
          sourceUtxo.key,
          'the wallet would not reserve ${sourceUtxo.key} for the split: it '
          'is already spoken for, or it did not answer. Nothing was built '
          'and the source is untouched.');
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
        return _SplitAttempt.notBuilt(
            sourceUtxo.key,
            'the split of ${sourceUtxo.key} could not be built or signed; '
            'nothing was recorded or broadcast and its reservation is '
            'released (the log names the failure)');
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
      final record = await _recordSplit(RecordOutgoingTransactionCommand(
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
      if (record.error != null) {
        // Not broadcast: nothing reached the network.
        _log.warning('Benford split $txid of ${sourceUtxo.key} not recorded, not broadcast: ${record.error}');
        var error = 'Benford split $txid of ${sourceUtxo.key} was not recorded (${record.error}); not broadcast';
        if (!record.answered) {
          // The wallet may still journal the recording, which would hold
          // the source for a transaction nobody broadcasts (bead
          // libspiffy-wdch). The cancellation reaches the wallet after the
          // recording, in command order: it releases a recording journaled
          // late, and is refused when there is none. Cancelled rather than
          // broadcast: this split never left the process, and a broadcast
          // follows only an acknowledged recording (bead libspiffy-ypp).
          _walletManager.tell(WalletCommandMessage(
            walletId,
            CancelDeferredSpendCommand(
              walletId: walletId,
              txid: txid,
              reason: 'Benford split never broadcast: the wallet did not acknowledge its recording in time',
            ),
          ));
          error += '; a recording the wallet journals late is cancelled';
        }
        _releaseReservation(walletId: walletId, reservationId: reservationId);
        return _SplitAttempt(txid, txHex, sourceUtxo.key,
            feePaid: actualFee,
            settled: SplitTransactionOutcome(
              txid: txid,
              sourceUtxoKey: sourceUtxo.key,
              status: SplitTransactionStatus.notRecorded,
              error: error,
              feePaid: actualFee,
            ));
      }

      // 7. Broadcast via ARCActor: the caller does, and waits for ARC's
      // answer outside the mailbox. ARC's answer settles the hold; a failed
      // submission is retried from ARCActor's queue.
      return _SplitAttempt(txid, txHex, sourceUtxo.key, feePaid: actualFee);

    } catch (e) {
      _log.warning('Failed to build or record Benford split transaction: $e');
      _releaseReservation(walletId: walletId, reservationId: reservationId);
      return _SplitAttempt.notBuilt(
          sourceUtxo.key,
          'the split of ${sourceUtxo.key} failed before anything was '
          'recorded or broadcast ($e); its reservation is released');
    }
  }

  /// Sends [command] to the wallet and waits until it is journaled. The
  /// error is null once it is, or says why it is not; [answered] is false
  /// when the wallet did not answer in time (it may still journal it).
  Future<({String? error, bool answered})> _recordSplit(RecordOutgoingTransactionCommand command) async {
    final completer = Completer<String?>();
    final receiver = await context.system.spawn(
      'benford-record-${command.txid}-${DateTime.now().microsecondsSinceEpoch}',
      () => _RecordingReceiverActor(command.txid, completer),
    );
    try {
      _walletManager.tell(WalletCommandMessage(command.walletId, command), sender: receiver);
      final error = await completer.future.timeout(_walletReplyTimeout);
      return (error: error, answered: true);
    } on TimeoutException {
      return (error: 'no answer from the wallet within $_walletReplyTimeout', answered: false);
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

      // Each command needs its own id so BitcoinWalletAggregate can track the
      // senders separately. The loop index alone makes it unique, so the
      // commands are not spaced out in time: the 10 us delay this used to
      // sleep per address rounds up to about a millisecond on most
      // platforms, for up to 100 outputs per source UTXO, and guarded an
      // invariant the index already holds (bead libspiffy-y0ce).
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

      // [feeRate] is satoshis per BYTE (SplitUTXOsToBenfordCommand) and this
      // builder takes satoshis per KILOBYTE: passing it through unscaled
      // understated the rate a thousandfold. It changes nothing today,
      // because every output amount is given explicitly and there is no
      // change output for the builder to size, but a wrong unit sitting in
      // the code is a trap for whoever adds one (bead libspiffy-q28i).
      txBuilder
          .withFeePerKb((feeRate * BigInt.from(1000)).toInt())
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

/// A split transaction that was built and signed: recorded, or not
/// ([notRecorded]).
class _SplitAttempt {
  /// Null when no transaction was built ([settled] is then the outcome).
  final String? txid;
  final String? txHex;
  final String sourceUtxoKey;

  /// The fee the built transaction pays; null when none was built.
  final BigInt? feePaid;

  /// The outcome when this attempt is already over — nothing was built, or
  /// it was built but not recorded. Null only when the split is recorded and
  /// is waiting for ARC's answer to its broadcast.
  final SplitTransactionOutcome? settled;

  _SplitAttempt(this.txid, this.txHex, this.sourceUtxoKey,
      {this.feePaid, this.settled});

  /// No transaction was built for [sourceUtxoKey]: [reason] says why.
  _SplitAttempt.notBuilt(String sourceUtxoKey, String reason)
      : this(null, null, sourceUtxoKey,
            settled: SplitTransactionOutcome(
              txid: null,
              sourceUtxoKey: sourceUtxoKey,
              status: SplitTransactionStatus.notBuilt,
              error: reason,
            ));
}

/// A split request waiting for ARC's answers to its broadcasts.
class _PendingSplitReply {
  final ActorRef? sender;
  final SplitUTXOsToBenfordCommand command;

  /// One per split transaction, in split order; null while its broadcast
  /// is unanswered.
  final List<SplitTransactionOutcome?> outcomes = [];
  int awaiting = 0;

  /// Every source UTXO has been attempted.
  bool allStarted = false;
  _PendingSplitReply(this.sender, this.command);
}

/// Mailbox half of one broadcast: ARCActor's [result], or why none came
/// ([failure]).
class _SplitBroadcastOutcome {
  final int requestId;
  final int index;
  final _SplitAttempt split;
  final DeferredPaymentNetworkResult? result;
  final String? failure;
  const _SplitBroadcastOutcome(this.requestId, this.index, this.split, this.result, this.failure);
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

