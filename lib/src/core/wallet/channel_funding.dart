/// Building and signing a payment channel's funding transaction from the
/// wallet's P2PKH UTXOs (bead libspiffy-dp4; part of
/// `BitcoinWalletAggregate`).
library;

import 'package:dartsv/dartsv.dart' as dartsv;

import '../../actors/wallet_messages.dart' show FundingTransactionBuiltResponse;
import '../../models/bitcoin_utxo.dart';
import '../../models/wallet_state.dart';
import '../../models/wallet_type.dart';
import '../wallet_commands.dart';
import '../wallet_events.dart';
import '../wallet_output_ownership.dart';
import 'deferred_payments.dart';
import 'utxo_ledger.dart';
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

  /// The UTXOs a funding transaction may spend, largest first. Inputs are
  /// signed as P2PKH, so a bare multisig or P2PK wallet UTXO (bead
  /// libspiffy-nlp) does not fund a channel, and a UTXO at a watch address
  /// (watch-only funds, bead libspiffy-87a2) funds nothing. Throws, naming
  /// the reason, when there is none.
  List<BitcoinUtxo> fundingCandidates(WalletState currentState) {
    final unspent = currentState.utxos.values
        .where((u) => u.isAvailable && !u.isSpent && !u.isReserved && deferred.holderOf(currentState, u.key) == null)
        .toList();
    final spendable = unspent.where((u) => !UtxoLedger.isWatchOnly(currentState, u)).toList();
    final availableUtxos = spendable.where((u) => !needsNonP2pkhUnlock(u.scriptPubKey)).toList()
      ..sort((a, b) => b.value.getValue().compareTo(a.value.getValue()));

    if (availableUtxos.isEmpty) {
      throw StateError(unspent.isEmpty
          ? 'No available UTXOs for funding'
          : spendable.isEmpty
              ? 'No available UTXOs for funding: the ${unspent.length} available UTXO(s) are at watch '
                  'addresses, watch-only funds the wallet holds no key for'
              : 'No available UTXOs for funding: the ${spendable.length} spendable UTXO(s) are bare '
                  'multisig or P2PK outputs, which cannot fund a channel');
    }
    return availableUtxos;
  }

  /// The estimated fee of a funding transaction with [inputs] P2PKH inputs,
  /// a multisig output and a change output.
  static BigInt _fee(int inputs) {
    final estimatedSize = _txOverhead + (inputs * _p2pkhInputSize) + _p2pkhOutputSize + _p2pkhOutputSize;
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

    // Select UTXOs using greedy algorithm (largest first)
    final selectedUtxos = <BitcoinUtxo>[];
    var selectedTotal = BigInt.zero;

    for (final utxo in availableUtxos) {
      selectedUtxos.add(utxo);
      selectedTotal += utxo.value.getValue();

      // Check if we have enough (with some buffer for fee variance)
      if (selectedTotal >= fundingAmount + _fee(selectedUtxos.length)) {
        break;
      }
    }

    // Final fee calculation with selected UTXOs
    final fee = _fee(selectedUtxos.length);

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
      final utxoPrivateKey = await keys.privateKeyForAddress(
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

    txBuilder.withFeePerKb(_feePerKb).withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);

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

    // Determine if change output was actually added (above dust threshold)
    final hasChange = changeAmount > BigInt.from(546);
    final actualChangeAmount = hasChange ? changeAmount.toInt() : 0;

    // Calculate totals
    final totalInputSats = selectedTotal.toInt();
    final totalOutputSats = fundingAmount.toInt() + actualChangeAmount;

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
      fee: fee.toInt(),
      totalInputSats: totalInputSats,
      totalOutputSats: totalOutputSats,
    );

    // Reservation events prevent a double-spend of the selected UTXOs; the
    // coordinator marks them spent after broadcast via
    // RecordOutgoingTransactionCommand.
    return (reservations: reserveEvents, response: response);
  }
}
