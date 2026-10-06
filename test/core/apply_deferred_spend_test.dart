/// Bead libspiffy-3egy, in the wallet aggregate: ApplyDeferredSpendCommand.
///
/// Once the network has a transaction, the wallet's UTXOs it spends are
/// spent and its outputs the wallet holds become available. ARCActor used to
/// work out which those are from the read model and send a SpendUTXOCommand
/// and a MarkUTXOAvailableCommand per UTXO. The read model shows a recording
/// one event at a time, its transaction row before its outputs, and a report
/// in between promoted nothing: the change waited for the next status scan.
///
/// The aggregate holds the recording whole from the moment it accepts it,
/// and decides the spend from its own state, as it does on a confirmation.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet/outgoing_transactions.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

const _w = 'apply-deferred-spend-wallet';
final _input = '${'a1' * 32}:0';
final _second = '${'c3' * 32}:2';

/// An output that was never the wallet's.
final _foreign = '${'e5' * 32}:1';

final _ourKey = dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST);
final _ourAddress = _ourKey.publicKey.toAddress(dartsv.NetworkType.TEST);
final _ourScript = dartsv.P2PKHLockBuilder.fromAddress(_ourAddress).getScriptPubkey().toHex();

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

/// A transaction spending [inputs], paying [sats] to the recipient and each
/// of [change] back to the wallet's own address.
String _paymentHex(List<String> inputs, {int sats = 1000, List<int> change = const [18900]}) {
  final tx = dartsv.Transaction();
  for (final key in inputs) {
    final parts = key.split(':');
    tx.addInput(dartsv.TransactionInput(parts[0], int.parse(parts[1]), dartsv.TransactionInput.MAX_SEQ_NUMBER));
  }
  tx.addOutput(dartsv.TransactionOutput(BigInt.from(sats), dartsv.SVScript.fromHex(_theirScript)));
  for (final amount in change) {
    tx.addOutput(dartsv.TransactionOutput(BigInt.from(amount), dartsv.SVScript.fromHex(_ourScript)));
  }
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

  BitcoinWalletAggregate replay() {
    final fresh = _aggregate();
    for (final e in journal) {
      fresh.eventHandler(e);
    }
    return fresh;
  }

  /// Records a deferred payment out of [inputs] with [change] back to the
  /// wallet. Returns the transaction.
  Future<({String txid, String rawHex})> pay(List<String> inputs,
      {List<int> change = const [18900], List<String>? recordedInputs}) async {
    final rawHex = _paymentHex(inputs, change: change);
    final txid = dartsv.Transaction.fromHex(rawHex).id;
    await handle(RecordOutgoingTransactionCommand(
      walletId: _w,
      txid: txid,
      rawHex: rawHex,
      totalInputSats: 20000,
      totalOutputSats: 1000 + change.fold(0, (a, b) => a + b),
      fee: 100,
      numInputs: inputs.length,
      numOutputs: 1 + change.length,
      txVersion: 1,
      txLockTime: 0,
      spentUtxoKeys: recordedInputs ?? inputs,
      recipientAddresses: [_theirAddress.toBase58()],
      paymentAmount: BigInt.from(1000),
      changeAddress: _ourAddress.toBase58(),
      changeAmount: BigInt.from(change.fold(0, (a, b) => a + b)),
      deferSpend: true,
      invoiceId: 'inv',
      purpose: 'invoice-payment',
    ));
    return (txid: txid, rawHex: rawHex);
  }
}

/// What a state says about each UTXO and each deferred payment.
Map<String, Object?> _picture(BitcoinWalletAggregate aggregate) {
  final state = aggregate.currentState;
  return {
    for (final u in state.utxos.values) u.key: (u.status, u.spentInTxId, u.statusBeforeReservation),
    'deferred': {
      for (final e in (state.metadata['deferredSpends'] as Map).entries) e.key: (e.value as Map)['state'],
    },
    'available': state.availableBalance,
  };
}

void main() {
  test('the inputs are spent and every output the wallet holds becomes available, in one command', () async {
    final wallet = _Wallet();
    final tx = await wallet.pay([_input, _second], change: [18900, 6000]);
    expect(wallet.utxo('${tx.txid}:1').status, UTXOStatus.pending);
    expect(wallet.utxo('${tx.txid}:2').status, UTXOStatus.pending);

    final events = await wallet.handle(ApplyDeferredSpendCommand(walletId: _w, txid: tx.txid, rawHex: tx.rawHex));

    expect([
      for (final e in events)
        switch (e) {
          UTXOSpentEvent() => 'spent ${e.txid}:${e.vout} by ${e.spentInTxId}',
          UTXOMarkedAvailableEvent() => 'available ${e.txid}:${e.vout}',
          _ => '$e',
        }
    ], unorderedEquals([
      'spent $_input by ${tx.txid}',
      'spent $_second by ${tx.txid}',
      'available ${tx.txid}:1',
      'available ${tx.txid}:2',
    ]));
    for (final state in [wallet.aggregate.currentState, wallet.replay().currentState]) {
      expect(state.utxos[_input]!.status, UTXOStatus.spent);
      expect(state.utxos[_second]!.status, UTXOStatus.spent);
      expect(state.utxos['${tx.txid}:1']!.status, UTXOStatus.available);
      expect(state.utxos['${tx.txid}:2']!.status, UTXOStatus.available);
      expect(state.availableBalance, BigInt.from(18900 + 6000));
    }
  });

  test('it leaves the wallet exactly where the per-UTXO commands it replaces left it', () async {
    final one = _Wallet();
    final tx = await one.pay([_input, _second], change: [18900, 6000]);
    await one.handle(ApplyDeferredSpendCommand(walletId: _w, txid: tx.txid, rawHex: tx.rawHex));

    final perUtxo = _Wallet();
    await perUtxo.pay([_input, _second], change: [18900, 6000]);
    for (final key in [_input, _second]) {
      await perUtxo
          .handle(SpendUTXOCommand(walletId: _w, utxoKey: key, spendingTxId: tx.txid, fee: BigInt.zero));
    }
    for (final vout in [1, 2]) {
      await perUtxo.handle(MarkUTXOAvailableCommand(walletId: _w, txid: tx.txid, vout: vout));
    }

    expect(_picture(one.aggregate), _picture(perUtxo.aggregate));
    expect(_picture(one.replay()), _picture(perUtxo.aggregate));
  });

  test('a second command journals nothing', () async {
    final wallet = _Wallet();
    final tx = await wallet.pay([_input]);

    final first = await wallet.handle(ApplyDeferredSpendCommand(walletId: _w, txid: tx.txid, rawHex: tx.rawHex));
    final second = await wallet.handle(ApplyDeferredSpendCommand(walletId: _w, txid: tx.txid, rawHex: tx.rawHex));

    expect(first, hasLength(2));
    expect(second, isEmpty);
  });

  test('without the raw transaction, the inputs the wallet recorded it as spending are spent', () async {
    final wallet = _Wallet();
    final tx = await wallet.pay([_input]);

    await wallet.handle(ApplyDeferredSpendCommand(walletId: _w, txid: tx.txid));

    expect(wallet.utxo(_input).status, UTXOStatus.spent);
    expect(wallet.utxo(_input).spentInTxId, tx.txid);
    expect(wallet.utxo('${tx.txid}:1').status, UTXOStatus.available);
  });

  test('an input the recording does not list is spent from the raw transaction', () async {
    final wallet = _Wallet();
    // Recorded as spending only one of the two inputs it spends.
    final tx = await wallet.pay([_input, _second], recordedInputs: [_input]);

    await wallet.handle(ApplyDeferredSpendCommand(walletId: _w, txid: tx.txid, rawHex: tx.rawHex));

    expect(wallet.utxo(_input).status, UTXOStatus.spent);
    expect(wallet.utxo(_second).status, UTXOStatus.spent);
    expect(wallet.utxo(_second).spentInTxId, tx.txid);
  });

  test('a raw transaction that is not the txid is refused', () async {
    final wallet = _Wallet();
    final tx = await wallet.pay([_input]);
    final other = _paymentHex([_second], change: [6000]);

    await expectLater(
      wallet.handle(ApplyDeferredSpendCommand(walletId: _w, txid: tx.txid, rawHex: other)),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('handed over as ${tx.txid}'))),
    );
    expect(wallet.utxo(_input).status, isNot(UTXOStatus.spent));
    expect(wallet.utxo(_second).status, UTXOStatus.available);
  });

  test('a transaction the wallet did not record spends its available UTXO; an input that is not the '
      'wallet\'s is skipped', () async {
    final wallet = _Wallet();
    final rawHex = _paymentHex([_foreign, _second], change: const []);
    final txid = dartsv.Transaction.fromHex(rawHex).id;

    final events = await wallet.handle(ApplyDeferredSpendCommand(walletId: _w, txid: txid, rawHex: rawHex));

    expect(events, hasLength(1));
    expect(wallet.utxo(_second).status, UTXOStatus.spent);
    expect(wallet.utxo(_second).spentInTxId, txid);
    expect(wallet.utxo(_input).status, UTXOStatus.available);
  });

  test('an input another payment reserved is not spent by a transaction the wallet did not record; '
      'the rest of the spend applies', () async {
    final wallet = _Wallet();
    await wallet.handle(ReserveUTXOCommand(walletId: _w, utxoKey: _input, reservedByTxId: 'another-payment'));
    final rawHex = _paymentHex([_input, _second], change: const []);
    final txid = dartsv.Transaction.fromHex(rawHex).id;

    await wallet.handle(ApplyDeferredSpendCommand(walletId: _w, txid: txid, rawHex: rawHex));

    expect(wallet.utxo(_input).status, UTXOStatus.reserved);
    expect(wallet.utxo(_input).reservedByTxId, 'another-payment');
    expect(wallet.utxo(_second).status, UTXOStatus.spent);
  });

  test('an input already spent by another transaction is left as recorded', () async {
    final wallet = _Wallet();
    final tx = await wallet.pay([_input]);
    await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: tx.txid));
    await wallet.handle(SpendUTXOCommand(walletId: _w, utxoKey: _input, spendingTxId: 'ee' * 32, fee: BigInt.zero));

    final events = await wallet.handle(ApplyDeferredSpendCommand(walletId: _w, txid: tx.txid, rawHex: tx.rawHex));

    expect(events.whereType<UTXOSpentEvent>(), isEmpty);
    expect(wallet.utxo(_input).spentInTxId, 'ee' * 32);
  });

  test('a cancelled payment that reaches the network after all: its released input is spent and its '
      'voided change is available', () async {
    final wallet = _Wallet();
    final tx = await wallet.pay([_input]);
    await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: tx.txid));
    expect(wallet.utxo(_input).status, UTXOStatus.available);
    expect(wallet.utxo('${tx.txid}:1').status, UTXOStatus.voided);

    await wallet.handle(ApplyDeferredSpendCommand(walletId: _w, txid: tx.txid, rawHex: tx.rawHex));

    for (final state in [wallet.aggregate.currentState, wallet.replay().currentState]) {
      expect(state.utxos[_input]!.status, UTXOStatus.spent);
      expect(state.utxos['${tx.txid}:1']!.status, UTXOStatus.available);
    }
  });

  test('change reserved while pending is promoted under its reservation', () async {
    final wallet = _Wallet();
    final tx = await wallet.pay([_input]);
    final changeKey = '${tx.txid}:1';
    await wallet.handle(ReserveUTXOCommand(walletId: _w, utxoKey: changeKey, reservedByTxId: 'next-payment'));
    expect(wallet.utxo(changeKey).awaitsPromotion, isTrue);

    await wallet.handle(ApplyDeferredSpendCommand(walletId: _w, txid: tx.txid, rawHex: tx.rawHex));

    expect(wallet.utxo(changeKey).status, UTXOStatus.reserved, reason: 'the reservation stays');
    expect(wallet.utxo(changeKey).statusBeforeReservation, UTXOStatus.available);
    expect(wallet.utxo(changeKey).awaitsPromotion, isFalse);
  });

  test('a wallet that does not exist refuses', () {
    expect(
      () => OutgoingTransactions.applyDeferredSpend(
          WalletState.empty(_w), ApplyDeferredSpendCommand(walletId: _w, txid: 'ab' * 32)),
      throwsStateError,
    );
  });
}
