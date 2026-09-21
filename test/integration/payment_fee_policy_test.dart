/// Bead libspiffy-bg7n: a payment pays ARC's policy rate on the size of the
/// transaction the network is given — the signed one.
///
/// The payment coordinator left the fee to dartsv's `withFeePerKb(100)`,
/// whose size estimate counts each input's unlocking script as it is
/// *before* signing (empty) and leaves out every input's 36-byte outpoint
/// and 4-byte sequence number, so every payment paid 6 satoshis whatever
/// its size: 226 bytes of one-input P2PKH payment, 521 bytes of three-input
/// payment and a 2-of-3 multisig input's two signatures alike. And the rate was a constant nobody published: the
/// owner's rule (21 Sep) is that every fee is ARC's published policy rate.
///
/// Selection had its own invented number too: it stopped adding inputs once
/// they covered the amount plus a flat 1,000 satoshis, whatever the fee
/// really was, and the payment reply's change was `inputs - amount - 1000`
/// rather than the change output the transaction has.
///
/// End to end through LibSpiffyActorSystem on regtest with real-PoW headers
/// and an ARC ([NetworkArc]) publishing its policy.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar/isar.dart';
import 'package:libspiffy/coordinator.dart' as coord;
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeadersReceivedMessage;
import 'package:libspiffy/src/core/wallet_commands.dart' show GenerateAddressCommand, ReceiveUTXOCommand;
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../mocks/network_arc.dart';
import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

const _walletId = 'bg7n-wallet';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;
  final hd = dartsv.HDPrivateKey.fromXpriv(kTestXpriv);

  /// The wallet's root key (m/0/0, kTestRootAddress).
  final rootKey = hd.deriveChildNumber(0).deriveChildNumber(0).privateKey.publicKey;

  /// A key the wallet does not hold.
  final otherKey = dartsv.SVPrivateKey.fromHex('11' * 32, dartsv.NetworkType.TEST).publicKey;

  final counterparty = dartsv.SVPrivateKey.fromHex('7a' * 32, dartsv.NetworkType.TEST)
      .publicKey
      .toAddress(dartsv.NetworkType.TEST)
      .toBase58();

  final p2pkhScript = dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(kTestRootAddress)).getScriptPubkey();

  late Directory dir;
  late Isar isar;
  late NetworkArc arc;
  late LibSpiffyActorSystem system;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bg7n_payment_fee_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'bg7n_${DateTime.now().microsecondsSinceEpoch}',
    );
    // 100 satoshis per 1,000 bytes: the rate the payment path used to
    // hardcode, so what differs is only the size it is charged on.
    arc = NetworkArc()..miningFee = const FeeRate(satoshis: 100, bytes: 1000);
    system = LibSpiffyActorSystem();
    await system.initialize(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      readModelStorage: InMemoryWalletStorage(),
      secureStorage: InMemorySecureStorage(),
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      arcService: arc,
    );
    await createWallet(
      walletManager: system.walletManager,
      actorSystem: system.actorSystem,
      walletId: _walletId,
      walletName: 'bg7n',
      xpriv: kTestXpriv,
    );
    await _until(() => system.walletStorage.isWalletAddress(_walletId, kTestRootAddress), 'root address projected');
  });

  tearDown(() async {
    try {
      await system.shutdown();
    } catch (_) {}
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  /// The next address the wallet generates, as its public key.
  Future<dartsv.SVPublicKey> generateWalletKey() async {
    final generated = Completer<AddressGeneratedResponse>();
    final receiver = await system.actorSystem.spawn('bg7n-address-${DateTime.now().microsecondsSinceEpoch}',
        () => TestReceiverActor<AddressGeneratedResponse>(generated));
    system.walletManager.tell(
      WalletCommandMessage(_walletId, GenerateAddressCommand(walletId: _walletId, includePublicKey: true)),
      sender: receiver,
    );
    final response = await generated.future.timeout(const Duration(seconds: 10));
    expect(response.success, isTrue, reason: response.error);
    await _until(() => system.walletStorage.isWalletAddress(_walletId, response.address), 'address projected');
    return dartsv.SVPublicKey.fromHex(response.publicKeyHex!);
  }

  dartsv.SVScript multisig(List<dartsv.SVPublicKey> keys, int threshold) =>
      dartsv.P2MSLockBuilder(keys, threshold, sorting: false).getScriptPubkey();

  /// Receives one mined transaction whose outputs are [outputs] and waits
  /// until the wallet holds each of them. An output the receive path does
  /// not credit (a P2PK) is handed to the wallet at [kTestRootAddress].
  Future<dartsv.Transaction> receiveMined(List<(dartsv.SVScript, int)> outputs) async {
    final p = _rawTransaction(
      prevTxid: Uint8List.fromList(List<int>.generate(32, (i) => 0x60 + i)),
      outputs: [for (final (script, sats) in outputs) (sats, Uint8List.fromList(hex.decode(script.toHex())))],
    );
    final internal = Uint8List.fromList(hex.decode(p.id).reversed.toList());
    final bump = BUMP.fromMerklePath(
      blockHeight: 1,
      txid: internal,
      index: 1,
      siblings: [Uint8List.fromList(List<int>.generate(32, (i) => (i * 5 + 1) & 0xff))],
    );
    final block1 = RegtestMiner.mine(parent: genesis, merkleRoot: Hash.fromBytes(bump.computeMerkleRoot(internal)));
    final block2 = RegtestMiner.mine(parent: block1, seed: 'bg7n-2');
    system.headerSyncActor.tell(BlockHeadersReceivedMessage(
      peerId: 'peer',
      headers: [block1, block2],
      startHeight: 1,
    ) as dynamic);
    await _until(() async => system.headerChain.bestHeight == 2, 'tip at 2');

    final imported = system.coordinatorEvents!
        .where((e) => e is coord.TransactionImportedEvent && e.transactionId == p.id)
        .cast<coord.TransactionImportedEvent>()
        .first
        .timeout(const Duration(seconds: 15));
    system.coordinator.tell(coord.ImportTransactionCommand(
      walletId: _walletId,
      beef: BEEF.create(
        bumps: [bump],
        txs: [Uint8List.fromList(hex.decode(p.serialize()))],
        hasMerkle: [true],
        bumpIndex: [0],
      ).serialize(),
    ));
    final event = await imported;
    expect(event.success, isTrue, reason: 'import failed: ${event.error}');

    Future<bool> held(int vout) async =>
        (await system.walletStorage.getPaymentUTXOs(_walletId)).any((u) => u.txid == p.id && u.vout == vout);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    for (var vout = 0; vout < outputs.length; vout++) {
      if (await held(vout)) continue;
      final (script, sats) = outputs[vout];
      final received = Completer<UTXOReceivedResponse>();
      final receiver = await system.actorSystem
          .spawn('bg7n-utxo-${DateTime.now().microsecondsSinceEpoch}', () => TestReceiverActor(received));
      system.walletManager.tell(
        WalletCommandMessage(
          _walletId,
          ReceiveUTXOCommand(
            walletId: _walletId,
            txid: p.id,
            vout: vout,
            satoshis: BigInt.from(sats),
            scriptPubKey: script.toHex(),
            address: kTestRootAddress,
            blockHeight: 1,
            confirmations: 2,
            initialStatus: UTXOStatus.available,
          ),
        ),
        sender: receiver,
      );
      final response = await received.future.timeout(const Duration(seconds: 10));
      expect(response.success, isTrue, reason: response.error);
    }
    for (var vout = 0; vout < outputs.length; vout++) {
      await _until(() => held(vout), 'UTXO ${p.id}:$vout projected');
    }
    return p;
  }

  Future<coord.PaymentReadyEvent> pay(String invoiceId, int amount) {
    final ready = system.coordinatorEvents!
        .where((e) => e is coord.PaymentReadyEvent && e.invoiceId == invoiceId)
        .cast<coord.PaymentReadyEvent>()
        .first
        .timeout(const Duration(seconds: 30));
    system.coordinator.tell(coord.PayInvoiceCommand(
      walletId: _walletId,
      invoiceId: invoiceId,
      addresses: [counterparty],
      amount: BigInt.from(amount),
    ));
    return ready;
  }

  /// The signed payment the event carries, with the value of what it spends
  /// read from [parent].
  (dartsv.Transaction, BigInt) signedPayment(coord.PaymentReadyEvent ready, dartsv.Transaction parent) {
    final payment = dartsv.Transaction.fromHex(hex.encode(BEEF.parse(ready.beefBytes).txs.last));
    expect(payment.id, ready.txid);
    final spent = payment.inputs.fold<BigInt>(BigInt.zero, (sum, input) {
      expect(input.prevTxnId, parent.id);
      return sum + parent.outputs[input.prevTxnOutputIndex].satoshis;
    });
    return (payment, spent);
  }

  /// The fee [payment] pays covers ARC's policy rate on its signed size.
  void expectPolicyFee(dartsv.Transaction payment, BigInt spent) {
    final paid = spent - payment.outputs.fold<BigInt>(BigInt.zero, (sum, o) => sum + o.satoshis);
    final signedBytes = payment.serialize().length ~/ 2;
    final policyFee = arc.miningFee.feeFor(signedBytes);
    expect(paid, greaterThanOrEqualTo(policyFee),
        reason: 'a $signedBytes-byte signed transaction pays $paid; the policy asks $policyFee');
    // No auction on this network: the estimate may round a signature up,
    // not pay for bytes the transaction does not have.
    expect(paid, lessThanOrEqualTo(arc.miningFee.feeFor(signedBytes + 2 * payment.inputs.length)),
        reason: 'paid well above the policy rate on the signed size');
  }

  test('bg7n: a payment from a P2PKH UTXO pays the policy rate on its signed size', () async {
    final parent = await receiveMined([(p2pkhScript, 100000)]);

    final ready = await pay('bg7n-p2pkh', 40000);

    expect(ready.success, isTrue, reason: ready.error);
    final (payment, spent) = signedPayment(ready, parent);
    // Old code: `a 226-byte signed transaction pays 6; the policy asks 23`.
    expectPolicyFee(payment, spent);
  });

  test('bg7n: a payment spending several P2PKH UTXOs pays for every input\'s outpoint and unlocking script', () async {
    final parent = await receiveMined([(p2pkhScript, 20000), (p2pkhScript, 20000), (p2pkhScript, 20000)]);

    final ready = await pay('bg7n-3in', 50000);

    expect(ready.success, isTrue, reason: ready.error);
    final (payment, spent) = signedPayment(ready, parent);
    expect(payment.inputs, hasLength(3));
    expectPolicyFee(payment, spent);
  });

  test('bg7n: a payment from a P2PK UTXO pays the policy rate on its signed size', () async {
    final script = dartsv.SVScript.fromString('${rootKey.toHex().length ~/ 2} 0x${rootKey.toHex()} OP_CHECKSIG');
    final parent = await receiveMined([(script, 100000)]);

    final ready = await pay('bg7n-p2pk', 40000);

    expect(ready.success, isTrue, reason: ready.error);
    final (payment, spent) = signedPayment(ready, parent);
    expectPolicyFee(payment, spent);
  });

  test('bg7n: a payment from a 2-of-3 bare multisig UTXO pays for both signatures', () async {
    final secondKey = await generateWalletKey();
    final parent = await receiveMined([(multisig([secondKey, otherKey, rootKey], 2), 100000)]);

    final ready = await pay('bg7n-2of3', 40000);

    expect(ready.success, isTrue, reason: ready.error);
    final (payment, spent) = signedPayment(ready, parent);
    expect(payment.inputs.single.script!.chunks, hasLength(3), reason: 'OP_0 and two signatures');
    expectPolicyFee(payment, spent);
  });

  test('bg7n: the reclaim of a payment made from a 2-of-3 multisig UTXO pays for both signatures', () async {
    final secondKey = await generateWalletKey();
    final parent = await receiveMined([(multisig([secondKey, otherKey, rootKey], 2), 100000)]);
    final ready = await pay('bg7n-reclaim', 40000);
    expect(ready.success, isTrue, reason: ready.error);
    await _until(() async => (await system.walletStorage.getDeferredPayment(_walletId, ready.txid)) != null,
        'payment recorded');

    final reclaimed = system.coordinatorEvents!
        .where((e) => e is coord.DeferredPaymentReclaimedEvent && e.requestId == 'bg7n-rc')
        .cast<coord.DeferredPaymentReclaimedEvent>()
        .first
        .timeout(const Duration(seconds: 30));
    system.coordinator.tell(coord.ReclaimDeferredPaymentCommand(
        walletId: _walletId, txid: ready.txid, reason: 'never broadcast', requestId: 'bg7n-rc'));
    final event = await reclaimed;

    expect(event.success, isTrue, reason: event.error);
    final reclaim = dartsv.Transaction.fromHex((await system.walletStorage.getTransaction(event.reclaimTxid!))!.rawHex);
    expect(reclaim.inputs.single.prevTxnId, parent.id);
    // Old code: every input sized as P2PKH, so `a 232-byte signed
    // transaction pays 20; the policy asks 24`.
    expectPolicyFee(reclaim, parent.outputs.first.satoshis);
    expect(event.fee, parent.outputs.first.satoshis - reclaim.outputs.single.satoshis);
  });

  test('bg7n: the payment reply reports the change the transaction pays back, not a flat guess', () async {
    final parent = await receiveMined([(p2pkhScript, 100000)]);

    final ready = await pay('bg7n-change', 40000);

    expect(ready.success, isTrue, reason: ready.error);
    final (payment, _) = signedPayment(ready, parent);
    final change = payment.outputs
        .where((o) => o.script.toHex() == p2pkhScript.toHex())
        .fold<BigInt>(BigInt.zero, (sum, o) => sum + o.satoshis);
    // Old code: 100000 - 40000 - 1000 = 59000, while the transaction's
    // change output holds 59994.
    expect(ready.changeAmount, change);
  });

  test('bg7n: selection covers the amount and the fee the transaction really pays, not a flat 1,000', () async {
    final parent = await receiveMined([(p2pkhScript, 100000)]);

    // 100,000 covers 99,500 and the ~23 satoshi fee; the old flat buffer
    // said it did not.
    final ready = await pay('bg7n-tight', 99500);

    // Old code: `Insufficient funds: need 99500 satoshis, have 100000`.
    expect(ready.success, isTrue, reason: ready.error);
    final (payment, spent) = signedPayment(ready, parent);
    expectPolicyFee(payment, spent);
  });

  test('bg7n: a payment to something that is not an address is refused, naming it', () async {
    await receiveMined([(p2pkhScript, 100000)]);

    final ready = system.coordinatorEvents!
        .where((e) => e is coord.PaymentReadyEvent && e.invoiceId == 'bg7n-bad-address')
        .cast<coord.PaymentReadyEvent>()
        .first
        .timeout(const Duration(seconds: 30));
    system.coordinator.tell(coord.PayInvoiceCommand(
        walletId: _walletId, invoiceId: 'bg7n-bad-address', addresses: ['mock-address'], amount: BigInt.from(1000)));
    final event = await ready;

    // The outputs are built before selection now, for their sizes; the
    // error says which address, not `Instance of 'AddressFormatException'`.
    expect(event.success, isFalse);
    expect(event.error, contains('mock-address'));
  });

  test('bg7n: a payment ARC\'s policy rate could not be read for is refused, not built at an invented rate', () async {
    await receiveMined([(p2pkhScript, 100000)]);
    arc.policyUnavailable = true;

    final ready = await pay('bg7n-no-policy', 40000);

    expect(ready.success, isFalse);
    expect(ready.error, contains('policy'));
    // Nothing was reserved or recorded for it: the UTXO is spendable.
    await _until(() async => (await system.walletStorage.getPaymentUTXOs(_walletId)).length == 1, 'UTXO available');
  });
}

/// A raw transaction with one input spending [prevTxid]:0 (display order
/// bytes reversed into the wire order) with an OP_TRUE scriptSig.
dartsv.Transaction _rawTransaction({required Uint8List prevTxid, required List<(int, Uint8List)> outputs}) {
  final b = BytesBuilder();
  void u32(int v) => b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  void varint(int v) {
    if (v < 0xfd) {
      b.addByte(v);
    } else {
      b.add([0xfd, v & 0xff, (v >> 8) & 0xff]);
    }
  }

  u32(1);
  b.addByte(1);
  b.add(prevTxid);
  u32(0);
  b.add([1, 0x51]);
  u32(0xffffffff);
  varint(outputs.length);
  for (final (sats, script) in outputs) {
    final v = ByteData(8)..setUint64(0, sats, Endian.little);
    b.add(v.buffer.asUint8List());
    varint(script.length);
    b.add(script);
  }
  u32(0);
  return dartsv.Transaction.fromHex(hex.encode(b.toBytes()));
}

Future<void> _until(Future<bool> Function() condition, String what,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
