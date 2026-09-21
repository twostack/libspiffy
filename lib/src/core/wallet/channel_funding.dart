/// Building and signing a payment channel's funding transaction from the
/// wallet's own UTXOs (bead libspiffy-dp4; part of `BitcoinWalletAggregate`).
library;

import 'dart:typed_data';

import 'package:dartsv/dartsv.dart' as dartsv;

import '../../actors/wallet_messages.dart' show FundingTransactionBuiltResponse;
import '../../models/bitcoin_utxo.dart';
import '../../models/wallet_balances.dart';
import '../../models/wallet_state.dart';
import '../../models/wallet_type.dart';
import '../wallet_commands.dart';
import '../wallet_events.dart';
import '../wallet_output_ownership.dart';
import 'deferred_payments.dart';
import 'transaction_signer.dart';
import 'wallet_keys.dart';

/// A funding transaction built for a [BuildFundingTransactionCommand]: the
/// reservations of its inputs, to journal, and the success reply, to send
/// once they are journaled.
typedef ChannelFundingBuilt = ({List<UTXOReservedEvent> reservations, FundingTransactionBuiltResponse response});

/// Builds channel funding transactions with one wallet's keys.
class ChannelFunding {
  final WalletKeys keys;
  final DeferredPayments deferred;

  ChannelFunding(this.keys, this.deferred);

  /// Fee estimation constants.
  static const _txOverhead = 10;
  static const _p2pkhInputSize = 148;
  static const _p2pkhOutputSize = 34;
  static const _feePerKb = 100;

  /// The 36-byte outpoint and 4-byte sequence number every input carries,
  /// plus the one-byte length prefix of its unlocking script.
  static const _inputOverhead = 36 + 4 + 1;

  /// One signature in an unlocking script: the push opcode plus a 72-byte DER
  /// signature with its sighash byte. (148 = [_inputOverhead] + this + the
  /// 34-byte push of a compressed public key.)
  static const _signaturePush = 73;

  /// The UTXOs a funding transaction may spend, largest first: the wallet's
  /// own spendable funds, by the one rule the rest of the wallet selects by
  /// ([WalletBalances.isSpendable], `UtxoLedger.available`), narrowed to the
  /// ones no deferred payment holds.
  ///
  /// Funding used to hand-roll its own predicate and so left out only what
  /// it had thought of. The shared rule leaves out a plugin-managed output —
  /// a token, a funding earmark, its plugin's to spend (bead
  /// libspiffy-ecy8) — which funding did not: such an output could be
  /// selected as plain satoshis and consumed, destroying the token behind
  /// the plugin's state (bead libspiffy-qfmb). It equally leaves out
  /// watch-only funds (bead libspiffy-87a2), a deferred payment's held input
  /// (bead libspiffy-7p2, journaled hold or inferred) and an output the
  /// wallet cannot unlock on its own — a bare multisig whose threshold its
  /// keys do not meet (bead libspiffy-0k8), or a P2PK to a key that is not
  /// the wallet's ([unlocksAlone]).
  ///
  /// That last check used to live here alone, so funding refused an output
  /// both balances went on counting (bead libspiffy-kfvv); it is now part of
  /// [WalletBalances.cannotSpendAlone] and funding adds nothing to the
  /// shared rule but the deferred hold. Bare multisig and P2PK outputs the
  /// wallet *can* unlock are still spent, with their own unlocking scripts
  /// (bead libspiffy-8egy, [WalletTransactionSigner.unlockFor]).
  ///
  /// Throws, naming the reason, when there is none.
  List<BitcoinUtxo> fundingCandidates(WalletState currentState) {
    final availableUtxos = currentState.utxos.values
        .where((u) =>
            WalletBalances.isSpendable(currentState, u) && deferred.holderOf(currentState, u.key) == null)
        .toList()
      ..sort((a, b) => b.value.getValue().compareTo(a.value.getValue()));

    if (availableUtxos.isEmpty) throw StateError(_noCandidatesReason(currentState));
    return availableUtxos;
  }

  /// Why [fundingCandidates] found nothing: the first exclusion that emptied
  /// the wallet's unspent funds, so the caller is told what kind of output it
  /// is holding rather than only that it has none.
  ///
  /// The walk itself is [WalletBalances.noneSelectableReason], shared with
  /// the Benford split (bead libspiffy-f4qy) so the two paths cannot come to
  /// diagnose the same wallet differently. Funding adds nothing to it: the
  /// `held` predicate it used to pass named a deferred payment's held input,
  /// which the shared walk excluded by status before the predicate was ever
  /// asked, so for a journaled hold it was dead code (bead libspiffy-a5h8).
  /// The walk asks [WalletBalances.isDeferredHeld] itself now.
  String _noCandidatesReason(WalletState currentState) => WalletBalances.noneSelectableReason(
        currentState,
        noneMessage: 'No available UTXOs for funding',
      );

  /// The bytes a signed input spending [utxo] adds to a transaction.
  ///
  /// Not every funding input is 148 bytes any more (bead libspiffy-8egy): a
  /// P2PK input carries one signature and no public key, and an m-of-n bare
  /// multisig input carries `OP_0` and m signatures. Estimating them all as
  /// P2PKH underpays an m-of-n input from m = 2 up.
  static int _inputSize(BitcoinUtxo utxo) {
    final multisig = BareMultisigScript.parseHex(utxo.scriptPubKey);
    if (multisig != null) {
      // `OP_0 <sig>...`, one signature per required key.
      return _inputOverhead + 1 + (multisig.threshold * _signaturePush);
    }
    // `<sig>` alone.
    if (p2pkPublicKeyHex(utxo.scriptPubKey) != null) return _inputOverhead + _signaturePush;
    return _p2pkhInputSize;
  }

  /// The bytes an output whose locking script is [scriptBytes] long adds: the
  /// 8-byte amount, the script's length prefix and the script itself.
  static int _outputSize(int scriptBytes) => 8 + (scriptBytes < 253 ? 1 : 3) + scriptBytes;

  /// The estimated fee of a funding transaction spending [inputs], with a
  /// channel funding output whose locking script is [fundingScriptBytes] long
  /// and a P2PKH change output, at the standard policy rate. There is no fee
  /// auction on this network: the policy rate is the whole requirement, for a
  /// channel funding as for anything else.
  ///
  /// The funding output is a 2-of-2 bare multisig (two public keys, ~71
  /// bytes), not the 34 bytes of a P2PKH output it used to be counted as.
  static BigInt _fee(Iterable<BitcoinUtxo> inputs, int fundingScriptBytes) {
    final estimatedSize = _txOverhead +
        inputs.fold<int>(0, (sum, utxo) => sum + _inputSize(utxo)) +
        _outputSize(fundingScriptBytes) +
        _p2pkhOutputSize;
    return BigInt.from((estimatedSize * _feePerKb) ~/ 1000);
  }

  /// Builds and signs the 2-of-2 multisig funding transaction [command]
  /// asks for, funded by the client's P2PKH UTXOs selected largest first.
  /// All signing happens here, keeping private keys inside the aggregate.
  Future<ChannelFundingBuilt> build(WalletState currentState, BuildFundingTransactionCommand command) async {
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

    final availableUtxos = fundingCandidates(currentState);

    final fundingAmount = BigInt.from(command.fundingAmountSats);

    // Create 2-of-2 multisig locking script (its size is part of the fee).
    final msLockBuilder = dartsv.P2MSLockBuilder(
      [clientPubKey, serverPubKey],
      2,
      sorting: true,
    );
    final fundingScriptBytes = msLockBuilder.getScriptPubkey().buffer.length;

    // Select UTXOs using greedy algorithm (largest first)
    final selectedUtxos = <BitcoinUtxo>[];
    var selectedTotal = BigInt.zero;

    for (final utxo in availableUtxos) {
      selectedUtxos.add(utxo);
      selectedTotal += utxo.value.getValue();

      // Check if we have enough (with some buffer for fee variance)
      if (selectedTotal >= fundingAmount + _fee(selectedUtxos, fundingScriptBytes)) {
        break;
      }
    }

    // Final fee calculation with selected UTXOs
    final fee = _fee(selectedUtxos, fundingScriptBytes);

    if (selectedTotal < fundingAmount + fee) {
      throw StateError('Insufficient funds: need ${fundingAmount + fee}, have $selectedTotal');
    }

    final changeAmount = selectedTotal - fundingAmount - fee;

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

    // The wallet's own signing rules, shared with SignTransactionCommand
    // (bead libspiffy-8egy): P2PKH, bare multisig and P2PK each get the
    // unlocking script their locking script expects.
    final signer = WalletTransactionSigner(keys);

    for (final utxo in selectedUtxos) {
      // The output's own locking script, not one rebuilt as P2PKH from the
      // UTXO's address: a bare multisig or P2PK input signed over a P2PKH
      // subscript is an input no node accepts. (A row with no script falls
      // back to the address, which is all there is to go on.)
      final lockingScript = utxo.scriptPubKey.isNotEmpty
          ? dartsv.SVScript.fromHex(utxo.scriptPubKey)
          : dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(utxo.address)).getScriptPubkey();

      final outpoint = dartsv.TransactionOutpoint(
        utxo.txid,
        utxo.vout,
        utxo.value.getValue(),
        lockingScript,
      );

      // Get the correct private key(s) for THIS specific UTXO. The UTXO
      // carries only the index; the chain comes from the aggregate's address
      // records (change-chain UTXOs were unsignable before H3).
      final unlock = await signer.unlockFor(
        currentState,
        command.walletId,
        utxo,
        derivationIndex: utxo.derivationIndex,
      );
      if (unlock == null) {
        throw StateError('Cannot fund a channel with UTXO ${utxo.key}: the wallet has no unlocking '
            'script for its locking script (${utxo.scriptPubKey})');
      }

      txBuilder.spendFromOutpointWithSigner(
        unlock.signingKeys.length == 1
            ? dartsv.DefaultTransactionSigner(sighashType, unlock.signingKeys.single)
            : _MultiKeySigner(sighashType, unlock.signingKeys),
        outpoint,
        dartsv.TransactionInput.MAX_SEQ_NUMBER,
        unlock.unlocker,
      );
    }

    // Our own estimate, not dartsv's: dartsv sizes an input by its unsigned
    // unlocking script (no signature yet) and leaves out the outpoint and
    // sequence number entirely, which underpays every input type.
    txBuilder.withFee(fee).withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);

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
    final multisigOutputIndex = signedTx.outputs.indexWhere((o) => o.script.toHex() == multisigScriptHex);
    if (multisigOutputIndex == -1) {
      throw StateError('Could not find multisig output in funding transaction');
    }
    int? actualChangeOutputIdx;
    for (int i = 0; i < signedTx.outputs.length; i++) {
      if (i != multisigOutputIndex) actualChangeOutputIdx = i;
    }

    // What the transaction actually pays, read off the transaction itself
    // rather than restated from the estimate: the estimate decided the
    // change, but the record is of what was built (spv-understanding.md,
    // "the library must not manufacture state it cannot evidence").
    final hasChange = actualChangeOutputIdx != null;
    final actualChangeAmount = hasChange ? signedTx.outputs[actualChangeOutputIdx].satoshis.toInt() : 0;

    // Calculate totals
    final totalInputSats = selectedTotal.toInt();
    final totalOutputSats = signedTx.outputs.fold<int>(0, (sum, o) => sum + o.satoshis.toInt());
    final actualFee = totalInputSats - totalOutputSats;

    // Response with full transaction details for wallet bookkeeping.
    final response = FundingTransactionBuiltResponse(
      walletId: command.walletId,
      correlationId: command.correlationId,
      channelId: command.channelId,
      fundingTxHex: fundingTxHex,
      fundingTxId: fundingTxId,
      fundingOutputIndex: multisigOutputIndex, // Use actual index, not hardcoded 0
      success: true,
      spentUtxoKeys: spentUtxoKeys,
      changeAddress: hasChange ? command.changeAddressBase58 : null,
      changeAmount: actualChangeAmount > 0 ? actualChangeAmount : null,
      changeOutputIndex: actualChangeOutputIdx, // Use actual index found above
      fee: actualFee,
      totalInputSats: totalInputSats,
      totalOutputSats: totalOutputSats,
    );

    // Reservation events prevent a double-spend of the selected UTXOs; the
    // coordinator marks them spent after broadcast via
    // RecordOutgoingTransactionCommand.
    return (reservations: reserveEvents, response: response);
  }
}

/// Signs one input with several of the wallet's keys, in order: what an
/// m-of-n bare multisig input needs, where dartsv's `TransactionBuilder`
/// holds a single signer per outpoint (bead libspiffy-8egy).
class _MultiKeySigner extends dartsv.TransactionSigner {
  @override
  final int sigHashType;
  final List<dartsv.SVPrivateKey> signingKeys;

  _MultiKeySigner(this.sigHashType, this.signingKeys);

  @override
  dartsv.Transaction sign(dartsv.Transaction unsignedTxn, dartsv.TransactionOutput utxo, int inputIndex) {
    for (final key in signingKeys) {
      dartsv.DefaultTransactionSigner(sigHashType, key).sign(unsignedTxn, utxo, inputIndex);
    }
    return unsignedTxn;
  }

  @override
  dartsv.SVSignature signPreimage(Uint8List preImage) => throw UnsupportedError(
      'signPreimage is not available: a funding input is signed with one key per required signature');
}
