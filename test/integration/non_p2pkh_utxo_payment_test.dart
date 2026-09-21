/// nlp (libspiffy-nlp): paying with a bare multisig or P2PK UTXO the
/// wallet can spend alone.
///
/// Since beads viy and n0p a bare multisig output is a wallet UTXO when the
/// wallet holds at least m of its keys (a 1-of-2 with one wallet key, a
/// 2-of-2 with both), attributed to the first wallet key's address. The
/// payment coordinator built every input as P2PKH for that address and the
/// wallet aggregate signed it as P2PKH, so the signature check failed and a
/// wallet whose funds sit in such an output could not pay.
///
/// Now the input is signed as multisig: `OP_0 <sig>...`, one signature per
/// required key from the wallet's keys, in script key order, each input
/// verified by dartsv's script interpreter against the multisig locking
/// script. A P2PK output (`<key> OP_CHECKSIG`, attributed to the key's
/// P2PKH address) had the same problem and is unlocked with `<sig>` alone.
///
/// End to end through LibSpiffyActorSystem on regtest with real-PoW headers:
/// the multisig output arrives in a mined transaction (BEEF with its BUMP),
/// then PayInvoiceCommand spends it.
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
import 'package:libspiffy/src/core/wallet_output_ownership.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';
import '../mocks/network_arc.dart';

const _walletId = 'nlp-wallet';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;
  final hd = dartsv.HDPrivateKey.fromXpriv(kTestXpriv);

  /// The wallet's root key (m/0/0, kTestRootAddress).
  final rootKey = hd.deriveChildNumber(0).deriveChildNumber(0).privateKey.publicKey;

  /// Keys the wallet does not hold.
  final otherKey = dartsv.SVPrivateKey.fromHex('11' * 32, dartsv.NetworkType.TEST).publicKey;

  final counterparty = dartsv.SVPrivateKey.fromHex('7a' * 32, dartsv.NetworkType.TEST)
      .publicKey
      .toAddress(dartsv.NetworkType.TEST)
      .toBase58();

  late Directory dir;
  late Isar isar;
  late LibSpiffyActorSystem system;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('nlp_multisig_payment_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'nlp_${DateTime.now().microsecondsSinceEpoch}',
    );
    system = LibSpiffyActorSystem();
    await system.initialize(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      readModelStorage: InMemoryWalletStorage(),
      secureStorage: InMemorySecureStorage(),
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      arcService: NetworkArc(),
    );
    await createWallet(
      walletManager: system.walletManager,
      actorSystem: system.actorSystem,
      walletId: _walletId,
      walletName: 'nlp',
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
    final receiver = await system.actorSystem.spawn('nlp-address-receiver-${DateTime.now().microsecondsSinceEpoch}',
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

  /// Receives a mined transaction whose output 0 is [script] worth [sats]
  /// (its BEEF carries the transaction and its BUMP) and waits for the
  /// wallet UTXO. [address] is the wallet address a P2PK output is
  /// attributed to; when the receive path does not credit it, the UTXO is
  /// handed to the wallet directly.
  Future<dartsv.Transaction> receiveMined(dartsv.SVScript script, int sats, {String? address}) async {
    final p = _rawTransaction(
      prevTxid: Uint8List.fromList(List<int>.generate(32, (i) => 0x60 + i)),
      outputs: [(sats, Uint8List.fromList(hex.decode(script.toHex())))],
    );
    final internal = Uint8List.fromList(hex.decode(p.id).reversed.toList());
    final bump = BUMP.fromMerklePath(
      blockHeight: 1,
      txid: internal,
      index: 1,
      siblings: [Uint8List.fromList(List<int>.generate(32, (i) => (i * 5 + 1) & 0xff))],
    );
    final block1 = RegtestMiner.mine(parent: genesis, merkleRoot: Hash.fromBytes(bump.computeMerkleRoot(internal)));
    final block2 = RegtestMiner.mine(parent: block1, seed: 'nlp-2');
    system.headerSyncActor.tell(BlockHeadersReceivedMessage(
      peerId: 'peer',
      headers: [block1, block2],
      startHeight: 1,
    ) as dynamic);
    await _until(() async => system.headerChain.bestHeight == 2, 'tip at 2');

    final beefHex = hex.encode(BEEF.create(
      bumps: [bump],
      txs: [Uint8List.fromList(hex.decode(p.serialize()))],
      hasMerkle: [true],
      bumpIndex: [0],
    ).serialize());
    final imported = system.coordinatorEvents!
        .where((e) => e is coord.TransactionImportedEvent && e.transactionId == p.id)
        .cast<coord.TransactionImportedEvent>()
        .first
        .timeout(const Duration(seconds: 15));
    system.coordinator.tell(coord.ImportTransactionCommand(walletId: _walletId, beef: hex.decode(beefHex)));
    final event = await imported;
    expect(event.success, isTrue, reason: 'import failed: ${event.error}');
    if (address != null && event.utxosCreated == 0) {
      final received = Completer<UTXOReceivedResponse>();
      final receiver = await system.actorSystem
          .spawn('nlp-utxo-receiver-${DateTime.now().microsecondsSinceEpoch}', () => TestReceiverActor(received));
      system.walletManager.tell(
        WalletCommandMessage(
          _walletId,
          ReceiveUTXOCommand(
            walletId: _walletId,
            txid: p.id,
            vout: 0,
            satoshis: BigInt.from(sats),
            scriptPubKey: script.toHex(),
            address: address,
            blockHeight: 1,
            confirmations: 2,
            initialStatus: UTXOStatus.available,
          ),
        ),
        sender: receiver,
      );
      final response = await received.future.timeout(const Duration(seconds: 10));
      expect(response.success, isTrue, reason: response.error);
    } else {
      expect(event.utxosCreated, 1, reason: 'the wallet can spend the output alone');
    }
    await _until(() async => (await system.walletStorage.getPaymentUTXOs(_walletId)).any((u) => u.txid == p.id),
        'UTXO projected');
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

  /// The payment's input 0 spends [parent]:0 locked by [script] with
  /// `OP_0` and [threshold] signatures, valid under the script interpreter.
  void expectValidMultisigSpend(
      coord.PaymentReadyEvent ready, dartsv.Transaction parent, dartsv.SVScript script, int threshold) {
    final beef = BEEF.parse(ready.beefBytes);
    final payment = dartsv.Transaction.fromHex(hex.encode(beef.txs.last));
    expect(payment.id, ready.txid);
    expect(payment.inputs, hasLength(1));
    final input = payment.inputs.single;
    expect(input.prevTxnId, parent.id);
    expect(input.prevTxnOutputIndex, 0);

    final scriptSig = input.script!;
    expect(scriptSig.chunks.first.opcodenum, dartsv.OpCodes.OP_0);
    expect(scriptSig.chunks, hasLength(1 + threshold));

    final flags = <dartsv.VerifyFlag>{dartsv.VerifyFlag.SIGHASH_FORKID, dartsv.VerifyFlag.UTXO_AFTER_GENESIS};
    final interpreter = dartsv.Interpreter();
    expect(
      () => interpreter.correctlySpends(
          scriptSig, script, payment, 0, flags, dartsv.Coin.ofSat(parent.outputs.first.satoshis)),
      returnsNormally,
    );
  }

  test('nlp: a 1-of-2 multisig UTXO holding one wallet key pays an invoice with a valid multisig spend', () async {
    final script = multisig([otherKey, rootKey], 1);
    final parent = await receiveMined(script, 100000);

    final ready = await pay('nlp-1of2', 40000);

    expect(ready.success, isTrue, reason: ready.error);
    expectValidMultisigSpend(ready, parent, script, 1);
    final storage = system.walletStorage;
    await _until(() async => (await storage.getDeferredPayment(_walletId, ready.txid)) != null, 'payment recorded');
    expect((await storage.getDeferredPayment(_walletId, ready.txid))!.heldInputs.single.utxoKey, '${parent.id}:0');
  });

  test('nlp: a 2-of-3 multisig UTXO holding two wallet keys pays with both signatures in script key order', () async {
    final secondKey = await generateWalletKey();
    final script = multisig([secondKey, otherKey, rootKey], 2);
    final parent = await receiveMined(script, 100000);

    final ready = await pay('nlp-2of3', 40000);

    expect(ready.success, isTrue, reason: ready.error);
    expectValidMultisigSpend(ready, parent, script, 2);
  });

  test('nlp: a P2PK UTXO locked to a wallet key pays an invoice with a valid <sig> spend', () async {
    final script = dartsv.SVScript.fromString('${rootKey.toHex().length ~/ 2} 0x${rootKey.toHex()} OP_CHECKSIG');
    expect(BareMultisigScript.parse(script), isNull);
    final parent = await receiveMined(script, 100000, address: kTestRootAddress);

    final ready = await pay('nlp-p2pk', 40000);

    expect(ready.success, isTrue, reason: ready.error);
    final payment = dartsv.Transaction.fromHex(hex.encode(BEEF.parse(ready.beefBytes).txs.last));
    final input = payment.inputs.single;
    expect('${input.prevTxnId}:${input.prevTxnOutputIndex}', '${parent.id}:0');
    expect(input.script!.chunks, hasLength(1), reason: 'P2PK is unlocked by the signature alone');
    dartsv.Interpreter().correctlySpends(
        input.script!,
        script,
        payment,
        0,
        {dartsv.VerifyFlag.SIGHASH_FORKID, dartsv.VerifyFlag.UTXO_AFTER_GENESIS},
        dartsv.Coin.ofSat(BigInt.from(100000)));
  });

  test('nlp: a 2-of-2 multisig UTXO whose keys are both the wallet\'s pays with a valid multisig spend', () async {
    final secondKey = await generateWalletKey();
    final script = multisig([rootKey, secondKey], 2);
    final parent = await receiveMined(script, 100000);

    final ready = await pay('nlp-2of2', 40000);

    expect(ready.success, isTrue, reason: ready.error);
    expectValidMultisigSpend(ready, parent, script, 2);
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
