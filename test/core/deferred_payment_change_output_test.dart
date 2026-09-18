/// Beads libspiffy-3arz and libspiffy-wfvi, in the wallet aggregate.
///
/// 3arz: a deferred payment's own outputs — the change back to us — are
/// created pending, and only a confirmation promotes them. A payment that is
/// cancelled, failed or reclaimed can never be confirmed, so its change used
/// to sit at pending forever, from a transaction that will not be mined, and
/// showed up as funds on the way. Nothing is deleted (spv-understanding.md,
/// Data Retention): the row is kept and its status says what is true —
/// [UTXOStatus.voided] — and a later confirmation still makes it available,
/// because a merkle proof outranks any resolution we recorded.
///
/// wfvi: when the recipient's copy of a payment being reclaimed reaches the
/// network first, our reclaim's self-spend is the one rejected. First seen
/// wins and there is no replace-by-fee (Critical Implementation Note 3), so
/// the moment the wallet sees the input spent by something else the reclaim
/// is failed — no ARC poll, no fee, no retry.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/deferred_payment.dart';
import 'package:libspiffy/src/models/wallet_balances.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

const _w = 'change-output-wallet';
final _input = '${'a1' * 32}:0';
final _second = '${'c3' * 32}:2';

/// The wallet's own key, so its change output really belongs to it.
final _ourKey = dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST);
final _ourAddress = _ourKey.publicKey.toAddress(dartsv.NetworkType.TEST);
final _ourScript = dartsv.P2PKHLockBuilder.fromAddress(_ourAddress).getScriptPubkey().toHex();

/// Somebody else's address: the recipient of the payment.
final _theirKey = dartsv.SVPrivateKey.fromHex('33' * 32, dartsv.NetworkType.TEST);
final _theirAddress = _theirKey.publicKey.toAddress(dartsv.NetworkType.TEST);
final _theirScript = dartsv.P2PKHLockBuilder.fromAddress(_theirAddress).getScriptPubkey().toHex();

class _NoStore implements EventStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

BitcoinWalletAggregate _aggregate() => BitcoinWalletAggregate(
      aggregateId: _w,
      aggregateType: 'BitcoinWallet',
      eventStore: _NoStore(),
      cryptoService: DartSVCryptoService(),
      secureStorage: InMemorySecureStorage(),
    );

/// A transaction spending [inputs], paying [sats] to the recipient and
/// [change] back to the wallet's own address (0 for no change output).
String _paymentHex(List<String> inputs, {required int sats, required int change}) {
  final tx = dartsv.Transaction();
  for (final key in inputs) {
    final parts = key.split(':');
    tx.addInput(dartsv.TransactionInput(parts[0], int.parse(parts[1]), dartsv.TransactionInput.MAX_SEQ_NUMBER));
  }
  tx.addOutput(dartsv.TransactionOutput(BigInt.from(sats), dartsv.SVScript.fromHex(_theirScript)));
  if (change > 0) {
    tx.addOutput(dartsv.TransactionOutput(BigInt.from(change), dartsv.SVScript.fromHex(_ourScript)));
  }
  return tx.serialize();
}

/// The wallet's own self-spend of [inputs], paying [back] to itself (the rest
/// is the policy fee, and nothing more: there is no fee auction here).
String _selfSpendHex(List<String> inputs, {required int back}) {
  final tx = dartsv.Transaction();
  for (final key in inputs) {
    final parts = key.split(':');
    tx.addInput(dartsv.TransactionInput(parts[0], int.parse(parts[1]), dartsv.TransactionInput.MAX_SEQ_NUMBER));
  }
  tx.addOutput(dartsv.TransactionOutput(BigInt.from(back), dartsv.SVScript.fromHex(_ourScript)));
  return tx.serialize();
}

class _Wallet {
  final BitcoinWalletAggregate aggregate = _aggregate();
  final List<Event> journal = [];

  _Wallet() {
    apply([
      WalletCreatedEvent(
        walletId: _w,
        walletName: 'w',
        rootAddress: _ourAddress.toBase58(),
        walletType: WalletType.hd,
        walletMetadata: {'network': 'testnet'},
        version: 1,
        timestamp: DateTime.utc(2026),
      ),
    ]);
    receive(_input, 20000);
    receive(_second, 7000);
  }

  void apply(List<Event> events) {
    for (final e in events) {
      aggregate.eventHandler(e);
      journal.add(e);
    }
  }

  void receive(String key, int sats) {
    final parts = key.split(':');
    apply([
      UTXOReceivedEvent(
        walletId: _w,
        txid: parts[0],
        vout: int.parse(parts[1]),
        satoshis: sats,
        scriptPubKey: _ourScript,
        address: _ourAddress.toBase58(),
        initialStatus: UTXOStatus.available,
        version: aggregate.currentState.version + 1,
        timestamp: DateTime.utc(2026),
      ),
    ]);
  }

  Future<List<Event>> handle(WalletCommand command) async {
    final events = await aggregate.handleCommand(aggregate.currentState, command);
    apply(events);
    return events;
  }

  BitcoinUtxo utxo(String key) => aggregate.currentState.utxos[key]!;

  Map deferred(String txid) => (aggregate.currentState.metadata['deferredSpends'] as Map)[txid] as Map;

  BitcoinWalletAggregate replay() {
    final fresh = _aggregate();
    for (final e in journal) {
      fresh.eventHandler(e);
    }
    return fresh;
  }

  /// Records a deferred payment of [sats] out of [inputs] with [change] back
  /// to the wallet. Returns its txid.
  Future<String> pay(List<String> inputs, {int sats = 1000, int change = 18900}) async {
    final rawHex = _paymentHex(inputs, sats: sats, change: change);
    final txid = dartsv.Transaction.fromHex(rawHex).id;
    await handle(RecordOutgoingTransactionCommand(
      walletId: _w,
      txid: txid,
      rawHex: rawHex,
      totalInputSats: 20000,
      totalOutputSats: sats + change,
      fee: 100,
      numInputs: inputs.length,
      numOutputs: change > 0 ? 2 : 1,
      txVersion: 1,
      txLockTime: 0,
      spentUtxoKeys: inputs,
      recipientAddresses: [_theirAddress.toBase58()],
      paymentAmount: BigInt.from(sats),
      changeAddress: _ourAddress.toBase58(),
      changeAmount: BigInt.from(change),
      deferSpend: true,
      invoiceId: 'inv-$sats',
      purpose: 'invoice-payment',
    ));
    return txid;
  }
}

void main() {
  group('3arz: the change of a payment the network will not settle', () {
    test('a cancellation voids the change output; it is no longer counted as incoming, and the row is kept',
        () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);
      final changeKey = '$txid:1';

      expect(wallet.utxo(changeKey).status, UTXOStatus.pending, reason: 'change starts pending');
      expect(wallet.aggregate.currentState.unconfirmedBalance.getValue(), BigInt.from(18900 + 7000),
          reason: 'while the payment is outstanding the change is money on the way');

      await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: txid, reason: 'recipient vanished'));

      for (final state in [wallet.aggregate.currentState, wallet.replay().currentState]) {
        final change = state.utxos[changeKey]!;
        expect(change.status, UTXOStatus.voided,
            reason: 'the transaction can never be mined; the output says so instead of sitting at pending');
        expect(WalletBalances.bucketOf(change), isNull, reason: 'it is not funds on the way any more');
        expect(change.satoshis, BigInt.from(18900), reason: 'RETENTION: the row is kept whole');
        expect(change.scriptPubKey, _ourScript);
        expect(state.unconfirmedBalance.getValue(), BigInt.from(20000 + 7000),
            reason: 'the released input and the untouched one, and nothing of the change');
        expect(state.confirmedBalance.getValue() + state.reservedBalance.getValue(), BigInt.zero);
        expect(state.metadata['deferredSpends'][txid]['state'], 'cancelled');
      }
      expect(wallet.utxo(_input).status, UTXOStatus.available, reason: 'the held input came back');
    });

    test('a confirmation after the cancellation still makes the change spendable', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);
      final changeKey = '$txid:1';
      await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: txid));
      expect(wallet.utxo(changeKey).status, UTXOStatus.voided);

      // The recipient's copy was broadcast after all and a merkle proof on
      // our active header chain reaches us (bead libspiffy-4r0 / V-55).
      await wallet.handle(
          ConfirmTransactionCommand(walletId: _w, txid: txid, blockHeight: 900001, blockHash: 'h'));

      for (final state in [wallet.aggregate.currentState, wallet.replay().currentState]) {
        expect(state.utxos[changeKey]!.status, UTXOStatus.available,
            reason: 'a proof outranks the cancellation: the change is spendable');
        // The seam between 3arz (voiding) and 4dja (the proven height): an
        // output that was voided and then proven must come back BOTH
        // spendable and carrying the height its proof puts it at. Voiding
        // must not cost the output its height, and the height stamp must not
        // skip a voided row.
        expect(state.utxos[changeKey]!.blockHeight, 900001,
            reason: 'the proof that revived it also says which block it is in');
        expect(state.utxos[_input]!.status, UTXOStatus.spent, reason: 'the confirmation spends its inputs');
        expect(state.metadata['deferredSpends'][txid]['state'], 'mined');
      }
      expect(wallet.aggregate.currentState.availableBalance, BigInt.from(18900 + 7000));
    });

    test('MarkUTXOAvailableCommand promotes a voided output: the command says it is in a block', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);
      final changeKey = '$txid:1';
      await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: txid));
      expect(wallet.utxo(changeKey).status, UTXOStatus.voided);

      // ARCActor promotes the outputs of a transaction it saw mined through
      // this command, beside the confirmation itself.
      final events = await wallet.handle(MarkUTXOAvailableCommand(walletId: _w, txid: txid, vout: 1));

      expect(events.single, isA<UTXOMarkedAvailableEvent>());
      expect(wallet.utxo(changeKey).status, UTXOStatus.available);
    });

    test('an ARC REJECTED voids the change too', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);

      await wallet.handle(RecordTransactionNetworkStatusCommand(
          walletId: _w, txid: txid, networkStatus: DeferredNetworkStatus.rejected));

      expect(wallet.deferred(txid)['state'], 'failed');
      expect(wallet.utxo('$txid:1').status, UTXOStatus.voided);
      expect(wallet.aggregate.currentState.unconfirmedBalance.getValue(), BigInt.from(20000 + 7000),
          reason: 'the released input and the untouched one, and nothing of the change');
    });

    test('the same payment handed out again after a cancellation has pending change again', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);
      final changeKey = '$txid:1';
      await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: txid));
      expect(wallet.utxo(changeKey).status, UTXOStatus.voided);

      // The same inputs signed deterministically give the same transaction
      // (bead libspiffy-4r0): it is outstanding again, so its change can
      // settle again.
      await wallet.pay([_input]);

      for (final state in [wallet.aggregate.currentState, wallet.replay().currentState]) {
        expect(state.metadata['deferredSpends'][txid]['state'], 'outstanding');
        expect(state.utxos[changeKey]!.status, UTXOStatus.pending,
            reason: 'the payment can settle again, so its change is on the way again');
      }
    });

    test('a reclaimed payment\'s change is voided when the self-spend reaches the network', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);
      final changeKey = '$txid:1';

      // Our own self-spend of the held input, back to us, paying the policy
      // fee and nothing else.
      final reclaimHex = _selfSpendHex([_input], back: 19900);
      final reclaimTxid = dartsv.Transaction.fromHex(reclaimHex).id;
      await wallet.handle(ReclaimDeferredSpendCommand(
          walletId: _w,
          txid: txid,
          reclaimTxid: reclaimTxid,
          rawHex: reclaimHex,
          recipientAddresses: [_ourAddress.toBase58()],
          reason: 'recipient vanished'));
      expect(wallet.utxo(changeKey).status, UTXOStatus.pending,
          reason: 'until the network has the self-spend the payment is still outstanding');

      await wallet.handle(RecordTransactionNetworkStatusCommand(
          walletId: _w, txid: reclaimTxid, networkStatus: DeferredNetworkStatus.seenOnNetwork));

      for (final state in [wallet.aggregate.currentState, wallet.replay().currentState]) {
        expect(state.metadata['deferredSpends'][txid]['state'], 'reclaimed');
        expect(state.utxos[changeKey]!.status, UTXOStatus.voided,
            reason: "the reclaimed payment's change belongs to a transaction that cannot be mined");
        expect(state.utxos['$reclaimTxid:0']!.status, UTXOStatus.pending,
            reason: "the self-spend's own output is a normal pending output; it can settle");
      }
    });
  });

  group('wfvi: a reclaim whose inputs another transaction spent first', () {
    test('the reclaim fails the moment the input is seen spent by the payment, with no ARC poll', () async {
      final wallet = _Wallet();
      final txid = await wallet.pay([_input]);
      final reclaimHex = _selfSpendHex([_input], back: 19900);
      final reclaimTxid = dartsv.Transaction.fromHex(reclaimHex).id;
      await wallet.handle(ReclaimDeferredSpendCommand(
          walletId: _w,
          txid: txid,
          reclaimTxid: reclaimTxid,
          rawHex: reclaimHex,
          recipientAddresses: [_ourAddress.toBase58()],
          reason: 'recipient vanished'));
      expect(wallet.deferred(reclaimTxid)['state'], 'outstanding');

      // The recipient broadcast their copy and it reached the network first:
      // the wallet sees the held input spent by the payment, not by our
      // self-spend. First seen wins; the fee is irrelevant.
      await wallet.handle(
          SpendUTXOCommand(walletId: _w, utxoKey: _input, spendingTxId: txid, fee: BigInt.zero));

      for (final state in [wallet.aggregate.currentState, wallet.replay().currentState]) {
        final reclaim = state.metadata['deferredSpends'][reclaimTxid] as Map;
        expect(reclaim['state'], 'failed',
            reason: 'the self-spend can never be mined; it does not wait for ARC to say so');
        expect(reclaim['resolutionReason'], allOf(contains(txid), contains('first seen wins')));
        expect(reclaim['lastNetworkStatus'], isNull, reason: 'nothing was asked of ARC');
        expect(state.metadata['deferredSpends'][txid]['state'], 'seen',
            reason: "the recipient's copy is the one on the network");
        expect(state.utxos[_input]!.spentInTxId, txid);
        expect((state.metadata['deferredHolds'] as Map).containsKey(_input), isFalse);
      }
    });

    test('an ordinary deferred payment whose input another transaction spends stays outstanding', () async {
      // Bead libspiffy-ey2 is unchanged: only a reclaim resolves this way,
      // because only a reclaim is the wallet's own deliberate double spend of
      // an input it holds. For any other payment either transaction may still
      // be mined, and the wallet keeps polling instead of deciding.
      final wallet = _Wallet();
      final holder = await wallet.pay([_second], sats: 100, change: 6800);
      // A second transaction of ours over the same input: its hold is refused
      // (the first hold wins) but the record lists the input it spends.
      final other = await wallet.pay([_second], sats: 200, change: 6700);

      await wallet.handle(
          SpendUTXOCommand(walletId: _w, utxoKey: _second, spendingTxId: other, fee: BigInt.zero));

      expect(wallet.deferred(holder)['state'], 'outstanding',
          reason: 'its status comes from the network, not from a spend we observed');
      expect(wallet.utxo('$holder:1').status, UTXOStatus.pending,
          reason: 'its change is still on the way: the payment may yet be mined');
      expect(wallet.deferred(other)['state'], 'seen');
    });
  });
}
