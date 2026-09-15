/// Bead libspiffy-hccp item 3, end to end through LibSpiffyActorSystem on
/// regtest with real-PoW headers: a counterparty re-delivers a transaction
/// the wallet already holds, this time without its merkle proof.
///
/// For an unproven subject WalletManagerActor sends ReceiveUTXOCommand with
/// status pending (and RecordImportedTransactionCommand, whose transaction
/// row bead libspiffy-7dj keeps confirmed). The question was whether that
/// pending receive lowers a UTXO that is already available, reserved or
/// spent, in the wallet aggregate or in the read model. It does not: the
/// aggregate rejects a second receipt of a known outpoint (no event is
/// journaled), and the projection leaves an existing row alone. These tests
/// pin that down for each status; the reorganization path, the one that
/// takes a UTXO back to pending, is test/integration/reorg_confirmation_revert_test.dart.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeadersReceivedMessage;
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;

  final counterpartyKey = dartsv.SVPrivateKey.fromHex('5c' * 32, dartsv.NetworkType.TEST);
  final counterpartyLock =
      dartsv.P2PKHLockBuilder.fromAddress(counterpartyKey.publicKey.toAddress(dartsv.NetworkType.TEST));

  /// G: a mined transaction paying the counterparty (proven by its BUMP).
  final g = _rawTransaction(
    prevTxid: Uint8List.fromList(List<int>.generate(32, (i) => 0x40 + i)),
    outputs: [(300000, Uint8List.fromList(hex.decode(counterpartyLock.getScriptPubkey().toHex())))],
  );

  /// P: the counterparty pays the wallet's root address (output 0) from G:0.
  final p = (dartsv.TransactionBuilder()
        ..spendFromOutpointWithSigner(
          dartsv.DefaultTransactionSigner(
              dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, counterpartyKey),
          dartsv.TransactionOutpoint(g.id, 0, g.outputs[0].satoshis, g.outputs[0].script),
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
          dartsv.P2PKHUnlockBuilder(counterpartyKey.publicKey),
        )
        ..spendToLockBuilder(dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(kTestRootAddress)), BigInt.from(200000))
        ..spendToLockBuilder(counterpartyLock, BigInt.from(99000))
        ..withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS))
      .build(false);

  final gInternal = Uint8List.fromList(hex.decode(g.id).reversed.toList());
  final gBump = BUMP.fromMerklePath(
    blockHeight: 2,
    txid: gInternal,
    index: 1,
    siblings: [Uint8List.fromList(List<int>.generate(32, (i) => (i * 11 + 3) & 0xff))],
  );
  final pInternal = Uint8List.fromList(hex.decode(p.id).reversed.toList());
  final pBump = BUMP.fromMerklePath(
    blockHeight: 4,
    txid: pInternal,
    index: 0,
    siblings: [Uint8List.fromList(List<int>.generate(32, (i) => (i * 5 + 9) & 0xff))],
  );
  final a1 = RegtestMiner.mine(parent: genesis, seed: 'hccp3-A1');
  final a2 = RegtestMiner.mine(parent: a1, merkleRoot: Hash.fromBytes(gBump.computeMerkleRoot(gInternal)));
  final a3 = RegtestMiner.mine(parent: a2, seed: 'hccp3-A3');
  final a4 = RegtestMiner.mine(parent: a3, merkleRoot: Hash.fromBytes(pBump.computeMerkleRoot(pInternal)));

  /// P with its proof (mined at height 4).
  BEEF provenBeef() => BEEF.create(
        bumps: [pBump],
        txs: [Uint8List.fromList(hex.decode(p.serialize()))],
        hasMerkle: [true],
        bumpIndex: [0],
      );

  /// The same P without its proof: G with its BUMP, then P.
  BEEF unprovenBeef() => BEEF.create(
        bumps: [gBump],
        txs: [Uint8List.fromList(hex.decode(g.serialize())), Uint8List.fromList(hex.decode(p.serialize()))],
        hasMerkle: [true, false],
        bumpIndex: [0],
      );

  late Directory dir;
  late LibSpiffyActorSystem libspiffy;
  late LocalActorSystem actorSystem;
  late String walletId;
  var receivers = 0;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('redelivered_unproven_');
    actorSystem = LocalActorSystem(ActorSystemConfig());
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'redelivered_${DateTime.now().microsecondsSinceEpoch}',
    );
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
    );
    walletId = 'redelivered-${DateTime.now().microsecondsSinceEpoch}';
    await createWallet(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
      walletName: 'Redelivered',
      xpriv: kTestXpriv,
    );
    await _until(() async => await libspiffy.walletStorage.isWalletAddress(walletId, kTestRootAddress),
        'root address projected');
    libspiffy.headerSyncActor.tell(
        BlockHeadersReceivedMessage(peerId: 'peer', headers: [a1, a2, a3, a4], startHeight: 1) as dynamic);
    await _until(() async => libspiffy.headerChain.bestHeight == 4, 'tip at 4');
  });

  tearDown(() async {
    await libspiffy.shutdown();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  ReadModelStorage storage() => libspiffy.walletStorage;
  Future<List<Object>> journal() async => await libspiffy.eventStore.getEvents('BitcoinWallet_$walletId');
  final utxoKey = '${p.id}:0';

  Future<BitcoinUtxo?> utxo() async {
    for (final u in await storage().getUTXOs(walletId, includeSpent: true)) {
      if (u.txid == p.id && u.vout == 0) return u;
    }
    return null;
  }

  Future<void> deliver(BEEF beef) async {
    final done = Completer<SPVValidationResult>();
    final receiver =
        await actorSystem.spawn('spv-receiver-${receivers++}', () => TestReceiverActor<SPVValidationResult>(done));
    libspiffy.spvActor.tell(
      ReceiveTransactionMessage(
        transactionId: p.id,
        beef: beef,
        fromCounterparty: 'counterparty',
        targetWalletId: walletId,
      ),
      sender: receiver,
    );
    final result = await done.future.timeout(const Duration(seconds: 10));
    expect(result.isValid, isTrue, reason: result.validationError);
  }

  /// Re-delivers P without its proof and waits until the wallet has handled
  /// the whole result: its record of P (queued after the receive of P's
  /// output) is journaled and applied to the read model.
  Future<void> redeliverUnproven() async {
    final importsBefore = (await journal()).whereType<TransactionImportedEvent>().length;
    await deliver(unprovenBeef());
    await _until(() async => (await journal()).whereType<TransactionImportedEvent>().length > importsBefore,
        'the unproven record journaled');
    final event = (await journal()).whereType<TransactionImportedEvent>().last;
    expect(event.bumpProof, isEmpty, reason: 'the second delivery carried no proof');
    await _until(() async {
      final t = await storage().getTransaction(p.id, walletId: walletId);
      return t != null && !t.updatedAt.isBefore(event.timestamp.subtract(const Duration(milliseconds: 1)));
    }, 'the unproven record applied to the read model');
  }

  Future<void> expectOneReceipt() async {
    final receipts = [
      for (final e in (await journal()).whereType<UTXOReceivedEvent>())
        if (e.txid == p.id && e.vout == 0) e.initialStatus
    ];
    expect(receipts, [UTXOStatus.available], reason: 'no second (pending) receipt is journaled');
  }

  test('an available UTXO stays available, with its block height, after the unproven re-delivery', () async {
    await deliver(provenBeef());
    await _until(() async => (await utxo())?.status == UTXOStatus.available, 'available with its proof');
    final before = (await utxo())!;
    expect(before.blockHeight, 4);
    expect(await storage().getBalance(walletId), BigInt.from(200000));

    await redeliverUnproven();

    final after = (await utxo())!;
    expect(after.status, UTXOStatus.available);
    expect(after.blockHeight, 4);
    expect(after.confirmations, before.confirmations);
    expect(await storage().getBalance(walletId), BigInt.from(200000));
    final row = (await storage().getWallet(walletId))!['metadata'] as Map<String, dynamic>;
    expect(row['totalBalance'], '200000');
    await expectOneReceipt();
    expect((await storage().getTransaction(p.id, walletId: walletId))!.status, TransactionStatus.confirmed);
  });

  test('a reserved UTXO stays reserved and a spent UTXO stays spent, with its spend, after the unproven re-delivery',
      () async {
    await deliver(provenBeef());
    await _until(() async => (await utxo())?.status == UTXOStatus.available, 'available with its proof');

    // Reserved by the transaction that later spends it.
    final spendingTxid = 'ab' * 32;
    libspiffy.walletManager.tell(WalletCommandMessage(walletId, ReserveUTXOCommand(
      walletId: walletId,
      utxoKey: utxoKey,
      reservedByTxId: spendingTxid,
      reservationReason: 'payment',
    )));
    await _until(() async => (await utxo())?.status == UTXOStatus.reserved, 'reserved');

    await redeliverUnproven();
    var after = (await utxo())!;
    expect((after.status, after.reservedByTxId, after.statusBeforeReservation),
        (UTXOStatus.reserved, spendingTxid, UTXOStatus.available));
    expect(after.blockHeight, 4);

    libspiffy.walletManager.tell(WalletCommandMessage(walletId, SpendUTXOCommand(
      walletId: walletId,
      utxoKey: utxoKey,
      spendingTxId: spendingTxid,
      fee: BigInt.from(100),
    )));
    await _until(() async => (await utxo())?.status == UTXOStatus.spent, 'spent');

    await redeliverUnproven();
    after = (await utxo())!;
    expect((after.status, after.spentInTxId), (UTXOStatus.spent, spendingTxid),
        reason: 'the spend is history and is kept');
    expect(after.blockHeight, 4);
    expect(await storage().getBalance(walletId), BigInt.zero);
    await expectOneReceipt();
  });

  test('a UTXO that became available without a block (seen on the network) is not taken back to pending', () async {
    await deliver(unprovenBeef());
    await _until(() async => (await utxo())?.status == UTXOStatus.pending, 'pending without a proof');
    libspiffy.walletManager.tell(WalletCommandMessage(walletId, MarkUTXOAvailableCommand(
      walletId: walletId,
      txid: p.id,
      vout: 0,
    )));
    await _until(() async => (await utxo())?.status == UTXOStatus.available, 'made available');

    await redeliverUnproven();

    expect((await utxo())!.status, UTXOStatus.available);
    final receipts = [
      for (final e in (await journal()).whereType<UTXOReceivedEvent>())
        if (e.txid == p.id && e.vout == 0) e.initialStatus
    ];
    expect(receipts, [UTXOStatus.pending], reason: 'only the first receipt is journaled');
  });
}

/// A raw transaction with one input spending [prevTxid]:0 (wire order) with
/// an OP_TRUE scriptSig.
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
    {Duration timeout = const Duration(seconds: 8)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
