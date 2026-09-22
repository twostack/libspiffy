import 'dart:typed_data';
import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart' as spiffy;
import 'package:convert/convert.dart';

import '../core/wallet_events.dart' as wevent;

import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../models/fee_rate.dart';
import '../models/invoice_output_spec.dart';
import '../plugin/plugin_registry.dart';
import '../plugin/plugin_types.dart';
import '../plugin/transaction_builder_plugin.dart';
import '../storage/read_model_storage.dart';
import '../storage/transaction_row_rules.dart';
import '../storage/secure_storage.dart';
import '../services/ancestor_chain_service.dart';
import '../services/watch_only_funds.dart';
import '../utils/beef.dart';
import '../core/wallet_commands.dart';
import '../core/wallet_output_ownership.dart';
import '../core/wallet/transaction_signer.dart' show WalletTransactionSigner;
import '../core/wallet/transaction_size.dart';
import '../services/transaction/builder/op_return_lockbuilder.dart';
import 'aggregate_signing_client.dart';
import 'payment_messages.dart';
import 'wallet_messages.dart';

/// Coordinator actor for payment operations with SPV BEEF construction
/// 
/// Handles PayInvoiceMessage by:
/// 1. Selecting UTXOs to fund payment
/// 2. Recursively collecting ancestor transactions back to first merkle proof
/// 3. Validating complete chain exists
/// 4. Building payment transaction
/// 5. Creating BEEF package with ancestors and proofs
/// 6. Returning BEEF (does NOT broadcast - pure SPV model)
class PaymentCoordinatorActor extends Actor {
  static final _log = Logger('PaymentCoordinatorActor');
  final ReadModelStorage _storage;
  final ActorRef _walletManager;
  final ActorRef _walletProjection;

  /// ARCActor, asked for the policy rate every payment's fee is paid at
  /// (bead libspiffy-bg7n).
  final ActorRef _arcActor;
  late final AncestorChainService _ancestorService;

  /// Default time we wait for the wallet projection to apply a recorded
  /// transaction event before treating the recording as failed.
  static const _recordPersistTimeout = Duration(seconds: 30);

  /// The payment [_handlePayInvoice] is building (messages are handled one at
  /// a time), with the transactions it recorded with a deferred spend.
  _InFlightPayment? _inFlightPayment;

  /// How long to wait for the aggregate's reply to a ReserveUTXOCommand.
  /// Injectable so tests can exercise the no-reply path quickly.
  final Duration _reservationReplyTimeout;

  /// How long to wait for the wallet aggregate's reply to each signing
  /// request (whole transaction, one input, or a public-key probe).
  final Duration _signingReplyTimeout;

  /// How long to wait for ARCActor's policy rate.
  final Duration _feeRateReplyTimeout;

  /// [secureStorage] is no longer used: every signature is produced by the
  /// wallet aggregate, which alone reads key material (audit A-H8).
  PaymentCoordinatorActor({
    required ActorRef walletManager,
    required ActorRef walletProjection,
    required ActorRef arcActor,
    required ReadModelStorage storage,
    @Deprecated('Unused: signing is delegated to the wallet aggregate')
    SecureStorage? secureStorage,
    Duration reservationReplyTimeout = const Duration(seconds: 10),
    Duration signingReplyTimeout = const Duration(seconds: 20),
    Duration feeRateReplyTimeout = const Duration(seconds: 30),
  })  : _storage = storage,
        _walletManager = walletManager,
        _walletProjection = walletProjection,
        _arcActor = arcActor,
        _reservationReplyTimeout = reservationReplyTimeout,
        _signingReplyTimeout = signingReplyTimeout,
        _feeRateReplyTimeout = feeRateReplyTimeout {
    _ancestorService = AncestorChainService(storage: storage);
  }

  @override
  void preStart() {
  }

  @override
  Future<void> onMessage(dynamic message) async {
    try {
      if (message is PayInvoiceMessage) {
        await _handlePayInvoice(message);
      } else if (message is ProvisionFundingMessage) {
        await _handleProvisionFunding(message);
      } else {
      }
    } catch (e, stackTrace) {
      _log.warning('Failed to handle ${message.runtimeType}: $e', e, stackTrace);
      if (message is PayInvoiceMessage) {
        // A third-party plugin's failure is reported by the plugin's id
        // (bead libspiffy-uetb).
        _sendError(message.invoiceId, e is _PluginCallFailure ? e.message : 'Internal error: $e');
      } else if (message is ProvisionFundingMessage) {
        context.sender?.tell(ProvisionFundingResponse.error(
          walletId: message.walletId,
          error: 'Internal error: $e',
        ));
      }
    }
  }

  /// Handle payment invoice request
  Future<void> _handlePayInvoice(PayInvoiceMessage msg) async {
    final totalSw = Stopwatch()..start();
    // Capture sender before any async gaps to avoid stale references
    final originalSender = context.sender;
    // Calculate effective amount (from outputs or legacy amount)
    final effectiveAmount = msg.effectiveAmount;

    _log.info('[pay ${msg.invoiceId}] Starting payment: amount=$effectiveAmount sats');

    // 1. Get available UTXOs
    final utxoSw = Stopwatch()..start();
    // UTXOs at watch addresses are watch-only funds: the wallet holds no key
    // for them, so no path selects them (bead libspiffy-87a2).
    final paymentUtxos = await splitWatchOnlyUtxos(_storage, msg.walletId, await _storage.getPaymentUTXOs(msg.walletId));
    var utxos = paymentUtxos.signable;
    _log.info('[pay ${msg.invoiceId}] getUTXOs: ${utxoSw.elapsedMilliseconds}ms, count=${utxos.length}, '
        'watch-only=${paymentUtxos.watchOnly.length}');
    // A TransactionBuilderPlugin builds its inputs itself. One that spends
    // its funding through `PluginTransactionRequest.fundingInputs` — each
    // output over its real locking script, with the unlocking script the
    // wallet writes — can be funded from bare multisig and P2PK outputs too
    // (bead libspiffy-0nfk). One that does not builds every input as P2PKH
    // (bead libspiffy-nlp) and would sign those over the wrong script, so
    // they are left out for it: an invalid transaction is worse than a
    // refusal that says why.
    var excludedNote = paymentUtxos.excludedNote;
    if (_isPluginTransaction(msg) && !_pluginSpendsAnyOutput(msg)) {
      final excluded = utxos.where((u) => needsNonP2pkhUnlock(u.scriptPubKey)).toList();
      if (excluded.isNotEmpty) {
        utxos = utxos.where((u) => !needsNonP2pkhUnlock(u.scriptPubKey)).toList();
        final sats = excluded.fold<BigInt>(BigInt.zero, (sum, u) => sum + u.satoshis);
        excludedNote += ' ($sats satoshis in ${excluded.length} bare multisig or P2PK UTXO(s) '
            'cannot fund a plugin transaction)';
      }
    }
    if (utxos.isEmpty) {
      _sendError(msg.invoiceId, 'Insufficient funds$excludedNote', sender: originalSender);
      return;
    }

    // 2. ARC's published policy rate. The fee is that rate on the signed
    // size (bead libspiffy-bg7n); a payment the rate cannot be read for is
    // refused before anything is reserved, not built at a rate nobody
    // published.
    final rate = await _policyRate(msg.invoiceId, originalSender);
    if (rate == null) return;

    // 3. The outputs the payment creates, whose sizes are part of its fee. A
    // TransactionBuilderPlugin builds its own outputs; its funding is sized
    // by the inputs alone.
    final List<_PaymentOutput> paymentOutputs;
    final BigInt amount;
    if (_isPluginTransaction(msg)) {
      paymentOutputs = const [];
      amount = effectiveAmount;
    } else {
      try {
        paymentOutputs = _paymentOutputs(msg);
      } on _PluginCallFailure {
        rethrow;
      } catch (e) {
        _log.warning('[pay ${msg.invoiceId}] cannot build its outputs: $e');
        _sendError(msg.invoiceId, 'Failed to build payment transaction: $e', sender: originalSender);
        return;
      }
      amount = paymentOutputs.fold(BigInt.zero, (sum, output) => sum + output.amount);
    }
    final outputScriptBytes = [for (final output in paymentOutputs) output.scriptBytes];

    // 4. Select UTXOs covering the amount and the fee of the transaction
    // they make.
    final selection = _selectUTXOs(utxos, amount, outputScriptBytes, rate);
    if (selection == null) {
      final totalBalance = utxos.fold<BigInt>(
        BigInt.zero,
        (sum, utxo) => sum + utxo.satoshis,
      );
      _sendError(
        msg.invoiceId,
        'Insufficient funds: need $amount satoshis and the fee of the transaction '
        '(${_feeFor(rate, utxos, outputScriptBytes)} satoshis at ARC\'s policy rate of $rate spending all '
        '${utxos.length} UTXO(s)), have $totalBalance$excludedNote',
        sender: originalSender,
      );
      return;
    }
    final (:selectedUtxos, :fee) = selection;

    // 2a. Reserve selected UTXOs to prevent double-spending
    final reservationId = 'payment-${msg.invoiceId}-${DateTime.now().millisecondsSinceEpoch}';
    final reserved = await _reserveUTXOs(msg.walletId, selectedUtxos, reservationId);
    if (!reserved) {
      _sendError(msg.invoiceId, 'Failed to reserve UTXOs — they may already be in use', sender: originalSender);
      return;
    }

    // From here on the reservation is released on every outcome except a
    // payment handed back to the caller (audit A-M7): failures reported by
    // the steps below and any unexpected exception alike.
    var paymentDelivered = false;
    final inFlight = _InFlightPayment(msg.invoiceId, msg.counterpartyMarker);
    _inFlightPayment = inFlight;
    try {
      paymentDelivered = await _payWithReservedUtxos(
        msg: msg,
        selectedUtxos: selectedUtxos,
        paymentOutputs: paymentOutputs,
        fee: fee,
        rate: rate,
        originalSender: originalSender,
        totalSw: totalSw,
      );
    } catch (e, stackTrace) {
      _log.warning('[pay ${msg.invoiceId}] failed after reserving UTXOs: $e\n$stackTrace');
      // A third-party plugin's failure is reported by the plugin's id, not
      // as an internal error of ours (bead libspiffy-uetb).
      _sendError(msg.invoiceId, e is _PluginCallFailure ? e.message : 'Internal error: $e',
          sender: originalSender);
    } finally {
      _inFlightPayment = null;
      if (!paymentDelivered) {
        // A transaction recorded with a deferred spend holds its inputs
        // until it is settled or cancelled (bead libspiffy-7p2); one that was
        // never handed to anyone is cancelled here, newest first, so the
        // reservation release below finds its inputs again.
        for (final txid in inFlight.deferredTxids.reversed) {
          _walletManager.tell(WalletCommandMessage(
            msg.walletId,
            CancelDeferredSpendCommand(
              walletId: msg.walletId,
              txid: txid,
              reason: 'payment for invoice ${msg.invoiceId} failed before it was handed over',
            ),
          ));
        }
        _releaseReservation(walletId: msg.walletId, reservationId: reservationId);
      }
    }
  }

  /// Builds, signs, records and packages a payment funded by
  /// [selectedUtxos], which the caller has reserved, creating
  /// [paymentOutputs] and paying [fee].
  ///
  /// Returns true once a successful [BEEFPaymentResponse] has been sent.
  /// Returns false after reporting a failure to [originalSender]; throws on
  /// unexpected errors. The caller owns the reservation in every case.
  Future<bool> _payWithReservedUtxos({
    required PayInvoiceMessage msg,
    required List<BitcoinUtxo> selectedUtxos,
    required List<_PaymentOutput> paymentOutputs,
    required BigInt fee,
    required FeeRate rate,
    required ActorRef? originalSender,
    required Stopwatch totalSw,
  }) async {
    final effectiveAmount = msg.effectiveAmount;
    final signing = _signingClient();

    // Check if this payment will be handled by a TransactionBuilderPlugin.
    // Plugin-built transactions manage their own inputs — ancestor chain
    // validation and BEEF construction are not applicable.
    final isPluginTransaction = _isPluginTransaction(msg);

    late final dynamic ancestorResult;
    if (!isPluginTransaction) {
      // 2b. Fast-fail if no block headers synced (can't construct valid BEEF)
      final bestHeight = await _storage.getBestHeight();
      if (bestHeight == 0) {
        _log.warning('[pay ${msg.invoiceId}] No block headers synced yet - cannot construct BEEF payment');
        _sendError(msg.invoiceId, 'No block headers synced yet - cannot construct BEEF payment', sender: originalSender);
        return false;
      }

      // 3. CRITICAL: Validate complete ancestor chain using AncestorChainService
      final ancestorSw = Stopwatch()..start();
      ancestorResult = await _ancestorService.collectAncestorChainForUtxos(
        selectedUtxos.map((u) => u.txid).toList(),
      );
      _log.info('[pay ${msg.invoiceId}] ancestorChain: ${ancestorSw.elapsedMilliseconds}ms, '
          'ancestors=${ancestorResult.isValid ? ancestorResult.ancestorTransactions.length : "N/A"}, '
          'proofs=${ancestorResult.isValid ? ancestorResult.merkleProofs.length : "N/A"}');
      if (!ancestorResult.isValid) {
        _sendError(
          msg.invoiceId,
          'Incomplete transaction chain: ${ancestorResult.error}',
          sender: originalSender,
        );
        return false;
      }
    } else {
      ancestorResult = null;
    }

    // 4. Build payment transaction (with outputs if provided)
    // Returns (transaction, preSigned, witnessTx) — plugin-built transactions are already signed.
    final buildSw = Stopwatch()..start();
    final (paymentTx, preSigned, witnessTx, ancestorTxids) =
        await _buildPaymentTransactionWithOutputs(
      selectedUtxos: selectedUtxos,
      outputs: msg.outputs,
      paymentOutputs: paymentOutputs,
      fee: fee,
      rate: rate,
      changeAddress: msg.changeAddress,
      walletId: msg.walletId,
      signing: signing,
    );

    _log.info('[pay ${msg.invoiceId}] buildTx: ${buildSw.elapsedMilliseconds}ms, preSigned=$preSigned');
    if (paymentTx == null) {
      _sendError(msg.invoiceId, 'Failed to build payment transaction', sender: originalSender);
      return false;
    }

    late final BitcoinTransaction signedPaymentTx;

    if (preSigned) {
      // TransactionBuilderPlugin already built the transaction, with every
      // signature produced by the wallet aggregate.
      signedPaymentTx = paymentTx;
    } else {
      // 4b. The wallet aggregate signs every input with its own key.
      final signSw = Stopwatch()..start();
      final String signedTxHex;
      try {
        signedTxHex = await signing.signTransaction(
          walletId: msg.walletId,
          transactionId: paymentTx.txid,
          unsignedTxHex: paymentTx.rawHex,
          utxos: selectedUtxos,
        );
      } on AggregateSigningException catch (e) {
        _log.warning('[sign] Failed: $e');
        _sendError(msg.invoiceId, 'Failed to sign transaction: $e', sender: originalSender);
        return false;
      }
      _log.info('[pay ${msg.invoiceId}] signing: ${signSw.elapsedMilliseconds}ms');

      // IMPORTANT: TXID changes after signing because scriptSig changes the raw bytes
      final signedDartsvTx = dartsv.Transaction.fromHex(signedTxHex);
      final signedTxid = signedDartsvTx.id;

      signedPaymentTx = BitcoinTransaction(
        txid: signedTxid,
        rawHex: signedTxHex,
        status: paymentTx.status,
        inputValue: paymentTx.inputValue,
        outputValue: paymentTx.outputValue,
        fee: paymentTx.fee,
        receivingAddresses: paymentTx.receivingAddresses,
        sendingAddresses: paymentTx.sendingAddresses,
        netAmount: paymentTx.netAmount,
        createdAt: paymentTx.createdAt,
        updatedAt: DateTime.now(),
        lockTime: paymentTx.lockTime,
        version: paymentTx.version,
      );
    }

    // 4c. Record the outgoing transaction in PENDING state

    // CRITICAL: Use the actual change address (same logic as _buildPaymentTransaction)
    // If no changeAddress was provided, we use the first UTXO's address as change destination
    final actualChangeAddress = msg.changeAddress ?? selectedUtxos.first.address;

    // Get recipient addresses for recording
    final recipientAddresses = _getRecipientAddresses(msg.outputs, msg.addresses);

    final spentUtxoKeys = selectedUtxos.map((u) => '${u.txid}:${u.vout}').toList();
    final primaryDerivationIndex = preSigned
        ? (await signing.pathForAddress(msg.walletId, selectedUtxos.first.address))
            ?.derivationIndex
        : null;
    // Phase 4: when this TX was built by a plugin (preSigned=true), emit a
    // TransactionSignedEvent alongside the recording for audit-trail parity
    // with the SignTransactionCommand path.
    try {
      await _recordOutgoingTransaction(
        walletId: msg.walletId,
        transaction: signedPaymentTx,
        spentUtxoKeys: spentUtxoKeys,
        recipientAddresses: recipientAddresses,
        paymentAmount: effectiveAmount,
        changeAddress: actualChangeAddress,
        deferSpend: true, // inputs held; ARCActor marks spent on SEEN_ON_NETWORK
        purpose: 'invoice-payment',
        preSigned: preSigned,
        signerMetadata: preSigned
            ? {
                'signerType': 'plugin-callback',
                'role': 'primary',
                'derivationIndex': primaryDerivationIndex,
              }
            : null,
      );
    } on _RecordingRefused catch (refused) {
      _sendError(msg.invoiceId, 'The wallet refused to record payment transaction ${signedPaymentTx.txid}: '
          '${refused.error}', sender: originalSender);
      return false;
    }

    if (preSigned) {
      // Plugin-built transaction — return raw tx bytes as a minimal BEEF.
      // The plugin manages its own inputs; no ancestor chain or merkle proofs.
      try {
        // Record paired witness TX if present
        if (witnessTx != null) {
          // Identify which reserved UTXOs the witness TX spends
          final witnessDartsvTx = dartsv.Transaction.fromHex(witnessTx.rawHex);
          final witnessSpentKeys = <String>[];
          for (final input in witnessDartsvTx.inputs) {
            final key = '${input.prevTxnId}:${input.prevTxnOutputIndex}';
            witnessSpentKeys.add(key);
          }
          await _recordOutgoingTransaction(
            walletId: msg.walletId,
            transaction: witnessTx,
            spentUtxoKeys: witnessSpentKeys,
            recipientAddresses: ['witness'],
            paymentAmount: BigInt.zero,
            changeAddress: actualChangeAddress,
            preSigned: true,
            signerMetadata: {
              'signerType': 'plugin-callback',
              'role': 'witness',
              'derivationIndex': primaryDerivationIndex,
            },
          );
        }

        // Package the primary plugin TX with any auto-provisioned ancestors
        // into a BEEF. Ancestors come from `ancestorTxids` (populated by
        // `_autoProvisionForPlugin`); their rawHex is loaded from the wallet
        // read model since `_autoProvisionForPlugin` persists every entry
        // before returning. They don't exist on chain yet so they carry
        // hasMerkle=false. The caller must settle this BEEF via ARC to push
        // everything out (see SettleBEEFCommand handler in
        // WalletCoordinatorActor). If no auto-provisioning happened (plugin
        // consumed a wallet UTXO directly), `ancestorTxids` is null and the
        // BEEF contains only the primary TX.
        final txBytes = Uint8List.fromList(hex.decode(signedPaymentTx.rawHex));
        final orderedAncestors = ancestorTxids != null
            ? await _orderedAncestorBytes(ancestorTxids, signedPaymentTx.txid)
            : const <Uint8List>[];
        final beef = _createPluginBEEF(
          ancestors: orderedAncestors,
          rawTx: txBytes,
        );

        // Build witness BEEF if present.
        //
        // The witness TX consumes earmark[1] (the second auto-provisioned
        // output), whose parent chain (the split TX + earmark[1]) overlaps
        // with what the primary BEEF already carries. We include the same
        // ancestor set in the witness BEEF so a caller that settles ONLY
        // the witness BEEF still has a complete chain. ARC dedupes
        // repeated submissions of the same TX across both BEEFs —
        // submitting split/earmark[1] a second time is a no-op.
        Uint8List? witnessBeef;
        String? witnessTxid;
        if (witnessTx != null) {
          final witnessTxBytes = Uint8List.fromList(hex.decode(witnessTx.rawHex));
          witnessBeef = _createPluginBEEF(
            ancestors: orderedAncestors,
            rawTx: witnessTxBytes,
          );
          witnessTxid = witnessTx.txid;
        }

        _log.info('[pay ${msg.invoiceId}] plugin tx TOTAL: ${totalSw.elapsedMilliseconds}ms'
            '${witnessTxid != null ? ', witnessTxid=$witnessTxid' : ''}');

        if (originalSender != null) {
          originalSender.tell(BEEFPaymentResponse(
            invoiceId: msg.invoiceId,
            beefBytes: beef,
            txid: signedPaymentTx.txid,
            amountPaid: effectiveAmount,
            changeAmount: BigInt.zero,
            ancestorCount: 0,
            success: true,
            witnessTxid: witnessTxid,
            witnessBeefBytes: witnessBeef,
            spentUtxoKeys: spentUtxoKeys,
          ));
        }
        return true;
      } catch (e) {
        _sendError(msg.invoiceId, 'Failed to package plugin transaction: $e', sender: originalSender);
        return false;
      }
    } else {
      // Standard transaction — full BEEF with ancestor chain and merkle proofs.
      final headerSw = Stopwatch()..start();
      final blockHeaders = await _getBlockHeaders(ancestorResult.blockHeights);
      _log.info('[pay ${msg.invoiceId}] getHeaders: ${headerSw.elapsedMilliseconds}ms');

      try {
        final beefSw = Stopwatch()..start();
        final beef = await _createBEEF(
          paymentTransaction: signedPaymentTx,
          ancestorTransactions: ancestorResult.ancestorTransactions,
          merkleProofs: ancestorResult.merkleProofs,
          blockHeaders: blockHeaders,
        );

        _log.info('[pay ${msg.invoiceId}] createBEEF: ${beefSw.elapsedMilliseconds}ms');

        // What the transaction pays back to the wallet: everything it
        // creates beyond the payment's own outputs.
        final changeAmount = signedPaymentTx.outputValue -
            paymentOutputs.fold<BigInt>(BigInt.zero, (sum, output) => sum + output.amount);

        _log.info('[pay ${msg.invoiceId}] TOTAL: ${totalSw.elapsedMilliseconds}ms');

        if (originalSender != null) {
          originalSender.tell(BEEFPaymentResponse(
            invoiceId: msg.invoiceId,
            beefBytes: beef,
            txid: signedPaymentTx.txid,
            amountPaid: effectiveAmount,
            changeAmount: changeAmount,
            ancestorCount: ancestorResult.ancestorTransactions.length,
            success: true,
            spentUtxoKeys: spentUtxoKeys,
          ));
        }
        return true;
      } catch (e) {
        _sendError(msg.invoiceId, 'Failed to create BEEF: $e', sender: originalSender);
        return false;
      }
    }
  }

  /// Whether a TransactionBuilderPlugin builds [msg]'s whole transaction.
  static bool _isPluginTransaction(PayInvoiceMessage msg) =>
      msg.outputs != null &&
      msg.outputs!.whereType<PluginOutputSpec>().any((p) {
        final plugin = PluginRegistry().getPlugin(p.pluginId);
        return plugin is TransactionBuilderPlugin &&
            p.params.containsKey('action') &&
            _guardPlugin(p.pluginId, 'reading its supported actions', () => plugin.supportedActions)
                .contains(p.params['action']);
      });

  /// Runs [call], a call into a third-party [TransactionBuilderPlugin]
  /// (bead libspiffy-uetb).
  ///
  /// The same shape the registry's own plugin calls got in bead
  /// libspiffy-u150 — catch, log against the `pluginId`, never let the
  /// plugin's own throw out — with the one difference a payment forces: the
  /// coordinator cannot carry on without the plugin it was asked to build
  /// with, and must not quietly build something else instead. So the call
  /// fails the payment, as [_PluginCallFailure], whose message names the
  /// plugin; the exception and stack trace themselves stay in the log.
  ///
  /// [SPVActor._decodeOutputLock] is deliberately left unguarded (recorded
  /// in u150): routing it through a guard would change the contract of bead
  /// libspiffy-rp6x, which reports such an output in
  /// `SPVValidationResult.unreadableOutputs`.
  static T _guardPlugin<T>(String pluginId, String what, T Function() call) {
    try {
      return call();
    } on _PluginCallFailure {
      rethrow;
    } catch (e, stackTrace) {
      _log.warning('Plugin "$pluginId" threw while $what: $e', e, stackTrace);
      throw _PluginCallFailure(pluginId, what, e);
    }
  }

  /// [_guardPlugin] for a plugin call that answers a Future.
  static Future<T> _guardPluginAsync<T>(String pluginId, String what, Future<T> Function() call) async {
    try {
      return await call();
    } on _PluginCallFailure {
      rethrow;
    } catch (e, stackTrace) {
      _log.warning('Plugin "$pluginId" threw while $what: $e', e, stackTrace);
      throw _PluginCallFailure(pluginId, what, e);
    }
  }

  AggregateSigningClient _signingClient() => AggregateSigningClient(
        system: context.system,
        walletManager: _walletManager,
        storage: _storage,
        replyTimeout: _signingReplyTimeout,
      );

  /// Extract recipient addresses from outputs or legacy addresses
  List<String> _getRecipientAddresses(List<InvoiceOutputSpec>? outputs, List<String> legacyAddresses) {
    if (outputs == null || outputs.isEmpty) {
      return legacyAddresses;
    }
    // For P2PKH outputs, return addresses; for P2MS, return "multisig" placeholder
    return outputs.map((o) {
      if (o is P2PKHOutputSpec) {
        return o.address;
      } else if (o is P2MSOutputSpec) {
        return 'multisig:${o.threshold}-of-${o.totalKeys}';
      } else if (o is OPReturnOutputSpec) {
        return 'op_return';
      }
      return 'unknown';
    }).toList();
  }

  // Ancestor collection methods removed - now using AncestorChainService

  /// ARC's published policy rate, or null after telling [sender] why there
  /// is none (bead libspiffy-bg7n).
  Future<FeeRate?> _policyRate(String invoiceId, ActorRef? sender) async {
    try {
      return await _askPolicyRate();
    } on StateError catch (e) {
      _sendError(invoiceId, '${e.message}; nothing was built', sender: sender);
      return null;
    }
  }

  /// ARC's published policy rate. Throws a [StateError] saying why when ARC
  /// cannot give one: a rate nobody published is not one to build at.
  Future<FeeRate> _askPolicyRate() async {
    String why;
    try {
      final quote = await _arcActor.ask<FeeRateQuote>(GetFeeRateMessage(), _feeRateReplyTimeout);
      final rate = quote.rate;
      if (quote.success && rate != null) return rate;
      why = quote.error ?? 'ARC gave no rate';
    } catch (e) {
      why = 'ARC did not answer: $e';
    }
    throw StateError("ARC's policy fee rate could not be read ($why)");
  }

  /// The fee of a transaction spending [inputs] and creating outputs whose
  /// locking scripts are [outputScriptBytes] long, plus a P2PKH change
  /// output: [rate] on its signed size.
  static BigInt _feeFor(FeeRate rate, Iterable<BitcoinUtxo> inputs, List<int> outputScriptBytes) =>
      rate.feeFor(TransactionSize.of(
        inputLockingScripts: [for (final utxo in inputs) utxo.scriptPubKey],
        outputScriptBytes: [...outputScriptBytes, TransactionSize.p2pkhScriptBytes],
      ));

  /// The UTXOs, largest first, that cover [amount] and the fee of the
  /// transaction they make ([_feeFor]), and that fee; null when all of
  /// [utxos] do not.
  ///
  /// Each input added makes the transaction bigger, so the fee is worked out
  /// again for every UTXO taken. This used to stop once the UTXOs covered
  /// [amount] plus a flat 1,000 satoshis, whatever the fee really was: a
  /// payment a UTXO did cover was refused, and one whose fee was larger was
  /// selected short.
  static ({List<BitcoinUtxo> selectedUtxos, BigInt fee})? _selectUTXOs(
      List<BitcoinUtxo> utxos, BigInt amount, List<int> outputScriptBytes, FeeRate rate) {
    final sortedUtxos = List<BitcoinUtxo>.from(utxos)..sort((a, b) => b.satoshis.compareTo(a.satoshis));

    final selected = <BitcoinUtxo>[];
    var total = BigInt.zero;
    for (final utxo in sortedUtxos) {
      selected.add(utxo);
      total += utxo.satoshis;
      final fee = _feeFor(rate, selected, outputScriptBytes);
      if (total >= amount + fee) return (selectedUtxos: selected, fee: fee);
    }
    return null;
  }

  /// The outputs a standard payment of [msg] creates, each with its locking
  /// script: its structured outputs, or the legacy amount split evenly
  /// across its addresses. Built before any UTXO is selected, because their
  /// sizes are part of the fee.
  static List<_PaymentOutput> _paymentOutputs(PayInvoiceMessage msg) {
    final outputs = msg.outputs;
    if (outputs == null || outputs.isEmpty) {
      final amountPerAddress = msg.amount ~/ BigInt.from(msg.addresses.length);
      return [
        for (final address in msg.addresses)
          _PaymentOutput(
              _p2pkhTo(address), amountPerAddress, address),
      ];
    }
    return [
      for (final output in outputs)
        ...switch (output) {
          P2PKHOutputSpec p2pkh => [
              _PaymentOutput(_p2pkhTo(p2pkh.address), p2pkh.amount, p2pkh.address),
            ],
          P2MSOutputSpec p2ms => [
              _PaymentOutput(
                dartsv.P2MSLockBuilder(
                  p2ms.publicKeys.map((hex) => dartsv.SVPublicKey.fromHex(hex)).toList(),
                  p2ms.threshold,
                  sorting: true, // BIP67 lexicographical sorting for determinism
                ),
                p2ms.amount,
                'multisig:${p2ms.threshold}-of-${p2ms.totalKeys}',
              ),
            ],
          // One transaction output per data chunk, or all chunks in one
          // (the default).
          OPReturnOutputSpec opReturn => opReturn.separateOutputs
              ? [
                  for (final chunk in opReturn.dataChunks)
                    _PaymentOutput(OpReturnLockBuilder([chunk]), BigInt.zero, 'op_return'),
                ]
              : [_PaymentOutput(OpReturnLockBuilder(opReturn.dataChunks), BigInt.zero, 'op_return')],
          PluginOutputSpec plugin => [_PaymentOutput(_pluginLock(plugin), plugin.amount,
              '${plugin.pluginId}:${plugin.pluginScriptType}')],
        },
    ];
  }

  /// The P2PKH locking script paying [address]; throws, naming it, when it
  /// is not an address.
  static dartsv.P2PKHLockBuilder _p2pkhTo(String address) {
    try {
      return dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address));
    } catch (_) {
      throw ArgumentError.value(address, 'address', 'not a valid address to pay');
    }
  }

  /// [utxos] as a TransactionBuilderPlugin spends them (bead
  /// libspiffy-0nfk): each over its real locking script, with the unlocking
  /// script the wallet writes for it; [publicKeys] are the keys a P2PKH
  /// input pushes.
  static List<PluginFundingInput> _fundingInputs(List<BitcoinUtxo> utxos, List<dartsv.SVPublicKey> publicKeys) =>
      [for (var i = 0; i < utxos.length; i++) _fundingInput(utxos[i], publicKeys[i])];

  static PluginFundingInput _fundingInput(BitcoinUtxo utxo, dartsv.SVPublicKey publicKey) {
    final lockingScript = utxo.scriptPubKey.isNotEmpty
        ? dartsv.SVScript.fromHex(utxo.scriptPubKey)
        : dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(utxo.address)).getScriptPubkey();
    final unlock = WalletTransactionSigner.unlockingScriptFor(lockingScript, publicKey: publicKey);
    if (unlock == null) {
      throw StateError('UTXO ${utxo.key} is locked by a script the wallet writes no unlocking script for');
    }
    return PluginFundingInput(
      utxo: utxo,
      lockingScript: lockingScript,
      signatures: unlock.signatures,
      newUnlocker: unlock.newUnlocker,
    );
  }

  /// Whether the TransactionBuilderPlugin that builds [msg]'s transaction
  /// spends its funding through `PluginTransactionRequest.fundingInputs`
  /// and so can be funded from any output the wallet can spend alone (bead
  /// libspiffy-0nfk).
  static bool _pluginSpendsAnyOutput(PayInvoiceMessage msg) {
    final spec = msg.outputs?.whereType<PluginOutputSpec>().firstOrNull;
    if (spec == null) return false;
    final plugin = PluginRegistry().getPlugin(spec.pluginId);
    return plugin is TransactionBuilderPlugin &&
        _guardPlugin(spec.pluginId, 'saying which outputs it spends', () => plugin.spendsAnyWalletOutput);
  }

  /// The locking script [plugin]'s plugin builds for it. Guarded: what the
  /// plugin throws is logged against it and reported as "cannot build lock"
  /// (bead libspiffy-u150).
  static dartsv.LockingScriptBuilder _pluginLock(PluginOutputSpec plugin) {
    if (PluginRegistry().getPlugin(plugin.pluginId) == null) {
      throw Exception('No plugin registered for "${plugin.pluginId}"');
    }
    final lockBuilder = PluginRegistry().createLockBuilder(plugin);
    if (lockBuilder == null) {
      throw Exception(
        'Plugin "${plugin.pluginId}" cannot build lock for '
        'script type "${plugin.pluginScriptType}"',
      );
    }
    return lockBuilder;
  }

  /// Build payment transaction with support for multiple output types (P2PKH, P2MS)
  /// Returns (transaction, preSigned) — preSigned is true when a TransactionBuilderPlugin
  /// built and signed the entire transaction.
  /// Returns (paymentTx, preSigned, witnessTx, ancestorTxids).
  ///
  /// `ancestorTxids` is the dependency-ordered list of auto-provisioned
  /// ancestor transaction ids (split TX first, then its earmark children)
  /// that the plugin path produced. It is non-null only on the plugin path
  /// when auto-provisioning was triggered; null otherwise. Every txid in
  /// this list is already persisted in the wallet read model when this
  /// function returns — callers should resolve their rawHex via storage.
  Future<(BitcoinTransaction?, bool, BitcoinTransaction?, List<String>?)>
      _buildPaymentTransactionWithOutputs({
    required List<BitcoinUtxo> selectedUtxos,
    List<InvoiceOutputSpec>? outputs,
    required List<_PaymentOutput> paymentOutputs,
    required BigInt fee,
    required FeeRate rate,
    String? changeAddress,
    required String walletId,
    required AggregateSigningClient signing,
  }) async {
    try {
      // Calculate total input
      final totalInput = selectedUtxos.fold<BigInt>(
        BigInt.zero,
        (sum, utxo) => sum + utxo.satoshis,
      );

      // Build transaction using TransactionBuilder pattern
      final txBuilder = dartsv.TransactionBuilder();

      // Track receiving addresses for record
      final receivingAddresses = <String>[];
      BigInt totalOutputAmount = BigInt.zero;

      // Add payment outputs based on outputs or legacy addresses
      if (outputs != null && outputs.isNotEmpty) {
        // Check if any PluginOutputSpec belongs to a TransactionBuilderPlugin.
        // If so, delegate the entire transaction build to the plugin.
        final pluginOutput = outputs.whereType<PluginOutputSpec>().firstOrNull;
        if (pluginOutput != null) {
          final pluginInstance = PluginRegistry().getPlugin(pluginOutput.pluginId);
          if (pluginInstance is TransactionBuilderPlugin &&
              pluginOutput.params.containsKey('action') &&
              _guardPlugin(pluginOutput.pluginId, 'reading its supported actions',
                      () => pluginInstance.supportedActions)
                  .contains(pluginOutput.params['action'])) {
            // Every signature the plugin asks for is produced by the wallet
            // aggregate (audit A-H8): the coordinator holds no key material.
            // Each funding UTXO's derivation path (index and chain) comes from
            // the read model's address metadata; its public key is the one the
            // aggregate proves it controls the address with.
            final fundingPaths = <SigningPath>[];
            final publicKeys = <dartsv.SVPublicKey>[];
            final keysByAddress = <String, dartsv.SVPublicKey>{};
            for (final utxo in selectedUtxos) {
              final path = await signing.pathForAddress(walletId, utxo.address) ??
                  SigningPath(utxo.derivationIndex ?? 0);
              fundingPaths.add(path);
              publicKeys.add(keysByAddress[utxo.address] ??=
                  await signing.publicKeyForAddress(walletId, utxo.address, path: path));
            }

            // Check if plugin needs more funding UTXOs than selected
            final action = pluginOutput.params['action'] as String;
            final requiredCount = _guardPlugin(pluginOutput.pluginId,
                'deciding how many funding UTXOs it needs', () => pluginInstance.requiredFundingUtxoCount(action));

            List<BitcoinUtxo> pluginFundingUtxos = selectedUtxos;
            List<dartsv.SVPublicKey> pluginPublicKeys = publicKeys;
            List<String>? ancestorTxids;

            if (selectedUtxos.length < requiredCount) {
              _log.info('[pay] plugin action "$action" needs $requiredCount funding UTXOs '
                  'but only ${selectedUtxos.length} selected — auto-provisioning');
              final provision = await _autoProvisionForPlugin(
                sourceUtxo: selectedUtxos.first,
                count: requiredCount,
                signing: signing,
                sourcePath: fundingPaths.first,
                publicKey: publicKeys.first,
                walletId: walletId,
                rate: rate,
              );
              pluginFundingUtxos = provision.earmarkUtxos;
              pluginPublicKeys = List.filled(requiredCount, publicKeys.first);
              ancestorTxids = provision.ancestorTxids;
            }

            final result = await signing.buildWithSigner(
              walletId: walletId,
              fallbackPath: fundingPaths.first,
              build: (signer) => _guardPluginAsync(
                  pluginOutput.pluginId,
                  'building the transaction',
                  () => pluginInstance.buildTransaction(PluginTransactionRequest(
                        fundingUtxos: pluginFundingUtxos,
                        signer: signer,
                        publicKeys: pluginPublicKeys,
                        params: pluginOutput.params,
                        fundingInputs: _fundingInputs(pluginFundingUtxos, pluginPublicKeys),
                        feeRate: rate,
                        transactionLookup: (txid) async {
                          // All auto-provisioned ancestors are persisted before
                          // _autoProvisionForPlugin returns, so a single storage read
                          // is authoritative. No in-memory shortcut.
                          final tx = await _storage.getTransaction(txid);
                          return tx?.rawHex;
                        },
                      ))),
            );

            // Validate primary TX structure
            if (!_guardPlugin(pluginOutput.pluginId, 'validating the transaction it built',
                () => pluginInstance.validateTransactionStructure(result.primaryTx, action))) {
              throw Exception('Plugin transaction structure validation failed');
            }

            // Validate witness TX structure if present
            if (result.hasPairedWitness) {
              final witnessAction = pluginOutput.params['witnessAction'] as String? ?? 'witness';
              if (!_guardPlugin(pluginOutput.pluginId, 'validating the witness transaction it built',
                  () => pluginInstance.validateTransactionStructure(result.witnessTx!, witnessAction))) {
                throw Exception('Plugin witness transaction structure validation failed');
              }
            }

            final primaryBtx = BitcoinTransaction.fromDartSvTransaction(
              walletId: walletId,
              transaction: result.primaryTx,
              status: TransactionStatus.pending,
              receivingAddresses: ['${pluginOutput.pluginId}:${pluginOutput.pluginScriptType}'],
              sendingAddresses: [],
              inputValue: totalInput,
              netAmount: -pluginOutput.amount,
            );

            // Convert witness TX if present
            BitcoinTransaction? witnessBtx;
            if (result.hasPairedWitness) {
              final witnessOutputValue = result.witnessTx!.outputs.fold<BigInt>(
                  BigInt.zero, (sum, o) => sum + o.satoshis);
              witnessBtx = BitcoinTransaction.fromDartSvTransaction(
                walletId: walletId,
                transaction: result.witnessTx!,
                status: TransactionStatus.pending,
                receivingAddresses: ['${pluginOutput.pluginId}:witness'],
                sendingAddresses: [],
                inputValue: result.witnessFeeSats + witnessOutputValue,
                netAmount: -result.witnessFeeSats,
              );
            }

            return (primaryBtx, true, witnessBtx, ancestorTxids); // preSigned: plugin built and signed the tx
          }
        }

      }

      // The payment's outputs, then what is left over after the fee back to
      // the wallet. With nothing left over there is no change output: the
      // selection's fee counted one, so the fee is a change output's worth
      // above the policy, never below it.
      for (final output in paymentOutputs) {
        txBuilder.spendToLockBuilder(output.lock, output.amount);
        receivingAddresses.add(output.recipient);
        totalOutputAmount += output.amount;
      }
      final change = totalInput - totalOutputAmount - fee;
      if (change < BigInt.zero) {
        throw StateError('$totalInput satoshis of inputs do not cover $totalOutputAmount of outputs and a $fee fee');
      }
      if (change > BigInt.zero) {
        txBuilder.sendChangeToPKH(dartsv.Address.fromBase58(changeAddress ?? selectedUtxos.first.address));
      }

      // Add inputs from selected UTXOs. They stay unsigned: the wallet
      // aggregate fills in each input's signature and public key.
      for (int i = 0; i < selectedUtxos.length; i++) {
        final utxo = selectedUtxos[i];

        final lockedAddress = dartsv.Address.fromBase58(utxo.address);
        final lockingScript = dartsv.P2PKHLockBuilder.fromAddress(lockedAddress).getScriptPubkey();

        final outpoint = dartsv.TransactionOutpoint(
          utxo.txid,
          utxo.vout,
          utxo.satoshis,
          lockingScript,
        );

        final unlockBuilder = dartsv.P2PKHUnlockBuilder(null);
        txBuilder.spendFromOutpoint(outpoint, dartsv.TransactionInput.MAX_SEQ_NUMBER, unlockBuilder);
      }

      // The fee is ARC's policy rate on the signed size, worked out by the
      // selection (bead libspiffy-bg7n). dartsv's own estimate
      // (`withFeePerKb`) sizes the transaction as it is unsigned and paid 6
      // satoshis whatever its size.
      txBuilder.withFee(fee).withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);

      // Build unsigned transaction (skip sanity checks for flexibility)
      final unsignedTx = txBuilder.build(false);
      final rawHex = unsignedTx.serialize();
      final txid = unsignedTx.id;

      // What the built transaction pays, read off it.
      final totalOutput = unsignedTx.outputs.fold<BigInt>(
        BigInt.zero,
        (sum, output) => sum + output.satoshis,
      );
      final paid = totalInput - totalOutput;

      // Create transaction record
      return (BitcoinTransaction(
        txid: txid,
        rawHex: rawHex,
        status: TransactionStatus.created,
        inputValue: totalInput,
        outputValue: totalOutput,
        fee: paid,
        receivingAddresses: receivingAddresses,
        sendingAddresses: selectedUtxos.map((u) => u.address).toList(),
        netAmount: -(totalOutputAmount + paid),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        lockTime: 0,
        version: 2,
      ), false, null, null); // preSigned: false — needs signing, no witness, no auto-provisioned ancestors
    } on _PluginCallFailure {
      // A third-party plugin failed (bead libspiffy-uetb). "Failed to build
      // payment transaction" names nobody; the payment fails with the
      // plugin named instead.
      rethrow;
    } catch (e, stackTrace) {
      _log.warning('[buildPaymentTx] failed: $e\n$stackTrace');
      return (null, false, null, null);
    }
  }


  /// Get block headers for validation
  Future<List<spiffy.BlockHeader>> _getBlockHeaders(List<int> blockHeights) async {
    final headers = <spiffy.BlockHeader>[];

    for (final height in blockHeights) {
      final header = await _storage.getBlockHeaderByHeight(height);
      if (header != null) {
        headers.add(header);
      }
    }

    return headers;
  }

  /// Create a minimal BEEF wrapper containing a single transaction with no
  /// ancestor chain. Used for plugin-built transactions where the plugin
  /// manages its own inputs and the standard BEEF ancestor chain is not
  /// applicable.
  /// Build a BEEF for a plugin-built transaction, including any auto-provisioned
  /// ancestors (split + earmark TXs) that were created in-memory and not yet
  /// on chain.
  ///
  /// All ancestors AND the primary TX are marked `hasMerkle=false` — they
  /// have no merkle proofs because they do not exist on chain yet. The
  /// caller is expected to call `SettleBEEFCommand` on this BEEF to push
  /// all `hasMerkle=false` entries through ARC in dependency order.
  ///
  /// Transaction order in the BEEF:
  ///   1..N-1: ancestors from [ancestors] (in dependency order, split first)
  ///   N:      the primary plugin-built [rawTx]
  ///
  /// Wire format matches BEEF.serialize / BEEF.parse in beef.dart:
  ///   version(4) + nBUMPs(varint)=0 + nTxs(varint) +
  ///     for each tx: [rawTx + hasBUMP(1)=0]
  Uint8List _createPluginBEEF({
    required List<Uint8List> ancestors,
    required Uint8List rawTx,
  }) {
    final writer = BytesBuilder();
    // Version 0100BEEF
    writer.add([0x01, 0x00, 0xBE, 0xEF]);
    // Number of BUMPs: 0 (no proofs; nothing on chain yet)
    writer.addByte(0x00);
    // Number of transactions = ancestors + 1 primary
    final nTxs = ancestors.length + 1;
    writer.add(dartsv.VarInt.fromInt(nTxs).encode());
    // Ancestors first, in dependency order, each followed by hasBUMP=0
    for (final anc in ancestors) {
      writer.add(anc);
      writer.addByte(0x00);
    }
    // Primary TX last, followed by hasBUMP=0
    writer.add(rawTx);
    writer.addByte(0x00);
    return Uint8List.fromList(writer.toBytes());
  }

  /// Order auto-provisioned ancestors by dependency. The split TX spends a
  /// wallet UTXO and must be broadcast first; each earmark TX spends one of
  /// the split TX's outputs and must come after. [ancestorTxids] is already
  /// in dependency order (split first, earmarks following) — we just load
  /// the rawHex for each from the wallet read model. By the time this runs,
  /// `_autoProvisionForPlugin` has awaited every recording, so the storage
  /// reads are guaranteed to find each row.
  Future<List<Uint8List>> _orderedAncestorBytes(
      List<String> ancestorTxids, String primaryTxid) async {
    final ordered = <Uint8List>[];
    for (final txid in ancestorTxids) {
      if (txid == primaryTxid) continue; // defensive; shouldn't occur
      final tx = await _storage.getTransaction(txid);
      if (tx == null) {
        throw StateError(
          'Auto-provisioned ancestor $txid not found in wallet read model. '
          'This should not happen — _autoProvisionForPlugin awaits projection '
          'persistence for every ancestor before returning.',
        );
      }
      ordered.add(Uint8List.fromList(hex.decode(tx.rawHex)));
    }
    return ordered;
  }

  /// Create BEEF package from transactions, proofs, and headers.
  ///
  /// Assembled by [AncestorChainService.buildBeef], the one BEEF builder in
  /// the library: ancestors parents first, the payment last with no proof,
  /// and one BRC-74 multi-leaf BUMP per block rather than one per proven
  /// ancestor (audit finding libspiffy-0lx).
  Future<Uint8List> _createBEEF({
    required BitcoinTransaction paymentTransaction,
    required List<BitcoinTransaction> ancestorTransactions,
    required List<MerkleProof> merkleProofs,
    required List<spiffy.BlockHeader> blockHeaders,
  }) async {
    final serialized = AncestorChainService.buildBeef(
      ancestorTransactions,
      [paymentTransaction],
      merkleProofs,
    ).serialize();

    // Sanity check: the BEEF must parse.
    try {
      BEEF.parse(serialized);
    } catch (e) {
      throw Exception('Created BEEF is invalid: $e');
    }

    return serialized;
  }


  /// Send error response to caller
  void _sendError(String invoiceId, String error, {ActorRef? sender}) {
    final target = sender ?? context.sender;
    target?.tell(BEEFPaymentResponse.error(
      invoiceId: invoiceId,
      error: error,
    ));
  }

  /// Reserve multiple UTXOs via the wallet aggregate.
  ///
  /// The aggregate replies with [UTXOReservedResponse] for every request
  /// (success or failure). A missing reply is a failure: the previous
  /// "no error within 2 s means reserved" convention treated a slow
  /// rejection as success and stalled every payment for the full 2 s.
  Future<bool> _reserveUTXOs(String walletId, List<BitcoinUtxo> utxos, String reservationId) async {
    final receivers = <ActorRef>[];
    final futures = <Future<void>>[];

    try {
      for (final utxo in utxos) {
        final completer = Completer<void>();
        final receiverName = 'reserve-receiver-${utxo.key.replaceAll(':', '-')}-${DateTime.now().microsecondsSinceEpoch}';
        final receiver = await context.system.spawn(
          receiverName,
          () => _ReservationReceiverActor(completer),
        );
        receivers.add(receiver);

        _walletManager.tell(
          WalletCommandMessage(
            walletId,
            ReserveUTXOCommand(
              walletId: walletId,
              utxoKey: utxo.key,
              reservedByTxId: reservationId,
              reservationReason: 'payment',
              reservationDuration: const Duration(minutes: 2),
            ),
          ),
          sender: receiver,
        );

        futures.add(completer.future);
      }

      await Future.wait(futures).timeout(_reservationReplyTimeout);
      return true;
    } on TimeoutException {
      _log.warning('UTXO reservation for $reservationId got no reply within '
          '$_reservationReplyTimeout; treating as failed');
      _releaseReservation(walletId: walletId, reservationId: reservationId);
      return false;
    } catch (e) {
      _log.info('UTXO reservation failed: $e');
      _releaseReservation(walletId: walletId, reservationId: reservationId);
      return false;
    } finally {
      for (final receiver in receivers) {
        await context.system.stop(receiver);
      }
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

  /// Auto-provision earmark funding TXs for a plugin that needs multiple
  /// separate funding UTXOs but the coordinator only selected one.
  ///
  /// Builds a two-level fan-out matching tstokenlib's FundingProvisionBuilder:
  ///   Level 1 (split TX): source UTXO → N equal outputs
  ///   Level 2 (earmark TXs): each split output → dust(546) + funding at vout=1
  ///
  /// Both the split TX and every earmark child are recorded through the
  /// canonical CQRS path (`_recordOutgoingTransaction` → projection applied)
  /// with `deferSpend: true`, so the source UTXO and every intermediate
  /// remain `reserved` (not yet `spent`) until ARC reports `SEEN_ON_NETWORK`
  /// for the broader payment. If the payment flow fails before broadcast,
  /// the reservation on the source UTXO can be released by the caller.
  ///
  /// Returns earmark [BitcoinUtxo]s (pointing to vout=1 of each earmark TX)
  /// and the dependency-ordered list of ancestor txids (split first, then
  /// earmarks). Callers resolve the rawHex for these txids via the
  /// read-model storage — no in-memory shortcut.
  Future<({
    List<BitcoinUtxo> earmarkUtxos,
    List<String> ancestorTxids,
  })> _autoProvisionForPlugin({
    required BitcoinUtxo sourceUtxo,
    required int count,
    required AggregateSigningClient signing,
    required SigningPath sourcePath,
    required dartsv.SVPublicKey publicKey,
    required String walletId,
    required FeeRate rate,
  }) async {
    final address = dartsv.Address.fromBase58(sourceUtxo.address);

    // Look up source TX from storage (needed by spendFromTxnWithSigner)
    final sourceBtx = await _storage.getTransaction(sourceUtxo.txid);
    if (sourceBtx == null) {
      throw StateError('Cannot resolve source TX ${sourceUtxo.txid} for auto-provisioning');
    }
    final sourceTx = dartsv.Transaction.fromHex(sourceBtx.rawHex);

    // ARC's policy rate, which the payment asked for, on each transaction's
    // signed size (bead libspiffy-lph4). The split spends the source and
    // pays [count] earmarks; each earmark spends one
    // split output (P2PKH to the source address) and pays a dust marker and
    // the funding. These used to be 148-byte guesses at a hardcoded
    // 100 sat/kB, under a comment naming a different rate.
    const p2pkh = TransactionSize.p2pkhScriptBytes;
    final addressScript = dartsv.P2PKHLockBuilder.fromAddress(address).getScriptPubkey().toHex();
    final earmarkFee = rate.feeFor(TransactionSize.of(
      inputLockingScripts: [addressScript],
      outputScriptBytes: const [p2pkh, p2pkh],
    ));
    final dust = BigInt.from(546);
    final splitFee = rate.feeFor(TransactionSize.of(
      inputLockingScripts: [sourceUtxo.scriptPubKey.isNotEmpty ? sourceUtxo.scriptPubKey : addressScript],
      outputScriptBytes: List.filled(count, p2pkh),
    ));

    // The earmarks share everything the split's fee leaves: there is no
    // change output. What the division leaves over — fewer satoshis than
    // there are earmarks — joins the fee. (A change output was counted in
    // the fee and built only above dust, which that remainder never is.)
    final inputSats = sourceUtxo.satoshis;
    final perEarmark = (inputSats - splitFee) ~/ BigInt.from(count);

    // Build the whole tree with signatures from the wallet aggregate. Every
    // input spends the source address, so every signature comes from
    // [sourcePath]. Nothing is recorded until the tree is fully signed.
    final (splitTx, earmarkTxs) = await signing.buildWithSigner(
      walletId: walletId,
      fallbackPath: sourcePath,
      build: (signer) async {
        // Level 1: Split TX
        final splitBuilder = dartsv.TransactionBuilder()
            .spendFromTxnWithSigner(signer, sourceTx, sourceUtxo.vout,
                dartsv.TransactionInput.MAX_SEQ_NUMBER, _fundingInput(sourceUtxo, publicKey).newUnlocker());

        for (int i = 0; i < count; i++) {
          splitBuilder.spendToLockBuilder(dartsv.P2PKHLockBuilder.fromAddress(address), perEarmark);
        }

        final split = splitBuilder.build(false);

        // Level 2: build all earmark TXs in memory before recording, so we can
        // record the split first and have it queryable by the time each earmark
        // references it.
        final earmarks = <dartsv.Transaction>[];
        for (int i = 0; i < count; i++) {
          final splitOutputSats = split.outputs[i].satoshis;
          final fundingSats = splitOutputSats - dust - earmarkFee;

          // Fresh unlocker per TX — TransactionBuilder mutates during build
          final earmarkBuilder = dartsv.TransactionBuilder()
              .spendFromTxnWithSigner(signer, split, i,
                  dartsv.TransactionInput.MAX_SEQ_NUMBER, dartsv.P2PKHUnlockBuilder(publicKey));

          earmarkBuilder.spendToLockBuilder(
              dartsv.P2PKHLockBuilder.fromAddress(address), dust);
          earmarkBuilder.spendToLockBuilder(
              dartsv.P2PKHLockBuilder.fromAddress(address), fundingSats);
          earmarkBuilder.withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);

          earmarks.add(earmarkBuilder.build(false));
        }
        return (split, earmarks);
      },
    );
    _log.info('[provision] split TX: ${splitTx.id}, $count earmark outputs');

    final earmarkUtxos = <BitcoinUtxo>[];
    for (int i = 0; i < count; i++) {
      final earmarkTx = earmarkTxs[i];
      final fundingSats = earmarkTx.outputs[1].satoshis;
      earmarkUtxos.add(BitcoinUtxo.create(
        txid: earmarkTx.id,
        vout: 1,
        satoshis: fundingSats,
        // What the earmark pays: P2PKH to the source's address, which is the
        // source's own script only when the source is P2PKH (bead
        // libspiffy-0nfk: a multisig or P2PK source can fund a plugin now).
        scriptPubKey: addressScript,
        address: sourceUtxo.address,
        derivationIndex: sourcePath.derivationIndex,
      ));

      _log.info('[provision] earmark $i: ${earmarkTx.id}, funding=$fundingSats sats at vout=1');
    }

    // Record the split TX. `deferSpend: true` keeps the source UTXO in the
    // `reserved` state — ARCActor will flip it to `spent` on SEEN_ON_NETWORK
    // for the broader payment. If anything downstream fails, the caller's
    // _releaseReservation restores the source UTXO to `available`. Awaited
    // so the row is queryable for the earmark recordings that follow and
    // for the plugin's `transactionLookup` afterwards.
    final splitBtx = BitcoinTransaction.fromDartSvTransaction(
      walletId: walletId,
      transaction: splitTx,
      status: TransactionStatus.pending,
      receivingAddresses: List.filled(count, 'self:earmark'),
      sendingAddresses: [],
      inputValue: sourceUtxo.satoshis,
      netAmount: BigInt.zero,
    );
    await _recordOutgoingTransaction(
      walletId: walletId,
      transaction: splitBtx,
      spentUtxoKeys: [sourceUtxo.key],
      recipientAddresses: ['self:earmark-split'],
      paymentAmount: BigInt.zero,
      changeAddress: sourceUtxo.address,
      deferSpend: true,
      purpose: 'provisioning-split',
      preSigned: true,
      signerMetadata: {
        'signerType': 'plugin-callback',
        'role': 'provisioning-split',
        'derivationIndex': sourcePath.derivationIndex,
      },
    );

    // Record each earmark child. `deferSpend: true` so the split-output
    // UTXOs that each earmark consumes stay `pending` (not `spent`) until
    // ARC confirms the broader payment. The earmarks' own outputs are
    // picked up automatically by the aggregate's output scan and registered
    // as wallet UTXOs in `pending` state — making the funding output at
    // vout=1 visible to recovery flows if anything fails before broadcast.
    final ancestorTxids = <String>[splitTx.id];
    for (int i = 0; i < count; i++) {
      final earmarkTx = earmarkTxs[i];
      final fundingSats = earmarkUtxos[i].satoshis;
      final splitOutputSats = splitTx.outputs[i].satoshis;
      final earmarkBtx = BitcoinTransaction.fromDartSvTransaction(
        walletId: walletId,
        transaction: earmarkTx,
        status: TransactionStatus.pending,
        receivingAddresses: ['self:earmark-$i'],
        sendingAddresses: [],
        inputValue: splitOutputSats,
        netAmount: BigInt.zero,
      );
      await _recordOutgoingTransaction(
        walletId: walletId,
        transaction: earmarkBtx,
        spentUtxoKeys: ['${splitTx.id}:$i'],
        recipientAddresses: ['self:earmark-$i'],
        paymentAmount: BigInt.zero,
        changeAddress: sourceUtxo.address,
        deferSpend: true,
        purpose: 'provisioning-earmark',
        preSigned: true,
        signerMetadata: {
          'signerType': 'plugin-callback',
          'role': 'provisioning-earmark',
          'earmarkIndex': i,
          'derivationIndex': sourcePath.derivationIndex,
        },
      );
      ancestorTxids.add(earmarkTx.id);
      _log.fine('[provision] recorded earmark ${earmarkTx.id} '
          '(funding=$fundingSats sats, deferred-spend on ${splitTx.id}:$i)');
    }

    return (earmarkUtxos: earmarkUtxos, ancestorTxids: ancestorTxids);
  }

  /// Record outgoing transaction in wallet history (in PENDING state) and
  /// wait until the wallet projection has applied the resulting event.
  ///
  /// Returns only after `bitcoinTransactionEntitys.get(txid)` is guaranteed
  /// to return the row — meaning the rawHex is queryable through
  /// [ReadModelStorage.getTransaction]. This is what makes the helper safe
  /// to call from flows that immediately need to look the row up (e.g., the
  /// plugin's `transactionLookup` after auto-provisioning). With
  /// [deferSpend] it also returns only after the read model holds the
  /// deferred payment and its held inputs.
  ///
  /// Throws [StateError] if the projection fails to apply the event within
  /// [_recordPersistTimeout] or the projection actor stops while waiting.
  Future<void> _recordOutgoingTransaction({
    required String walletId,
    required BitcoinTransaction transaction,
    required List<String> spentUtxoKeys,
    required List<String> recipientAddresses,
    required BigInt paymentAmount,
    String? changeAddress,
    bool deferSpend = false,
    String? purpose,
    bool preSigned = false,
    Map<String, dynamic>? signerMetadata,
  }) async {
    // Calculate change amount
    final changeAmount = transaction.outputValue - paymentAmount;

    // The consensus fields the journal records (bead libspiffy-zpu7): every
    // caller here builds [transaction] from a transaction it has just
    // serialized, so both are known, and the raw hex carries them where the
    // record does not. Refuse rather than journal an invented 0/1.
    final intrinsics = TransactionRowRules.intrinsicsOf(transaction);
    if (intrinsics.version == null || intrinsics.lockTime == null) {
      throw StateError('Cannot record outgoing transaction ${transaction.txid}: '
          'its version and nLockTime are unknown and its raw hex does not carry them');
    }

    final command = RecordOutgoingTransactionCommand(
      walletId: walletId,
      txid: transaction.txid,
      rawHex: transaction.rawHex,
      totalInputSats: transaction.inputValue.toInt(),
      totalOutputSats: transaction.outputValue.toInt(),
      fee: transaction.fee.toInt(),
      numInputs: spentUtxoKeys.length,
      numOutputs: recipientAddresses.length + (changeAddress != null ? 1 : 0),
      txVersion: intrinsics.version!,
      txLockTime: intrinsics.lockTime!,
      spentUtxoKeys: spentUtxoKeys,
      recipientAddresses: recipientAddresses,
      paymentAmount: paymentAmount,
      changeAddress: changeAddress,
      changeAmount: changeAmount > BigInt.zero ? changeAmount : null,
      deferSpend: deferSpend,
      preSigned: preSigned,
      signerMetadata: signerMetadata,
      invoiceId: deferSpend ? _inFlightPayment?.invoiceId : null,
      purpose: purpose,
      // Who the in-flight payment is to, as the app named them (cq16).
      // Null for the recordings that are not a payment to a counterparty
      // (a UTXO split, a channel funding): no placeholder is invented.
      counterpartyMarker: _inFlightPayment?.counterpartyMarker,
    );

    // Register the awaiter BEFORE telling the command, so we cannot miss the
    // event if the projection processes it very fast. The projection actor's
    // mailbox serializes our AwaitEventApplied message against the
    // _EventReceived dispatches from the event stream, so as long as the
    // ask is enqueued before the event lands in the same mailbox, ordering
    // is guaranteed by dactor.
    final txid = transaction.txid;
    final applied = _walletProjection.ask<dynamic>(
      AwaitEventApplied(
        // A deferred recording is done when its hold is applied: the hold
        // follows the recorded transaction, and the payment's answer lets
        // the app list, cancel or reclaim it at once. A cancelled deferred
        // payment recorded again journals the hold alone (re-activated,
        // bead libspiffy-4r0).
        (e) => deferSpend
            ? e is wevent.TransactionSpendDeferredEvent && e.txid == txid
            : e is wevent.TransactionRecordedEvent && e.txid == txid,
        timeout: _recordPersistTimeout,
      ),
      // Ask timeout must outlast the awaiter's own window, otherwise dactor's
      // default (5 s) fires first and a slow projection looks like a failure.
      _recordPersistTimeout + const Duration(seconds: 2),
    );

    // The wallet's refusal is answered to this receiver, so a refused
    // recording fails the payment at once instead of after the wait above.
    final refusal = Completer<String>();
    final receiver = await context.system.spawn(
      'record-receiver-$txid-${DateTime.now().microsecondsSinceEpoch}',
      () => _RecordingRefusalReceiver(refusal),
    );
    final dynamic response;
    try {
      _walletManager.tell(
        WalletCommandMessage(walletId, command),
        sender: receiver,
      );
      if (deferSpend) _inFlightPayment?.deferredTxids.add(txid);
      response = await Future.any<dynamic>([applied, refusal.future.then(_RecordingRefused.new)]);
    } finally {
      await context.system.stop(receiver);
    }
    if (response is _RecordingRefused) {
      // Nothing was held by this recording: nothing to cancel.
      if (deferSpend) _inFlightPayment?.deferredTxids.remove(txid);
      throw response;
    }
    if (response is AwaitFailed) {
      throw StateError(
        'Failed to persist outgoing transaction $txid in wallet read model: '
        '${response.reason}',
      );
    }
  }

  /// Handle funding provisioning request.
  ///
  /// Looks up the plugin, selects the largest available UTXO (or uses a
  /// params-specified one), builds the provision tree, records each
  /// transaction, and registers earmarked UTXOs in the wallet.
  Future<void> _handleProvisionFunding(ProvisionFundingMessage msg) async {
    final originalSender = context.sender;
    final walletId = msg.walletId;

    String? reservationId;
    try {
      // 1. Look up plugin
      final plugin = PluginRegistry().getPlugin(msg.pluginId);
      if (plugin is! TransactionBuilderPlugin) {
        throw Exception('Plugin "${msg.pluginId}" is not a TransactionBuilderPlugin');
      }

      // 2. Get available UTXOs and select the largest
      // (bare multisig and P2PK UTXOs excluded unless the plugin spends its
      // funding through `fundingInputs`: one that builds every input as
      // P2PKH would sign them over the wrong script, beads libspiffy-nlp,
      // libspiffy-0nfk; see _handlePayInvoice)
      // (UTXOs at watch addresses excluded: watch-only funds, bead
      // libspiffy-87a2)
      final paymentUtxos = await splitWatchOnlyUtxos(_storage, walletId, await _storage.getPaymentUTXOs(walletId));
      final spendable = paymentUtxos.signable;
      final spendsAny =
          _guardPlugin(msg.pluginId, 'saying which outputs it spends', () => plugin.spendsAnyWalletOutput);
      final availableUtxos =
          spendsAny ? spendable : spendable.where((u) => !needsNonP2pkhUnlock(u.scriptPubKey)).toList();
      if (availableUtxos.isEmpty) {
        throw Exception(spendable.isEmpty
            ? 'No available UTXOs for provisioning${paymentUtxos.excludedNote}'
            : 'No available UTXOs for provisioning: the ${spendable.length} spendable UTXO(s) '
                'are bare multisig or P2PK outputs, which plugin transactions cannot spend');
      }
      final sortedUtxos = List<BitcoinUtxo>.from(availableUtxos)
        ..sort((a, b) => b.satoshis.compareTo(a.satoshis));
      final selectedUtxo = sortedUtxos.first;

      // ARC's policy rate, which the provisioned transactions pay (bead
      // libspiffy-lph4), before anything is reserved.
      final feeRate = await _askPolicyRate();

      // 2a. Reserve the selected UTXO to prevent double-spending
      reservationId = 'provision-$walletId-${DateTime.now().millisecondsSinceEpoch}';
      final reserved = await _reserveUTXOs(walletId, [selectedUtxo], reservationId);
      if (!reserved) {
        throw Exception('Failed to reserve UTXO for provisioning — it may already be in use');
      }

      // 3. Signatures come from the wallet aggregate (same as the plugin
      // payment path); the derivation path from the read model.
      final signing = _signingClient();
      final path = await signing.pathForAddress(walletId, selectedUtxo.address) ??
          SigningPath(selectedUtxo.derivationIndex ?? 0);
      final derivationIndex = path.derivationIndex;
      final publicKey =
          await signing.publicKeyForAddress(walletId, selectedUtxo.address, path: path);

      // 4. Build plugin request and call provisionFunding
      final provisions = await signing.buildWithSigner(
        walletId: walletId,
        fallbackPath: path,
        build: (signer) => _guardPluginAsync(
            msg.pluginId,
            'provisioning funding',
            () => plugin.provisionFunding(PluginTransactionRequest(
                  fundingUtxos: [selectedUtxo],
                  signer: signer,
                  publicKeys: [publicKey],
                  params: msg.pluginParams,
                  fundingInputs: [_fundingInput(selectedUtxo, publicKey)],
                  feeRate: feeRate,
                ))),
      );
      _log.info('[provision $walletId] built ${provisions.length} TXs '
          '(${provisions.where((p) => p.role == "earmark").length} earmarks)');

      // 5. Record each provisioned transaction
      for (final ptx in provisions) {
        final tx = dartsv.Transaction.fromHex(ptx.rawHex);
        final outputValue = tx.outputs.fold<BigInt>(
            BigInt.zero, (sum, o) => sum + o.satoshis);

        final btx = BitcoinTransaction.fromDartSvTransaction(
          walletId: walletId,
          transaction: tx,
          status: TransactionStatus.pending,
          receivingAddresses: [ptx.role == 'earmark' ? 'earmark:${ptx.purpose}' : 'split'],
          sendingAddresses: [],
          inputValue: outputValue + BigInt.from(ptx.feeSats),
          netAmount: BigInt.from(-ptx.feeSats),
        );

        // Identify spent UTXOs for this TX
        final spentKeys = <String>[];
        for (final input in tx.inputs) {
          spentKeys.add('${input.prevTxnId}:${input.prevTxnOutputIndex}');
        }

        await _recordOutgoingTransaction(
          walletId: walletId,
          transaction: btx,
          spentUtxoKeys: spentKeys,
          recipientAddresses: btx.receivingAddresses,
          paymentAmount: BigInt.zero,
          preSigned: true,
          signerMetadata: {
            'signerType': 'plugin-callback',
            'role': ptx.role == 'earmark'
                ? 'provisioning-earmark'
                : 'provisioning-split',
            'pluginId': msg.pluginId,
            'derivationIndex': derivationIndex,
          },
        );
      }

      // 6. Register earmarked UTXOs in the wallet
      final earmarks = provisions.where((p) => p.role == 'earmark').toList();
      final changeAddress = selectedUtxo.address;
      final scriptPubKey = selectedUtxo.scriptPubKey;

      for (final earmark in earmarks) {
        _walletManager.tell(
          WalletCommandMessage(walletId, ReceiveUTXOCommand(
            walletId: walletId,
            txid: earmark.txid,
            vout: earmark.fundingVout,
            satoshis: BigInt.from(earmark.fundingSats),
            scriptPubKey: scriptPubKey,
            address: changeAddress,
            initialStatus: UTXOStatus.available,
            derivationIndex: derivationIndex,
            pluginMetadata: {
              'pluginId': 'funding-earmark',
              'purpose': earmark.purpose,
            },
          )),
        );
      }

      // 7. Send response
      if (originalSender != null) {
        originalSender.tell(ProvisionFundingResponse(
          walletId: walletId,
          transactionCount: provisions.length,
          earmarkCount: earmarks.length,
          success: true,
        ));
      }
    } catch (e) {
      _log.warning('[provision $walletId] failed: $e');
      if (reservationId != null) {
        _releaseReservation(walletId: walletId, reservationId: reservationId);
      }
      if (originalSender != null) {
        originalSender.tell(ProvisionFundingResponse.error(
          walletId: walletId,
          error: e.toString(),
        ));
      }
    }
  }

  @override
  Future<void> postStop() async {
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
    // The wallet's failure reply: the aggregate refused the command, or
    // the manager could not route it.
    final payload = message is LocalMessage ? message.payload : message;
    if (payload is FailureResponse) {
      completer.completeError(StateError(payload.error));
    }
  }
}

/// Completes with the error of the wallet aggregate's refusal of a
/// RecordOutgoingTransactionCommand (its generic failure reply).
class _RecordingRefusalReceiver extends Actor {
  final Completer<String> refusal;

  _RecordingRefusalReceiver(this.refusal);

  @override
  Future<void> onMessage(dynamic message) async {
    if (refusal.isCompleted) return;
    if (message is TransactionRecordedResponse && !message.success) {
      refusal.complete(message.error ?? 'recording refused');
      return;
    }
    final payload = message is LocalMessage ? message.payload : message;
    if (payload is FailureResponse) {
      refusal.complete(payload.error);
    }
  }
}

/// The wallet aggregate refused to record an outgoing transaction.
class _RecordingRefused implements Exception {
  final String error;
  _RecordingRefused(this.error);

  @override
  String toString() => error;
}

/// A payment in progress and the deferred-spend transactions it recorded
/// (cancelled if the payment is not handed over).
/// One output a standard payment creates: its locking script, its amount and
/// the recipient the transaction record names for it.
class _PaymentOutput {
  final dartsv.LockingScriptBuilder lock;
  final BigInt amount;
  final String recipient;

  _PaymentOutput(this.lock, this.amount, this.recipient);

  /// The length of its locking script, which is part of the fee.
  int get scriptBytes => lock.getScriptPubkey().buffer.length;
}

class _InFlightPayment {
  final String invoiceId;

  /// The app's opaque marker for the payee (bead libspiffy-cq16), journaled
  /// with each transaction this payment records.
  final String? counterpartyMarker;

  final List<String> deferredTxids = [];

  _InFlightPayment(this.invoiceId, [this.counterpartyMarker]);
}

/// A call into a third-party [TransactionBuilderPlugin] that threw (bead
/// libspiffy-uetb).
///
/// The plugin's own exception and stack trace are logged against its
/// [pluginId] by [PaymentCoordinatorActor._guardPlugin] and never propagated
/// raw: the payment (or the provisioning) fails with this instead, and
/// [message] tells the caller which plugin failed and at what.
class _PluginCallFailure implements Exception {
  /// The plugin that threw.
  final String pluginId;

  /// What it was asked to do, e.g. 'building the transaction'.
  final String what;

  /// What the plugin threw.
  final Object cause;

  _PluginCallFailure(this.pluginId, this.what, this.cause);

  String get message => 'Plugin "$pluginId" failed while $what: $cause';

  @override
  String toString() => message;
}
