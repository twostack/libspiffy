/// libspiffy-dp4 characterization: behaviour of the wallet aggregate that its
/// decomposition into collaborators (lib/src/core/wallet/) must not change.
/// Written against the single-file aggregate (a2750cf) and kept passing after
/// the split.
///
/// * Balances after each kind of UTXO transition, incremental and from a
///   full recomputation, and after a snapshot restore.
/// * The aggregate's availability and selection helpers.
/// * Channel funding selection (largest first, every UTXO the wallet can
///   unlock on its own: bead libspiffy-8egy) and its reply.
/// * Signed transactions for each script type the wallet signs (ECDSA
///   signatures are deterministic, so the signed txids are pinned).
/// * The outputs a recorded outgoing transaction credits to the wallet.
/// * Holds inferred for deferred payments recorded before holds were
///   journaled, including the cached "no legacy payment" check across the
///   events that can invalidate it.
library;

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/utils/bip32.dart';

import '../actors/in_memory_event_store.dart';
import 'package:libspiffy/src/models/fee_rate.dart';

const _w = 'dp4-wallet';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _foreign = 'muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg';

String _txid(int n) => n.toRadixString(16).padLeft(64, '0');
String _key(int n, [int vout = 0]) => '${_txid(n)}:$vout';

String _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();

/// A wallet aggregate driven without an actor system: commands are handled
/// against its state and their events applied and kept as the journal.
class _Wallet {
  final InMemoryEventStore store = InMemoryEventStore();
  final InMemorySecureStorage secureStorage = InMemorySecureStorage();
  late final _Aggregate aggregate = _Aggregate(store, secureStorage);
  final List<Event> journal = [];

  late String root;
  late String receive1;
  late String receive1PubKey;
  late String change2;
  late String rootPubKey;

  static Future<_Wallet> create() async {
    final wallet = _Wallet();
    await wallet.handle(CreateWalletCommand(walletId: _w, walletName: 'dp4', mnemonic: _mnemonic));
    wallet.root = wallet.state.rootAddress!;
    final a1 = (await wallet.handle(GenerateAddressCommand(walletId: _w, includePublicKey: true))).single
        as AddressGeneratedEvent;
    wallet.receive1 = a1.address;
    wallet.receive1PubKey = a1.publicKeyHex!;
    final a2 = (await wallet.handle(GenerateAddressCommand(
      walletId: _w,
      purpose: BitcoinWalletAggregate.changePurpose,
      includePublicKey: true,
    )))
        .single as AddressGeneratedEvent;
    wallet.change2 = a2.address;
    final hd = dartsv.HDPublicKey.fromXpub((await wallet.secureStorage.getString('wallet_hdpubkey_$_w'))!);
    wallet.rootPubKey = Bip32.derivePublicPath(hd, 'm/0/0').publicKey.toHex();
    expect(dartsv.SVPublicKey.fromHex(wallet.rootPubKey).toAddress(dartsv.NetworkType.TEST).toBase58(), wallet.root);
    return wallet;
  }

  WalletState get state => aggregate.state ?? aggregate.createInitialState();

  Future<List<Event>> handle(WalletCommand command) async {
    final events = await aggregate.handleCommand(state, command);
    apply(events);
    return events;
  }

  void apply(List<Event> events) {
    for (final e in events) {
      aggregate.eventHandler(e);
      journal.add(e);
    }
  }

  /// [provenHeight] is the block a verified merkle proof puts the receipt
  /// in, which is what the confirmed bucket counts (bead libspiffy-jc3h);
  /// null while it is unproven (and `ReceiveUTXOCommand` refuses a height on
  /// a pending receipt).
  Future<void> receive(int tx, int sats,
          {int vout = 0,
          String? script,
          String? address,
          UTXOStatus status = UTXOStatus.available,
          int? provenHeight = 900000,
          Map<String, dynamic>? pluginMetadata}) =>
      handle(ReceiveUTXOCommand(
        walletId: _w,
        txid: _txid(tx),
        vout: vout,
        satoshis: BigInt.from(sats),
        scriptPubKey: script ?? _p2pkh(address ?? root),
        address: address ?? root,
        initialStatus: status,
        blockHeight: provenHeight,
        pluginMetadata: pluginMetadata,
      ));

  BitcoinUtxo utxo(String key) => state.utxos[key]!;
}

class _Aggregate extends BitcoinWalletAggregate {
  _Aggregate(EventStore store, InMemorySecureStorage secureStorage)
      : super(
          aggregateId: _w,
          aggregateType: 'BitcoinWallet',
          eventStore: store,
          cryptoService: DartSVCryptoService(),
          secureStorage: secureStorage,
        );

  Future<WalletState> restore(Map<String, dynamic> map) => restoreStateFromMap(map, 0);
}

(BigInt, BigInt, BigInt) _balances(WalletState s) =>
    (s.confirmedBalance.getValue(), s.unconfirmedBalance.getValue(), s.reservedBalance.getValue());

(BigInt, BigInt, BigInt) _b(int confirmed, int unconfirmed, int reserved) =>
    (BigInt.from(confirmed), BigInt.from(unconfirmed), BigInt.from(reserved));

/// A transaction spending [inputs] to [outputs] (script hex -> sats).
String _txHex(List<String> inputs, List<(String, int)> outputs) {
  final tx = dartsv.Transaction()
    ..version = 1
    ..nLockTime = 0;
  for (final key in inputs) {
    final parts = key.split(':');
    tx.inputs.add(dartsv.TransactionInput(parts[0], int.parse(parts[1]), dartsv.TransactionInput.MAX_SEQ_NUMBER));
  }
  for (final (script, sats) in outputs) {
    tx.outputs.add(dartsv.TransactionOutput(BigInt.from(sats), dartsv.SVScript.fromHex(script)));
  }
  return tx.serialize();
}

RecordOutgoingTransactionCommand _outgoing(String rawHex, List<String> inputs, {bool deferSpend = false}) =>
    RecordOutgoingTransactionCommand(
      walletId: _w,
      txid: dartsv.Transaction.fromHex(rawHex).id,
      rawHex: rawHex,
      totalInputSats: 10000,
      totalOutputSats: 9000,
      fee: 100,
      numInputs: inputs.length,
      numOutputs: 1,
      txVersion: 1,
      txLockTime: 0,
      spentUtxoKeys: inputs,
      recipientAddresses: const [_foreign],
      paymentAmount: BigInt.from(9000),
      deferSpend: deferSpend,
      invoiceId: 'inv',
      purpose: 'invoice-payment',
    );

void main() {
  group('balances', () {
    test('after each kind of UTXO transition: incremental, recomputed and restored from a snapshot agree', () async {
      final wallet = await _Wallet.create();
      final watchKey = dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST).publicKey;
      final watchAddress = watchKey.toAddress(dartsv.NetworkType.TEST).toBase58();

      Future<void> expectBalances(String step, (BigInt, BigInt, BigInt) expected) async {
        final state = wallet.state;
        expect(_balances(state), expected, reason: step);
        expect(_balances(state.recalculateBalances()), expected, reason: '$step (recalculated)');
        final restored = await wallet.aggregate.restore(CborSerializerRoundTrip.of(state.toMap()));
        expect(_balances(restored), expected, reason: '$step (snapshot restore)');
      }

      await wallet.receive(9, 1000, provenHeight: null);
      await expectBalances('unproven receive (unconfirmed)', _b(0, 1000, 0));
      await wallet.receive(1, 10000, status: UTXOStatus.pending, provenHeight: null);
      await expectBalances('pending receive', _b(0, 11000, 0));
      await wallet.receive(2, 20000);
      await expectBalances('proven receive (confirmed at depth one)', _b(20000, 11000, 0));
      await wallet.receive(3, 5000, provenHeight: null, pluginMetadata: {'pluginId': 'tok'});
      await expectBalances('plugin receive', _b(20000, 16000, 0));
      // A reported count moves nothing at all. It used to move the UTXO's
      // amount into the confirmed bucket at seven confirmations; bead
      // libspiffy-jc3h makes the proven block height the confirmed test, so
      // a count nobody verified leaves the buckets exactly as they were (and
      // bead libspiffy-8oaq had already stopped it promoting the status).
      await wallet.handle(UpdateUTXOConfirmationsCommand(walletId: _w, utxoKey: _key(1), confirmations: 7));
      await expectBalances('confirmations updated', _b(20000, 16000, 0));
      expect(wallet.state.utxos[_key(1)]!.status, UTXOStatus.pending,
          reason: 'a caller-supplied count is a claim, not evidence');
      expect(wallet.state.availableBalance, BigInt.from(21000),
          reason: 'only the genuinely available UTXOs can fund a payment');
      await wallet.handle(MarkUTXOAvailableCommand(walletId: _w, txid: _txid(1), vout: 0));
      await expectBalances('marked available (spendable, still unproven)', _b(20000, 16000, 0));
      expect(wallet.state.utxos[_key(1)]!.status, UTXOStatus.available,
          reason: 'this is the path that does make it spendable');
      expect(wallet.state.availableBalance, BigInt.from(31000),
          reason: 'the promoted 10000 joins them');
      await wallet.handle(ReserveUTXOCommand(walletId: _w, utxoKey: _key(2), reservedByTxId: 'r'));
      await expectBalances('reserved', _b(0, 16000, 20000));
      await wallet.handle(RenewUTXOReservationCommand(
          walletId: _w, utxoKey: _key(2), extensionDuration: const Duration(minutes: 5)));
      await expectBalances('renewed', _b(0, 16000, 20000));
      await wallet.handle(ReleaseUTXOCommand(walletId: _w, utxoKey: _key(2)));
      await expectBalances('released', _b(20000, 16000, 0));
      await wallet.handle(SpendUTXOCommand(walletId: _w, utxoKey: _key(3), spendingTxId: 's', fee: BigInt.zero));
      await expectBalances('spent', _b(20000, 11000, 0));

      final payment = _txHex([_key(1)], [(_p2pkh(_foreign), 9000)]);
      final record = _outgoing(payment, [_key(1)], deferSpend: true);
      await wallet.handle(record);
      await expectBalances('deferred hold', _b(20000, 1000, 10000));
      await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: record.txid));
      await expectBalances('deferred cancelled', _b(20000, 11000, 0));

      await wallet.handle(ConfirmTransactionCommand(walletId: _w, txid: _txid(2), blockHeight: 100, blockHash: 'h'));
      await expectBalances('confirmed transaction (the proof restamps the height)', _b(20000, 11000, 0));
      await wallet.handle(RevertTransactionConfirmationCommand(walletId: _w, txid: _txid(2), reason: 'reorg'));
      // The revert takes the height off, so the amount leaves the confirmed
      // bucket: nothing puts it in a block on our chain any more.
      await expectBalances('confirmation reverted', _b(0, 31000, 0));

      await wallet.handle(AddWatchAddressCommand(walletId: _w, address: watchAddress, scriptType: 'p2pkh'));
      await wallet.receive(4, 7000, address: watchAddress);
      await expectBalances('watch-only receive (counted in the state balances)', _b(7000, 31000, 0));

      final spend = _txHex([_key(2)], [(_p2pkh(_foreign), 1000), (_p2pkh(wallet.change2), 18000)]);
      await wallet.handle(_outgoing(spend, [_key(2)]));
      await expectBalances('recorded spend with change', _b(7000, 29000, 0));

      await wallet.handle(ReserveUTXOsCommand(walletId: _w, utxoKeys: [_key(1), _key(4)], reservationId: 'multi'));
      await expectBalances('reserved many', _b(0, 19000, 17000));
      await wallet.handle(ReleaseUTXOsCommand(walletId: _w, reservationId: 'multi'));
      await expectBalances('released many', _b(7000, 29000, 0));
      await wallet.handle(ReserveUTXOCommand(
          walletId: _w, utxoKey: _key(1), reservedByTxId: 'x', reservationDuration: const Duration(seconds: -1)));
      await wallet.handle(CleanupExpiredReservationsCommand(walletId: _w));
      await expectBalances('expired reservation cleaned up', _b(7000, 29000, 0));
    });
  });

  group('availability and selection helpers', () {
    Future<_Wallet> stocked() async {
      final wallet = await _Wallet.create();
      final watchAddress =
          dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST).publicKey.toAddress(dartsv.NetworkType.TEST).toBase58();
      await wallet.handle(AddWatchAddressCommand(walletId: _w, address: watchAddress, scriptType: 'p2pkh'));
      await wallet.receive(1, 3000);
      await wallet.receive(2, 9000, provenHeight: null);
      await wallet.receive(3, 6000);
      await wallet.receive(4, 50000, status: UTXOStatus.pending, provenHeight: null);
      await wallet.receive(5, 8000);
      await wallet.handle(ReserveUTXOCommand(walletId: _w, utxoKey: _key(5), reservedByTxId: 'res-5'));
      await wallet.receive(6, 100000, pluginMetadata: {'pluginId': 'tok'});
      await wallet.receive(7, 70000, address: watchAddress);
      return wallet;
    }

    test('getAvailableUTXOs, selectUTXOsForAmount and the predicates', () async {
      final wallet = await stocked();
      final agg = wallet.aggregate;
      final state = wallet.state;

      expect(agg.getAvailableUTXOs(state).map((u) => u.key), [_key(1), _key(2), _key(3)]);
      expect(agg.selectUTXOsForAmount(state, BigInt.from(10000)).map((u) => u.key), [_key(2), _key(3)]);
      expect(agg.selectUTXOsForAmount(state, BigInt.from(18000)).map((u) => u.key), [_key(2), _key(3), _key(1)]);
      expect(
        () => agg.selectUTXOsForAmount(state, BigInt.from(18001)),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            'Insufficient funds: need 18001 satoshis, have 18000 available')),
      );
      expect(agg.canSpendUTXO(state, _key(1)), isTrue);
      expect(agg.canSpendUTXO(state, _key(4)), isFalse);
      expect(agg.canSpendUTXO(state, _key(5)), isFalse);
      expect(agg.canSpendUTXO(state, _key(7)), isTrue, reason: 'watch-only is not considered');
      expect(agg.canReserveUTXO(state, _key(6)), isTrue);
      expect(agg.canReserveUTXO(state, 'missing:0'), isFalse);
      expect(agg.getReservedUTXOs(state, 'res-5').map((u) => u.key), [_key(5)]);
      expect(_balances(state), _b(179000, 59000, 8000));
      // libspiffy-ad07: the amount selection can fund (was 230000, the
      // buckets less the reserved amount, counting pending, plugin-managed
      // and watch-only UTXOs).
      expect(state.availableBalance, BigInt.from(18000));
      expect(agg.hasSufficientBalance(state, BigInt.from(18000)), isTrue);
      expect(agg.hasSufficientBalance(state, BigInt.from(18001)), isFalse);
    });

    // Defect found by libspiffy-dp4, fixed by libspiffy-ad07: confirmed and
    // unconfirmed balances already leave reserved UTXOs out, and
    // availableBalance subtracted them a second time.
    test('defect: availableBalance subtracts reserved amounts the confirmed and unconfirmed balances already exclude',
        () async {
      final wallet = await _Wallet.create();
      await wallet.receive(1, 10000);
      await wallet.receive(2, 4000);
      await wallet.handle(ReserveUTXOCommand(walletId: _w, utxoKey: _key(2), reservedByTxId: 'r'));

      expect(_balances(wallet.state), _b(10000, 0, 4000));
      expect(wallet.state.availableBalance, BigInt.from(10000));
      expect(wallet.aggregate.hasSufficientBalance(wallet.state, BigInt.from(10000)), isTrue);
    });

  });

  group('channel funding', () {
    final client = dartsv.SVPrivateKey.fromHex('31' * 32, dartsv.NetworkType.TEST).publicKey.toHex();
    final server = dartsv.SVPrivateKey.fromHex('32' * 32, dartsv.NetworkType.TEST).publicKey.toHex();

    Future<_Wallet> funded() async {
      final wallet = await _Wallet.create();
      await wallet.receive(1, 3000);
      await wallet.receive(2, 40000, address: wallet.receive1);
      await wallet.receive(3, 20000, address: wallet.change2);
      await wallet.receive(4, 90000,
          script: dartsv.P2PKLockBuilder(dartsv.SVPublicKey.fromHex(wallet.rootPubKey)).getScriptPubkey().toHex());
      await wallet.receive(5, 80000);
      await wallet.handle(ReserveUTXOCommand(walletId: _w, utxoKey: _key(5), reservedByTxId: 'other'));
      return wallet;
    }

    BuildFundingTransactionCommand command(_Wallet wallet, int sats) => BuildFundingTransactionCommand(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          walletId: _w,
          correlationId: 'corr',
          channelId: 'ch-1',
          clientPubKeyHex: client,
          serverPubKeyHex: server,
          fundingAmountSats: sats,
          changeAddressBase58: wallet.change2,
        );

    test('selects spendable UTXOs largest first until amount and fee are covered, and reserves them', () async {
      // UTXO 4 is a P2PK output to a wallet key: the wallet's own money and
      // the largest UTXO, so it is picked first (bead libspiffy-8egy; it
      // used to be excluded as un-signable and never funded a channel).
      final wallet = await funded();
      final one = await wallet.handle(command(wallet, 30000));
      expect([for (final e in one.cast<UTXOReservedEvent>()) '${e.txid}:${e.vout}'], [_key(4)]);

      final wallet2 = await funded();
      final two = (await wallet2.handle(command(wallet2, 100000))).cast<UTXOReservedEvent>();
      expect([for (final e in two) '${e.txid}:${e.vout}'], [_key(4), _key(2)]);
      expect(two.map((e) => e.priority), [10, 10]);
      expect(two.map((e) => e.reservationReason), ['Payment channel funding: ch-1', 'Payment channel funding: ch-1']);
      expect(two.first.reservedByTxId, two.last.reservedByTxId);
      expect(two.first.expiresAt.difference(DateTime.now()).inMinutes, inInclusiveRange(58, 60));

      // 90000 + 40000 + 20000 + 3000 available; UTXO 5 is reserved.
      final wallet3 = await funded();
      await expectLater(
        wallet3.handle(command(wallet3, 153000)),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            'Failed to build funding transaction: Bad state: Insufficient funds: need 153069, have 153000')),
      );
    });

    test('the funding reply (actor system) is pinned', () async {
      final wallet = await funded();
      await wallet.store.persistEvents('BitcoinWallet_$_w', wallet.journal, 0);
      final system = TestActorSystem();
      addTearDown(system.shutdown);
      final ActorRef ref = await system.spawn('funding-wallet', () => _Aggregate(wallet.store, wallet.secureStorage));
      final probe = await system.createProbe();
      ref.tell(command(wallet, 30000), sender: probe.ref);
      final response = await probe.expectMsgType<FundingTransactionBuiltResponse>(timeout: const Duration(seconds: 10));

      expect(response.success, isTrue, reason: response.error);
      expect(
        [response.fundingTxId, response.fundingOutputIndex, response.changeOutputIndex, response.changeAddress,
          response.changeAmount, response.fee, response.totalInputSats, response.totalOutputSats],
        // The fee is 24, not 23, since bead libspiffy-zs4l: ARC's policy rate
        // rounded up, as every fee is — the funding used to round down.
        ['50c13621fff0aa65a0e81dce0f54658df4f97c626c940f5b6c2e101938458b03', 1, 0, wallet.change2, 59976, 24, 90000, 89976],
      );
      expect(response.spentUtxoKeys, [_key(4)]);
      expect(dartsv.Transaction.fromHex(response.fundingTxHex).id, response.fundingTxId);
    });
  });

  group('signing', () {
    SignTransactionCommand sign(List<String> keys, String rawHex) => SignTransactionCommand(
          walletId: _w,
          transactionId: 'unsigned',
          rawTransaction: rawHex,
          utxoKeys: keys,
          publicKeys: const [],
        );

    Future<String> signedTxid(_Wallet wallet, List<String> keys) async {
      final raw = _txHex(keys, [(_p2pkh(_foreign), 1000)]);
      final event = (await wallet.handle(sign(keys, raw))).single as TransactionSignedEvent;
      expect(event.txid, dartsv.Transaction.fromHex(event.signedRawHex).id);
      return event.txid;
    }

    test('each script type the wallet signs gives the pinned transaction', () async {
      final wallet = await _Wallet.create();
      final rootKey = dartsv.SVPublicKey.fromHex(wallet.rootPubKey);
      final key1 = dartsv.SVPublicKey.fromHex(wallet.receive1PubKey);
      final foreignKey = dartsv.SVPrivateKey.fromHex('7a' * 32, dartsv.NetworkType.TEST).publicKey;
      await wallet.receive(1, 5000);
      await wallet.receive(2, 6000, address: wallet.change2);
      await wallet.receive(3, 7000, script: dartsv.P2PKLockBuilder(key1).getScriptPubkey().toHex(), address: wallet.receive1);
      await wallet.receive(4, 8000,
          script: dartsv.P2MSLockBuilder([foreignKey, key1], 1, sorting: false).getScriptPubkey().toHex(),
          address: wallet.receive1);
      await wallet.receive(5, 9000,
          script: dartsv.P2MSLockBuilder([rootKey, foreignKey, key1], 2, sorting: false).getScriptPubkey().toHex(),
          address: wallet.root);

      expect([
        await signedTxid(wallet, [_key(1)]), // P2PKH, receive chain
        await signedTxid(wallet, [_key(2)]), // P2PKH, change chain
        await signedTxid(wallet, [_key(3)]), // P2PK
        await signedTxid(wallet, [_key(4)]), // 1-of-2 multisig
        await signedTxid(wallet, [_key(5)]), // 2-of-3 multisig, two wallet keys
        await signedTxid(wallet, [_key(1), _key(3), _key(5)]), // mixed inputs
      ], [
        '03d11651c8f362b8ac34f58f0c01b6b0266626ae8995a49171f856239ce72157',
        '51db33491a3de93dd15954093d54f4b0c867ad868f3455caccf225f5380f2a32',
        'e60c63c822e1a994efb3152d595315375a833fabbf27c11c1b0859d9f89a332e',
        'b637942b75ed865f6c7c9b09315f478649abd397b89f04a8bb4e2bce05f46e81',
        '1b6bc373eb57c1acc3e7dc7c83cca0af3ac40a940ba8d2e8b37c8a32794ff851',
        '767975874edd39e4e4c80c53e1f79d15742771035b5f8ec79d872595100de15e',
      ]);
    });

    test('refusals keep their texts', () async {
      final wallet = await _Wallet.create();
      await expectLater(
        wallet.handle(sign(['${'f' * 64}:0'], _txHex(['${'f' * 64}:0'], [(_p2pkh(_foreign), 1)]))),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            'Failed to sign transaction: Bad state: UTXO ${'f' * 64}:0 not found in wallet state')),
      );
      await wallet.receive(6, 8000, address: wallet.receive1);
      await expectLater(
        wallet.handle(SignTransactionCommand(
          walletId: _w,
          transactionId: 'wrong-index',
          rawTransaction: _txHex([_key(6)], [(_p2pkh(_foreign), 1000)]),
          utxoKeys: [_key(6)],
          publicKeys: const [],
          derivationIndices: const [0],
        )),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            'Failed to sign transaction: Bad state: Cannot sign UTXO ${_key(6)} at ${wallet.receive1}: the wallet '
                'holds no key for it (the key derived for ${wallet.receive1} does not control its script)')),
      );
    });
  });

  group('recorded outgoing transaction outputs', () {
    test('P2PKH, P2PK and spendable multisig outputs are credited; OP_RETURN, foreign and unspendable ones are not',
        () async {
      final wallet = await _Wallet.create();
      await wallet.receive(1, 50000);
      final key1 = dartsv.SVPublicKey.fromHex(wallet.receive1PubKey);
      final foreignKey = dartsv.SVPrivateKey.fromHex('7a' * 32, dartsv.NetworkType.TEST).publicKey;
      const opReturn = '006a02cafe';
      final raw = _txHex([_key(1)], [
        (_p2pkh(_foreign), 1000),
        (_p2pkh(wallet.change2), 2000),
        (dartsv.P2PKLockBuilder(key1).getScriptPubkey().toHex(), 3000),
        (dartsv.P2MSLockBuilder([foreignKey, key1], 1, sorting: false).getScriptPubkey().toHex(), 4000),
        (dartsv.P2MSLockBuilder([foreignKey, key1], 2, sorting: false).getScriptPubkey().toHex(), 5000),
        (opReturn, 0),
        (_p2pkh(wallet.root), 6000),
      ]);
      final events = await wallet.handle(_outgoing(raw, [_key(1)]));

      expect(events.map((e) => e.runtimeType.toString()), [
        'TransactionRecordedEvent',
        'UTXOSpentEvent',
        'UTXOReceivedEvent',
        'UTXOReceivedEvent',
        'UTXOReceivedEvent',
        'UTXOReceivedEvent',
      ]);
      expect([for (final e in events.whereType<UTXOReceivedEvent>()) (e.vout, e.address, e.satoshis, e.initialStatus)], [
        (1, wallet.change2, 2000, UTXOStatus.pending),
        (2, wallet.receive1, 3000, UTXOStatus.pending),
        (3, wallet.receive1, 4000, UTXOStatus.pending),
        (6, wallet.root, 6000, UTXOStatus.pending),
      ]);
      expect([for (final e in events) e.version], [
        for (var i = 0; i < events.length; i++) wallet.journal.first.version + 3 + i + 1,
      ]);
      expect(await wallet.handle(_outgoing(raw, [_key(1)])), isEmpty, reason: 'recorded once');
    });
  });

  group('deferred payments recorded before holds were journaled', () {
    /// Applies a legacy outgoing record of [inputs] (no hold) at [at].
    String legacyRecord(_Wallet wallet, List<String> inputs, DateTime at, {int sats = 1000}) {
      final raw = _txHex(inputs, [(_p2pkh(_foreign), sats)]);
      final txid = dartsv.Transaction.fromHex(raw).id;
      wallet.apply([
        TransactionRecordedEvent(
          walletId: _w,
          txid: txid,
          rawHex: raw,
          totalInputSats: 20000,
          totalOutputSats: sats,
          fee: 100,
          numInputs: inputs.length,
          numOutputs: 1,
          txVersion: 1,
          txLockTime: 0,
          spentUtxoKeys: inputs,
          recipientAddresses: const [_foreign],
          paymentAmount: '$sats',
          version: wallet.state.version + 1,
          timestamp: at,
        ),
      ]);
      return txid;
    }

    Future<void> expectReservable(_Wallet wallet, String key, bool reservable) async {
      final attempt = wallet.aggregate.handleCommand(
          wallet.state, ReserveUTXOCommand(walletId: _w, utxoKey: key, reservedByTxId: 'probe'));
      if (reservable) {
        await attempt;
      } else {
        await expectLater(attempt, throwsA(isA<StateError>().having((e) => e.message, 'message', contains('held by deferred payment'))));
      }
    }

    test('an input two legacy records list is held by the older one; the inferred holds are ordered by record time',
        () async {
      final wallet = await _Wallet.create();
      await wallet.receive(1, 1000);
      await wallet.receive(2, 2000);
      await wallet.receive(3, 3000);
      final newer = legacyRecord(wallet, [_key(2), _key(3)], DateTime.utc(2025, 2), sats: 900);
      final older = legacyRecord(wallet, [_key(1), _key(2)], DateTime.utc(2025, 1), sats: 800);

      final events = (await wallet.handle(ReconcileDeferredSpendsCommand(walletId: _w))).cast<TransactionSpendDeferredEvent>();
      expect([for (final e in events) (e.txid, e.inferred, e.purpose, e.paymentAmount, e.fee)], [
        (older, true, 'legacy', '800', 100),
        (newer, true, 'legacy', '900', 100),
      ]);
      expect([for (final e in events) e.heldUtxoKeys], [
        [_key(1), _key(2)],
        [_key(3)],
      ]);
      expect(events.first.recordedAt, DateTime.utc(2025, 1));
      expect([for (final e in events) e.version], [wallet.state.version - 1, wallet.state.version]);
    });

    test('the cached "no legacy payment" check is invalidated by a record, a received UTXO and a reverted confirmation',
        () async {
      final wallet = await _Wallet.create();
      await wallet.receive(1, 1000);
      await expectReservable(wallet, _key(1), true);

      legacyRecord(wallet, [_key(1)], DateTime.utc(2025));
      await expectReservable(wallet, _key(1), false);

      final wallet2 = await _Wallet.create();
      legacyRecord(wallet2, [_key(2)], DateTime.utc(2025));
      await wallet2.receive(1, 1000);
      await expectReservable(wallet2, _key(1), true);
      await wallet2.receive(2, 2000);
      await expectReservable(wallet2, _key(2), false);

      final wallet3 = await _Wallet.create();
      await wallet3.receive(2, 2000);
      final txid = legacyRecord(wallet3, [_key(2)], DateTime.utc(2025));
      // A confirmation journaled before bead hccp, which did not spend the
      // inputs (a ConfirmTransactionCommand now spends them).
      wallet3.apply([
        TransactionConfirmedEvent(
            walletId: _w, txid: txid, blockHeight: 5, blockHash: 'h',
            version: wallet3.state.version + 1, timestamp: DateTime.utc(2025, 2)),
      ]);
      await expectReservable(wallet3, _key(2), true);
      await wallet3.handle(RevertTransactionConfirmationCommand(walletId: _w, txid: txid, reason: 'reorg'));
      await expectReservable(wallet3, _key(2), false);
    });
  });
}

/// The snapshot map after eventador's CBOR round trip.
abstract final class CborSerializerRoundTrip {
  static Map<String, dynamic> of(Map<String, dynamic> map) =>
      Map<String, dynamic>.from(CborSerializer.deserializeState(CborSerializer.serializeState(map), 'state') as Map);
}
