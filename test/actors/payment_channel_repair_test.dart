/// PaymentChannelManagerActor: repairing an open that did not finish
/// (bead libspiffy-1n3).
///
/// Two things can leave a client-side open unfinished, and each has its own
/// command:
///   * the funding broadcast failed -> [RetryChannelFundingMessage] starts
///     another attempt at the SAME transaction, read from the channel's own
///     state rather than supplied by the caller;
///   * the funding is on the network and the channel is open here, but
///     `channel_open` never reached the server -> [ResendChannelOpenMessage]
///     rebuilds that one message from the journal and journals nothing.
///
/// Both refuse, locally and without touching the journal, every state they
/// do not describe. That matters: driving the ordinary open flow for an
/// already-open channel makes the aggregate throw 'Refund not signed yet',
/// which the P2P adapter reports to the counterparty as `channel_error`.
///
/// Same harness as payment_channel_manager_funding_test.dart: a real channel
/// aggregate over an in-memory journal, [FixtureWalletManager] and
/// [RecordingArcActor].
library;

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:eventador/eventador.dart' show Event;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/payment_channel_manager_actor.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';

import 'channel_test_fixtures.dart';
import 'in_memory_event_store.dart';

const _channelId = 'chan-repair';
const _walletId = 'client-wallet';
const _timeout = Duration(seconds: 10);

void main() {
  late TestActorSystem system;
  late InMemoryEventStore store;
  late ChannelRefundFixture f;
  late FixtureWalletManager wallet;
  late RecordingArcActor arc;
  late ActorRef managerRef;

  setUpAll(LibSpiffyActorSystem.registerEventTypes);

  setUp(() async {
    system = TestActorSystem();
    store = InMemoryEventStore();
    f = await ChannelRefundFixture.create(channelId: _channelId);
  });

  tearDown(() async {
    await system.shutdown();
  });

  Future<void> spawn(List<Event> journal) async {
    if (journal.isNotEmpty) {
      await store.persistEvents('PaymentChannel_$_channelId', journal, 0);
    }
    wallet = FixtureWalletManager(f.clientKey);
    arc = RecordingArcActor();
    final walletRef = await system.spawn('wallet', () => wallet);
    final arcRef = await system.spawn('arc', () => arc);
    managerRef = await system.spawn(
      'manager',
      () => PaymentChannelManagerActor(
        walletManager: walletRef,
        eventStore: store,
        cryptoService: DartSVCryptoService(),
        arcActor: arcRef,
        signingTimeout: const Duration(seconds: 2),
      ),
    );
  }

  List<Event> journal() => store.journal['PaymentChannel_$_channelId'] ?? [];
  List<String> journalTypes() => journal().map((e) => e.typeName).toList();

  /// The public seam: nothing but the channel id.
  Future<ChannelFundingRetriedResponse> retryFunding() =>
      managerRef.ask<ChannelFundingRetriedResponse>(
        RetryChannelFundingMessage(channelId: _channelId),
        _timeout,
      );

  Future<ChannelOpenResentResponse> resendOpen() =>
      managerRef.ask<ChannelOpenResentResponse>(
        ResendChannelOpenMessage(channelId: _channelId),
        _timeout,
      );

  /// Client journal up to the verified, countersigned refund: the channel is
  /// in `refundSigned`, waiting for its funding broadcast.
  List<Event> countersigned() =>
      f.openClientJournal(walletId: _walletId).take(4).toList();

  /// Client journal of an open channel, with the BEEF the opening journaled.
  List<Event> opened({String? fundingBeefHex = 'beef00'}) => [
        ...countersigned(),
        FundingBroadcastStartedEvent(
            channelId: _channelId,
            fundingTxId: f.fundingTxId,
            attempt: 1,
            version: 5),
        FundingRecordedInWalletEvent(
            channelId: _channelId, fundingTxId: f.fundingTxId, version: 6),
        ChannelOpenedEvent(
          channelId: _channelId,
          fundingTxId: f.fundingTxId,
          fundingOutputIndex: 0,
          fundingTxHex: f.fundingTxHex,
          initialClientBalanceSats: f.amountSats,
          initialServerBalanceSats: BigInt.zero,
          fundingBeefHex: fundingBeefHex,
          version: 7,
        ),
      ];

  group('retrying a failed funding broadcast', () {
    test(
        'the channel id alone re-broadcasts the same transaction, records the '
        'funding once and opens', () async {
      await spawn(countersigned());
      arc.failWith = 'ARC unavailable';

      final failed = await retryFunding();

      expect(failed.success, isFalse);
      expect(failed.error, contains('ARC unavailable'));
      expect(failed.fundingTxId, f.fundingTxId,
          reason: 'the funding transaction is read from the channel, not '
              'supplied by the caller');
      expect(journalTypes().last, FundingBroadcastFailedEvent.stableTypeName);
      expect(journal().whereType<ChannelOpenedEvent>(), isEmpty);
      expect(wallet.commands.whereType<SpendUTXOCommand>(), isEmpty,
          reason: 'the inputs stay reserved for this funding transaction');

      arc.failWith = null;
      final retried = await retryFunding();

      expect(retried.success, isTrue, reason: retried.error);
      expect(retried.fundingTxId, f.fundingTxId);
      expect(
          arc.broadcasts.map((b) => b.txHex), [f.fundingTxHex, f.fundingTxHex],
          reason: 'the same transaction, twice: there is no replace-by-fee');
      expect(wallet.commands.whereType<RecordOutgoingTransactionCommand>(),
          hasLength(1));
      // Spending the inputs is ARCActor's deferred spend, not the channel's
      // (bead libspiffy-tg4d).
      expect(wallet.commands.whereType<SpendUTXOCommand>(), isEmpty);
      expect(
          journal()
              .whereType<FundingBroadcastStartedEvent>()
              .map((e) => e.attempt),
          [1, 2]);
      expect(journalTypes().last, ChannelOpenedEvent.stableTypeName);
    });

    test('an already-open channel is refused, and nothing is journaled or '
        'broadcast', () async {
      await spawn(opened());
      final before = journalTypes();

      final response = await retryFunding();

      expect(response.success, isFalse);
      expect(response.error, contains('is not waiting for its funding'));
      expect(response.error, contains('status=open'));
      expect(response.error, contains('ResendChannelOpenCommand'),
          reason: 'the refusal names the command that does what the host '
              'was trying to do');
      expect(arc.broadcasts, isEmpty);
      expect(wallet.commands, isEmpty);
      expect(journalTypes(), before);
    });

    test('a channel with no journal is refused without spawning one for it',
        () async {
      await spawn(const []);

      final response = await retryFunding();

      expect(response.success, isFalse);
      expect(response.error, contains('Channel not found'));
      expect(journal(), isEmpty);
      expect(arc.broadcasts, isEmpty);
    });
  });

  group('re-sending channel_open', () {
    test('rebuilds the payload from the journal and journals nothing',
        () async {
      await spawn(opened());
      final before = journalTypes();

      final response = await resendOpen();

      expect(response.success, isTrue, reason: response.error);
      expect(response.channelId, _channelId);
      expect(response.walletId, _walletId);
      expect(response.fundingTxId, f.fundingTxId);
      expect(response.fundingOutputIndex, 0);
      expect(response.fundingTxHex, f.fundingTxHex);
      expect(response.fundingBeefHex, 'beef00',
          reason: 'the BEEF the server SPV-validates travels again');
      expect(journalTypes(), before,
          reason: 'a re-send is not a new fact about the channel');
      expect(journal().whereType<ChannelOpenedEvent>(), hasLength(1));
      expect(arc.broadcasts, isEmpty);
      expect(wallet.commands, isEmpty);
    });

    test('a channel still waiting for its funding is refused, and nothing is '
        'journaled', () async {
      await spawn(countersigned());
      final before = journalTypes();

      final response = await resendOpen();

      expect(response.success, isFalse);
      expect(response.error, contains('is not open here'));
      expect(response.error, contains('status=refundSigned'));
      expect(response.error, contains('RetryChannelFundingCommand'),
          reason: 'the refusal names the command that does what the host '
              'was trying to do');
      expect(response.fundingTxHex, isNull);
      expect(journalTypes(), before);
      expect(arc.broadcasts, isEmpty);
    });

    test('an open channel without a journaled BEEF says so rather than '
        'inventing one', () async {
      await spawn(opened(fundingBeefHex: null));

      final response = await resendOpen();

      expect(response.success, isTrue, reason: response.error);
      expect(response.fundingBeefHex, isNull);
      expect(response.fundingTxHex, f.fundingTxHex);
    });

    test('a channel with no journal is refused', () async {
      await spawn(const []);

      final response = await resendOpen();

      expect(response.success, isFalse);
      expect(response.error, contains('Channel not found'));
      expect(journal(), isEmpty);
    });
  });

  /// The other end of a re-send: the channel_open the client repeats
  /// arrives at a server that may already have opened. Answering that with
  /// a rejection sends the client `channel_error` — the message that says
  /// the channel was abandoned — so a repeat of a fact already recorded is
  /// answered as the no-op it is.
  group('a repeated open of the same funding output', () {
    Future<ChannelOpenedResponse> openAgain(int outputIndex) =>
        managerRef.ask<ChannelOpenedResponse>(
          OpenChannelMessage(
            channelId: _channelId,
            fundingTxId: f.fundingTxId,
            fundingOutputIndex: outputIndex,
            fundingTxHex: f.fundingTxHex,
          ),
          _timeout,
        );

    test('is answered without journaling or broadcasting anything again',
        () async {
      await spawn(opened());
      final before = journalTypes();

      final again = await openAgain(0);

      expect(again.success, isTrue, reason: again.error);
      expect(journalTypes(), before,
          reason: 'the channel opened once; a repeat is not a second opening');
      expect(arc.broadcasts, isEmpty);
      expect(wallet.commands, isEmpty);
    });

    test('naming a different funding output is still refused', () async {
      await spawn(opened());
      final before = journalTypes();

      final again = await openAgain(1);

      expect(again.success, isFalse,
          reason: 'a different output is a different claim about the channel');
      expect(journalTypes(), before);
      expect(arc.broadcasts, isEmpty);
    });
  });

  group('the server side of a channel repairs neither', () {
    test('the server cannot retry a funding broadcast or re-send '
        'channel_open', () async {
      await spawn([f.serverAccepted(version: 1)]);

      final retried = await retryFunding();
      expect(retried.success, isFalse);
      expect(retried.error, contains('Only the client'));

      final resent = await resendOpen();
      expect(resent.success, isFalse);
      expect(resent.error, contains('Only the client'));
      expect(arc.broadcasts, isEmpty);
    });
  });
}
