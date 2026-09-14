/// Payment channel aggregate: the client keeps a verified refund and funds
/// only after it (libspiffy-b83, libspiffy-9f7).
///
/// * b83: the client never journaled its refund, so it held no refund once
///   the channel opened; the server's refund signature was journaled without
///   being checked, so a bad signature still opened the channel.
/// * 9f7: nothing gated the funding broadcast (it never happened), and the
///   channel opened on a client that had broadcast nothing and on a server
///   that never looked at the funding transaction.
library;

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/core/channel_commands.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/core/payment_channel_aggregate.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/services/payment_channel_builder.dart';

import '../actors/channel_test_fixtures.dart';
import '../actors/in_memory_event_store.dart';

const _channelId = 'channel-refund-guards';
const _persistenceId = 'PaymentChannel_$_channelId';
const _ask = Duration(seconds: 5);

void main() {
  late InMemoryEventStore store;
  late TestActorSystem system;
  late ChannelRefundFixture f;
  var spawned = 0;

  setUpAll(LibSpiffyActorSystem.registerEventTypes);

  setUp(() async {
    store = InMemoryEventStore();
    system = TestActorSystem();
    f = await ChannelRefundFixture.create(channelId: _channelId);
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

  List<Event> journal() => store.journal[_persistenceId] ?? const [];

  void expectRejected(dynamic reply, String errorFragment) {
    expect(reply, isA<Map>(), reason: 'expected a rejection, got $reply');
    expect((reply as Map)['success'], isFalse);
    expect(reply['error'], contains(errorFragment));
  }

  RecordRefundBuiltCommand recordRefund({
    String? fundingTxHex,
    String? fundingTxId,
    String? refundTxHex,
    String? clientSignatureHex,
  }) =>
      RecordRefundBuiltCommand(
        channelId: _channelId,
        fundingTxId: fundingTxId ?? f.fundingTxId,
        fundingOutputIndex: 0,
        fundingTxHex: fundingTxHex ?? f.fundingTxHex,
        refundTxHex: refundTxHex ?? f.refundTxHex,
        clientSignatureHex: clientSignatureHex ?? f.clientSignatureHex,
        fundingInputSats: 150200,
      );

  /// Rebuilds the fixture refund with [edit] applied to the transaction.
  String refundWith(void Function(dartsv.Transaction tx) edit) {
    final tx = dartsv.Transaction.fromHex(f.refundTxHex);
    edit(tx);
    return tx.serialize();
  }

  group('libspiffy-b83: RecordRefundBuiltCommand', () {
    test(
        'journals the refund template, the client signature and the funding '
        'transaction', () async {
      final ref = await spawn(
          [f.requested(version: 1), f.serverAcceptance(version: 2)]);

      final reply = await ref.ask<dynamic>(recordRefund(), _ask);

      expect(reply, isA<List>(), reason: '$reply');
      final built = journal().whereType<RefundBuiltEvent>().single;
      expect(built.refundTxHex, f.refundTxHex);
      expect(built.clientSignatureHex, f.clientSignatureHex);
      expect(built.fundingTxHex, f.fundingTxHex);
      expect(built.fundingInputSats, 150200);
    });

    test('rejects a funding output that does not lock the agreed amount',
        () async {
      final ref = await spawn(
          [f.requested(version: 1), f.serverAcceptance(version: 2)]);
      final wrong = channelFundingTx(
          clientPubKeyHex: f.clientPubKeyHex,
          serverPubKeyHex: f.serverPubKeyHex,
          amountSats: f.amountSats - BigInt.one);

      final reply = await ref.ask<dynamic>(
          recordRefund(fundingTxHex: wrong.hex, fundingTxId: wrong.txid), _ask);

      expectRejected(reply, 'not the agreed');
      expect(journal(), hasLength(2));
    });

    test('rejects a funding output locked to other keys', () async {
      final ref = await spawn(
          [f.requested(version: 1), f.serverAcceptance(version: 2)]);
      final other = dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST);
      final wrong = channelFundingTx(
          clientPubKeyHex: f.clientPubKeyHex,
          serverPubKeyHex: other.publicKey.toString(),
          amountSats: f.amountSats);

      final reply = await ref.ask<dynamic>(
          recordRefund(fundingTxHex: wrong.hex, fundingTxId: wrong.txid), _ask);

      expectRejected(reply, 'not the channel 2-of-2');
    });

    test('rejects a refund whose nLockTime is not the channel lockTime',
        () async {
      final ref = await spawn(
          [f.requested(version: 1), f.serverAcceptance(version: 2)]);

      final reply = await ref.ask<dynamic>(
          recordRefund(
              refundTxHex:
                  refundWith((tx) => tx.nLockTime = f.lockTimeUnix - 3600)),
          _ask);

      expectRejected(reply, 'nLockTime');
    });

    test('rejects a refund with a final input sequence', () async {
      final ref = await spawn(
          [f.requested(version: 1), f.serverAcceptance(version: 2)]);

      final reply = await ref.ask<dynamic>(
          recordRefund(
              refundTxHex: refundWith((tx) => tx.inputs[0] =
                  dartsv.TransactionInput(f.fundingTxId, 0,
                      dartsv.TransactionInput.MAX_SEQ_NUMBER))),
          _ask);

      expectRejected(reply, 'sequence is final');
    });

    test('rejects a refund that pays someone other than the client', () async {
      final ref = await spawn(
          [f.requested(version: 1), f.serverAcceptance(version: 2)]);

      final reply = await ref.ask<dynamic>(
          recordRefund(
              refundTxHex: refundWith((tx) => tx.outputs[0] =
                  dartsv.TransactionOutput(
                      tx.outputs[0].satoshis,
                      dartsv.P2PKHLockBuilder.fromAddress(
                              dartsv.Address.fromBase58(f.serverAddressB58))
                          .getScriptPubkey()))),
          _ask);

      expectRejected(reply, 'does not pay the client address');
    });

    test('rejects a client signature that does not verify', () async {
      final ref = await spawn(
          [f.requested(version: 1), f.serverAcceptance(version: 2)]);

      final reply = await ref.ask<dynamic>(
          recordRefund(clientSignatureHex: f.serverSignatureHex), _ask);

      expectRejected(reply, 'Client refund signature does not verify');
    });

    test('is refused on the server side', () async {
      final ref = await spawn([f.serverAccepted(version: 1)]);

      final reply = await ref.ask<dynamic>(recordRefund(), _ask);

      expectRejected(reply, 'Only the client');
    });
  });

  group(
      'libspiffy-b83: ProvideRefundSignatureCommand verifies the server '
      'signature', () {
    test(
        'journals the fully signed refund, which satisfies the script '
        'interpreter against the funding output', () async {
      final ref = await spawn(f.clientJournalWithRefund());

      final reply = await ref.ask<dynamic>(
          ProvideRefundSignatureCommand(
              channelId: _channelId, serverSignatureHex: f.serverSignatureHex),
          _ask);

      expect(reply, isA<List>(), reason: '$reply');
      final countersigned =
          journal().whereType<RefundCountersignedEvent>().single;
      final signed =
          dartsv.Transaction.fromHex(countersigned.signedRefundTxHex!);
      expect(signed.nLockTime, f.lockTimeUnix);
      PaymentChannelBuilder(cryptoService: DartSVCryptoService())
          .verifyMultisigSpend(
        signedTx: signed,
        redeemScript: dartsv.P2MSLockBuilder(
                [f.clientKey.publicKey, f.serverKey.publicKey], 2,
                sorting: true)
            .getScriptPubkey(),
        inputValueSats: f.amountSats,
      );

      final state = await ref.ask<dynamic>(
          ChannelStateQuery(channelId: _channelId), _ask);
      expect((state as FullChannelStateResponse).signedRefundTxHex,
          countersigned.signedRefundTxHex);
    });

    test('rejects a signature by another key and journals nothing', () async {
      final ref = await spawn(f.clientJournalWithRefund());

      final reply = await ref.ask<dynamic>(
          ProvideRefundSignatureCommand(
              channelId: _channelId,
              serverSignatureHex: await f.forgedServerSignature()),
          _ask);

      expectRejected(reply, 'Server refund signature does not verify');
      expect(journal(), hasLength(3));
    });

    test('rejects a malformed signature', () async {
      final ref = await spawn(f.clientJournalWithRefund());

      final reply = await ref.ask<dynamic>(
          ProvideRefundSignatureCommand(
              channelId: _channelId, serverSignatureHex: 'zz'),
          _ask);

      expectRejected(reply, 'malformed');
    });

    test('rejects a signature when no refund was built', () async {
      final ref = await spawn(
          [f.requested(version: 1), f.serverAcceptance(version: 2)]);

      final reply = await ref.ask<dynamic>(
          ProvideRefundSignatureCommand(
              channelId: _channelId, serverSignatureHex: f.serverSignatureHex),
          _ask);

      expectRejected(reply, 'No refund transaction built');
      expect(journal(), hasLength(2));
    });

    test(
        'ClaimRefundCommand claims the fully signed refund after the '
        'lockTime', () async {
      final expired = await ChannelRefundFixture.create(
          channelId: _channelId,
          lockTimeUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60);
      final ref = await spawn(expired.openClientJournal());

      final reply = await ref.ask<dynamic>(
          ClaimRefundCommand(channelId: _channelId), _ask);

      expect(reply, isA<List>(), reason: '$reply');
      expect(journal().whereType<RefundClaimedEvent>().single.refundTxId,
          dartsv.Transaction.fromHex(expired.signedRefundTxHex()).id);
    });
  });

  group('libspiffy-9f7: StartFundingBroadcastCommand', () {
    test('is refused before the refund is countersigned', () async {
      final ref = await spawn(f.clientJournalWithRefund());

      final reply = await ref.ask<dynamic>(
          StartFundingBroadcastCommand(
              channelId: _channelId, fundingTxId: f.fundingTxId),
          _ask);

      expectRejected(reply, 'Refund not signed');
      expect(journal(), hasLength(3));
    });

    test(
        'is refused when the countersigned journal holds no signed refund '
        '(a journal written before b83)', () async {
      final ref = await spawn([
        ...f.clientJournalWithRefund(),
        RefundCountersignedEvent(
            channelId: _channelId,
            serverSignatureHex: f.serverSignatureHex,
            version: 4),
      ]);

      final reply = await ref.ask<dynamic>(
          StartFundingBroadcastCommand(
              channelId: _channelId, fundingTxId: f.fundingTxId),
          _ask);

      expectRejected(reply, 'No fully signed refund retained');
    });

    test('is refused for a funding transaction the refund does not spend',
        () async {
      final ref = await spawn(f.openClientJournal().take(4).toList());

      final reply = await ref.ask<dynamic>(
          StartFundingBroadcastCommand(
              channelId: _channelId, fundingTxId: 'e1' * 32),
          _ask);

      expectRejected(reply, 'is not the one the refund spends');
    });

    test(
        'starts attempt 1, attempt 2 after a failure, and attempt 3 when an '
        'attempt\'s outcome was lost (still in flight)', () async {
      final ref = await spawn(f.openClientJournal().take(4).toList());
      StartFundingBroadcastCommand start() => StartFundingBroadcastCommand(
          channelId: _channelId, fundingTxId: f.fundingTxId);

      expect(await ref.ask<dynamic>(start(), _ask), isA<List>());
      expect(
          await ref.ask<dynamic>(
              RecordFundingBroadcastFailedCommand(
                  channelId: _channelId,
                  fundingTxId: f.fundingTxId,
                  error: 'ARC down',
                  walletRecorded: true),
              _ask),
          isA<List>());
      expect(await ref.ask<dynamic>(start(), _ask), isA<List>());
      expect(await ref.ask<dynamic>(start(), _ask), isA<List>());

      expect(
          journal()
              .whereType<FundingBroadcastStartedEvent>()
              .map((e) => e.attempt),
          [1, 2, 3]);
      final state = await ref.ask<dynamic>(
          ChannelStateQuery(channelId: _channelId), _ask);
      expect(
          (state as FullChannelStateResponse).fundingRecordedInWallet, isTrue);
    });
  });

  group('libspiffy-9f7: OpenChannelCommand', () {
    OpenChannelCommand open({String? txid, String? hex}) => OpenChannelCommand(
          channelId: _channelId,
          fundingTxId: txid ?? f.fundingTxId,
          fundingOutputIndex: 0,
          fundingTxHex: hex ?? f.fundingTxHex,
        );

    test('client: refused while the funding transaction was not broadcast',
        () async {
      final ref = await spawn(f.openClientJournal().take(4).toList());

      expectRejected(
          await ref.ask<dynamic>(open(), _ask), 'has not been broadcast');
    });

    test('client: refused after the funding broadcast failed', () async {
      final ref = await spawn([
        ...f.openClientJournal().take(5),
        FundingBroadcastFailedEvent(
            channelId: _channelId,
            fundingTxId: f.fundingTxId,
            error: 'ARC down',
            walletRecorded: true,
            version: 6),
      ]);

      expectRejected(
          await ref.ask<dynamic>(open(), _ask), 'has not been broadcast');
    });

    test('client: opens once the funding broadcast started', () async {
      final ref = await spawn(f.openClientJournal().take(5).toList());

      expect(await ref.ask<dynamic>(open(), _ask), isA<List>());
    });

    test(
        'server: refuses a funding transaction that does not lock the agreed '
        'amount in the channel 2-of-2, and opens for one that does', () async {
      final ref = await spawn([
        f.serverAccepted(version: 1),
        RefundCountersignedEvent(
            channelId: _channelId,
            serverSignatureHex: f.serverSignatureHex,
            version: 2),
      ]);
      final short = channelFundingTx(
          clientPubKeyHex: f.clientPubKeyHex,
          serverPubKeyHex: f.serverPubKeyHex,
          amountSats: BigInt.from(1000));

      expectRejected(
          await ref.ask<dynamic>(open(txid: short.txid, hex: short.hex), _ask),
          'not the agreed');
      expectRejected(await ref.ask<dynamic>(open(hex: ''), _ask),
          'Invalid funding transaction');
      expectRejected(
          await ref.ask<dynamic>(open(txid: 'e1' * 32), _ask), 'not e1');
      expect(journal(), hasLength(2));

      expect(await ref.ask<dynamic>(open(), _ask), isA<List>());
    });
  });

  group('journal rows written before b83/9f7 still load', () {
    test(
        'RefundBuiltEvent without fundingInputSats and RefundCountersignedEvent '
        'without signedRefundTxHex', () {
      final built = f.refundBuilt(version: 3).toMap()
        ..remove('fundingInputSats');
      final countersigned = RefundCountersignedEvent(
              channelId: _channelId, serverSignatureHex: '30', version: 4)
          .toMap()
        ..remove('signedRefundTxHex');

      expect(RefundBuiltEvent.fromMap(built).fundingInputSats, isNull);
      expect(RefundCountersignedEvent.fromMap(countersigned).signedRefundTxHex,
          isNull);
    });

    test('a channel snapshot without the new keys restores', () async {
      final aggregate = PaymentChannelAggregate(
        aggregateId: _channelId,
        eventStore: store,
        cryptoService: DartSVCryptoService(),
      );
      final map = {
        'channelId': _channelId,
        'status': 'refundSigned',
        'role': 'client',
        'fundingAmountSats': '100000',
        'clientBalanceSats': '100000',
        'serverBalanceSats': '0',
        'latestSequenceNumber': 0,
        'version': 4,
      };
      final restored = await aggregate.restoreStateFromMap(map, 4);
      expect(restored.signedRefundTxHex, isNull);
      expect(restored.fundingBroadcastAttempts, 0);
      expect(restored.fundingBroadcastInFlight, isFalse);
      expect(restored.fundingRecordedInWallet, isFalse);
    });
  });
}
