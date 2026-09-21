/// Bead libspiffy-5ml6: what an app is told when it records its own payment.
///
/// Before this, the answer was: a lie, and nothing.
///
/// `RecordOutgoingCommand` was announced nowhere on success. The arm that
/// would have announced it was dead, because `_handleRecordOutgoing` told
/// the wallet manager with no sender, and bead libspiffy-kl4i deleted it
/// rather than let it go live: it published a manufactured `BigInt.zero` for
/// an amount it did not hold. Supplying that sender — which is what made a
/// *refused* recording reach the app at all — turned on a different arm.
/// The aggregate answers a recording with one `UTXOReceivedResponse` per
/// output of the transaction that pays the wallet itself (`_addWalletOutputs`
/// credits change, settlement and self-transfer outputs), and the
/// coordinator announced each of those as a `TransactionReceivedEvent` of
/// **zero satoshis, incoming** — an app's own outgoing payment reported back
/// to it as money arriving, for nothing.
///
/// So: `TransactionReceivedEvent` is gone (an incoming receive is reported
/// by `SPVValidationResultEvent` and `TransactionImportedEvent`, which carry
/// the amount the wallet measured), and a recording is announced once, with
/// the amount journaled for it, after the read model has it.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/coordinator_messages.dart';
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart' as wm;
import 'package:libspiffy/src/core/wallet_commands.dart' as domain;
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import 'in_memory_event_store.dart';

const _walletId = 'w-5ml6';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
final _fundingTxid = 'a' * 64;
final _wait = const Duration(seconds: 10);

void main() {
  late ActorSystem system;
  late InMemoryWalletStorage storage;
  late _StubProjection projection;
  late ActorRef manager;
  late ActorRef coordinator;
  late List<CoordinatorEvent> events;
  late StreamSubscription<CoordinatorEvent> sub;
  late String root;

  dartsv.SVScript lock(String address) =>
      dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey();

  setUp(() async {
    system = LocalActorSystem();
    storage = InMemoryWalletStorage();
    events = [];
    manager = await system.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: InMemoryEventStore(),
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
      ),
    );
    projection = _StubProjection();
    final projectionRef = await system.spawn('projection', () => projection);
    final noop = await system.spawn('noop', () => _Noop());
    final actor = WalletCoordinatorActor(
      walletManager: manager,
      invoiceCoordinator: noop,
      paymentCoordinator: noop,
      spvActor: noop,
      arcActor: noop,
      headerSyncActor: noop,
      benfordCoordinator: noop,
      channelManager: noop,
      walletProjection: projectionRef,
      storage: storage,
    );
    sub = actor.events.listen(events.add);
    coordinator = await system.spawn('coordinator', () => actor);

    final created = await manager.ask<wm.WalletCreatedMessage>(
      wm.CreateWalletMessage(_walletId, '5ml6', mnemonic: _mnemonic, walletMetadata: {'network': 'testnet'}),
      _wait,
    );
    expect(created.success, isTrue, reason: created.error);
    root = created.rootAddress;

    // One spendable UTXO to pay from.
    manager.tell(wm.WalletCommandMessage(
      _walletId,
      domain.ReceiveUTXOCommand(
        walletId: _walletId,
        txid: _fundingTxid,
        vout: 0,
        satoshis: BigInt.from(100000),
        scriptPubKey: lock(root).toHex(),
        address: root,
        blockHeight: 900000,
        initialStatus: UTXOStatus.available,
      ),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });

  tearDown(() async {
    projection.release();
    await sub.cancel();
    await system.shutdown();
  });

  /// A transaction spending the funding UTXO: [walletOutputs] outputs back to
  /// the wallet's own address (change, as any real payment has), and one
  /// output of [paid] satoshis to someone else.
  dartsv.Transaction payment({required int paid, int walletOutputs = 1}) {
    final other = dartsv.SVPrivateKey.fromHex('77' * 32, dartsv.NetworkType.TEST)
        .publicKey
        .toAddress(dartsv.NetworkType.TEST)
        .toBase58();
    final tx = dartsv.Transaction()
      ..addInput(dartsv.TransactionInput(_fundingTxid, 0, 0xffffffff))
      ..addOutput(dartsv.TransactionOutput(BigInt.from(paid), lock(other)));
    for (var i = 0; i < walletOutputs; i++) {
      tx.addOutput(dartsv.TransactionOutput(BigInt.from(1000), lock(root)));
    }
    return tx;
  }

  RecordOutgoingCommand record(dartsv.Transaction tx, {required int paid, String? walletId}) =>
      RecordOutgoingCommand(
        walletId: walletId ?? _walletId,
        txid: tx.id,
        rawHex: tx.serialize(),
        totalInputSats: 100000,
        totalOutputSats: paid,
        fee: 5000,
        numInputs: 1,
        numOutputs: tx.outputs.length,
        txVersion: 1,
        txLockTime: 0,
        spentUtxoKeys: ['$_fundingTxid:0'],
        recipientAddresses: const ['recipient'],
        paymentAmount: paid,
        changeAddress: root,
        changeAmount: 1000,
      );

  Future<T> nextEvent<T extends CoordinatorEvent>() async {
    final deadline = DateTime.now().add(_wait);
    while (DateTime.now().isBefore(deadline)) {
      final match = events.whereType<T>();
      if (match.isNotEmpty) return match.first;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('no $T within $_wait; received: $events');
  }

  group('5ml6: a recording the app asked for is announced', () {
    test('an outgoing recording is announced with the amount it recorded', () async {
      final tx = payment(paid: 40000);

      coordinator.tell(record(tx, paid: 40000));

      // Old code: nothing said the recording succeeded.
      final recorded = await nextEvent<TransactionRecordedEvent>();
      expect(recorded.success, isTrue, reason: recorded.error);
      expect(recorded.walletId, _walletId);
      expect(recorded.txid, tx.id);
      expect(recorded.amountSatoshis, BigInt.from(40000),
          reason: 'the amount is read off the event the wallet journaled');
    });

    test('a payment with two of the wallet\'s own outputs is announced once, '
        'not once per output', () async {
      final tx = payment(paid: 40000, walletOutputs: 2);

      coordinator.tell(record(tx, paid: 40000));
      await nextEvent<TransactionRecordedEvent>();
      // Anything the aggregate's own-output replies would produce has been
      // handled by now: they are sent before the recording's own reply.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Old code: two TransactionReceivedEvents, each claiming the app had
      // received zero satoshis, incoming — and no recording event at all.
      expect(events, hasLength(1), reason: 'received: $events');
      expect(events.single, isA<TransactionRecordedEvent>());
    });

    test('recording the same transaction again is announced with no amount '
        'rather than a zero', () async {
      final tx = payment(paid: 40000);
      coordinator.tell(record(tx, paid: 40000));
      final first = await nextEvent<TransactionRecordedEvent>();
      expect(first.amountSatoshis, BigInt.from(40000));

      // The wallet records a transaction once (bead libspiffy-viy), so the
      // second command journals nothing and there is no event to read an
      // amount off. The recording still stands.
      events.clear();
      coordinator.tell(record(tx, paid: 40000));

      final again = await nextEvent<TransactionRecordedEvent>();
      expect(again.success, isTrue, reason: again.error);
      expect(again.amountSatoshis, isNull,
          reason: 'an absence, not a zero: nothing was journaled to read it off');
    });

    // The property bead libspiffy-kl4i established, which this change must
    // not take away: a refusal has no TransactionRecordedResponse, it comes
    // back as WalletCommandFailed and is announced as an error.
    test('a recording the wallet cannot route still reaches the app as an error', () async {
      final tx = payment(paid: 40000);

      coordinator.tell(record(tx, paid: 40000, walletId: 'no-such-wallet'));

      final failed = await nextEvent<ErrorEvent>();
      expect(failed.walletId, 'no-such-wallet');
      expect(failed.message, contains('Wallet not found'));
      expect(events.whereType<TransactionRecordedEvent>(), isEmpty);
    });
  });

  group('5ml6: recorded means queryable', () {
    test('the recording is not announced until the projection has applied it', () async {
      projection.hold();
      final tx = payment(paid: 40000);

      coordinator.tell(record(tx, paid: 40000));

      // The aggregate has journaled it and answered; the read model has no
      // row for it, and the projection is holding the awaiter.
      await _eventually(() async => projection.awaited);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await storage.getTransaction(tx.id), isNull,
          reason: 'precondition: the read model does not hold the transaction');
      expect(events.whereType<TransactionRecordedEvent>(), isEmpty,
          reason: 'announced before the read model could answer a query for it');

      projection.release();

      final recorded = await nextEvent<TransactionRecordedEvent>();
      expect(recorded.success, isTrue, reason: recorded.error);
    });

    test('a projection that never applies it is announced as recorded but not applied', () async {
      projection.fail('timeout');
      final tx = payment(paid: 40000);

      coordinator.tell(record(tx, paid: 40000));

      final recorded = await nextEvent<TransactionRecordedEvent>();
      expect(recorded.success, isFalse);
      expect(recorded.error, allOf(contains('journaled'), contains('timeout')));
      expect(recorded.txid, tx.id);
    });
  });
}

Future<void> _eventually(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(_wait);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met within $_wait');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A wallet projection that answers the coordinator's two questions on cue:
/// the FIFO barrier ([GetProjectionInfo]) and the awaiter
/// ([AwaitEventApplied]). Holding the awaiter is "the projection has not
/// applied it yet", held for as long as the test likes rather than raced.
class _StubProjection extends Actor {
  final List<Completer<void>> _held = [];
  bool _hold = false;
  String? _failReason;
  bool awaited = false;

  void hold() => _hold = true;

  void fail(String reason) => _failReason = reason;

  void release() {
    _hold = false;
    for (final c in _held) {
      if (!c.isCompleted) c.complete();
    }
    _held.clear();
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is GetProjectionInfo) {
      context.sender?.tell(_Info());
      return;
    }
    if (message is AwaitEventApplied) {
      awaited = true;
      final sender = context.sender;
      if (_failReason != null) {
        sender?.tell(AwaitFailed(reason: _failReason!));
        return;
      }
      if (_hold) {
        final gate = Completer<void>();
        _held.add(gate);
        await gate.future;
      }
      sender?.tell(EventAppliedResponse());
    }
  }
}

class _Info extends LocalMessage {
  _Info() : super(payload: null);
  @override
  dynamic get payload => this;
}

class _Noop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}
