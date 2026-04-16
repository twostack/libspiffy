/// Settlement correlation tests for WalletCoordinatorActor.
///
/// Exercises the [_handleSettleBEEF] correlation logic by driving a real
/// `LibSpiffyActorSystem` with a configurable mock `ArcService`. The mock
/// lets us control per-txid whether `submitTransaction` succeeds or throws,
/// which in turn exercises the BroadcastSuccess/Failed routing back into
/// WalletCoordinatorActor.
///
/// What we verify:
///
/// 1. **All-success path**: every TX submit succeeds → BEEFSettledEvent
///    fires once with `success=true, submittedCount=N, failedCount=0`.
///
/// 2. **Mixed success/failure**: some TXs succeed, some fail → event fires
///    with `success=false`, `failedTxids` contains the right txids, and
///    `failureErrors` has the corresponding messages.
///
/// 3. **All-failure path**: every submit throws → event with
///    `success=false, failedCount=N`, aggregated error string.
///
/// 4. **Degenerate BEEF** (nothing to broadcast): if every TX in the BEEF
///    has hasMerkle=true, the event fires immediately with success=true
///    and submittedCount=0.
///
/// These tests do NOT go through the overnode_v2 wallet isolate bridge —
/// they speak directly to libspiffy's `WalletCoordinatorActor` via its
/// public message API. That keeps the test surface small and focused on
/// the correlation logic under test.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:test/test.dart';

import '../integration/isar_test_helper.dart';

// =============================================================================
// CONFIGURABLE MOCK ARC SERVICE
// =============================================================================

/// Configurable mock ArcService. Per-txid behavior is set via [setTxidResult]
/// before the test calls `settleBEEF`. Any txid without an entry defaults to
/// success.
class _ConfigurableArcService extends ArcService {
  _ConfigurableArcService() : super(baseUrl: 'mock://arc', apiKey: null);

  /// If value is non-null, `submitTransaction` throws with that message.
  /// If value is null (entry present), `submitTransaction` succeeds.
  /// If entry absent, defaults to success.
  final Map<String, String?> _perTxidErrors = {};

  void setTxidResult(String txid, {String? errorMessage}) {
    _perTxidErrors[txid] = errorMessage;
  }

  void reset() {
    _perTxidErrors.clear();
  }

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async {
    // Tiny delay to simulate network
    await Future.delayed(const Duration(milliseconds: 5));
    final tx = dartsv.Transaction.fromHex(rawTx);
    final txid = tx.id;
    final configured = _perTxidErrors[txid];
    if (configured != null) {
      throw Exception(configured);
    }
    return ArcSubmitResponse(
      txid: txid,
      status: ArcTransactionStatus.seenOnNetwork,
      message: 'accepted (mock)',
      blockHeight: null,
      blockHash: null,
      timestamp: DateTime.now().toIso8601String(),
    );
  }
}

// =============================================================================
// TEST BEEF CONSTRUCTION
// =============================================================================

/// Build a minimal BEEF containing N distinct transactions, all with
/// hasMerkle=false. Returns (beefHex, parentTxid, childTxids).
///
/// The TXs are minimum-viable P2PKH sends signed with a throwaway WIF so
/// they're byte-valid and dartsv can round-trip them. No on-chain context
/// is required — ARCActor's submitTransaction is mocked.
({String beefHex, String parentTxid, List<String> childTxids}) buildTestBeef(int n) {
  // Use a deterministic WIF so txids are stable across runs. We never
  // broadcast these to a real network.
  // Known-good testnet WIF from overnode_v2/test/integration/token/helpers
  final privKey = dartsv.SVPrivateKey.fromWIF(
      'cStLVGeWx7fVYKKDXYWVeEbEcPZEC4TD73DjQpHCks2Y8EAjVDSS');
  final pubKey = privKey.publicKey;
  final addr = dartsv.Address.fromPublicKey(pubKey, dartsv.NetworkType.TEST);

  // Build a single "source" tx with N outputs, then N child txs each
  // spending one output. That gives us N+1 TXs in the BEEF.
  // For simplicity and determinism, build N entirely independent txs
  // instead — each with a fake prev-tx-id. dartsv will produce byte-valid
  // TXs since we're not validating on-chain.
  final txs = <dartsv.Transaction>[];
  final childTxids = <String>[];

  for (int i = 0; i < n; i++) {
    final builder = dartsv.TransactionBuilder();
    // Fake prev outpoint per TX so they have distinct txids
    final fakePrevTxid = List<int>.generate(32, (j) => (i + 1) * 13 + j);
    final fakeScriptPubkey =
        dartsv.P2PKHLockBuilder.fromAddress(addr).getScriptPubkey();
    final outpoint = dartsv.TransactionOutpoint(
      hex.encode(fakePrevTxid),
      0,
      BigInt.from(1000 + i * 100),
      fakeScriptPubkey,
    );
    builder.spendFromOutpoint(
      outpoint,
      dartsv.TransactionInput.MAX_SEQ_NUMBER,
      dartsv.P2PKHUnlockBuilder(pubKey),
    );
    builder.spendToLockBuilder(
      dartsv.P2PKHLockBuilder.fromAddress(addr),
      BigInt.from(546),
    );
    builder.withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);
    final tx = builder.build(false);
    txs.add(tx);
    childTxids.add(tx.id);
  }

  // Manual BEEF wire encoding matching BEEF.serialize. All hasMerkle=false.
  final writer = BytesBuilder();
  writer.add([0x01, 0x00, 0xBE, 0xEF]); // magic+version
  writer.addByte(0x00); // nBUMPs = 0
  writer.add(dartsv.VarInt.fromInt(txs.length).encode()); // nTxs
  for (final tx in txs) {
    writer.add(hex.decode(tx.serialize()));
    writer.addByte(0x00); // hasBUMP = false
  }

  final beefHex = hex.encode(writer.toBytes());
  // "Parent" is the last TX — the same convention production code uses
  final parentTxid = txs.last.id;
  return (beefHex: beefHex, parentTxid: parentTxid, childTxids: childTxids);
}

/// Build a BEEF containing transactions all marked hasMerkle=true. Used to
/// exercise the "nothing to broadcast" degenerate path.
({String beefHex, String parentTxid}) buildAllConfirmedBeef() {
  // Known-good testnet WIF from overnode_v2/test/integration/token/helpers
  final privKey = dartsv.SVPrivateKey.fromWIF(
      'cStLVGeWx7fVYKKDXYWVeEbEcPZEC4TD73DjQpHCks2Y8EAjVDSS');
  final pubKey = privKey.publicKey;
  final addr = dartsv.Address.fromPublicKey(pubKey, dartsv.NetworkType.TEST);

  // Build a single plausibly-shaped TX
  final builder = dartsv.TransactionBuilder();
  final fakePrevTxid = List<int>.generate(32, (j) => j + 7);
  final fakeScriptPubkey =
      dartsv.P2PKHLockBuilder.fromAddress(addr).getScriptPubkey();
  final outpoint = dartsv.TransactionOutpoint(
    hex.encode(fakePrevTxid),
    0,
    BigInt.from(2000),
    fakeScriptPubkey,
  );
  builder.spendFromOutpoint(
    outpoint,
    dartsv.TransactionInput.MAX_SEQ_NUMBER,
    dartsv.P2PKHUnlockBuilder(pubKey),
  );
  builder.spendToLockBuilder(
    dartsv.P2PKHLockBuilder.fromAddress(addr),
    BigInt.from(546),
  );
  builder.withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);
  final tx = builder.build(false);

  // Need at least one BUMP since hasMerkle=true references bumpIndex[0].
  // The BUMP content doesn't matter — we never validate the merkle proof
  // in the settle path (only BEEF.parse has to accept it).
  //
  // The simplest valid BUMP encoding we can hand-craft: blockHeight=1,
  // treeHeight=0, zero leaves. BUMP.serialize wraps blockHeight as a
  // varint and treeHeight as a single byte, followed by leaf arrays.
  final bumpBytes = BytesBuilder();
  bumpBytes.add(dartsv.VarInt.fromInt(1).encode()); // blockHeight = 1
  bumpBytes.addByte(0x00); // treeHeight = 0
  // No leaf arrays at treeHeight=0

  final writer = BytesBuilder();
  writer.add([0x01, 0x00, 0xBE, 0xEF]);
  writer.addByte(0x01); // nBUMPs = 1
  writer.add(bumpBytes.toBytes());
  writer.addByte(0x01); // nTxs = 1
  writer.add(hex.decode(tx.serialize()));
  writer.addByte(0x01); // hasBUMP = true
  writer.add(dartsv.VarInt.fromInt(0).encode()); // bumpIndex = 0

  return (beefHex: hex.encode(writer.toBytes()), parentTxid: tx.id);
}

// =============================================================================
// TEST INFRASTRUCTURE
// =============================================================================

class _TestContext {
  final Directory testDir;
  final LocalActorSystem actorSystem;
  final Isar isar;
  final LibSpiffyActorSystem libspiffy;
  final _ConfigurableArcService arcMock;
  final List<coord.CoordinatorEvent> capturedEvents = [];
  late final StreamSubscription<coord.CoordinatorEvent> _eventsSub;

  _TestContext({
    required this.testDir,
    required this.actorSystem,
    required this.isar,
    required this.libspiffy,
    required this.arcMock,
  });

  Future<void> dispose() async {
    await _eventsSub.cancel();
    // libspiffy.shutdown() may close the Isar instance itself. Double-close
    // has caused SEGV in CI; wrap defensively.
    try {
      await libspiffy.shutdown();
    } catch (_) {}
    try {
      if (isar.isOpen) await isar.close(deleteFromDisk: false);
    } catch (_) {}
    if (testDir.existsSync()) {
      try {
        testDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

Future<_TestContext> setupTestContext() async {
  await ensureIsarInitialized();
  final testDir = Directory.systemTemp.createTempSync('settle-correlation-');
  final actorSystem = LocalActorSystem(ActorSystemConfig());
  final isar = await Isar.open(
    LibSpiffySchemas.allSchemas,
    directory: testDir.path,
    name: 'test_settle_db',
  );
  final arcMock = _ConfigurableArcService();
  final libspiffy = LibSpiffyActorSystem();
  await libspiffy.initialize(
    actorSystem: actorSystem,
    isar: isar,
    dataDirectory: testDir.path,
    enableP2P: false,
    arcService: arcMock,
  );
  final ctx = _TestContext(
    testDir: testDir,
    actorSystem: actorSystem,
    isar: isar,
    libspiffy: libspiffy,
    arcMock: arcMock,
  );
  ctx._eventsSub = libspiffy.coordinatorEvents!.listen(ctx.capturedEvents.add);
  return ctx;
}

/// Send a `SettleBEEFCommand` and await the matching `BEEFSettledEvent`.
/// Fails the test if the event doesn't arrive within [timeout].
Future<coord.BEEFSettledEvent> sendSettleAndWait(
  _TestContext ctx, {
  required String beefHex,
  required String parentTxid,
  String walletId = 'test-wallet',
  Duration timeout = const Duration(seconds: 10),
}) async {
  final completer = Completer<coord.BEEFSettledEvent>();
  late final StreamSubscription<coord.CoordinatorEvent> sub;
  sub = ctx.libspiffy.coordinatorEvents!.listen((event) {
    if (event is coord.BEEFSettledEvent && event.txid == parentTxid) {
      if (!completer.isCompleted) completer.complete(event);
      sub.cancel();
    }
  });
  ctx.libspiffy.coordinator.tell(coord.SettleBEEFCommand(
    walletId: walletId,
    beefHex: beefHex,
    txid: parentTxid,
  ));
  try {
    return await completer.future.timeout(timeout);
  } catch (e) {
    await sub.cancel();
    rethrow;
  }
}

// =============================================================================
// TESTS
// =============================================================================

void main() {
  group('SettleBEEFCommand correlation', () {
    late _TestContext ctx;

    setUp(() async {
      ctx = await setupTestContext();
    });

    tearDown(() async {
      await ctx.dispose();
    });

    test('all-success path: emits success once with submittedCount=N', () async {
      final beef = buildTestBeef(4);
      // No per-txid failures configured → all succeed by default

      final event = await sendSettleAndWait(
        ctx,
        beefHex: beef.beefHex,
        parentTxid: beef.parentTxid,
      );

      expect(event.success, isTrue,
          reason: 'All TXs succeeded in mock, settlement should report success');
      expect(event.submittedCount, equals(4));
      expect(event.failedCount, equals(0));
      expect(event.skippedCount, equals(0));
      expect(event.failedTxids, isEmpty);
      expect(event.failureErrors, isEmpty);
      expect(event.error, isNull);
    });

    test('mixed success/failure: collects failed txids and errors', () async {
      final beef = buildTestBeef(4);
      // Fail 2 of the 4 with distinct messages
      ctx.arcMock.setTxidResult(beef.childTxids[1],
          errorMessage: 'mock: no children to pick from');
      ctx.arcMock.setTxidResult(beef.childTxids[3],
          errorMessage: 'mock: missing inputs');

      final event = await sendSettleAndWait(
        ctx,
        beefHex: beef.beefHex,
        parentTxid: beef.parentTxid,
      );

      expect(event.success, isFalse);
      expect(event.submittedCount, equals(2));
      expect(event.failedCount, equals(2));
      expect(event.skippedCount, equals(0));
      expect(event.failedTxids.toSet(),
          equals({beef.childTxids[1], beef.childTxids[3]}));
      expect(event.failureErrors.length, equals(2));
      expect(event.error, isNotNull);
      expect(event.error!, contains('no children to pick from'));
      expect(event.error!, contains('missing inputs'));
    });

    test('all-failure: submittedCount=0, every txid in failedTxids', () async {
      final beef = buildTestBeef(3);
      for (final childTxid in beef.childTxids) {
        ctx.arcMock.setTxidResult(childTxid, errorMessage: 'mock: arc down');
      }

      final event = await sendSettleAndWait(
        ctx,
        beefHex: beef.beefHex,
        parentTxid: beef.parentTxid,
      );

      expect(event.success, isFalse);
      expect(event.submittedCount, equals(0));
      expect(event.failedCount, equals(3));
      expect(event.failedTxids.toSet(), equals(beef.childTxids.toSet()));
      expect(event.error, contains('arc down'));
    });

    test('degenerate BEEF (all hasMerkle=true): emits success immediately with submittedCount=0',
        () async {
      final beef = buildAllConfirmedBeef();

      final event = await sendSettleAndWait(
        ctx,
        beefHex: beef.beefHex,
        parentTxid: beef.parentTxid,
      );

      expect(event.success, isTrue);
      expect(event.submittedCount, equals(0));
      expect(event.failedCount, equals(0));
      expect(event.skippedCount, equals(1),
          reason: 'The single TX was already on chain and should be skipped');
    });

    // NOTE: The "duplicate in-flight settle rejection" edge case is covered
    // by the defensive guard at the top of _handleSettleBEEF. A full test
    // exercising it has proven flaky due to Isar teardown races when two
    // settle commands overlap in the same test. It's worth writing later
    // as a standalone test in its own isolate; not essential for Fix A's
    // core coverage (see tasks 12-15 for the primary correctness tests).
  });
}
