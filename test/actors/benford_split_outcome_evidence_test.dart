/// Bead libspiffy-q28i: the Benford split reported outcomes it could not
/// evidence.
///
/// * A split that failed before a transaction was built vanished. Four paths
///   in `_splitSingleUtxo` returned null -- source too small, reservation
///   refused, build or SIGN failure, any exception -- and the caller saw
///   nothing at all. If EVERY source failed that way the reply was
///   `success: true` with an empty `splits`: a total failure answered as a
///   success.
/// * `transactionCount` on the public `UTXOSplitCompleteEvent` was fed from
///   `splitCount`, which is a UTXO count, so one split transaction was
///   reported as `targetUtxoCount` of them.
/// * `totalFeePaid: BigInt.zero` was manufactured: the fee was computed
///   inside the coordinator and thrown away.
library;

// The stand-in wallet manager answers its sender through dactor's @internal
// `Actor.context`.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/actors/arc_actor.dart';
import 'package:libspiffy/src/actors/internal_messages.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/actors/benford_coordinator_actor.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:test/test.dart';

import 'in_memory_event_store.dart';
import '../mocks/offline_arc.dart';
import 'package:libspiffy/src/models/fee_rate.dart';

const _xpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';
const _walletId = 'benford-q28i';
final _sourceTxid = 'b3' * 32;
const _wait = Duration(seconds: 10);

/// targetUtxoCount 3 at ARC's policy rate (the fake's 100 sat/1000 bytes)
/// on the split's signed size — one P2PKH input and three P2PKH outputs,
/// 260 bytes, so 26 satoshis (bead libspiffy-lph4) — and one satoshi per
/// output on top. Anything under this cannot be split. (It was 292 + 3 at
/// the app-supplied 1 sat/byte the split used to default to.)
final _minSplittable = BigInt.from(26 + 3);

/// A source too small to split.
final _tooSmall = (_minSplittable - BigInt.one).toInt();

void main() {
  late LocalActorSystem system;
  late InMemoryEventStore eventStore;
  late InMemoryWalletStorage readModel;
  late _SilentArc arc;
  late ActorRef walletManager;

  setUp(() async {
    system = LocalActorSystem(ActorSystemConfig());
    eventStore = InMemoryEventStore();
    readModel = InMemoryWalletStorage();
    arc = _SilentArc();
    walletManager = await system.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: eventStore,
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
        aggregateIdleTimeout: null,
        readModelStorage: readModel,
      ),
    );
  });

  tearDown(() async => system.shutdown());

  Future<ActorRef> realArcActor() => system.spawn(
        'arc',
        () => ARCActor(
          walletManager: walletManager,
          storage: readModel,
          arcService: arc,
          statusCheckInterval: const Duration(minutes: 10),
        ),
      );

  Future<ActorRef> benfordWith(ActorRef arcActor) => system.spawn(
        'benford-${DateTime.now().microsecondsSinceEpoch}',
        () => BenfordCoordinatorActor(
          walletManager: walletManager,
          arcActor: arcActor,
          storage: readModel,
        ),
      );

  /// Creates the wallet and gives it one UTXO per entry of [amounts], all at
  /// one generated address, each acknowledged by the wallet aggregate and
  /// mirrored into the read model as a caught-up projection would.
  Future<void> walletWithUtxos(List<int> amounts) async {
    final created = await walletManager.ask<WalletCreatedMessage>(
      CreateWalletMessage(_walletId, 'Benford', xpriv: _xpriv),
      _wait,
    );
    expect(created.success, isTrue, reason: created.error);
    final generated = await walletManager.ask<AddressGeneratedResponse>(
      WalletCommandMessage(_walletId, GenerateAddressCommand(walletId: _walletId)),
      _wait,
    );
    expect(generated.success, isTrue, reason: generated.error);
    final address = generated.address;
    final script = dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(address))
        .getScriptPubkey()
        .toHex();
    await readModel.storeWallet(_walletId, 'Benford',
        networkType: 'testnet', metadata: {'walletType': 'hd'});

    for (var vout = 0; vout < amounts.length; vout++) {
      final satoshis = BigInt.from(amounts[vout]);
      final received = await walletManager.ask<UTXOReceivedResponse>(
        WalletCommandMessage(
          _walletId,
          ReceiveUTXOCommand(
            walletId: _walletId,
            txid: _sourceTxid,
            vout: vout,
            satoshis: satoshis,
            scriptPubKey: script,
            address: address,
            blockHeight: 100,
            confirmations: 6,
            initialStatus: UTXOStatus.available,
          ),
        ),
        _wait,
      );
      expect(received.success, isTrue, reason: received.error);
      await readModel.upsertUTXO(
        _walletId,
        BitcoinUtxo.create(
          txid: _sourceTxid,
          vout: vout,
          satoshis: satoshis,
          scriptPubKey: script,
          address: address,
          status: UTXOStatus.available,
        ),
      );
    }
  }

  Future<SplitUTXOsResponse> split(ActorRef benford) =>
      benford.ask<SplitUTXOsResponse>(
        SplitUTXOsToBenfordCommand(
            walletId: _walletId, targetUtxoCount: 3),
        const Duration(seconds: 40),
      );

  String key(int vout) => '$_sourceTxid:$vout';

  group('a split that builds no transaction is reported, not dropped', () {
    test('every source too small: a total failure is NOT a success', () async {
      // The killer case. Old code: outcomes empty -> failed empty ->
      // success: true, splitCount: 0, splits: [].
      await walletWithUtxos([_tooSmall, _tooSmall - 5]);
      final response = await split(await benfordWith(await realArcActor()));

      expect(response.success, isFalse,
          reason: 'not one transaction was built; this is a total failure');
      expect(response.txids, isEmpty);
      expect(response.splitCount, 0);
      expect(response.splits, hasLength(2),
          reason: 'one outcome per source UTXO that was attempted');
      expect(response.splits.map((o) => o.status),
          everyElement(SplitTransactionStatus.notBuilt));
      expect(response.splits.map((o) => o.sourceUtxoKey), [key(0), key(1)]);
      expect(response.splits.map((o) => o.txid), everyElement(isNull),
          reason: 'there is no transaction, so there is no txid to state');
      for (final outcome in response.splits) {
        expect(outcome.error, contains('too small'),
            reason: 'the reason is reported, not just logged');
        expect(outcome.error, contains(outcome.sourceUtxoKey));
      }
      expect(response.error, contains(key(0)));
      expect(response.error, contains(key(1)));
    });

    test('a partial failure names the source that was skipped', () async {
      await walletWithUtxos([100000, _tooSmall]);
      final response = await split(await benfordWith(await realArcActor()));

      expect(response.success, isFalse,
          reason: 'one source was never split; that is not a success');
      expect(response.splits, hasLength(2));
      expect(response.splits[0].status, SplitTransactionStatus.accepted);
      expect(response.splits[1].status, SplitTransactionStatus.notBuilt);
      expect(response.txids, [response.splits[0].txid]);
      expect(response.error, contains(key(1)));
      expect(response.error, isNot(contains('${response.splits[0].txid}')),
          reason: 'the split that worked is not reported as an error');
    });

    test('a source the wallet will not reserve is reported', () async {
      // The read model still offers the source, but the aggregate refuses to
      // reserve it -- a payment got there first between the two reads. The
      // split must report that, not drop the source silently.
      await walletWithUtxos([100000]);
      final refusing = await system.spawn(
          'reservation-refused', () => _ReservationRefusedWallet(walletManager));
      final arcRef = await realArcActor();
      final benford = await system.spawn(
        'benford-noreserve',
        () => BenfordCoordinatorActor(
          walletManager: refusing,
          arcActor: arcRef,
          storage: readModel,
        ),
      );

      final response = await split(benford);

      expect(response.success, isFalse);
      expect(response.splits.single.status, SplitTransactionStatus.notBuilt);
      expect(response.splits.single.sourceUtxoKey, key(0));
      expect(response.splits.single.error, contains('reserve'));
    });

    test('a source that cannot be signed is reported', () async {
      await walletWithUtxos([100000]);
      // A wallet manager that refuses to sign: the transaction is built and
      // then dies at the signing step, the third of the four silent paths.
      final refusing =
          await system.spawn('refusing', () => _SigningRefusedWallet(walletManager));
      final arcRef = await realArcActor();
      final benford = await system.spawn(
        'benford-nosign',
        () => BenfordCoordinatorActor(
          walletManager: refusing,
          arcActor: arcRef,
          storage: readModel,
          signingReplyTimeout: const Duration(seconds: 2),
        ),
      );

      final response = await split(benford);

      expect(response.success, isFalse);
      expect(response.splits.single.status, SplitTransactionStatus.notBuilt);
      expect(response.splits.single.sourceUtxoKey, key(0));
      expect(response.splits.single.txid, isNull);
      expect(response.splits.single.error, contains('built or signed'),
          reason: 'the signing failure is named as such, not swallowed by '
              'the generic catch-all');
      expect(response.splits.single.error, contains('released'),
          reason: 'the host is told its source is not left reserved');
    });

    test('a source too small still leaves the wallet able to spend it',
        () async {
      // The reservation must not be left behind by the refusal path.
      await walletWithUtxos([_tooSmall]);
      await split(await benfordWith(await realArcActor()));

      final reserved = await walletManager.ask<UTXOReservedResponse>(
        WalletCommandMessage(
          _walletId,
          ReserveUTXOCommand(
              walletId: _walletId, utxoKey: key(0), reservedByTxId: 'later-payment'),
        ),
        _wait,
      );
      expect(reserved.success, isTrue,
          reason: 'a source that was never split is still spendable: '
              '${reserved.error}');
    });
  });

  group('the public event states numbers it can evidence', () {
    test('transactionCount is the number of transactions, not of UTXOs',
        () async {
      await walletWithUtxos([100000]);
      final benford = await benfordWith(await realArcActor());
      walletManager.tell(SetBenfordCoordinatorMessage(benford));
      final noop = await system.spawn('noop', () => _Noop());

      final coordinator = WalletCoordinatorActor(
        walletManager: walletManager,
        invoiceCoordinator: noop,
        paymentCoordinator: noop,
        spvActor: noop,
        arcActor: noop,
        headerSyncActor: noop,
        benfordCoordinator: benford,
        channelManager: noop,
        walletProjection: noop,
        storage: readModel,
      );
      final completed =
          coordinator.events.firstWhere((e) => e is coord.UTXOSplitCompleteEvent);
      final ref = await system.spawn('coordinator', () => coordinator);

      ref.tell(coord.SplitUTXOsCommand(walletId: _walletId, targetUtxoCount: 3));
      final event = await completed.timeout(const Duration(seconds: 40))
          as coord.UTXOSplitCompleteEvent;

      expect(event.success, isTrue, reason: event.error);
      expect(event.txids, hasLength(1));
      expect(event.transactionCount, 1,
          reason: 'one transaction was built and broadcast; the old code '
              'multiplied it by targetUtxoCount and reported 3');
      expect(event.newUtxoCount, 3,
          reason: 'three outputs were created, which is the UTXO count');
    });

    test('totalFeePaid is the fee the split actually paid, not zero',
        () async {
      await walletWithUtxos([100000]);
      final benford = await benfordWith(await realArcActor());
      walletManager.tell(SetBenfordCoordinatorMessage(benford));
      final noop = await system.spawn('noop', () => _Noop());

      final coordinator = WalletCoordinatorActor(
        walletManager: walletManager,
        invoiceCoordinator: noop,
        paymentCoordinator: noop,
        spvActor: noop,
        arcActor: noop,
        headerSyncActor: noop,
        benfordCoordinator: benford,
        channelManager: noop,
        walletProjection: noop,
        storage: readModel,
      );
      final completed =
          coordinator.events.firstWhere((e) => e is coord.UTXOSplitCompleteEvent);
      final ref = await system.spawn('coordinator', () => coordinator);

      ref.tell(coord.SplitUTXOsCommand(walletId: _walletId, targetUtxoCount: 3));
      final event = await completed.timeout(const Duration(seconds: 40))
          as coord.UTXOSplitCompleteEvent;

      expect(event.totalFeePaid, greaterThan(BigInt.zero),
          reason: 'a broadcast split paid a fee; zero was manufactured');
      // The fee is the difference the transaction itself records.
      final outcome = event.splits.single;
      expect(outcome.feePaid, isNotNull);
      expect(event.totalFeePaid, outcome.feePaid,
          reason: 'the total is the sum of the splits that succeeded');
      // Checked against the transaction that actually went to ARC, not
      // against the number the coordinator carried: the fee is the source
      // minus what the broadcast transaction pays out.
      final broadcast = dartsv.Transaction.fromHex(arc.submittedHex.single);
      final outputs = broadcast.outputs
          .fold(BigInt.zero, (BigInt sum, o) => sum + o.satoshis);
      expect(broadcast.id, outcome.txid);
      expect(outcome.feePaid, BigInt.from(100000) - outputs,
          reason: 'the fee is the source minus the outputs of the signed '
              'transaction that was broadcast');
    });

    test('a split that built nothing reports no fee, not a fee of zero',
        () async {
      await walletWithUtxos([_tooSmall]);
      final response = await split(await benfordWith(await realArcActor()));

      expect(response.splits.single.status, SplitTransactionStatus.notBuilt);
      expect(response.splits.single.feePaid, isNull,
          reason: 'no transaction was built, so no fee is known; an absence '
              'is honest and a zero is not');
    });
  });

  test('every address command of a split carries its own id (bead libspiffy-y0ce)',
      () async {
    // The coordinator used to sleep 10 us between address commands "to
    // ensure unique timestamps for commandId". The loop index already makes
    // them unique; this pins that, which is the invariant the sleep guarded.
    await walletWithUtxos([100000]);
    late _RecordingWallet recorder;
    final recording = await system.spawn('recording', () {
      recorder = _RecordingWallet(walletManager);
      return recorder;
    });
    final arcRef = await realArcActor();
    final benford = await system.spawn(
      'benford-ids',
      () => BenfordCoordinatorActor(
        walletManager: recording,
        arcActor: arcRef,
        storage: readModel,
      ),
    );

    final response = await benford.ask<SplitUTXOsResponse>(
      SplitUTXOsToBenfordCommand(
          walletId: _walletId, targetUtxoCount: 8),
      const Duration(seconds: 40),
    );
    expect(response.success, isTrue, reason: response.error);

    final ids = recorder.addressCommandIds;
    expect(ids, hasLength(8), reason: 'one command per output');
    expect(ids.toSet(), hasLength(8),
        reason: 'the ids are distinct without spacing the commands in time');

    // What the uniqueness is FOR: eight outputs on eight different
    // addresses. A split whose outputs shared an address would defeat the
    // point of splitting, and is what a collided command id would cause.
    final outputs = dartsv.Transaction.fromHex(arc.submittedHex.single).outputs;
    expect(outputs, hasLength(8));
    final lockingScripts = outputs.map((o) => o.script.toHex()).toSet();
    expect(lockingScripts, hasLength(8),
        reason: 'every output pays a distinct address (a P2PKH locking '
            'script is the address)');
  });

  // Bead libspiffy-lph4: the split pays ARC's policy rate on its signed
  // size. It took an app-supplied rate in satoshis per byte, defaulting to
  // 1 (ten times the rate everything else paid), on a `180 + 34n + 10`
  // guess.
  // The watch-only refusal was also pinned on the wallet aggregate's split
  // handler, which the command never reached and bead libspiffy-lph4
  // deleted; this is the coordinator the command does reach.
  test('a watch-only wallet is refused a split: it holds no key to sign one', () async {
    final xpub = dartsv.HDPrivateKey.fromXpriv(_xpriv).hdPublicKey.xpubkey;
    final created = await walletManager.ask<WalletCreatedMessage>(
      CreateWalletMessage(_walletId, 'Benford', xpub: xpub),
      _wait,
    );
    expect(created.success, isTrue, reason: created.error);

    final response = await split(await benfordWith(await realArcActor()));

    expect(response.success, isFalse);
    expect(response.error, contains('watch-only'));
    expect(arc.submittedHex, isEmpty);
  });

  test('lph4: a split pays ARC\'s policy rate on its signed size', () async {
    const rate = FeeRate(satoshis: 500, bytes: 1000);
    arc.miningFee = rate;
    await walletWithUtxos([100000]);

    final response = await split(await benfordWith(await realArcActor()));

    expect(response.splits.single.status, SplitTransactionStatus.accepted, reason: response.error);
    final tx = dartsv.Transaction.fromHex(arc.submittedHex.single);
    final paid = BigInt.from(100000) - tx.outputs.fold<BigInt>(BigInt.zero, (sum, o) => sum + o.satoshis);
    final signedBytes = tx.serialize().length ~/ 2;
    expect(response.splits.single.feePaid, paid);
    expect(paid, greaterThanOrEqualTo(rate.feeFor(signedBytes)),
        reason: 'a $signedBytes-byte signed split pays $paid');
    // Old code: 292 satoshis, at 1 sat/byte on 292 guessed bytes.
    expect(paid, lessThanOrEqualTo(rate.feeFor(signedBytes + 2)),
        reason: 'paid for bytes the transaction does not have');
  });

  test('lph4: a split ARC cannot give the rate for is refused, and nothing is reserved', () async {
    arc.policyUnavailable = true;
    await walletWithUtxos([100000]);

    final response = await split(await benfordWith(await realArcActor()));

    expect(response.success, isFalse);
    expect(response.error, contains('policy'));
    expect(arc.submittedHex, isEmpty);
    final reserved = await walletManager.ask<UTXOReservedResponse>(
      WalletCommandMessage(
        _walletId,
        ReserveUTXOCommand(walletId: _walletId, utxoKey: key(0), reservedByTxId: 'later-payment'),
      ),
      _wait,
    );
    expect(reserved.success, isTrue, reason: 'the split reserved its source: ${reserved.error}');
  });

  test('a source smaller than the fee is still worth reporting to the host',
      () async {
    // Boundary: one satoshi under the minimum is refused, the minimum is not.
    await walletWithUtxos([(_minSplittable - BigInt.one).toInt()]);
    final response = await split(await benfordWith(await realArcActor()));
    expect(response.splits.single.status, SplitTransactionStatus.notBuilt);
    expect(response.splits.single.error, contains('${_minSplittable}'),
        reason: 'the refusal states what the source would have had to be');
  });
}

/// Answers nothing; stands in for the coordinator's other actors.
class _Noop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

/// Passes everything through and records the id of every address command.
class _RecordingWallet extends Actor {
  final ActorRef _delegate;
  final List<String> addressCommandIds = [];
  _RecordingWallet(this._delegate);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletCommandMessage &&
        message.command is GenerateAddressCommand) {
      addressCommandIds.add(message.command.commandId);
    }
    _delegate.tell(message, sender: context.sender);
  }
}

/// Forwards everything to the real wallet manager except a reservation,
/// which it refuses as the aggregate would when the source is already taken.
class _ReservationRefusedWallet extends Actor {
  final ActorRef _delegate;
  _ReservationRefusedWallet(this._delegate);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletCommandMessage && message.command is ReserveUTXOCommand) {
      final command = message.command as ReserveUTXOCommand;
      context.sender?.tell(UTXOReservedResponse(
        walletId: command.walletId,
        utxoKey: command.utxoKey,
        reservedByTxId: command.reservedByTxId,
        success: false,
        error: 'UTXO ${command.utxoKey} is already reserved by another payment',
      ));
      return;
    }
    _delegate.tell(message, sender: context.sender);
  }
}

/// Forwards everything to the real wallet manager except the signing request,
/// which it refuses: the split is built and then cannot be signed.
class _SigningRefusedWallet extends Actor {
  final ActorRef _delegate;
  _SigningRefusedWallet(this._delegate);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletCommandMessage &&
        message.command is SignTransactionCommand) {
      return; // no reply: the signing times out
    }
    _delegate.tell(message, sender: context.sender);
  }
}

/// ARC without a network: accepts every broadcast as SEEN_ON_NETWORK.
class _SilentArc extends OfflineArc {
  _SilentArc() : super(baseUrl: 'fake://arc');

  final List<String> submitted = [];
  final List<String> submittedHex = [];

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async {
    final txid = dartsv.Transaction.fromHex(rawTx).id;
    submitted.add(txid);
    submittedHex.add(rawTx);
    return ArcSubmitResponse.fromJson({'txid': txid, 'txStatus': 'SEEN_ON_NETWORK'});
  }

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async =>
      throw ArcException('Failed to get transaction: {"status":404}', statusCode: 404);
}
