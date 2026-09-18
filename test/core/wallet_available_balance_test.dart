/// libspiffy-ad07: the wallet write model's spendable amount
/// ([WalletState.availableBalance], [BitcoinWalletAggregate.hasSufficientBalance])
/// agrees with the aggregate's coin selection
/// ([BitcoinWalletAggregate.selectUTXOsForAmount]): both follow one
/// eligibility rule ([WalletBalances.isSpendable]).
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';

const _w = 'ad07-wallet';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _foreign = 'muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg';

String _txid(int n) => n.toRadixString(16).padLeft(64, '0');
String _key(int n) => '${_txid(n)}:0';

String _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();

/// A wallet aggregate driven without an actor system.
class _Wallet {
  final BitcoinWalletAggregate aggregate = BitcoinWalletAggregate(
    aggregateId: _w,
    aggregateType: 'BitcoinWallet',
    eventStore: InMemoryEventStore(),
    cryptoService: DartSVCryptoService(),
    secureStorage: InMemorySecureStorage(),
  );

  late String root;
  late String receivePubKey;
  late String receiveAddress;

  WalletState get state => aggregate.state ?? aggregate.createInitialState();

  static Future<_Wallet> create() async {
    final wallet = _Wallet();
    await wallet.handle(CreateWalletCommand(walletId: _w, walletName: 'ad07', mnemonic: _mnemonic));
    wallet.root = wallet.state.rootAddress!;
    final generated = (await wallet.handle(GenerateAddressCommand(walletId: _w, includePublicKey: true))).single
        as AddressGeneratedEvent;
    wallet.receiveAddress = generated.address;
    wallet.receivePubKey = generated.publicKeyHex!;
    return wallet;
  }

  Future<List<Event>> handle(WalletCommand command) async {
    final events = await aggregate.handleCommand(state, command);
    for (final e in events) {
      aggregate.eventHandler(e);
    }
    return events;
  }

  /// [provenHeight] is the block a verified merkle proof puts the receipt
  /// in; null while it is unproven (bead libspiffy-jc3h: that height is what
  /// the confirmed bucket is, and `ReceiveUTXOCommand` refuses one on a
  /// pending receipt).
  Future<void> receive(int tx, int sats,
          {String? script,
          String? address,
          UTXOStatus status = UTXOStatus.available,
          int? provenHeight = 900000,
          Map<String, dynamic>? pluginMetadata}) =>
      handle(ReceiveUTXOCommand(
        walletId: _w,
        txid: _txid(tx),
        vout: 0,
        satoshis: BigInt.from(sats),
        scriptPubKey: script ?? _p2pkh(address ?? root),
        address: address ?? root,
        initialStatus: status,
        blockHeight: provenHeight,
        pluginMetadata: pluginMetadata,
      ));
}

/// A transaction spending [input] to a foreign address.
String _paymentHex(String input) {
  final parts = input.split(':');
  final tx = dartsv.Transaction()
    ..version = 1
    ..nLockTime = 0;
  tx.inputs.add(dartsv.TransactionInput(parts[0], int.parse(parts[1]), dartsv.TransactionInput.MAX_SEQ_NUMBER));
  tx.outputs.add(dartsv.TransactionOutput(BigInt.from(9000), dartsv.SVScript.fromHex(_p2pkh(_foreign))));
  return tx.serialize();
}

/// A wallet holding one UTXO of each kind the balance and selection rules
/// distinguish. The spendable ones are 1, 2, 3 and 9 (80000 + 7000 + 500 +
/// 2500 = 90000 satoshis).
Future<_Wallet> _mixedWallet() async {
  final wallet = await _Wallet.create();
  final watchAddress = dartsv.SVPrivateKey.fromHex('33' * 32, dartsv.NetworkType.TEST)
      .publicKey
      .toAddress(dartsv.NetworkType.TEST)
      .toBase58();
  await wallet.handle(AddWatchAddressCommand(walletId: _w, address: watchAddress, scriptType: 'p2pkh'));

  await wallet.receive(1, 80000); // confirmed (a proven height), available
  await wallet.receive(2, 7000, provenHeight: null); // unconfirmed bucket, available
  await wallet.receive(3, 500, provenHeight: null); // unconfirmed bucket, available
  await wallet.receive(4, 40000, status: UTXOStatus.pending, provenHeight: null); // pending
  await wallet.receive(5, 11000); // reserved below
  await wallet.handle(ReserveUTXOCommand(walletId: _w, utxoKey: _key(5), reservedByTxId: 'payment-5'));
  await wallet.receive(6, 13000); // held by a deferred payment below
  final payment = _paymentHex(_key(6));
  await wallet.handle(RecordOutgoingTransactionCommand(
    walletId: _w,
    txid: dartsv.Transaction.fromHex(payment).id,
    rawHex: payment,
    totalInputSats: 13000,
    totalOutputSats: 9000,
    fee: 100,
    numInputs: 1,
    numOutputs: 1,
    txVersion: 1,
    txLockTime: 0,
    spentUtxoKeys: [_key(6)],
    recipientAddresses: const [_foreign],
    paymentAmount: BigInt.from(9000),
    deferSpend: true,
    invoiceId: 'inv',
    purpose: 'invoice-payment',
  ));
  await wallet.receive(7, 100000, pluginMetadata: {'pluginId': 'tok'}); // plugin-managed
  await wallet.receive(8, 200000, address: watchAddress); // watch-only
  // A P2PK output to the wallet's own key: the aggregate's selection takes it
  // (only the channel-funding and payment-coordinator paths, which sign every
  // input as P2PKH, leave it out).
  await wallet.receive(9, 2500, script: '21${wallet.receivePubKey}ac', address: wallet.receiveAddress);
  await wallet.receive(10, 60000); // spent below
  await wallet.handle(SpendUTXOCommand(walletId: _w, utxoKey: _key(10), spendingTxId: 'f' * 64, fee: BigInt.from(100)));
  return wallet;
}

BigInt _sum(Iterable<BitcoinUtxo> utxos) => utxos.fold(BigInt.zero, (sum, u) => sum + u.satoshis);

void main() {
  test('availableBalance is the sum of the UTXOs coin selection can select '
      '(confirmed, unconfirmed, pending, reserved, deferred-held, plugin-managed, watch-only, P2PK, spent)', () async {
    final wallet = await _mixedWallet();
    final state = wallet.state;
    final agg = wallet.aggregate;

    expect(state.utxos[_key(6)]!.status, UTXOStatus.reserved, reason: 'the deferred payment holds its input');
    expect(state.utxos[_key(10)]!.status, UTXOStatus.spent);

    // Everything selection can pick: an amount no wallet covers selects all
    // of it before failing, and the amount it names is what it had.
    final selectable = agg.getAvailableUTXOs(state);
    expect(selectable.map((u) => u.key).toSet(), {_key(1), _key(2), _key(3), _key(9)});
    expect(
      () => agg.selectUTXOsForAmount(state, BigInt.from(10).pow(12)),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('have 90000 available'))),
    );

    expect(state.availableBalance, _sum(selectable));
    expect(state.availableBalance, BigInt.from(90000));
    expect(_sum(agg.selectUTXOsForAmount(state, state.availableBalance)), BigInt.from(90000));

    // The buckets keep their own rule: every unspent UTXO counts in one.
    expect(state.confirmedBalance.getValue(), BigInt.from(80000 + 100000 + 200000 + 2500));
    expect(state.unconfirmedBalance.getValue(), BigInt.from(7000 + 500 + 40000));
    expect(state.reservedBalance.getValue(), BigInt.from(11000 + 13000));

    // The rule holds for a state rebuilt from its serialized form.
    expect(WalletState.fromMap(state.toMap()).availableBalance, BigInt.from(90000));
  });

  test('hasSufficientBalance agrees with selectUTXOsForAmount at the boundary', () async {
    final wallet = await _mixedWallet();
    final state = wallet.state;
    final agg = wallet.aggregate;
    final available = state.availableBalance;

    for (final amount in [BigInt.zero, BigInt.one, BigInt.from(80000), available, available + BigInt.one]) {
      final selectionSucceeds = () {
        try {
          agg.selectUTXOsForAmount(state, amount);
          return true;
        } on StateError {
          return false;
        }
      }();
      expect(agg.hasSufficientBalance(state, amount), selectionSucceeds, reason: 'amount $amount');
    }
    expect(agg.hasSufficientBalance(state, BigInt.from(90000)), isTrue);
    expect(agg.hasSufficientBalance(state, BigInt.from(90001)), isFalse);
    expect(
      () => agg.selectUTXOsForAmount(state, BigInt.from(90001)),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', 'Insufficient funds: need 90001 satoshis, have 90000 available')),
    );
  });

  test('releasing a reservation, cancelling a deferred payment and promoting a pending UTXO make them spendable',
      () async {
    final wallet = await _mixedWallet();
    await wallet.handle(ReleaseUTXOsCommand(walletId: _w, reservationId: 'payment-5'));
    expect(wallet.state.availableBalance, BigInt.from(90000 + 11000));
    final holder = wallet.state.utxos[_key(6)]!.reservedByTxId!;
    await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: holder));
    expect(wallet.state.availableBalance, BigInt.from(90000 + 11000 + 13000));
    await wallet.handle(MarkUTXOAvailableCommand(walletId: _w, txid: _txid(4), vout: 0));
    expect(wallet.state.availableBalance, BigInt.from(90000 + 11000 + 13000 + 40000));
    expect(wallet.state.availableBalance, _sum(wallet.aggregate.getAvailableUTXOs(wallet.state)));
    expect(wallet.aggregate.hasSufficientBalance(wallet.state, BigInt.from(154000)), isTrue);
    expect(wallet.aggregate.hasSufficientBalance(wallet.state, BigInt.from(154001)), isFalse);
  });
}
