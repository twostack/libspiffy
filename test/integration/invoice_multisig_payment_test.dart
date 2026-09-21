/// n0p (libspiffy-n0p): an invoice's bare multisig output received through
/// SPVActor.
///
/// SPVActor attributed an invoice's multisig output to a 'p2ms:m-of-n'
/// pseudo-address and handed it to the wallet as a UTXO whatever keys the
/// wallet holds, and BitcoinWalletAggregate exempted outputs attributed
/// that way from the "a multisig output is the wallet's only when it holds
/// at least m of its keys" rule (bead libspiffy-viy). On 9143ae6 that
/// branch never ran: it read the keys under a name dartsv's P2MS template
/// does not use ('pubKeys'; dartsv 3 says 'publicKeys', as SVPublicKey), so
/// an invoice paid with its multisig output was not recognised at all, and
/// the invoice aggregate would have refused it anyway (it only accepted
/// payments to the invoice's P2PKH addresses). Reading the keys correctly
/// alone would have credited a 2-of-2 escrow holding one wallet key as
/// spendable balance.
///
/// Now: the payment is recognised against the invoice terms (invoice
/// marked paid), the transaction is recorded whole with its raw bytes and
/// proof, and the output is a wallet UTXO only when the wallet holds at
/// least m of its keys.
///
/// End to end through LibSpiffyActorSystem on regtest with real-PoW headers:
/// CreateInvoiceCommand with a P2MSOutputSpec, then ValidateBEEFCommand
/// with the invoice id and a BEEF holding the mined payment and its BUMP.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/coordinator.dart' as coord;
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeadersReceivedMessage;
import 'package:libspiffy/src/core/wallet_commands.dart' show GenerateAddressCommand;
import 'package:libspiffy/src/core/wallet_events.dart' as we;
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

const _walletId = 'n0p-wallet';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;
  final hd = dartsv.HDPrivateKey.fromXpriv(kTestXpriv);

  /// The wallet's root key (m/0/0, kTestRootAddress).
  final rootKey = hd.deriveChildNumber(0).deriveChildNumber(0).privateKey.publicKey;

  /// Keys the wallet does not hold (the other parties of an escrow).
  final otherKey = dartsv.SVPrivateKey.fromHex('11' * 32, dartsv.NetworkType.TEST).publicKey;
  final otherKey2 = dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST).publicKey;

  final counterpartyLock = dartsv.P2PKHLockBuilder.fromAddress(
      dartsv.SVPrivateKey.fromHex('7a' * 32, dartsv.NetworkType.TEST).publicKey.toAddress(dartsv.NetworkType.TEST));

  late Directory dir;
  late Isar isar;
  late LibSpiffyActorSystem system;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('n0p_invoice_multisig_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'n0p_${DateTime.now().microsecondsSinceEpoch}',
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
    );
    await createWallet(
      walletManager: system.walletManager,
      actorSystem: system.actorSystem,
      walletId: _walletId,
      walletName: 'n0p',
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

  /// A wallet key other than the root key: the address the wallet generates
  /// next, with its public key.
  Future<dartsv.SVPublicKey> generateWalletKey() async {
    final generated = Completer<AddressGeneratedResponse>();
    final receiver = await system.actorSystem
        .spawn('n0p-address-receiver', () => TestReceiverActor<AddressGeneratedResponse>(generated));
    system.walletManager.tell(
      WalletCommandMessage(_walletId,
          GenerateAddressCommand(walletId: _walletId, label: 'escrow', includePublicKey: true)),
      sender: receiver,
    );
    final response = await generated.future.timeout(const Duration(seconds: 10));
    expect(response.success, isTrue, reason: response.error);
    await _until(() => system.walletStorage.isWalletAddress(_walletId, response.address), 'second address projected');
    final key = dartsv.SVPublicKey.fromHex(response.publicKeyHex!);
    expect(key.toAddress(dartsv.NetworkType.TEST).toBase58(), response.address);
    return key;
  }

  Future<String> createInvoice(List<InvoiceOutputSpec> outputs) async {
    final created = system.coordinatorEvents!
        .where((e) => e is coord.InvoiceCreatedEvent)
        .cast<coord.InvoiceCreatedEvent>()
        .first
        .timeout(const Duration(seconds: 10));
    system.coordinator.tell(coord.CreateInvoiceCommand(walletId: _walletId, outputs: outputs));
    final event = await created;
    expect(event.success, isTrue, reason: event.error);
    return event.invoiceId;
  }

  /// A mined payment P with [outputs], in a block at height 1 of a regtest
  /// chain that is sent to the wallet; P's BEEF carries P and its BUMP.
  Future<(dartsv.Transaction, String)> minedPayment(List<(int, dartsv.SVScript)> outputs) async {
    final p = _rawTransaction(
      prevTxid: Uint8List.fromList(List<int>.generate(32, (i) => 0x40 + i)),
      outputs: [
        for (final (sats, script) in outputs) (sats, Uint8List.fromList(hex.decode(script.toHex()))),
        (12345, Uint8List.fromList(hex.decode(counterpartyLock.getScriptPubkey().toHex()))),
      ],
    );
    final internal = Uint8List.fromList(hex.decode(p.id).reversed.toList());
    final bump = BUMP.fromMerklePath(
      blockHeight: 1,
      txid: internal,
      index: 1,
      siblings: [Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 3) & 0xff))],
    );
    final block1 = RegtestMiner.mine(parent: genesis, merkleRoot: Hash.fromBytes(bump.computeMerkleRoot(internal)));
    final block2 = RegtestMiner.mine(parent: block1, seed: 'n0p-2');
    system.headerSyncActor.tell(BlockHeadersReceivedMessage(
      peerId: 'peer',
      headers: [block1, block2],
      startHeight: 1,
    ) as dynamic);
    await _until(() async => system.headerChain.bestHeight == 2, 'tip at 2');

    final beefHex = hex.encode(BEEF
        .create(
          bumps: [bump],
          txs: [Uint8List.fromList(hex.decode(p.serialize()))],
          hasMerkle: [true],
          bumpIndex: [0],
        )
        .serialize());
    return (p, beefHex);
  }

  /// The payment of [invoiceId]: received the way an app receives one.
  Future<coord.BEEFValidationResultEvent> receive(dartsv.Transaction p, String beefHex, String invoiceId) async {
    final answered = system.coordinatorEvents!
        .where((e) => e is coord.BEEFValidationResultEvent && e.txid == p.id)
        .cast<coord.BEEFValidationResultEvent>()
        .first
        .timeout(const Duration(seconds: 15));
    system.coordinator.tell(coord.ValidateBEEFCommand(
      walletId: _walletId,
      beefHex: beefHex,
      invoiceId: invoiceId,
      fromCounterparty: 'payer',
    ));
    final event = await answered;
    expect(event.valid, isTrue, reason: "payment failed: ${event.error}");
    return event;
  }

  Future<List<Event>> journal() => system.eventStore.getEvents('BitcoinWallet_$_walletId');

  dartsv.SVScript multisig(List<dartsv.SVPublicKey> keys, int threshold) =>
      dartsv.P2MSLockBuilder(keys, threshold, sorting: false).getScriptPubkey();

  P2MSOutputSpec spec(List<dartsv.SVPublicKey> keys, int threshold, int sats) =>
      P2MSOutputSpec(publicKeys: [for (final k in keys) k.toHex()], threshold: threshold, amount: BigInt.from(sats));

  /// The invoice paid by [p], the payment recorded whole with its bytes and
  /// proof.
  Future<void> expectPaidAndRecorded(String invoiceId, dartsv.Transaction p, int sats) async {
    final storage = system.walletStorage;
    await _until(() async => (await storage.getInvoice(invoiceId))?.status == InvoiceStatus.paid, 'invoice marked paid');
    final invoice = await storage.getInvoice(invoiceId);
    expect(invoice!.paymentTxid, p.id);
    expect(invoice.amountReceived, BigInt.from(sats));

    final row = await storage.getTransaction(p.id, walletId: _walletId);
    expect(row, isNotNull, reason: 'the payment is kept in the history');
    expect(row!.rawHex, p.serialize());
    expect(row.blockHeight, 1);
    expect(dartsv.Transaction.fromHex(row.rawHex).outputs, hasLength(p.outputs.length));
    final proof = await storage.getMerkleProof(p.id);
    expect(proof, isNotNull, reason: "the payment's proof is kept");
    expect(proof!.merkleProof, isNotEmpty);
  }

  for (final (label, threshold, keys) in [
    ('2-of-2', 2, () => [rootKey, otherKey]),
    ('2-of-3', 2, () => [otherKey, rootKey, otherKey2]),
  ]) {
    test(
        'n0p: an invoice paid with a $label multisig output holding one wallet key is '
        'paid and recorded, but the output is no wallet UTXO and no balance', () async {
      final scriptKeys = keys();
      final invoiceId = await createInvoice([spec(scriptKeys, threshold, 100000)]);
      final (p, beefHex) = await minedPayment([(100000, multisig(scriptKeys, threshold))]);

      final imported = await receive(p, beefHex, invoiceId);

      await expectPaidAndRecorded(invoiceId, p, 100000);

      // The import was awaited up to the projection, and the aggregate
      // handles the output before the import: nothing more is on the way.
      final storage = system.walletStorage;
      expect(await storage.getBalance(_walletId), BigInt.zero);
      expect((await storage.getUTXOs(_walletId, includeSpent: true)).where((u) => u.txid == p.id), isEmpty,
          reason: 'the wallet cannot spend the output without another signature');
      expect(await storage.getPaymentUTXOs(_walletId), isEmpty);
      expect((await journal()).whereType<we.UTXOReceivedEvent>().where((e) => e.txid == p.id), isEmpty);
      expect(imported.spendableUTXOs, isEmpty);
    });
  }

  test(
      'n0p guard: an invoice paid with a 2-of-2 multisig output whose keys are both the '
      "wallet's credits a wallet UTXO", () async {
    final secondKey = await generateWalletKey();
    final scriptKeys = [rootKey, secondKey];
    final invoiceId = await createInvoice([spec(scriptKeys, 2, 100000)]);
    final (p, beefHex) = await minedPayment([(100000, multisig(scriptKeys, 2))]);

    final imported = await receive(p, beefHex, invoiceId);

    await expectPaidAndRecorded(invoiceId, p, 100000);
    expect(imported.spendableUTXOs, hasLength(1));
    final storage = system.walletStorage;
    await _until(() async => (await storage.getUTXOs(_walletId)).any((u) => u.txid == p.id), 'UTXO projected');
    final utxo = (await storage.getUTXOs(_walletId)).singleWhere((u) => u.txid == p.id);
    expect(utxo.vout, 0);
    expect(utxo.value.getValue(), BigInt.from(100000));
    expect(utxo.scriptPubKey, multisig(scriptKeys, 2).toHex());
    expect(utxo.address, kTestRootAddress, reason: 'attributed to the first wallet key, as on every other path');
    expect(await storage.getBalance(_walletId), BigInt.from(100000));
  });

  test(
      'n0p: without an invoice a multisig output is a wallet UTXO only when the wallet '
      'holds at least m of its keys', () async {
    final secondKey = await generateWalletKey();
    final escrow = multisig([rootKey, otherKey], 2);
    final owned = multisig([otherKey, secondKey, rootKey], 2);
    final (p, beefHex) = await minedPayment([
      (30000, dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(kTestRootAddress)).getScriptPubkey()),
      (50000, escrow),
      (70000, owned),
    ]);

    final imported = system.coordinatorEvents!
        .where((e) => e is coord.TransactionImportedEvent && e.transactionId == p.id)
        .cast<coord.TransactionImportedEvent>()
        .first
        .timeout(const Duration(seconds: 15));
    system.coordinator.tell(coord.ImportTransactionCommand(walletId: _walletId, beef: hex.decode(beefHex)));
    final event = await imported;
    expect(event.success, isTrue, reason: 'import failed: ${event.error}');
    expect(event.utxosCreated, 2);

    final storage = system.walletStorage;
    await _until(
        () async => (await storage.getUTXOs(_walletId)).where((u) => u.txid == p.id).length == 2, 'UTXOs projected');
    final utxos = (await storage.getUTXOs(_walletId, includeSpent: true)).where((u) => u.txid == p.id).toList()
      ..sort((a, b) => a.vout.compareTo(b.vout));
    final secondAddress = secondKey.toAddress(dartsv.NetworkType.TEST).toBase58();
    expect(utxos.map((u) => (u.vout, u.address)), [(0, kTestRootAddress), (2, secondAddress)],
        reason: 'a multisig UTXO is attributed to the first wallet key in script order');
    expect(await storage.getBalance(_walletId), BigInt.from(100000));
    final row = await storage.getTransaction(p.id, walletId: _walletId);
    expect(row!.rawHex, p.serialize(), reason: 'the escrow output stays in the recorded transaction');
    expect((await journal()).whereType<we.UTXOReceivedEvent>().where((e) => e.txid == p.id).map((e) => e.vout),
        [0, 2]);
  });

  test(
      'n0p: an invoice with a P2PKH output and a 2-of-2 escrow output holding one wallet key: '
      'both count towards the invoice, only the P2PKH output is balance', () async {
    final scriptKeys = [rootKey, otherKey];
    final invoiceId = await createInvoice([
      P2PKHOutputSpec(address: kTestRootAddress, amount: BigInt.from(40000)),
      spec(scriptKeys, 2, 60000),
    ]);
    final (p, beefHex) = await minedPayment([
      (40000, dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(kTestRootAddress)).getScriptPubkey()),
      (60000, multisig(scriptKeys, 2)),
    ]);

    final imported = await receive(p, beefHex, invoiceId);

    await expectPaidAndRecorded(invoiceId, p, 100000);
    expect(imported.spendableUTXOs, hasLength(1));
    final storage = system.walletStorage;
    await _until(() async => (await storage.getUTXOs(_walletId)).any((u) => u.txid == p.id), 'UTXO projected');
    expect((await storage.getUTXOs(_walletId, includeSpent: true)).where((u) => u.txid == p.id).map((u) => u.vout),
        [0]);
    expect(await storage.getBalance(_walletId), BigInt.from(40000));
    final row = await storage.getTransaction(p.id, walletId: _walletId);
    expect(row!.receivingAddresses, [kTestRootAddress]);
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
