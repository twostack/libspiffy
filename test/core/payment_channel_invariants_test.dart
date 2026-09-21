/// Payment-channel seam, pass 1: two invariants the aggregate could not
/// enforce.
///
/// * Bead libspiffy-ubl0. `_handleAcknowledgePayment` (the server half)
///   guards that both proposed balances are non-negative and that they sum
///   to the funding amount. `_handleRecordPayment` (the client half) guarded
///   neither, so the two halves of one protocol disagreed about what a valid
///   payment is.
/// * Bead libspiffy-07mx. Nothing in `ChannelState` recorded that a refund
///   had been claimed, so the aggregate had nothing to test and a second
///   `ClaimRefundCommand` journaled a second `RefundClaimedEvent`. The
///   status cannot stand in for it: `_applyRefundClaimed` sets `expired`,
///   and `expired` must stay claimable because expire-then-claim is the
///   required convergence path (V-86).
library;

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/core/channel_commands.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/core/channel_state.dart';
import 'package:libspiffy/src/core/payment_channel_aggregate.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';

import '../actors/channel_test_fixtures.dart';
import '../actors/in_memory_event_store.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/models/fee_rate.dart';

const _channelId = 'channel-invariants';
const _persistenceId = 'PaymentChannel_$_channelId';
const _ask = Duration(seconds: 5);

/// The aggregate applied the command: its own reply, successful. The events
/// it carries may be empty -- an idempotent repeat journals nothing
/// (libspiffy-y8x3).
final _applied =
    isA<ChannelCommandResult>().having((r) => r.success, 'success', isTrue);

void main() {
  late InMemoryEventStore store;
  late TestActorSystem system;
  /// A channel whose lock time is still in the future: payments are live.
  late ChannelRefundFixture f;

  /// The same channel past its lock time, so a refund can be claimed.
  late ChannelRefundFixture expired;
  var spawned = 0;

  setUpAll(LibSpiffyActorSystem.registerEventTypes);

  setUp(() async {
    store = InMemoryEventStore();
    system = TestActorSystem();
    f = await ChannelRefundFixture.create(channelId: _channelId);
    expired = await ChannelRefundFixture.create(
      channelId: _channelId,
      lockTimeUnix: DateTime.now()
              .subtract(const Duration(days: 1))
              .millisecondsSinceEpoch ~/
          1000,
    );
  });

  tearDown(() async => system.shutdown());

  Future<ActorRef> spawn(List<Event> journal) async {
    if (journal.isNotEmpty) {
      await store.persistEvents(_persistenceId, journal, 0);
    }
    return system.spawn(
      'channel-${spawned++}',
      () => PaymentChannelAggregate(
        aggregateId: _channelId,
        eventStore: store,
        cryptoService: DartSVCryptoService(),
      ),
    );
  }

  List<Event> journal() => store.journal[_persistenceId] ?? const [];

  void expectRejected(dynamic reply, Matcher errorMatcher) {
    expect(reply, isA<ChannelCommandResult>(), reason: 'expected a rejection, got $reply');
    expect((reply as ChannelCommandResult).success, isFalse);
    expect(reply.error, errorMatcher);
  }

  group('a payment keeps the channel whole, on both sides (libspiffy-ubl0)',
      () {
    test('the client refuses balances that do not sum to the funding amount',
        () async {
      final ref = await spawn(f.openClientJournal());

      // Arithmetic that is self-consistent about the amount and still
      // impossible: 100 000 went in, 99 000 is accounted for. The server's
      // own handler has refused this shape since audit M10.
      final reply = await ref.ask<dynamic>(
        RecordPaymentCommand(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          channelId: _channelId,
          amountSats: BigInt.from(1000),
          newClientBalanceSats: BigInt.from(98000),
          newServerBalanceSats: BigInt.from(1000),
          sequenceNumber: 1,
          paymentTxHex: '0100000000',
          paymentTxId: 'aa' * 32,
          clientSignatureHex: 'ab',
        ),
        _ask,
      );

      expectRejected(
          reply, allOf(contains('sum'), contains(f.amountSats.toString())));
      expect(journal().whereType<PaymentRecordedEvent>(), isEmpty);
    });

    test('both halves refuse the SAME payment for the same reason', () async {
      // The bead's actual complaint: one protocol, two handlers, two
      // different ideas of what a valid payment is. The server has refused
      // this shape since audit M10; the client did not.
      const bad = (amount: 1000, client: 98000, server: 1000);

      final client = await spawn(f.openClientJournal());
      final clientReply = await client.ask<dynamic>(
        RecordPaymentCommand(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          channelId: _channelId,
          amountSats: BigInt.from(bad.amount),
          newClientBalanceSats: BigInt.from(bad.client),
          newServerBalanceSats: BigInt.from(bad.server),
          sequenceNumber: 1,
          paymentTxHex: '0100000000',
          paymentTxId: 'aa' * 32,
          clientSignatureHex: 'ab',
        ),
        _ask,
      );

      store.journal.clear();
      final server = await spawn(_openServerChannel(f));
      final serverReply = await server.ask<dynamic>(
        AcknowledgePaymentCommand(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          channelId: _channelId,
          amountSats: BigInt.from(bad.amount),
          paymentTxHex: '00',
          clientSignatureHex: '30' * 36,
          serverSignatureHex: '30' * 36,
          fullySignedPaymentTxHex: '',
          proposedSequence: 1,
          proposedClientBalance: BigInt.from(bad.client),
          proposedServerBalance: BigInt.from(bad.server),
        ),
        _ask,
      );

      expectRejected(clientReply,
          allOf(contains('sum'), contains(f.amountSats.toString())));
      expectRejected(serverReply,
          allOf(contains('sum'), contains(f.amountSats.toString())));
      expect((clientReply as ChannelCommandResult).error, (serverReply as ChannelCommandResult).error,
          reason: 'one statement of the rule, so one answer: the two halves '
              'of a protocol must not disagree about what is valid');
    });

    test('a payment that keeps the channel whole is recorded', () async {
      final ref = await spawn(f.openClientJournal());

      final reply = await ref.ask<dynamic>(
        RecordPaymentCommand(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          channelId: _channelId,
          amountSats: BigInt.from(1000),
          newClientBalanceSats: f.amountSats - BigInt.from(1000),
          newServerBalanceSats: BigInt.from(1000),
          sequenceNumber: 1,
          paymentTxHex: channelPaymentTxHex(
            fundingTxId: f.fundingTxId,
            serverAddress: f.serverAddressB58,
            clientAddress: f.clientAddressB58,
            server: BigInt.from(1000),
            client: f.amountSats - BigInt.from(1000),
          ),
          paymentTxId: 'aa' * 32,
          clientSignatureHex: 'ab',
        ),
        _ask,
      );

      expect(reply, _applied, reason: '$reply');
      final recorded = journal().whereType<PaymentRecordedEvent>().single;
      expect(recorded.newClientBalanceSats, f.amountSats - BigInt.from(1000));
      expect(recorded.newServerBalanceSats, BigInt.from(1000));
    });

    // Bead libspiffy-zj20: the server countersigns only a transaction that
    // pays the balances; the client, by the same rule, journals only one.
    test('zj20: a payment whose transaction does not pay its balances is not recorded', () async {
      final ref = await spawn(f.openClientJournal());

      final reply = await ref.ask<dynamic>(
        RecordPaymentCommand(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
          channelId: _channelId,
          amountSats: BigInt.from(1000),
          newClientBalanceSats: f.amountSats - BigInt.from(1000),
          newServerBalanceSats: BigInt.from(1000),
          sequenceNumber: 1,
          paymentTxHex: channelPaymentTxHex(
            fundingTxId: f.fundingTxId,
            serverAddress: f.serverAddressB58,
            clientAddress: f.clientAddressB58,
            server: BigInt.from(999),
            client: f.amountSats - BigInt.from(1000),
          ),
          paymentTxId: 'aa' * 32,
          clientSignatureHex: 'ab',
        ),
        _ask,
      );

      expectRejected(reply, allOf(contains('pays the server 999'), contains('1000')));
      expect(journal().whereType<PaymentRecordedEvent>(), isEmpty);
    });
  });

  group('a repeated inbound protocol message is a repeat (libspiffy-y8x3)',
      () {
    test('a second channel_accept naming the same server journals nothing',
        () async {
      final ref = await spawn([f.requested(version: 1)]);

      final first = await ref.ask<dynamic>(
          RecordServerAcceptanceCommand(
            channelId: _channelId,
            serverPubKeyHex: f.serverPubKeyHex,
            serverAddressB58: f.serverAddressB58,
          ),
          _ask);
      expect(first, _applied, reason: '$first');
      expect(journal().whereType<ServerAcceptanceRecordedEvent>(),
          hasLength(1));

      // The server was not sure the first one arrived -- the very reason a
      // re-send exists. It must not be told the channel failed.
      final second = await ref.ask<dynamic>(
          RecordServerAcceptanceCommand(
            channelId: _channelId,
            serverPubKeyHex: f.serverPubKeyHex,
            serverAddressB58: f.serverAddressB58,
          ),
          _ask);

      expect(second, _applied,
          reason: 'a repeat naming the same acceptance is answered, not '
              'refused: $second');
      expect(journal().whereType<ServerAcceptanceRecordedEvent>(),
          hasLength(1));
    });

    test('a second channel_accept naming DIFFERENT keys is still refused',
        () async {
      final ref = await spawn([f.requested(version: 1)]);
      await ref.ask<dynamic>(
          RecordServerAcceptanceCommand(
            channelId: _channelId,
            serverPubKeyHex: f.serverPubKeyHex,
            serverAddressB58: f.serverAddressB58,
          ),
          _ask);

      final reply = await ref.ask<dynamic>(
          RecordServerAcceptanceCommand(
            channelId: _channelId,
            serverPubKeyHex: '02${'99' * 32}',
            serverAddressB58: f.serverAddressB58,
          ),
          _ask);

      expectRejected(reply, contains('already accepted'));
      expect(journal().whereType<ServerAcceptanceRecordedEvent>(),
          hasLength(1),
          reason: 'the guard stays narrow: a DIFFERENT fact is not a repeat');
    });

    test('a second refund_signed records nothing and does not refuse',
        () async {
      final ref = await spawn([
        f.requested(version: 1),
        f.serverAcceptance(version: 2),
        f.refundBuilt(version: 3),
      ]);

      final first = await ref.ask<dynamic>(
          ProvideRefundSignatureCommand(
            channelId: _channelId,
            serverSignatureHex: f.serverSignatureHex,
          ),
          _ask);
      expect(first, _applied, reason: '$first');
      expect(journal().whereType<RefundCountersignedEvent>(), hasLength(1));

      final second = await ref.ask<dynamic>(
          ProvideRefundSignatureCommand(
            channelId: _channelId,
            serverSignatureHex: f.serverSignatureHex,
          ),
          _ask);

      expect(second, _applied,
          reason: 'the old status guard refused this, and the adapter told '
              'the peer channel_error: $second');
      expect(journal().whereType<RefundCountersignedEvent>(), hasLength(1));
    });

    test('a bad second refund signature cannot destroy the good one',
        () async {
      final ref = await spawn([
        f.requested(version: 1),
        f.serverAcceptance(version: 2),
        f.refundBuilt(version: 3),
      ]);
      await ref.ask<dynamic>(
          ProvideRefundSignatureCommand(
            channelId: _channelId,
            serverSignatureHex: f.serverSignatureHex,
          ),
          _ask);
      final good = journal().whereType<RefundCountersignedEvent>().single;

      await ref.ask<dynamic>(
          ProvideRefundSignatureCommand(
            channelId: _channelId,
            serverSignatureHex: await f.forgedServerSignature(),
          ),
          _ask);

      expect(journal().whereType<RefundCountersignedEvent>().single
          .signedRefundTxHex, good.signedRefundTxHex,
          reason: 'nothing is journaled on the repeat path at all, so a '
              'signature that would not verify cannot replace the refund '
              'the client already holds');
    });
  });

  group('a refund is claimed once (libspiffy-07mx)', () {
    /// The refund that the open client journal already holds, fully signed.
    String signedRefund() => expired.signedRefundTxHex();

    test('a repeated claim of the SAME refund journals nothing twice',
        () async {
      final ref = await spawn(expired.openClientJournal());

      final first = await ref.ask<dynamic>(
          ClaimRefundCommand(
              channelId: _channelId, refundTxHex: signedRefund()),
          _ask);
      expect(first, _applied, reason: '$first');
      final claimed = journal().whereType<RefundClaimedEvent>().single;

      // A retry: the app did not hear the first answer. The same transaction
      // is the same ending, so it must be idempotent, not a second ending.
      final second = await ref.ask<dynamic>(
          ClaimRefundCommand(
              channelId: _channelId, refundTxHex: signedRefund()),
          _ask);

      expect(journal().whereType<RefundClaimedEvent>(), hasLength(1),
          reason: 'the journal is the permanent record; a channel ends once');
      expect(second, _applied,
          reason: 'a repeat of the same claim is answered, not refused: '
              'the money did come back');
      expect(claimed.refundTxId, isNotEmpty);
    });

    test('a second claim naming a DIFFERENT transaction is refused', () async {
      final ref = await spawn(expired.openClientJournal());

      await ref.ask<dynamic>(
          ClaimRefundCommand(
              channelId: _channelId, refundTxHex: signedRefund()),
          _ask);
      final claimed = journal().whereType<RefundClaimedEvent>().single;

      // Another transaction spending the same funding output. Only one of
      // the two can ever be true (BSV, first seen wins), so the journal must
      // not assert the channel ended twice with two different transactions.
      final other = dartsv.Transaction.fromHex(signedRefund());
      other.outputs[0] = dartsv.TransactionOutput(
          other.outputs[0].satoshis - BigInt.from(17), other.outputs[0].script);
      final otherHex = other.serialize();
      expect(dartsv.Transaction.fromHex(otherHex).id, isNot(claimed.refundTxId),
          reason: 'sanity: the second really is a different transaction');

      final reply = await ref.ask<dynamic>(
          ClaimRefundCommand(channelId: _channelId, refundTxHex: otherHex),
          _ask);

      expectRejected(reply,
          allOf(contains('already claimed'), contains(claimed.refundTxId)));
      expect(journal().whereType<RefundClaimedEvent>(), hasLength(1));
    });

    test('an expiry observed first still lets the claim through', () async {
      // The convergence path V-86 exists for: the expiry records the refund
      // without broadcasting it, and the claim is what carries the
      // broadcast. `expired` must therefore stay claimable.
      final ref = await spawn([
        ...expired.openClientJournal(),
        ChannelExpiredEvent(
            channelId: _channelId, observedBy: 'test', version: 7),
      ]);

      final reply = await ref.ask<dynamic>(
          ClaimRefundCommand(
              channelId: _channelId, refundTxHex: signedRefund()),
          _ask);

      expect(reply, _applied, reason: '$reply');
      expect(journal().whereType<RefundClaimedEvent>(), hasLength(1));
    });

    test('the claim survives a snapshot and replay', () async {
      // A field the snapshot drops is a guard that stops working after the
      // first restart, which is exactly when a retry is likely.
      final ref = await spawn(expired.openClientJournal());
      await ref.ask<dynamic>(
          ClaimRefundCommand(
              channelId: _channelId, refundTxHex: signedRefund()),
          _ask);
      final claimed = journal().whereType<RefundClaimedEvent>().single;

      final aggregate = PaymentChannelAggregate(
        aggregateId: _channelId,
        eventStore: store,
        cryptoService: DartSVCryptoService(),
      );
      final state = ChannelState(
        channelId: _channelId,
        refundClaimedTxId: claimed.refundTxId,
        version: 7,
        lastModified: DateTime.now(),
      );
      final restored = await aggregate.restoreStateFromMap(
          PaymentChannelAggregate.channelStateToMap(state), 7);

      expect(restored.refundClaimedTxId, claimed.refundTxId);
    });
  });
}

/// Journal of a SERVER-side channel that is open with the whole balance on
/// the client, built from the same fixture keys as the client journal.
List<Event> _openServerChannel(ChannelRefundFixture f) => [
      f.serverAccepted(version: 1),
      RefundCountersignedEvent(
          channelId: _channelId,
          serverSignatureHex: f.serverSignatureHex,
          version: 2),
      ChannelOpenedEvent(
        channelId: _channelId,
        fundingTxId: f.fundingTxId,
        fundingOutputIndex: 0,
        fundingTxHex: f.fundingTxHex,
        initialClientBalanceSats: f.amountSats,
        initialServerBalanceSats: BigInt.zero,
        version: 3,
      ),
    ];
