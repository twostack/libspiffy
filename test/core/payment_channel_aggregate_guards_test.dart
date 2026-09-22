/// Audit 2026-09-14, payment-channel aggregate guards:
///
/// * M10 (libspiffy-qxv): the server accepted any proposed balances in
///   AcknowledgePaymentCommand (no client + server == funding, no
///   server == previous + amount check), and ProvideRefundSignatureCommand
///   had no status or role guard.
/// * L3 (libspiffy-w5i): ChannelStateQuery on a channel with no events threw
///   inside the actor instead of replying, so the ask timed out.
/// * L4 (libspiffy-8d8): ClaimRefundCommand journaled the placeholder
///   refundTxId 'pending-broadcast' instead of the refund transaction's txid.
library;

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/core/channel_commands.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/core/payment_channel_aggregate.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';

import '../actors/channel_test_fixtures.dart';
import '../actors/in_memory_event_store.dart';
import 'package:libspiffy/src/models/fee_rate.dart';

const _channelId = 'channel-guards';
const _persistenceId = 'PaymentChannel_$_channelId';
const _ask = Duration(seconds: 3);
final _funding = BigInt.from(100000);
// Real keys: a payment's fee is checked against the signed size of a spend
// of their 2-of-2 (bead libspiffy-zs4l), which needs points on the curve.
final _clientKey = dartsv.SVPrivateKey.fromHex('11' * 32, dartsv.NetworkType.TEST);
final _clientPub = _clientKey.publicKey.toHex();
final _serverPub = dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST).publicKey.toHex();
const _clientAddress = 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt';
const _serverAddress = 'n2eMqTT929pb1RDNuqEnxdaLau1rxy3efi';
final _fundingTxId = 'f1' * 32;

int _nowUnix() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

ChannelRequestedEvent _requested({required int lockTimeUnix}) =>
    ChannelRequestedEvent(
      channelId: _channelId,
      walletId: 'wallet',
      clientPeerId: 'client-peer',
      serverPeerId: 'server-peer',
      clientPubKeyHex: _clientPub,
      clientAddressB58: _clientAddress,
      derivationIndex: 0,
      fundingAmountSats: _funding,
      lockTimeUnix: lockTimeUnix,
      version: 1,
    );

ServerAcceptanceRecordedEvent _serverAcceptanceRecorded() =>
    ServerAcceptanceRecordedEvent(
      channelId: _channelId,
      serverPubKeyHex: _serverPub,
      serverAddressB58: _serverAddress,
      version: 2,
    );

ChannelAcceptedEvent _accepted() => ChannelAcceptedEvent(
      channelId: _channelId,
      walletId: 'wallet',
      clientPeerId: 'client-peer',
      clientPubKeyHex: _clientPub,
      clientAddressB58: _clientAddress,
      serverPubKeyHex: _serverPub,
      serverAddressB58: _serverAddress,
      derivationIndex: 0,
      fundingAmountSats: _funding,
      lockTimeUnix: _nowUnix() + 86400,
      version: 1,
    );

/// Journal of a server-side channel that is open with balances
/// client = funding, server = 0.
List<Event> _openServerChannel() => [
      _accepted(),
      RefundCountersignedEvent(
          channelId: _channelId, serverSignatureHex: '30' * 36, version: 2),
      ChannelOpenedEvent(
        channelId: _channelId,
        fundingTxId: _fundingTxId,
        fundingOutputIndex: 0,
        fundingTxHex: '',
        initialClientBalanceSats: _funding,
        initialServerBalanceSats: BigInt.zero,
        version: 3,
      ),
    ];

AcknowledgePaymentCommand _ack({
  required int amount,
  required int client,
  required int server,
  int sequence = 1,
}) {
  final paymentTxHex = channelPaymentTxHex(
    fundingTxId: _fundingTxId,
    serverAddress: _serverAddress,
    clientAddress: _clientAddress,
    server: BigInt.from(server),
    client: BigInt.from(client),
  );
  return AcknowledgePaymentCommand(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
      channelId: _channelId,
      amountSats: BigInt.from(amount),
      paymentTxHex: paymentTxHex,
      // The client's real signature (bead libspiffy-c5zw).
      clientSignatureHex: channelClientSignature(paymentTxHex,
          clientKey: _clientKey, serverPubKey: dartsv.SVPublicKey.fromHex(_serverPub), fundingSats: _funding),
      serverSignatureHex: '30' * 36,
      fullySignedPaymentTxHex: '',
      proposedSequence: sequence,
      proposedClientBalance: BigInt.from(client),
      proposedServerBalance: BigInt.from(server),
    );
}

/// Journal of a client-side channel that is open with balances
/// client = funding, server = 0 (the client journals its own request).
List<Event> _openClientChannel() => [
      _requested(lockTimeUnix: _nowUnix() + 86400),
      _serverAcceptanceRecorded(),
      RefundCountersignedEvent(
          channelId: _channelId, serverSignatureHex: '30' * 36, version: 3),
      ChannelOpenedEvent(
        channelId: _channelId,
        fundingTxId: _fundingTxId,
        fundingOutputIndex: 0,
        fundingTxHex: '',
        initialClientBalanceSats: _funding,
        initialServerBalanceSats: BigInt.zero,
        version: 4,
      ),
    ];

RecordPaymentCommand _record({
  required int amount,
  required int client,
  required int server,
  int sequence = 1,
}) =>
    RecordPaymentCommand(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
      channelId: _channelId,
      amountSats: BigInt.from(amount),
      sequenceNumber: sequence,
      paymentTxHex: channelPaymentTxHex(
        fundingTxId: _fundingTxId,
        serverAddress: _serverAddress,
        clientAddress: _clientAddress,
        server: BigInt.from(server),
        client: BigInt.from(client),
      ),
      paymentTxId: 'ab' * 32,
      clientSignatureHex: '30' * 36,
      newClientBalanceSats: BigInt.from(client),
      newServerBalanceSats: BigInt.from(server),
    );

/// The aggregate applied the command: its own reply, successful. The events
/// it carries may be empty -- an idempotent repeat journals nothing
/// (libspiffy-y8x3).
final _applied =
    isA<ChannelCommandResult>().having((r) => r.success, 'success', isTrue);

void main() {
  late InMemoryEventStore store;
  late TestActorSystem system;
  var spawned = 0;

  setUp(() {
    store = InMemoryEventStore();
    system = TestActorSystem();
  });

  tearDown(() async {
    await system.shutdown();
  });

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

  int journalLength() => store.journal[_persistenceId]?.length ?? 0;

  void expectRejected(dynamic reply, String errorFragment) {
    expect(reply, isA<ChannelCommandResult>(),
        reason: 'the command must be rejected with the failure reply, '
            'got $reply');
    expect((reply as ChannelCommandResult).success, isFalse);
    expect(reply.error, contains(errorFragment));
  }

  group('M10: AcknowledgePaymentCommand balance invariants', () {
    test('rejects proposed balances that do not sum to the funding amount',
        () async {
      final ref = await spawn(_openServerChannel());
      // server == previous + amount, but the client was not debited.
      final reply = await ref.ask<dynamic>(
          _ack(amount: 1000, client: 100000, server: 1000), _ask);
      expectRejected(reply, 'funding amount');
      expect(journalLength(), 3);
    });

    test('rejects a server balance that is not previous + amount', () async {
      final ref = await spawn(_openServerChannel());
      // Sums to funding, but the server claims 2000 for a 1000 payment.
      final reply = await ref.ask<dynamic>(
          _ack(amount: 1000, client: 98000, server: 2000), _ask);
      // The refusal names what a 1000 payment implies for BOTH sides rather
      // than only the first mismatch it met (bead libspiffy-ubl0): this
      // scenario has the client wrong too, and the old message said so for
      // whichever side the handler happened to check first.
      expectRejected(reply, 'expected client 99000 / server 1000');
      expect(journalLength(), 3);
    });

    test('rejects a non-positive payment amount', () async {
      final ref = await spawn([
        ..._openServerChannel(),
        PaymentAcknowledgedEvent(
          channelId: _channelId,
          amountSats: BigInt.from(5000),
          sequenceNumber: 1,
          newClientBalanceSats: BigInt.from(95000),
          newServerBalanceSats: BigInt.from(5000),
          fullySignedPaymentTxHex: '',
          serverSignatureHex: '30' * 36,
          version: 4,
        ),
      ]);
      // A "payment" that moves 1000 back from the server to the client.
      final reply = await ref.ask<dynamic>(
          _ack(amount: -1000, client: 96000, server: 4000, sequence: 2),
          _ask);
      expectRejected(reply, 'positive');
      expect(journalLength(), 4);
    });

    test('accepts balances that satisfy both invariants', () async {
      final ref = await spawn(_openServerChannel());
      final reply = await ref.ask<dynamic>(
          _ack(amount: 1000, client: 99000, server: 1000), _ask);
      expect(reply, _applied, reason: '$reply');
      final event = (reply as ChannelCommandResult).events.single as PaymentAcknowledgedEvent;
      expect(event.newServerBalanceSats, BigInt.from(1000));
      expect(journalLength(), 4);
    });
  });

  group('kyw: RecordPaymentCommand amount', () {
    test('rejects a payment of zero', () async {
      final ref = await spawn(_openClientChannel());
      final reply = await ref.ask<dynamic>(
          _record(amount: 0, client: 100000, server: 0), _ask);
      expectRejected(reply, 'positive');
      expect(journalLength(), 4,
          reason: 'a payment that moves nothing is journaled as nothing');
    });

    test('rejects a payment of a negative amount, which every other guard '
        'lets through', () async {
      final ref = await spawn([
        ..._openClientChannel(),
        PaymentRecordedEvent(
          channelId: _channelId,
          amountSats: BigInt.from(5000),
          newClientBalanceSats: BigInt.from(95000),
          newServerBalanceSats: BigInt.from(5000),
          sequenceNumber: 1,
          paymentTxHex: '00',
          paymentTxId: 'ab' * 32,
          clientSignatureHex: '30' * 36,
          version: 5,
        ),
      ]);
      // Balances that match the arithmetic exactly: the "payment" moves
      // 6000 sats back from the server, which holds 5000, to the client.
      final reply = await ref.ask<dynamic>(
          _record(amount: -6000, client: 101000, server: -1000, sequence: 2),
          _ask);
      expectRejected(reply, 'positive');
      expect(journalLength(), 5,
          reason: 'the client cannot claw back what it paid by journaling a '
              'negative payment');
    });

    test('a positive payment is still recorded', () async {
      final ref = await spawn(_openClientChannel());
      final reply = await ref.ask<dynamic>(
          _record(amount: 1000, client: 99000, server: 1000), _ask);
      expect(reply, _applied, reason: '$reply');
      final event = (reply as ChannelCommandResult).events.single as PaymentRecordedEvent;
      expect(event.amountSats, BigInt.from(1000));
      expect(event.newServerBalanceSats, BigInt.from(1000));
      expect(journalLength(), 5);
    });
  });

  group('M10: ProvideRefundSignatureCommand guards', () {
    ProvideRefundSignatureCommand provide() => ProvideRefundSignatureCommand(
        channelId: _channelId, serverSignatureHex: '30' * 36);

    test('is rejected on the server side of a channel', () async {
      final ref = await spawn([_accepted()]);
      final reply = await ref.ask<dynamic>(provide(), _ask);
      expectRejected(reply, 'client');
      expect(journalLength(), 1);
    });

    test('is rejected before the server accepted the channel', () async {
      final ref = await spawn([_requested(lockTimeUnix: _nowUnix() + 86400)]);
      final reply = await ref.ask<dynamic>(provide(), _ask);
      expectRejected(reply, 'accepted');
      expect(journalLength(), 1);
    });

    test('is rejected once the refund is already countersigned', () async {
      final ref = await spawn([
        _requested(lockTimeUnix: _nowUnix() + 86400),
        _serverAcceptanceRecorded(),
        RefundCountersignedEvent(
            channelId: _channelId, serverSignatureHex: '30' * 36, version: 3),
      ]);
      final reply = await ref.ask<dynamic>(provide(), _ask);
      expectRejected(reply, 'accepted');
      expect(journalLength(), 3);
    });

    test('is accepted by the client of an accepted channel whose refund the '
        'signature completes', () async {
      // The signature must complete the journaled refund (libspiffy-b83), so
      // this channel has real keys and a real refund.
      final fixture = await ChannelRefundFixture.create(channelId: _channelId);
      final ref = await spawn(fixture.clientJournalWithRefund());
      final reply = await ref.ask<dynamic>(
          ProvideRefundSignatureCommand(
              channelId: _channelId,
              serverSignatureHex: fixture.serverSignatureHex),
          _ask);
      expect(reply, _applied, reason: '$reply');
      expect((reply as ChannelCommandResult).events.single, isA<RefundCountersignedEvent>());
    });
  });

  /// Bead libspiffy-lfrv. `RecordReturnLegInWalletCommand` is the channel's
  /// own record that the WALLET write happened, so an ending interrupted
  /// between journaling its outcome and writing the wallet can be resumed.
  ///
  /// The manager never sends it twice — it returns early on a channel whose
  /// state already says the write is journaled — so these exercise the
  /// aggregate directly. It is exported from `internals.dart`, and a rule
  /// nothing happens to reach today is still a rule the journal depends on.
  group('lfrv: RecordReturnLegInWalletCommand', () {
    RecordReturnLegInWalletCommand cmd() =>
        RecordReturnLegInWalletCommand(channelId: _channelId, txId: 'ab' * 32);

    List<Event> expiredChannel() => [
          ..._openServerChannel(),
          ChannelExpiredEvent(
              channelId: _channelId, observedBy: 'server', version: 4),
        ];

    test('is rejected on a channel that is not ending', () async {
      final ref = await spawn(_openServerChannel());
      expectRejected(await ref.ask<dynamic>(cmd(), _ask), 'is not ending');
      expect(journalLength(), 3);
    });

    test('records the write once on an expired channel', () async {
      final ref = await spawn(expiredChannel());
      await ref.ask<dynamic>(cmd(), _ask);
      expect(journalLength(), 5);
      expect(store.journal[_persistenceId]!.last,
          isA<ReturnLegRecordedInWalletEvent>());
    });

    test('journals nothing the second time, rather than refusing', () async {
      final ref = await spawn(expiredChannel());
      await ref.ask<dynamic>(cmd(), _ask);
      final after = journalLength();

      // Idempotent, not an error: the manager calls this straight after a
      // wallet write that may itself have been a no-op on a resumed ending,
      // and a refusal there would be noise about a state that is correct.
      await ref.ask<dynamic>(cmd(), _ask);

      expect(journalLength(), after);
      expect(
          store.journal[_persistenceId]!
              .whereType<ReturnLegRecordedInWalletEvent>(),
          hasLength(1));
    });
  });

  group('L3: ChannelStateQuery', () {
    test('on a channel with no events gets a failure reply', () async {
      final ref = await spawn(const []);
      final reply = await ref.ask<dynamic>(
          ChannelStateQuery(channelId: _channelId), _ask);
      expect(reply, isA<FullChannelStateResponse>());
      final response = reply as FullChannelStateResponse;
      expect(response.success, isFalse);
      expect(response.error, contains(_channelId));
    });

    test('on a channel with events replies with its state', () async {
      final ref = await spawn(_openServerChannel());
      final reply = await ref.ask<dynamic>(
          ChannelStateQuery(channelId: _channelId), _ask);
      final response = reply as FullChannelStateResponse;
      expect(response.success, isTrue);
      expect(response.status, 'open');
      expect(response.clientBalanceSats, _funding);
    });
  });

  group('L4: ClaimRefundCommand', () {
    String refundTxHex({String? spending, int outputSats = 99000}) {
      final tx = dartsv.Transaction()
        ..version = 1
        ..nLockTime = 1700000000;
      tx.inputs.add(dartsv.TransactionInput(spending ?? _fundingTxId, 0, 0));
      tx.outputs.add(dartsv.TransactionOutput(
          BigInt.from(outputSats),
          dartsv.P2PKHLockBuilder.fromAddress(
                  dartsv.Address.fromBase58(_clientAddress))
              .getScriptPubkey()));
      return tx.serialize();
    }

    /// Client channel whose lockTime has passed and whose refund
    /// transaction was built.
    List<Event> expiredClientChannel(String refundHex) => [
          _requested(lockTimeUnix: _nowUnix() - 60),
          RefundBuiltEvent(
            channelId: _channelId,
            fundingTxId: _fundingTxId,
            fundingOutputIndex: 0,
            fundingTxHex: '',
            refundTxHex: refundHex,
            clientSignatureHex: '30' * 36,
            version: 2,
          ),
        ];

    test('journals the txid of the channel refund transaction', () async {
      final hex = refundTxHex();
      final ref = await spawn(expiredClientChannel(hex));

      final reply = await ref.ask<dynamic>(
          ClaimRefundCommand(channelId: _channelId), _ask);

      expect(reply, _applied, reason: '$reply');
      final persisted = store.journal[_persistenceId]!
          .whereType<RefundClaimedEvent>()
          .single;
      expect(persisted.refundTxId, dartsv.Transaction.fromHex(hex).id);
      expect(persisted.refundTxId, isNot('pending-broadcast'));
    });

    test('uses the refund transaction carried by the command', () async {
      final ref = await spawn(expiredClientChannel(refundTxHex()));
      // The fully signed refund differs from the stored unsigned one.
      final signedHex = refundTxHex(outputSats: 98999);

      final reply = await ref.ask<dynamic>(
          ClaimRefundCommand(channelId: _channelId, refundTxHex: signedHex),
          _ask);

      expect(reply, _applied, reason: '$reply');
      final persisted = store.journal[_persistenceId]!
          .whereType<RefundClaimedEvent>()
          .single;
      expect(persisted.refundTxId, dartsv.Transaction.fromHex(signedHex).id);
    });

    test('rejects a refund transaction that does not spend the funding output',
        () async {
      final ref = await spawn(expiredClientChannel(refundTxHex()));

      final reply = await ref.ask<dynamic>(
          ClaimRefundCommand(
              channelId: _channelId,
              refundTxHex: refundTxHex(spending: 'e2' * 32)),
          _ask);

      expectRejected(reply, 'funding output');
      expect(journalLength(), 2);
    });

    test('rejects a claim when no refund transaction is known', () async {
      final ref = await spawn([_requested(lockTimeUnix: _nowUnix() - 60)]);

      final reply = await ref.ask<dynamic>(
          ClaimRefundCommand(channelId: _channelId), _ask);

      expectRejected(reply, 'refund transaction');
      expect(journalLength(), 1);
    });
  });
}
