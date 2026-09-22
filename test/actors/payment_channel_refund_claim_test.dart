/// libspiffy-cqc (b): a client can actually claim its refund.
///
/// `ClaimRefundCommand` was handled by the aggregate, guarded, and projected
/// into the read model — and nothing in lib/ ever constructed it. Only tests
/// did. So a client holding a fully signed refund after its channel's
/// lockTime had no way to take its money back: the expiry path journals the
/// expiry and records the refund in the wallet, but it never broadcasts, and
/// a transaction nobody broadcasts is not a claim.
///
/// The claim is the expiry path plus the broadcast. The refund is OUR
/// transaction, so ARC has standing to answer for it (spv-understanding.md);
/// a rejection is a terminal answer, because THIS IS BSV and there is no
/// replace-by-fee to retry it with.
library;

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart' show Event, EventStore, SnapshotData;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/payment_channel_manager_actor.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/payment_channel.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/projections/channel_projection.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import 'channel_test_fixtures.dart';
import 'in_memory_event_store.dart';
import '../mocks/fixed_time_header_chain.dart';
import '../mocks/test_channel_timing.dart';

const _channelId = 'chan-claim';
const _walletId = 'wallet';
const _timeout = Duration(seconds: 10);

/// A real wallet aggregate and its projection, so the wallet commands the
/// channel manager sent can be replayed and read back.
class _Wallet {
  final storage = InMemoryWalletStorage();
  late final BitcoinWalletAggregate aggregate;
  late final WalletProjection projection;

  WalletState get state => aggregate.state ?? aggregate.createInitialState();

  static Future<_Wallet> create() async {
    final wallet = _Wallet();
    wallet.aggregate = BitcoinWalletAggregate(
      aggregateId: _walletId,
      aggregateType: 'BitcoinWallet',
      eventStore: InMemoryEventStore(),
      cryptoService: DartSVCryptoService(),
      secureStorage: InMemorySecureStorage(),
    );
    wallet.projection = WalletProjection(
      projectionId: 'claim-projection',
      eventStore: _NoopEventStore(),
      storage: wallet.storage,
    );
    await wallet.apply(CreateWalletCommand(
        walletId: _walletId,
        walletName: 'channel',
        mnemonic: channelFixtureMnemonic));
    for (var i = 0; i < 4; i++) {
      await wallet.apply(
          GenerateAddressCommand(walletId: _walletId, purpose: 'receive'));
    }
    return wallet;
  }

  Future<void> apply(WalletCommand command) async {
    final events = await aggregate.handleCommand(state, command);
    for (final event in events) {
      aggregate.eventHandler(event);
      await projection.handle(event);
    }
  }
}

void main() {
  late TestActorSystem system;
  late InMemoryEventStore store;
  late ChannelRefundFixture f;
  late FixtureWalletManager wallet;
  late RecordingArcActor arc;
  late ActorRef walletRef;
  late ActorRef managerRef;
  late String refundTxId;

  /// The node's header chain: its median time past is what a refund's lock
  /// time is held to (bead libspiffy-lpjh). Now, unless a test moves it.
  late FixedTimeHeaderChain headers;

  setUpAll(LibSpiffyActorSystem.registerEventTypes);

  setUp(() async {
    system = TestActorSystem();
    store = InMemoryEventStore();
    // Past its lockTime: the refund is spendable and the aggregate's expiry
    // guard is satisfied.
    f = await ChannelRefundFixture.create(
      channelId: _channelId,
      lockTimeUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60,
    );
    refundTxId = dartsv.Transaction.fromHex(f.signedRefundTxHex()).id;
    headers = FixedTimeHeaderChain.now();
  });

  tearDown(() async {
    await system.shutdown();
  });

  Future<void> spawn(List<Event> journal,
      {dartsv.SVPrivateKey? key, bool withArc = true}) async {
    if (journal.isNotEmpty) {
      await store.persistEvents('PaymentChannel_$_channelId', journal, 0);
    }
    wallet = FixtureWalletManager(key ?? f.clientKey);
    arc = RecordingArcActor();
    walletRef = await system.spawn('wallet', () => wallet);
    final arcRef = await system.spawn('arc', () => arc);
    managerRef = await system.spawn(
      'manager',
      () => PaymentChannelManagerActor(timing: testChannelTiming, 
        walletManager: walletRef,
        eventStore: store,
        cryptoService: DartSVCryptoService(),
        arcActor: withArc ? arcRef : null,
        headerChain: headers,
        signingTimeout: const Duration(seconds: 2),
      ),
    );
  }

  List<Event> journal() => store.journal['PaymentChannel_$_channelId'] ?? [];

  Future<void> flushWallet() async {
    final probe = await system.createProbe();
    walletRef.tell(
      WalletCommandMessage(
          _walletId, GenerateAddressCommand(walletId: _walletId)),
      sender: probe.ref,
    );
    await probe.expectMsgType<AddressGeneratedResponse>(timeout: _timeout);
  }

  List<RecordImportedTransactionCommand> imported() =>
      wallet.commands.whereType<RecordImportedTransactionCommand>().toList();
  List<ReceiveUTXOCommand> received() =>
      wallet.commands.whereType<ReceiveUTXOCommand>().toList();

  Future<_Wallet> readBack() async {
    final w = await _Wallet.create();
    for (final command in wallet.commands) {
      if (command is RecordImportedTransactionCommand ||
          command is ReceiveUTXOCommand) {
        await w.apply(command);
      }
    }
    return w;
  }

  /// The channel read model as the projection builds it from the journal.
  Future<PaymentChannel?> channelRow() async {
    final storage = InMemoryWalletStorage();
    final projection = ChannelProjection(
      projectionId: 'claim-channel-projection',
      eventStore: InMemoryEventStore(),
      storage: storage,
    );
    for (final event in journal()) {
      await projection.handle(event);
    }
    return storage.getPaymentChannel(_channelId);
  }

  Future<ChannelRefundClaimedResponse> claim({String? refundTxHex}) =>
      managerRef.ask<ChannelRefundClaimedResponse>(
        ClaimRefundMessage(channelId: _channelId, refundTxHex: refundTxHex),
        _timeout,
      );

  Future<ChannelExpiredResponse> expire() =>
      managerRef.ask<ChannelExpiredResponse>(
        ExpireChannelMessage(channelId: _channelId, observedBy: 'client'),
        _timeout,
      );

  group('libspiffy-cqc (b): the refund claim flow', () {
    test('broadcasts the refund, journals the claim, and records the money '
        'coming back', () async {
      await spawn(f.openClientJournal(walletId: _walletId));

      final claimed = await claim();
      expect(claimed.success, isTrue, reason: claimed.error);
      expect(claimed.refundTxId, refundTxId);
      await flushWallet();

      // ARC was asked to broadcast the refund, and nothing else.
      expect(arc.broadcasts, hasLength(1),
          reason: 'the claim is the broadcast; without it the refund is a '
              'transaction nobody has seen');
      expect(arc.broadcasts.single.txid, refundTxId);
      expect(arc.broadcasts.single.txHex, f.signedRefundTxHex());
      expect(arc.broadcasts.single.walletId, _walletId);
      expect(arc.broadcasts.single.retryOnFailure, isFalse,
          reason: 'a failed claim is claimed again by the app; ARC must not queue a second retry (r56l)');

      // The claim is journaled.
      final events = journal().whereType<RefundClaimedEvent>().toList();
      expect(events, hasLength(1));
      expect(events.single.refundTxId, refundTxId);
      expect(events.single.refundAmountSats, f.amountSats);

      // The channel read model shows it.
      final row = (await channelRow())!;
      expect(row.state, PaymentChannelState.expired);
      expect(row.settlementTxId, refundTxId,
          reason: 'the read model names the transaction that claimed it');

      // The wallet holds the refund and its output.
      expect(imported().single.txid, refundTxId);
      expect(imported().single.blockHeight, isNull,
          reason: 'nothing has proved the refund mined');
      expect(received().single.initialStatus, UTXOStatus.pending);

      final w = await readBack();
      final tx = await w.storage.getTransaction(refundTxId, walletId: _walletId);
      expect(tx, isNotNull);
      expect(tx!.status, TransactionStatus.pending);
      final ours = (await w.storage.getUTXOs(_walletId))
          .where((u) => u.txid == refundTxId)
          .toList();
      expect(ours, hasLength(1));
      expect(ours.single.status, UTXOStatus.pending,
          reason: 'an unproven receive is pending, not spendable');
      expect(ours.single.blockHeight, isNull);
    });

    test('the wallet write is journaled, so a resumed claim does not repeat it',
        () async {
      await spawn(f.openClientJournal(walletId: _walletId));

      expect((await claim()).success, isTrue);
      await flushWallet();

      expect(
          journal().whereType<ReturnLegRecordedInWalletEvent>().single.txId,
          refundTxId);
    });
  });

  group('libspiffy-cqc (b): a refund the network refuses is not a claim', () {
    test('a rejected broadcast journals nothing and says so', () async {
      await spawn(f.openClientJournal(walletId: _walletId));
      arc.failWith = 'double spend attempted';

      final claimed = await claim();

      expect(claimed.success, isFalse);
      expect(claimed.error, contains('double spend attempted'));
      expect(claimed.refundTxId, isNull);
      expect(arc.broadcasts, hasLength(1),
          reason: 'first seen wins on BSV: a rejection is a terminal answer, '
              'never a reason to rebroadcast at a higher fee');
      expect(journal().whereType<RefundClaimedEvent>(), isEmpty,
          reason: 'a claim is a claim about the network; nothing the network '
              'refused is journaled as claimed');
      await flushWallet();
      expect(imported(), isEmpty);
      expect(received(), isEmpty);
    });

    // Bead libspiffy-67eo, seen on the localnet regtest ARC: a refund that
    // loses to the server's settlement is answered with HTTP 200 and
    // DOUBLE_SPEND_ATTEMPTED, not with a failure. The client whose
    // channel_closed was lost claimed after the lock time, and the claim was
    // journaled and the whole funding recorded as received.
    test('67eo: a refund ARC answers as a double spend journals nothing and '
        'records nothing', () async {
      await spawn(f.openClientJournal(walletId: _walletId));
      arc.networkStatus = 'DOUBLE_SPEND_ATTEMPTED';

      final claimed = await claim();

      expect(claimed.success, isFalse);
      expect(claimed.error, contains('contested'));
      expect(arc.broadcasts, hasLength(1));
      expect(journal().whereType<RefundClaimedEvent>(), isEmpty);
      await flushWallet();
      expect(imported(), isEmpty,
          reason: 'the settlement spent the funding output; no refund came back');
      expect(received(), isEmpty);
    });

    // The same client, when the settlement was already mined: the node
    // finds the funding output spent in a block, which it cannot tell from
    // an unknown parent, and ARC answers SEEN_IN_ORPHAN_MEMPOOL (bead
    // libspiffy-jh6a, seen on the localnet regtest ARC). That refund is
    // never mined.
    test('jh6a: a refund ARC answers as an orphan journals nothing and '
        'records nothing', () async {
      await spawn(f.openClientJournal(walletId: _walletId));
      arc.networkStatus = 'SEEN_IN_ORPHAN_MEMPOOL';

      final claimed = await claim();

      expect(claimed.success, isFalse);
      expect(claimed.error, contains('orphan'));
      expect(journal().whereType<RefundClaimedEvent>(), isEmpty);
      await flushWallet();
      expect(imported(), isEmpty);
      expect(received(), isEmpty);
    });

    test('a channel holding no fully signed refund claims nothing', () async {
      // Requested, acceptance recorded, refund built — but never
      // countersigned, so the client holds only its own half.
      await spawn([
        ...f.clientJournalWithRefund(),
      ]);

      final claimed = await claim();

      expect(claimed.success, isFalse);
      expect(claimed.error, contains('no fully signed refund'));
      expect(arc.broadcasts, isEmpty,
          reason: 'nothing to broadcast is an absence, not a transaction to '
              'invent');
      expect(journal().whereType<RefundClaimedEvent>(), isEmpty);
    });

    test('a server cannot claim a refund', () async {
      await spawn([
        f.serverAccepted(version: 1),
        RefundCountersignedEvent(
          channelId: _channelId,
          serverSignatureHex: f.serverSignatureHex,
          signedRefundTxHex: f.signedRefundTxHex(),
          version: 2,
        ),
        ChannelOpenedEvent(
          channelId: _channelId,
          fundingTxId: f.fundingTxId,
          fundingOutputIndex: 0,
          fundingTxHex: f.fundingTxHex,
          initialClientBalanceSats: f.amountSats,
          initialServerBalanceSats: BigInt.zero,
          version: 3,
        ),
      ], key: f.serverKey);

      final claimed = await claim();

      expect(claimed.success, isFalse);
      expect(claimed.error, contains('Only client can claim refund'));
      expect(arc.broadcasts, isEmpty,
          reason: 'a claim the channel refuses never reaches the network (1a5k)');
      expect(journal().whereType<RefundClaimedEvent>(), isEmpty);
    });

    test('a channel still inside its lockTime claims nothing', () async {
      final unexpired = await ChannelRefundFixture.create(
        channelId: _channelId,
        lockTimeUnix:
            DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
                1000,
      );
      f = unexpired;
      await spawn(f.openClientJournal(walletId: _walletId));

      final claimed = await claim();

      expect(claimed.success, isFalse);
      expect(claimed.error, contains('Channel not yet expired'));
      // Seen on the localnet regtest node (bead libspiffy-1a5k): the
      // refund went out before the aggregate refused the claim, and ARC and
      // the node's non-final mempool held it while the host heard "failed".
      expect(arc.broadcasts, isEmpty,
          reason: 'a claim the channel refuses never reaches the network');
      expect(journal().whereType<RefundClaimedEvent>(), isEmpty);
    });

    // Bead libspiffy-lpjh: the network holds a refund's lock time to the
    // chain's median time past, which trails the clock (about an hour on
    // mainnet). Claimed on the clock, the refund was accepted by ARC and
    // held by the node as non-final; the server's settlement then evicted it
    // (seen on the localnet regtest node) while ARC went on reporting it
    // seen, and the claim stood journaled and recorded.
    test('lpjh: past the lock time on the clock but not on the chain, nothing '
        'is claimed or broadcast', () async {
      await spawn(f.openClientJournal(walletId: _walletId));
      headers.time =
          DateTime.fromMillisecondsSinceEpoch(f.lockTimeUnix * 1000);

      final claimed = await claim();

      expect(claimed.success, isFalse);
      expect(claimed.error, contains('median time past'));
      expect(arc.broadcasts, isEmpty,
          reason: 'the refund is not final until the median time passes its '
              'lock time; a node holds it only until a final spend arrives');
      expect(journal().whereType<RefundClaimedEvent>(), isEmpty);
    });

    test('lpjh: once the chain\'s median time passes the lock time the refund '
        'is claimed', () async {
      await spawn(f.openClientJournal(walletId: _walletId));
      headers.time =
          DateTime.fromMillisecondsSinceEpoch((f.lockTimeUnix + 1) * 1000);

      final claimed = await claim();

      expect(claimed.success, isTrue, reason: claimed.error);
      expect(arc.broadcasts.single.txid, refundTxId);
    });

    test('lpjh: a node holding no block headers claims nothing', () async {
      await spawn(f.openClientJournal(walletId: _walletId));
      headers.time = null;

      final claimed = await claim();

      expect(claimed.success, isFalse);
      expect(claimed.error, contains('No block headers'));
      expect(arc.broadcasts, isEmpty);
      expect(journal().whereType<RefundClaimedEvent>(), isEmpty);
    });

    test('no broadcaster configured claims nothing', () async {
      await spawn(f.openClientJournal(walletId: _walletId), withArc: false);

      final claimed = await claim();

      expect(claimed.success, isFalse);
      expect(claimed.error, contains('ARC actor'));
      expect(journal().whereType<RefundClaimedEvent>(), isEmpty);
    });
  });

  group('libspiffy-cqc (b): expiry and claim converge on one record', () {
    test('expire, then claim: one wallet row, one RefundClaimedEvent',
        () async {
      await spawn(f.openClientJournal(walletId: _walletId));

      expect((await expire()).success, isTrue);
      await flushWallet();
      expect(imported(), hasLength(1),
          reason: 'the expiry records the refund without broadcasting it');
      expect(arc.broadcasts, isEmpty);

      final claimed = await claim();
      expect(claimed.success, isTrue, reason: claimed.error);
      await flushWallet();

      expect(arc.broadcasts, hasLength(1),
          reason: 'the claim contributes the broadcast the expiry never did');
      expect(imported(), hasLength(1),
          reason: 'the wallet write is journaled, so the claim adds no second '
              'row for the same transaction');
      expect(received(), hasLength(1));
      expect(journal().whereType<RefundClaimedEvent>(), hasLength(1));
      expect(journal().whereType<ChannelExpiredEvent>(), hasLength(1));

      final w = await readBack();
      expect(
          (await w.storage.getTransactionHistory(_walletId))
              .where((t) => t.txid == refundTxId),
          hasLength(1),
          reason: 'the money comes back once, however the ending was reached');
    });

    test('claim, then expire: one wallet row, one RefundClaimedEvent',
        () async {
      await spawn(f.openClientJournal(walletId: _walletId));

      expect((await claim()).success, isTrue);
      await flushWallet();

      // The aggregate refuses to expire a terminated channel; the manager
      // sees the wallet write already journaled and answers without asking.
      final expired = await expire();
      expect(expired.success, isTrue, reason: expired.error);
      await flushWallet();

      expect(imported(), hasLength(1));
      expect(received(), hasLength(1));
      expect(journal().whereType<RefundClaimedEvent>(), hasLength(1));
      expect(journal().whereType<ChannelExpiredEvent>(), isEmpty,
          reason: 'the claim already ended the channel; expiring it again '
              'would journal a second ending for one transaction');

      final row = (await channelRow())!;
      expect(row.state, PaymentChannelState.expired);
      expect(row.settlementTxId, refundTxId);

      final w = await readBack();
      expect(
          (await w.storage.getTransactionHistory(_walletId))
              .where((t) => t.txid == refundTxId),
          hasLength(1),
          reason: 'the money comes back once, however the ending was reached');
    });

    test('a cooperatively closed channel has no refund to claim', () async {
      // Exactly one transaction can ever spend the 2-of-2 funding output
      // (BSV, first seen wins). For a closed channel that is the settlement,
      // so a refund claim over it would both misstate the ending and be a
      // double spend.
      await spawn([
        ...f.openClientJournal(walletId: _walletId),
        ChannelClosingEvent(
          channelId: _channelId,
          initiator: 'client',
          clientBalanceSats: f.amountSats,
          serverBalanceSats: BigInt.zero,
          version: 7,
        ),
        ChannelClosedEvent(
          channelId: _channelId,
          settlementTxId: 'ab' * 32,
          finalClientBalanceSats: f.amountSats,
          finalServerBalanceSats: BigInt.zero,
          version: 8,
        ),
      ]);

      final claimed = await claim();

      expect(claimed.success, isFalse);
      expect(claimed.error, contains('already terminated'));
      expect(arc.broadcasts, isEmpty,
          reason: 'a claim the channel refuses never reaches the network (1a5k)');
      expect(journal().whereType<RefundClaimedEvent>(), isEmpty);
      final row = (await channelRow())!;
      expect(row.state, PaymentChannelState.closed,
          reason: 'a refund claim must not rewrite how the channel ended');
      expect(row.settlementTxId, 'ab' * 32);
    });
  });

  group('libspiffy-cqc (b): the projection keeps the claim', () {
    test('RefundClaimedEvent is handled and names the claiming transaction',
        () async {
      final storage = InMemoryWalletStorage();
      final projection = ChannelProjection(
        projectionId: 'claim-arm',
        eventStore: InMemoryEventStore(),
        storage: storage,
      );
      for (final event in f.openClientJournal(walletId: _walletId)) {
        await projection.handle(event);
      }
      expect((await storage.getPaymentChannel(_channelId))!.settlementTxId,
          isNull);

      final claimedAt = DateTime.utc(2026, 9, 19, 12);
      final handled = await projection.handle(RefundClaimedEvent(
        channelId: _channelId,
        refundTxId: refundTxId,
        refundAmountSats: f.amountSats,
        timestamp: claimedAt,
        version: 7,
      ));

      expect(handled, isTrue,
          reason: 'an event no projection handles is a fact that is journaled '
              'and never reaches anyone reading the channel');
      final row = (await storage.getPaymentChannel(_channelId))!;
      expect(row.state, PaymentChannelState.expired);
      expect(row.settlementTxId, refundTxId);
      expect(row.closedAt!.toUtc(), claimedAt);
      expect(row.refundTxHex, isNotNull,
          reason: 'the retained refund transaction survives the claim');
    });
  });
}

class _NoopEventStore implements EventStore {
  @override
  Future<void> persistEvent(
      String persistenceId, Event event, int expectedVersion) async {}

  @override
  Future<void> persistEvents(
      String persistenceId, List<Event> events, int expectedVersion) async {}

  @override
  Future<List<Event>> getEvents(String persistenceId,
          {int fromSequence = 0, int? toSequence}) async =>
      [];

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) async => 0;

  @override
  Future<void> saveSnapshot(
      String persistenceId, dynamic state, int sequenceNumber) async {}

  @override
  Future<SnapshotData?> loadSnapshot(String persistenceId) async => null;

  @override
  Future<void> deleteOldSnapshots(String persistenceId, int keepCount) async {}

  @override
  Future<void> close() async {}
}
