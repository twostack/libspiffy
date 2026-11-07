/// SPVActor with a gap in its header chain below the tip (epic
/// spiffyvault-emk, step emk.2).
///
/// A chain that starts at a built-in checkpoint holds no headers below it
/// until they are filled in. A receive whose proof needs one of those headers
/// is parked as before, but "the tip has reached its height" no longer means
/// "we hold its header". Replaying it on every block would only park it
/// again (after asking the network for the header each time). It is replayed
/// when the header is actually held, which a backfill notification reports.
library;

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/spv_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/bump.dart' show BUMP;

import '../spv/testnet_proof_fixture.dart';

void main() {
  late TestActorSystem system;
  late _RecordingWalletManager walletManager;
  late _SilentActor probe;
  late ActorRef probeRef;
  late ActorRef spvActor;
  late InMemoryWalletStorage storage;

  /// The tip: a header far above the fixture's block, with nothing below it.
  const tip = kFixture2Height;

  setUp(() async {
    system = TestActorSystem();
    walletManager = _RecordingWalletManager();
    probe = _SilentActor();
    storage = InMemoryWalletStorage();
    await storage.storeBlockHeader(fixture2Header(), tip);
    final walletRef = await system.spawn('wallet-manager', () => walletManager);
    probeRef = await system.spawn('probe', () => probe);
    final invoiceRef = await system.spawn('invoices', () => _SilentActor());
    spvActor = await system.spawn(
      'spv',
      () => SPVActor(walletManager: walletRef, invoiceCoordinator: invoiceRef, storage: storage),
    );
  });

  tearDown(() async {
    await system.shutdown();
  });

  BEEF provenBeef() => BEEF.create(
        bumps: [fixtureBump()],
        txs: [Uint8List.fromList(hex.decode(kFixtureTxHex))],
        hasMerkle: [true],
        bumpIndex: [0],
      );

  Future<void> until(bool Function() done, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Everything told to the SPV actor before this has been handled: a
  /// question asked now is answered after it.
  Future<void> barrier() async {
    final before = probe.received.whereType<SPVValidationResult>().length;
    spvActor.tell(
      ValidateCounterpartyTransactionMessage(
        transactionId: 'ff' * 32,
        beef: provenBeef(),
        fromCounterparty: 'barrier',
      ),
      sender: probeRef,
    );
    await until(() => probe.received.whereType<SPVValidationResult>().length > before, 'the barrier');
  }

  test('a receive waiting for a header below the tip is not replayed by new blocks, and is '
      'credited once that header is filled in', () async {
    spvActor.tell(
      ReceiveTransactionMessage(
        transactionId: kFixtureTxid,
        beef: provenBeef(),
        fromCounterparty: 'payer',
        targetWalletId: 'w',
      ),
      sender: probeRef,
    );
    await until(() => walletManager.results.isNotEmpty, 'the first verdict');
    expect(walletManager.results.single.isValid, isFalse);
    final parked = await storage.getPendingReceive('w', kFixtureTxid);
    expect(parked?.isWaiting, isTrue);
    expect(parked!.neededHeight, lessThan(tip), reason: 'the missing header is below the tip');
    expect((await storage.getMerkleProof(kFixtureTxid))?.status, MerkleProofStatus.pendingHeader);

    // A new block on top. The tip is above the needed height, but the header
    // there is still missing: nothing to replay.
    await storage.storeBlockHeader(fixture2Header(), tip + 1);
    spvActor.tell(BlockHeaderStoredMessage(header: fixture2Header(), height: tip + 1));
    await barrier();
    expect(walletManager.results, hasLength(1),
        reason: 'replaying would only park the receive again, on every block');
    expect((await storage.getPendingReceive('w', kFixtureTxid))?.isWaiting, isTrue);

    // The header below the tip is filled in.
    await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    spvActor.tell(BlockHeadersBackfilledMessage(fromHeight: kFixtureHeight, toHeight: kFixtureHeight));
    await until(() => walletManager.results.length == 2, 'the replayed verdict');
    expect(walletManager.results.last.isValid, isTrue);
    expect((await storage.getPendingReceive('w', kFixtureTxid))?.isWaiting, isFalse);
    final proof = await storage.getMerkleProof(kFixtureTxid);
    expect((proof?.status, proof?.blockHash), (MerkleProofStatus.verified, kFixtureBlockHash),
        reason: 'the proof filed while its header was missing is checked once the header is held');
  });

  test('receives waiting for a missing header do not hide a newer one that can be judged', () async {
    // Many receives parked first, all waiting for the missing header.
    final old = DateTime.utc(2026, 1, 1);
    for (var i = 0; i < 70; i++) {
      await storage.storePendingReceive(PendingReceive(
        walletId: 'w$i',
        txid: kFixtureTxid,
        beefHex: hex.encode(provenBeef().serialize()),
        fromCounterparty: 'payer',
        neededHeight: kFixtureHeight,
        createdAt: old.add(Duration(seconds: i)),
        updatedAt: old.add(Duration(seconds: i)),
      ));
    }
    // A newer one that needs only the tip's header, which is held.
    final held = BEEF.create(
      bumps: [BUMP.fromHex(fixture2BumpHex())],
      txs: [Uint8List.fromList(hex.decode(kFixture2TxHex))],
      hasMerkle: [true],
      bumpIndex: [0],
    );
    await storage.storePendingReceive(PendingReceive(
      walletId: 'later',
      txid: kFixture2Txid,
      beefHex: hex.encode(held.serialize()),
      fromCounterparty: 'payer',
      neededHeight: tip,
      createdAt: DateTime.utc(2026, 6, 1),
      updatedAt: DateTime.utc(2026, 6, 1),
    ));

    spvActor.tell(BlockHeaderStoredMessage(header: fixture2Header(), height: tip + 1));
    await until(() => walletManager.results.isNotEmpty, 'the replayed verdict');
    await barrier();
    expect([for (final r in walletManager.results) (r.targetWalletId, r.isValid)], [('later', true)],
        reason: 'only the receive whose header is held is replayed, though 70 older ones come first');
    expect((await storage.getPendingReceive('w0', kFixtureTxid))?.isWaiting, isTrue);
  });
}

/// Records every message the SPV actor sends the wallet manager, and says
/// every queried address is the wallet's.
class _RecordingWalletManager extends Actor {
  final List<dynamic> messages = [];

  List<SPVValidationResult> get results => messages.whereType<SPVValidationResult>().toList();

  @override
  Future<void> onMessage(dynamic message) async {
    messages.add(message);
    if (message is WalletOwnershipQuery) {
      context.sender?.tell(WalletOwnershipResponse(
        walletId: message.walletId,
        walletFound: true,
        ownedAddresses: message.addresses,
      ));
    }
  }
}

/// Records everything and answers nothing.
class _SilentActor extends Actor {
  final List<dynamic> received = [];

  @override
  Future<void> onMessage(dynamic message) async => received.add(message);
}
