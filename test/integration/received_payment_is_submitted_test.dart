/// Beads libspiffy-xggs and libspiffy-ckr4: receiving a counterparty's
/// payment, end to end.
///
/// In the peer-to-peer model the receiver broadcasts the payment it cares
/// about: the counterparty hands us the payment with its ancestors' proofs,
/// we check those against our headers — which is not double-spend
/// protection — and we submit the payment ourselves, then follow it to its
/// block. Before this:
///
/// * Only the invoice path (`ValidateBEEFCommand`) submitted, as a
///   fire-and-forget tell, and answered `broadcasted: true` at once — before
///   ARC said anything, and whatever it said.
/// * A payment whose ancestor's proof waited for a block header was never
///   submitted: the first reply ("waiting") used up the correlation, and the
///   verdict that followed was treated as an import.
/// * `ReceiveTransactionCommand` and `ImportTransactionCommand` recorded a
///   counterparty's unproven payment and submitted it nowhere, and the status
///   scan then asked ARC about a transaction nobody had given it.
///
/// Now a payment is `ValidateBEEFCommand`, submitted on its verdict whenever
/// that comes, and answered with what ARC said; an import must carry its own
/// proof and is submitted nowhere; `ReceiveTransactionCommand` is gone.
///
/// Through LibSpiffyActorSystem on regtest with real-PoW headers.
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
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;

  final bobKey = dartsv.SVPrivateKey.fromHex('5f' * 32, dartsv.NetworkType.TEST);
  final bobLock = dartsv.P2PKHLockBuilder.fromAddress(bobKey.publicKey.toAddress(dartsv.NetworkType.TEST));
  final ourLock = dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(kTestRootAddress));

  /// G: Bob's mined coin, proven in block 3.
  final g = _rawTransaction(
    prevTxid: Uint8List.fromList(List<int>.generate(32, (i) => 0x60 + i)),
    outputs: [(400000, Uint8List.fromList(hex.decode(bobLock.getScriptPubkey().toHex())))],
  );

  Uint8List internalTxid(String displayTxid) => Uint8List.fromList(hex.decode(displayTxid).reversed.toList());

  BUMP bumpFor(String displayTxid, int blockHeight, int seed) => BUMP.fromMerklePath(
        blockHeight: blockHeight,
        txid: internalTxid(displayTxid),
        index: 0,
        siblings: [Uint8List.fromList(List<int>.generate(32, (i) => (i * seed + seed) & 0xff))],
      );

  Hash rootOf(BUMP bump, String displayTxid) => Hash.fromBytes(bump.computeMerkleRoot(internalTxid(displayTxid)));

  final gBump = bumpFor(g.id, 3, 29);
  final a1 = RegtestMiner.mine(parent: genesis, seed: 'xggs-A1');
  final a2 = RegtestMiner.mine(parent: a1, seed: 'xggs-A2');
  final a3 = RegtestMiner.mine(parent: a2, merkleRoot: rootOf(gBump, g.id));

  /// P: Bob spends G and pays us 90,000 satoshis.
  final p = (dartsv.TransactionBuilder()
        ..spendFromOutpointWithSigner(
          dartsv.DefaultTransactionSigner(
              dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, bobKey),
          dartsv.TransactionOutpoint(g.id, 0, g.outputs[0].satoshis, g.outputs[0].script),
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
          dartsv.P2PKHUnlockBuilder(bobKey.publicKey),
        )
        ..spendToLockBuilder(ourLock, BigInt.from(90000))
        ..spendToLockBuilder(bobLock, BigInt.from(300000))
        ..withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS))
      .build(false);

  /// Q: Bob spends G differently, also paying us 90,000 satoshis: a second
  /// payment, where P is the first.
  final q = (dartsv.TransactionBuilder()
        ..spendFromOutpointWithSigner(
          dartsv.DefaultTransactionSigner(
              dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, bobKey),
          dartsv.TransactionOutpoint(g.id, 0, g.outputs[0].satoshis, g.outputs[0].script),
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
          dartsv.P2PKHUnlockBuilder(bobKey.publicKey),
        )
        ..spendToLockBuilder(ourLock, BigInt.from(90000))
        ..spendToLockBuilder(bobLock, BigInt.from(299000))
        ..withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS))
      .build(false);

  /// P mined in block 4, for the cases where it arrives with its own proof.
  final pBump = bumpFor(p.id, 4, 31);
  final a4 = RegtestMiner.mine(parent: a3, merkleRoot: rootOf(pBump, p.id));

  String beefHex(List<(dartsv.Transaction, BUMP?)> members) {
    final bumps = <BUMP>[];
    final bumpIndex = <int>[];
    for (final (_, bump) in members) {
      if (bump == null) continue;
      bumpIndex.add(bumps.length);
      bumps.add(bump);
    }
    return hex.encode(BEEF
        .create(
          bumps: bumps,
          txs: [for (final (tx, _) in members) Uint8List.fromList(hex.decode(tx.serialize()))],
          hasMerkle: [for (final (_, bump) in members) bump != null],
          bumpIndex: bumpIndex,
        )
        .serialize());
  }

  /// The payment as Bob hands it over: P unproven, G proven.
  String payment() => beefHex([(g, gBump), (p, null)]);

  late Directory dir;
  late Isar isar;
  late _RecordingArc arc;
  late LibSpiffyActorSystem system;
  late InMemoryWalletStorage readModel;
  const walletId = 'xggs-wallet';

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('xggs_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'xggs_${DateTime.now().microsecondsSinceEpoch}',
    );
    arc = _RecordingArc();
    readModel = InMemoryWalletStorage();
    system = LibSpiffyActorSystem();
    await system.initialize(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      readModelStorage: readModel,
      secureStorage: InMemorySecureStorage(),
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      arcService: arc,
    );
  });

  tearDown(() async {
    arc.release();
    try {
      await system.shutdown();
    } catch (_) {}
    try {
      await isar.close(deleteFromDisk: true);
    } catch (_) {}
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> sendHeaders(List<BlockHeader> headers, int startHeight, int tip) async {
    system.headerSyncActor.tell(BlockHeadersReceivedMessage(
      peerId: 'peer',
      headers: headers,
      startHeight: startHeight,
    ) as dynamic);
    await _until(() async => system.headerChain.bestHeight == tip, 'header chain at $tip');
  }

  Future<void> createTheWallet() async {
    await createWallet(
      walletManager: system.walletManager,
      actorSystem: system.actorSystem,
      walletId: walletId,
      walletName: 'A',
      xpriv: kTestXpriv,
    );
    await _until(() async => await readModel.isWalletAddress(walletId, kTestRootAddress), 'root address projected');
  }

  /// The coordinator's answers about P, as they arrive.
  List<coord.BEEFValidationResultEvent> answersAboutP() {
    final answers = <coord.BEEFValidationResultEvent>[];
    final sub = system.coordinatorEvents!.listen((e) {
      if (e is coord.BEEFValidationResultEvent && e.txid == p.id) answers.add(e);
    });
    addTearDown(sub.cancel);
    return answers;
  }

  Future<coord.BEEFValidationResultEvent> verdict(List<coord.BEEFValidationResultEvent> answers) async {
    await _until(() async => answers.any((a) => !a.awaitingHeader), 'a verdict on P', timeout: const Duration(seconds: 20));
    return answers.firstWhere((a) => !a.awaitingHeader);
  }

  /// An invoice for P's 90,000 satoshis to our root address.
  Future<String> invoice() async {
    final created = system.coordinatorEvents!
        .where((e) => e is coord.InvoiceCreatedEvent)
        .cast<coord.InvoiceCreatedEvent>()
        .first
        .timeout(const Duration(seconds: 10));
    system.coordinator.tell(coord.CreateInvoiceCommand(
      walletId: walletId,
      outputs: [P2PKHOutputSpec(address: kTestRootAddress, amount: BigInt.from(90000))],
    ));
    final event = await created;
    expect(event.success, isTrue, reason: event.error);
    return event.invoiceId;
  }

  void pay({String? invoiceId, String? beef}) => system.coordinator.tell(coord.ValidateBEEFCommand(
        walletId: walletId,
        beefHex: beef ?? payment(),
        invoiceId: invoiceId,
        fromCounterparty: 'bob',
      ));

  group('xggs: a payment is submitted to ARC, and the answer is what ARC said', () {
    setUp(() async {
      await sendHeaders([a1, a2, a3], 1, 3);
      await createTheWallet();
    });

    test('a payment ARC accepts is submitted and reported with its status', () async {
      arc.answer = 'SEEN_ON_NETWORK';
      final answers = answersAboutP();

      final invoiceId = await invoice();
      pay(invoiceId: invoiceId);
      final answer = await verdict(answers);

      expect(answer.valid, isTrue, reason: answer.error);
      expect(answer.invoiceId, invoiceId);
      expect(arc.submitted, [p.serialize()], reason: 'the receiver submits the payment it cares about');
      expect(answer.broadcasted, isTrue);
      expect(answer.networkStatus, 'SEEN_ON_NETWORK');
      expect(answer.broadcastError, isNull);
    });

    // Seen on the localnet regtest ARC: the answer said SEEN_ON_NETWORK and
    // a balance read on it showed nothing received, because the output was
    // made spendable a moment after the answer went out.
    test('a payment answered as on the network is spendable in the read model when the answer arrives', () async {
      arc.answer = 'SEEN_ON_NETWORK';
      UTXOStatus? statusOnAnswer;
      final answered = system.coordinatorEvents!
          .where((e) => e is coord.BEEFValidationResultEvent && e.txid == p.id && !e.awaitingHeader)
          .asyncMap((_) async => statusOnAnswer = (await readModel.getUTXO(walletId, p.id, 0))?.status)
          .first
          .timeout(const Duration(seconds: 20));

      pay(invoiceId: await invoice());
      await answered;

      expect(statusOnAnswer, UTXOStatus.available);
      expect(await readModel.getBalance(walletId), BigInt.from(90000));
    });

    // Bead libspiffy-6142, seen on the localnet regtest ARC: a payer that
    // heard no answer hands the same payment over again. It is the payment
    // that paid the invoice, not a second one: it used to be refused as
    // "Invoice ... is not pending (status: paid)", telling the payer the
    // payment it made had failed.
    test('6142: a payment handed over twice for its invoice is answered valid both times, and received and paid once', () async {
      arc.answer = 'SEEN_ON_NETWORK';
      final answers = answersAboutP();
      final refusals = <String>[];
      final logs = Logger.root.onRecord
          .where((r) => r.message.contains('was not marked paid'))
          .listen((r) => refusals.add(r.message));
      addTearDown(logs.cancel);
      final paid = <coord.InvoicePaidEvent>[];
      final announcements = system.coordinatorEvents!
          .where((e) => e is coord.InvoicePaidEvent)
          .cast<coord.InvoicePaidEvent>()
          .listen(paid.add);
      addTearDown(announcements.cancel);

      final invoiceId = await invoice();
      pay(invoiceId: invoiceId);
      await verdict(answers);
      pay(invoiceId: invoiceId);
      await _until(() async => answers.where((a) => !a.awaitingHeader).length == 2, 'a verdict on each delivery',
          timeout: const Duration(seconds: 20));

      for (final answer in answers) {
        expect(answer.valid, isTrue, reason: answer.error);
        expect(answer.invoiceId, invoiceId);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await readModel.getBalance(walletId), BigInt.from(90000));
      final journal = await system.eventStore.getEvents('Invoice_$invoiceId');
      expect(journal.where((e) => e.typeName == 'invoice.paid'), hasLength(1),
          reason: 'the invoice is paid once, by P');
      expect(refusals, isEmpty, reason: 'the invoice was marked paid again, and refused');
      // Bead libspiffy-mu09: announced, once, as the read model holds it.
      expect(paid.map((e) => (e.invoiceId, e.txid, e.amountReceived)), [(invoiceId, p.id, BigInt.from(90000))]);
    });

    test('6142: another payment for an invoice P already paid is refused', () async {
      arc.answer = 'SEEN_ON_NETWORK';
      final answers = answersAboutP();
      final invoiceId = await invoice();
      pay(invoiceId: invoiceId);
      expect((await verdict(answers)).valid, isTrue);

      final other = system.coordinatorEvents!
          .where((e) => e is coord.BEEFValidationResultEvent && e.txid == q.id)
          .cast<coord.BEEFValidationResultEvent>()
          .first
          .timeout(const Duration(seconds: 20));
      pay(invoiceId: invoiceId, beef: beefHex([(g, gBump), (q, null)]));
      final answer = await other;

      expect(answer.valid, isFalse);
      expect(answer.error, contains('is not pending'));
    });


    // Bead libspiffy-yyby. The invoice is paid when the network holds the
    // payment, not when a valid BEEF arrives: ARC answers a submission
    // DOUBLE_SPEND_ATTEMPTED when another transaction spends an input
    // (the payer reclaimed first), and SEEN_IN_ORPHAN_MEMPOOL when an
    // input is unknown or already spent in a block. Both seen on the
    // localnet regtest ARC. A paid invoice refuses every other transaction
    // (bead libspiffy-6142), so an invoice paid by a payment the network
    // refuses turns the payer's genuine replacement away.
    for (final refused in ['DOUBLE_SPEND_ATTEMPTED', 'SEEN_IN_ORPHAN_MEMPOOL']) {
      test('yyby: a payment ARC answers $refused does not pay the invoice, and the payer\'s '
          'replacement still can', () async {
        arc.answer = refused;
        final answers = answersAboutP();
        final paid = <coord.InvoicePaidEvent>[];
        final announcements = system.coordinatorEvents!
            .where((e) => e is coord.InvoicePaidEvent)
            .cast<coord.InvoicePaidEvent>()
            .listen(paid.add);
        addTearDown(announcements.cancel);

        final invoiceId = await invoice();
        pay(invoiceId: invoiceId);
        final answer = await verdict(answers);

        expect(answer.valid, isTrue, reason: 'the payment is valid; the network did not take it');
        expect(answer.networkStatus, refused);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        // Old code: paid at validation, before ARC said anything.
        expect((await readModel.getInvoice(invoiceId))?.status, InvoiceStatus.pending);
        final journal = await system.eventStore.getEvents('Invoice_$invoiceId');
        expect(journal.where((e) => e.typeName == 'invoice.paid'), isEmpty,
            reason: 'the invoice was paid by a payment the network refused');
        expect(paid, isEmpty);

        // The payment the network does take pays it.
        arc.answer = 'SEEN_ON_NETWORK';
        final replacement = system.coordinatorEvents!
            .where((e) => e is coord.BEEFValidationResultEvent && e.txid == q.id)
            .cast<coord.BEEFValidationResultEvent>()
            .first
            .timeout(const Duration(seconds: 20));
        pay(invoiceId: invoiceId, beef: beefHex([(g, gBump), (q, null)]));
        final second = await replacement;

        expect(second.valid, isTrue, reason: second.error);
        expect(second.networkStatus, 'SEEN_ON_NETWORK');
        await _until(() async => (await readModel.getInvoice(invoiceId))?.status == InvoiceStatus.paid,
            'the invoice paid by the replacement');
        expect(paid.map((e) => (e.invoiceId, e.txid)), [(invoiceId, q.id)]);
      });
    }

    test('yyby: an answer ARC gave while it was still taking the payment to the network pays '
        'nothing yet', () async {
      arc.answer = 'ACCEPTED_BY_NETWORK'; // ARC's wait for the network ran out
      final answers = answersAboutP();

      final invoiceId = await invoice();
      pay(invoiceId: invoiceId);
      final answer = await verdict(answers);

      expect(answer.valid, isTrue, reason: answer.error);
      expect(answer.networkStatus, 'ACCEPTED_BY_NETWORK', reason: 'what ARC said, not a verdict');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect((await readModel.getInvoice(invoiceId))?.status, InvoiceStatus.pending,
          reason: 'ARC has not said the network holds it; its status scan follows it '
              'and the invoice settles then (invoice_paid_when_the_network_holds_the_payment_test)');
    });

    test('yyby: a payment that arrives already mined, with its own verified proof, pays its invoice',
        () async {
      await sendHeaders([a4], 4, 4);
      final answers = answersAboutP();

      final invoiceId = await invoice();
      pay(invoiceId: invoiceId, beef: beefHex([(g, gBump), (p, pBump)]));
      final answer = await verdict(answers);

      expect(answer.valid, isTrue, reason: answer.error);
      expect(answer.networkStatus, 'MINED');
      expect(arc.submitted, isEmpty, reason: 'a mined payment needs no broadcast');
      expect((await readModel.getInvoice(invoiceId))?.status, InvoiceStatus.paid);
    });

    test('a payment ARC rejects is reported as not broadcast, with ARC\'s status and reason', () async {
      arc.answer = 'REJECTED';
      final answers = answersAboutP();

      pay();
      final answer = await verdict(answers);

      // Old code: broadcasted: true, emitted before ARC answered.
      expect(answer.valid, isTrue, reason: 'the payment is valid; the network refused it');
      expect(answer.broadcasted, isFalse);
      expect(answer.networkStatus, 'REJECTED');
      expect(answer.broadcastError, contains('rejected'));
    });

    test('the answer waits for ARC, and for the read model to hold the payment', () async {
      arc.answer = 'SEEN_ON_NETWORK';
      arc.hold();
      final answers = answersAboutP();

      pay();
      await _until(() async => arc.submitted.isNotEmpty, 'the payment submitted');

      // Submitted from the read model's row: the wallet holds it already.
      expect(await readModel.getTransaction(p.id, walletId: walletId), isNotNull,
          reason: 'submitted before the read model held the payment, so ARC\'s status had no row to land on');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(answers, isEmpty, reason: 'announced as broadcast before ARC answered');

      arc.release();
      final answer = await verdict(answers);
      expect(answer.broadcasted, isTrue);
    });

    test('a payment carrying its own proof is already mined: nothing is submitted', () async {
      await sendHeaders([a4], 4, 4);
      final answers = answersAboutP();

      pay(beef: beefHex([(g, gBump), (p, pBump)]));
      final answer = await verdict(answers);

      expect(answer.valid, isTrue, reason: answer.error);
      expect(answer.broadcasted, isFalse);
      expect(answer.broadcastError, isNull, reason: 'nothing failed: nothing needed submitting');
      expect(arc.submitted, isEmpty);
    });
  });

  test('xggs: a payment waiting for a header is submitted when the header arrives, without the '
      'counterparty re-sending', () async {
    await sendHeaders([a1, a2], 1, 2);
    await createTheWallet();
    arc.answer = 'SEEN_ON_NETWORK';
    final answers = answersAboutP();

    final invoiceId = await invoice();
    pay(invoiceId: invoiceId);
    await _until(() async => answers.isNotEmpty, 'the first answer');
    expect(answers.single.awaitingHeader, isTrue, reason: 'G is proven in block 3, which we do not hold');
    expect(answers.single.valid, isFalse);
    expect(arc.submitted, isEmpty, reason: 'nothing is submitted before the payment validates');

    await sendHeaders([a3], 3, 3);
    final answer = await verdict(answers);

    // Old code: the "waiting" reply used up the correlation, the verdict
    // was announced as an import, and P never reached ARC.
    expect(answer.valid, isTrue, reason: answer.error);
    expect(answer.invoiceId, invoiceId, reason: 'the stored receive keeps the invoice it paid');
    expect(arc.submitted, [p.serialize()]);
    expect(answer.broadcasted, isTrue);
    expect(answer.networkStatus, 'SEEN_ON_NETWORK');
  });

  group('ckr4: an import carries its own proof', () {
    setUp(() async {
      await sendHeaders([a1, a2, a3, a4], 1, 4);
      await createTheWallet();
    });

    Future<coord.TransactionImportedEvent> import(String beef) {
      final imported = system.coordinatorEvents!
          .where((e) => e is coord.TransactionImportedEvent && e.transactionId == p.id)
          .cast<coord.TransactionImportedEvent>()
          .first
          .timeout(const Duration(seconds: 15));
      system.coordinator.tell(coord.ImportTransactionCommand(walletId: walletId, beef: hex.decode(beef)));
      return imported;
    }

    test('an import without its subject\'s proof is refused, recorded nowhere and submitted nowhere', () async {
      final refused = await import(payment());

      // Old code: recorded, and then polled on ARC though nobody gave it P.
      expect(refused.success, isFalse);
      expect(refused.error, allOf(contains('merkle proof'), contains('ValidateBEEFCommand')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await readModel.getTransaction(p.id, walletId: walletId), isNull);
      expect(arc.submitted, isEmpty);
    });

    test('an import with its proof is recorded, confirmed, and submitted nowhere', () async {
      final imported = await import(beefHex([(g, gBump), (p, pBump)]));

      expect(imported.success, isTrue, reason: imported.error);
      expect(imported.transactionId, p.id, reason: 'the txid is the BEEF\'s');
      final row = await readModel.getTransaction(p.id, walletId: walletId);
      expect((row?.status, row?.blockHeight), (TransactionStatus.confirmed, 4));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(arc.submitted, isEmpty, reason: 'a mined transaction needs no broadcast');
    });
  });
}

/// A raw transaction with one input spending [prevTxid]:0 (display order
/// bytes reversed into the wire order) with an OP_TRUE scriptSig.
dartsv.Transaction _rawTransaction({required Uint8List prevTxid, required List<(int, Uint8List)> outputs}) {
  final b = BytesBuilder();
  void u32(int v) => b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  u32(1);
  b.addByte(1);
  b.add(prevTxid);
  u32(0);
  b.add([1, 0x51]);
  u32(0xffffffff);
  b.addByte(outputs.length);
  for (final (sats, script) in outputs) {
    final v = ByteData(8)..setUint64(0, sats, Endian.little);
    b.add(v.buffer.asUint8List());
    b.addByte(script.length);
    b.add(script);
  }
  u32(0);
  return dartsv.Transaction.fromHex(hex.encode(b.toBytes()));
}

Future<void> _until(Future<bool> Function() condition, String what,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// ARC that records what it is given and answers every submission with
/// [answer], once [hold] is released. Status queries: unknown.
class _RecordingArc extends ArcService {
  _RecordingArc() : super(baseUrl: 'fake://arc');

  final List<String> submitted = [];
  String answer = 'SEEN_ON_NETWORK';

  /// What a status query answers, as ARC does after answering a submission
  /// with where it had got to; null: ARC does not know the transaction.
  String? statusAnswer;
  Completer<void>? _gate;

  void hold() => _gate = Completer<void>();

  void release() {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async {
    submitted.add(rawTx);
    await _gate?.future;
    return ArcSubmitResponse.fromJson({
      'timestamp': '2026-09-21T08:00:00Z',
      'txid': dartsv.Transaction.fromHex(rawTx).id,
      'txStatus': answer,
      if (answer == 'REJECTED') 'extraInfo': 'rejected by the test',
    });
  }

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    final status = statusAnswer;
    if (status == null) {
      throw ArcException('Failed to get transaction: {"status":404}', statusCode: 404);
    }
    return ArcTransactionResponse.fromJson({
      'timestamp': '2026-09-21T08:00:00Z',
      'txid': txid,
      'txStatus': status,
    });
  }
}
