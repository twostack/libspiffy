import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';

import '../core/wallet_commands.dart';
import '../models/bitcoin_transaction.dart';
import '../models/bitcoin_utxo.dart';
import '../storage/read_model_storage.dart';

/// An output the wallet holds as unspent although one of the wallet's own
/// confirmed transactions spends it.
class SpentOutputFinding {
  /// `txid:vout` of the output.
  final String utxoKey;

  /// The confirmed transaction that spends it.
  final String spentBy;
  final int? blockHeight;

  /// The transaction the output is reserved for, when another one: an
  /// outstanding deferred payment holding a coin that is already gone.
  final String? heldBy;

  const SpentOutputFinding({required this.utxoKey, required this.spentBy, this.blockHeight, this.heldBy});

  @override
  String toString() => '$utxoKey spent by $spentBy${heldBy == null ? '' : ' (held by $heldBy)'}';
}

/// Finds and repairs outputs a wallet holds as unspent although one of its
/// own recorded transactions, confirmed by a merkle proof, spends them.
///
/// Such an output is a coin that does not exist. An import that recorded a
/// child before its parent left them behind (the child could not mark an
/// output it did not hold yet; see `orderForImport`), and a payment built
/// from one never reaches a block.
///
/// The repair reads only the wallet's own records: its transactions (their
/// raw bytes) and its outputs. It asks no network and rescans no chain.
/// Only a **confirmed** transaction counts as the spender: a proof says the
/// spend is final. A spend the network has only seen leaves the output as
/// it is; ARC settles those.
class SpentOutputRepair {
  static final Logger _log = Logger('SpentOutputRepair');

  /// The findings for one wallet's [transactions] and [utxos]. Pure.
  static List<SpentOutputFinding> find({
    required Iterable<BitcoinTransaction> transactions,
    required Iterable<BitcoinUtxo> utxos,
  }) {
    final spenders = <String, BitcoinTransaction>{};
    for (final tx in transactions) {
      if (tx.status != TransactionStatus.confirmed || tx.rawHex.isEmpty) continue;
      final dartsv.Transaction parsed;
      try {
        parsed = dartsv.Transaction.fromHex(tx.rawHex);
      } catch (e) {
        _log.fine('Skipping ${tx.txid}: unparseable raw transaction ($e)');
        continue;
      }
      for (final input in parsed.inputs) {
        spenders.putIfAbsent('${input.prevTxnId}:${input.prevTxnOutputIndex}', () => tx);
      }
    }

    final findings = <SpentOutputFinding>[];
    for (final utxo in utxos) {
      if (utxo.status == UTXOStatus.spent || utxo.status == UTXOStatus.voided) continue;
      final key = '${utxo.txid}:${utxo.vout}';
      final spender = spenders[key];
      if (spender == null || spender.txid == utxo.txid) continue;
      final reservedBy = utxo.status == UTXOStatus.reserved ? utxo.reservedByTxId : null;
      findings.add(SpentOutputFinding(
        utxoKey: key,
        spentBy: spender.txid,
        blockHeight: spender.blockHeight,
        heldBy: reservedBy != null && reservedBy != spender.txid ? reservedBy : null,
      ));
    }
    return findings;
  }

  /// Finds the outputs of [walletId] to repair and sends the commands that
  /// repair them through [send], in order. Returns what it found.
  ///
  /// An output held by an outstanding deferred payment fails that payment
  /// first (`INPUT_SPENT`, which releases its inputs, and its row becomes
  /// failed), then is spent. An output reserved for anything else (a payment
  /// being built) is spent too when the spender's row has its block: a
  /// proven spend stands over a reservation (bead libspiffy-bapp). Without a
  /// height it is left alone and logged, for the reservation to end.
  static Future<List<SpentOutputFinding>> run({
    required String walletId,
    required ReadModelStorage storage,
    required void Function(WalletCommand command) send,
  }) async {
    final findings = find(
      transactions: await storage.getTransactionHistory(walletId),
      utxos: await storage.getUTXOs(walletId, includeSpent: false),
    );
    final failed = <String>{};
    for (final finding in findings) {
      final heldBy = finding.heldBy;
      if (heldBy != null) {
        final payment = await storage.getDeferredPayment(walletId, heldBy);
        final outstanding = payment != null && payment.state == DeferredPaymentState.outstanding;
        if (!outstanding && finding.blockHeight == null) {
          _log.warning('Wallet $walletId: ${finding.utxoKey} is spent by ${finding.spentBy} but reserved for '
              '$heldBy, and the spender has no block height; left for the reservation to end');
          continue;
        }
        if (outstanding && failed.add(heldBy)) {
          send(RecordTransactionNetworkStatusCommand(
            walletId: walletId,
            txid: heldBy,
            networkStatus: DeferredNetworkStatus.inputSpent,
            source: 'wallet',
            explicit: true,
            detail: 'Input ${finding.utxoKey} is already spent by ${finding.spentBy}, a confirmed transaction; '
                'this payment can never be mined',
          ));
          send(UpdateTransactionStatusCommand(walletId: walletId, txid: heldBy, newStatus: TransactionStatus.failed));
        }
      }
      send(SpendUTXOCommand(
        walletId: walletId,
        utxoKey: finding.utxoKey,
        spendingTxId: finding.spentBy,
        fee: BigInt.zero,
        blockHeight: finding.blockHeight,
      ));
    }
    if (findings.isNotEmpty) {
      _log.warning('Wallet $walletId: ${findings.length} output(s) were held as unspent although a confirmed '
          'transaction of the wallet spends them; repaired: ${findings.join(', ')}');
    }
    return findings;
  }
}
