/// Bead spiffyvault-mnz.2: locking coins with a HODLocker output and
/// unlocking them, end to end through LibSpiffyActorSystem on regtest with
/// real-PoW headers.
///
/// A lock pays a HODLocker output to a fresh receive address of the wallet,
/// with change, and the coin is the wallet's locked balance. An unlock
/// spends a mined lock back to the wallet: nLockTime at the lock height, a
/// non-final input, and `<sig> <pubkey> <preimage>`, which dartsv's script
/// interpreter accepts against the locking script. Before the lock height
/// it is refused and nothing is built.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar_community/isar.dart';
import 'package:libspiffy/coordinator.dart' as coord;
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeadersReceivedMessage;
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';
import '../mocks/network_arc.dart';
import 'package:libspiffy/src/services/arc_service.dart' show ArcSubmitResponse;
import 'package:libspiffy/src/utils/extended_format.dart' show ExtendedFormat;

const _walletId = 'hodl-wallet';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;

  late Directory dir;
  late Isar isar;
  late LibSpiffyActorSystem system;
  late _RecordingArc arc;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hodl_lock_unlock_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'hodl_${DateTime.now().microsecondsSinceEpoch}',
    );
    arc = _RecordingArc();
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
      walletName: 'hodl',
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

  dartsv.SVScript lockTo(String address, int height) => dartsv.HODLockerLockingScriptBuilder(
        hex.decode(dartsv.Address.fromBase58(address).pubkeyHash160),
        BigInt.from(height),
      ).getScriptPubkey();

  /// Mines a transaction whose output 0 is [script] worth [sats] into block
  /// 1 of a two-block chain, imports it, and waits for the wallet's UTXO.
  Future<dartsv.Transaction> receiveMined(dartsv.SVScript script, int sats) async {
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
    final block2 = RegtestMiner.mine(parent: block1, seed: 'hodl-2');
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
    await _until(
        () async => (await system.walletStorage.getUTXOs(_walletId))
            .any((u) => u.txid == p.id && u.status == UTXOStatus.available),
        'UTXO projected');
    return p;
  }

  Future<T> send<T extends coord.CoordinatorEvent>(coord.CoordinatorRequest request) {
    final answer = system.coordinatorEvents!
        .where((e) => e is T && (e as coord.CoordinatorReply).requestId == request.requestId)
        .cast<T>()
        .first
        .timeout(const Duration(seconds: 30));
    system.coordinator.tell(request);
    return answer;
  }

  Future<coord.BalanceResponse> balance() =>
      send<coord.BalanceResponse>(coord.GetBalanceQuery(walletId: _walletId, requestId: 'b-${DateTime.now().microsecondsSinceEpoch}'));

  group('lock', () {
    test('locks an amount to a fresh wallet key, with change, as locked balance', () async {
      final funding = await receiveMined(
          dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(kTestRootAddress)).getScriptPubkey(), 100000);

      final locked = await send<coord.CoinsLockedEvent>(coord.LockCoinsCommand(
          walletId: _walletId, amount: BigInt.from(30000), lockHeight: 10, requestId: 'lock-1'));

      expect(locked.success, isTrue, reason: locked.error);
      expect(locked.ownerAddress, isNot(kTestRootAddress), reason: 'a fresh receive address');
      expect(await system.walletStorage.isWalletAddress(_walletId, locked.ownerAddress!), isTrue);
      final tx = dartsv.Transaction.fromHex(arc.submitted[locked.transactionId]!);
      expect(tx.inputs.single.prevTxnId, funding.id);
      final lockOutput = tx.outputs.singleWhere((o) => HodlockerLock.parse(o.script) != null);
      expect(HodlockerLock.parse(lockOutput.script)!.lockHeight, 10);
      expect(HodlockerLock.parse(lockOutput.script)!.ownerAddress(dartsv.NetworkType.REGTEST), locked.ownerAddress);
      expect(lockOutput.satoshis, BigInt.from(30000));
      expect(tx.outputs, hasLength(2), reason: 'the lock and the change');

      await _until(() async => (await balance()).lockedBalance == BigInt.from(30000), 'locked balance');
      final after = await balance();
      expect(after.lockedBalance + after.totalBalance + after.pendingBalance + after.reservedBalance,
          lessThan(BigInt.from(100000)),
          reason: 'the lock is counted once, and the fee is gone');
    });

    test('a height the chain has reached is refused, and nothing is built', () async {
      await receiveMined(
          dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(kTestRootAddress)).getScriptPubkey(), 100000);

      final locked = await send<coord.CoinsLockedEvent>(coord.LockCoinsCommand(
          walletId: _walletId, amount: BigInt.from(30000), lockHeight: 2, requestId: 'lock-2'));

      expect(locked.success, isFalse);
      expect(locked.error, contains('not ahead of the chain'));
      expect(arc.submitted, isEmpty);
    });
  });

  group('unlock', () {
    test('a lock the chain has reached is spent back to the wallet, valid under the script', () async {
      final script = lockTo(kTestRootAddress, 2);
      final parent = await receiveMined(script, 100000);
      expect((await balance()).lockedBalance, BigInt.from(100000));

      final unlocked = await send<coord.CoinsUnlockedEvent>(
          coord.UnlockCoinsCommand(walletId: _walletId, utxoKey: '${parent.id}:0', requestId: 'unlock-1'));

      expect(unlocked.success, isTrue, reason: unlocked.error);
      final tx = dartsv.Transaction.fromHex(arc.submitted[unlocked.transactionId]!);
      expect(tx.nLockTime, 2);
      final input = tx.inputs.single;
      expect('${input.prevTxnId}:${input.prevTxnOutputIndex}', '${parent.id}:0');
      expect(input.sequenceNumber, 0xfffffffe);
      expect(input.script!.chunks, hasLength(3), reason: '<sig> <pubkey> <preimage>');
      dartsv.Interpreter().correctlySpends(input.script!, script, tx, 0,
          {dartsv.VerifyFlag.SIGHASH_FORKID, dartsv.VerifyFlag.UTXO_AFTER_GENESIS}, dartsv.Coin.ofSat(BigInt.from(100000)));
      final back = tx.outputs.single;
      expect(back.satoshis, unlocked.amount);
      expect(back.satoshis, lessThan(BigInt.from(100000)));
      expect(back.satoshis, greaterThan(BigInt.from(99000)), reason: 'a small fee for about 1.4 KB');
      final to = dartsv.P2PKHLockBuilder.fromScript(back.script, networkType: dartsv.NetworkType.REGTEST).address!.toBase58();
      expect(await system.walletStorage.isWalletAddress(_walletId, to), isTrue);

      await _until(() async => (await balance()).lockedBalance == BigInt.zero, 'the lock is spent');
      final row = await system.walletStorage.getUTXO(_walletId, parent.id, 0);
      expect(row?.status, UTXOStatus.spent);
    });

    test('before the lock height it is refused, and nothing is built', () async {
      final parent = await receiveMined(lockTo(kTestRootAddress, 5), 100000);

      final unlocked = await send<coord.CoinsUnlockedEvent>(
          coord.UnlockCoinsCommand(walletId: _walletId, utxoKey: '${parent.id}:0', requestId: 'unlock-2'));

      expect(unlocked.success, isFalse);
      expect(unlocked.error, contains('locked until block 5'));
      expect(arc.submitted, isEmpty);
      final row = await system.walletStorage.getUTXO(_walletId, parent.id, 0);
      expect(row?.status, UTXOStatus.available);
    });

    test('a coin that is not a lock is refused', () async {
      final parent = await receiveMined(
          dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(kTestRootAddress)).getScriptPubkey(), 100000);

      final unlocked = await send<coord.CoinsUnlockedEvent>(
          coord.UnlockCoinsCommand(walletId: _walletId, utxoKey: '${parent.id}:0', requestId: 'unlock-3'));

      expect(unlocked.success, isFalse);
      expect(unlocked.error, contains('not a locked coin'));
    });
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

/// [NetworkArc], keeping the raw transaction of each submission by txid.
class _RecordingArc extends NetworkArc {
  final Map<String, String> submitted = {};

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) {
    final raw = ExtendedFormat.rawHexOf(rawTx);
    submitted[dartsv.Transaction.fromHex(raw).id] = raw;
    return super.submitTransaction(rawTx, callbackUrl: callbackUrl);
  }
}
