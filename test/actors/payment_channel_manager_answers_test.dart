/// Bead libspiffy-yypk: every request-shaped message the payment channel
/// manager handles is answered, including when it fails.
///
/// The manager has no top-level net, deliberately. V-104 removed a generic
/// `_sendErrorResponse` that knew only two of the message types and replied
/// to `context.sender` -- which, after a handler's awaits, is the sender of
/// whatever message arrived NEXT. Extending it to every arm would have
/// propagated a wrong-recipient bug; it was removed and the outer catch now
/// logs at `severe`.
///
/// What that leaves is a convention: each handler wraps its body in
/// try/catch and answers the sender it captured before its first await, in
/// the response type that matches the request. The q7a lane verified all
/// twenty by reading them. A convention twenty methods happen to follow is
/// not a property -- it drifts the first time someone adds the twenty-first,
/// or adds an early `return` to an existing one.
///
/// This is that property, made checkable. Every request type is driven into
/// a failure its handler cannot avoid -- a channel that does not exist -- and
/// each must come back with its OWN response type carrying `success: false`.
/// A handler that returns without answering fails here instead of leaving
/// its caller to discover it by timing out in production.
library;

import 'dart:async';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/internal_messages.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/payment_channel_manager_actor.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import 'in_memory_event_store.dart';
import '../mocks/test_channel_timing.dart';

/// A channel id no journal and no aggregate knows.
const _ghost = 'channel-that-does-not-exist';
const _ask = Duration(seconds: 5);

void main() {
  late TestActorSystem system;
  late ActorRef manager;

  setUpAll(LibSpiffyActorSystem.registerEventTypes);

  setUp(() async {
    system = TestActorSystem();
    final wallet = await system.spawn('wallet', () => _SilentWallet());
    manager = await system.spawn(
      'channel-manager',
      () => PaymentChannelManagerActor(timing: testChannelTiming, 
        walletManager: wallet,
        eventStore: InMemoryEventStore(),
        cryptoService: DartSVCryptoService(),
        storage: InMemoryWalletStorage(),
        signingTimeout: const Duration(milliseconds: 300),
        broadcastTimeout: const Duration(milliseconds: 300),
      ),
    );
  });

  tearDown(() async => system.shutdown());

  /// Asks [message] and requires an answer of type [T] that says it failed.
  Future<void> answersFailure<T extends ActorResponse>(
      String what, dynamic message) async {
    final T reply;
    try {
      reply = await manager.ask<T>(message, _ask);
    } on TimeoutException {
      fail('$what was never answered: its handler returned without replying, '
          'so its caller waits until the ask times out');
    } catch (e) {
      fail('$what was answered with something that is not a $T: $e');
    }
    expect(reply.success, isFalse,
        reason: '$what named a channel that does not exist');
    expect(reply.error, isNotNull,
        reason: '$what must say WHY, not just that it failed');
    expect(reply.error, isNotEmpty);
  }

  group('every request about an unknown channel is answered', () {
    test('RecordServerAcceptanceMessage', () async {
      await answersFailure<ServerAcceptanceRecordedResponse>(
        'RecordServerAcceptanceMessage',
        RecordServerAcceptanceMessage(
          channelId: _ghost,
          serverPubKeyHex: '03${'cd' * 32}',
          serverAddressB58: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
        ),
      );
    });

    test('BuildRefundTransactionMessage', () async {
      await answersFailure<RefundTransactionBuiltResponse>(
        'BuildRefundTransactionMessage',
        BuildRefundTransactionMessage(
          channelId: _ghost,
          walletId: 'w',
          fundingTxId: 'ab' * 32,
          fundingOutputIndex: 0,
          fundingAmountSats: BigInt.from(100000),
          clientPubKeyHex: '02${'ab' * 32}',
          clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
          serverPubKeyHex: '03${'cd' * 32}',
          serverAddressB58: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
          lockTimeUnix: 1900000000,
        ),
      );
    });

    test('SignRefundTransactionMessage', () async {
      await answersFailure<RefundTransactionSignedResponse>(
        'SignRefundTransactionMessage',
        SignRefundTransactionMessage(
          channelId: _ghost,
          walletId: 'w',
          refundTxHex: '0100000000',
          clientPubKeyHex: '02${'ab' * 32}',
          serverPubKeyHex: '03${'cd' * 32}',
          serverAddressB58: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
          derivationIndex: 0,
          fundingAmountSats: BigInt.from(100000),
          lockTimeUnix: 1900000000,
        ),
      );
    });

    test('RecordRefundSignatureMessage', () async {
      await answersFailure<RefundSignatureRecordedResponse>(
        'RecordRefundSignatureMessage',
        RecordRefundSignatureMessage(
          channelId: _ghost,
          serverSignatureHex: '30' * 36,
        ),
      );
    });

    test('OpenChannelMessage', () async {
      await answersFailure<ChannelOpenedResponse>(
        'OpenChannelMessage',
        OpenChannelMessage(
          channelId: _ghost,
          fundingTxId: 'ab' * 32,
          fundingOutputIndex: 0,
          fundingTxHex: '0100000000',
        ),
      );
    });

    test('RetryChannelFundingMessage', () async {
      await answersFailure<ChannelFundingRetriedResponse>(
        'RetryChannelFundingMessage',
        RetryChannelFundingMessage(channelId: _ghost),
      );
    });

    test('ResendChannelOpenMessage', () async {
      await answersFailure<ChannelOpenResentResponse>(
        'ResendChannelOpenMessage',
        ResendChannelOpenMessage(channelId: _ghost),
      );
    });

    test('RecordPaymentMessage', () async {
      await answersFailure<PaymentRecordedResponse>(
        'RecordPaymentMessage',
        RecordPaymentMessage(
          channelId: _ghost,
          walletId: 'w',
          amountSats: BigInt.from(1000),
        ),
      );
    });

    test('AcknowledgePaymentMessage', () async {
      await answersFailure<PaymentAcknowledgedResponse>(
        'AcknowledgePaymentMessage',
        AcknowledgePaymentMessage(
          channelId: _ghost,
          walletId: 'w',
          amountSats: BigInt.from(1000),
          paymentTxHex: '0100000000',
          clientSignatureHex: '30' * 36,
          proposedSequence: 1,
          proposedClientBalance: BigInt.from(99000),
          proposedServerBalance: BigInt.from(1000),
        ),
      );
    });

    test('CloseChannelMessage', () async {
      await answersFailure<ChannelClosedResponse>(
        'CloseChannelMessage',
        CloseChannelMessage(channelId: _ghost),
      );
    });

    test('RecordSettlementMessage', () async {
      await answersFailure<ChannelClosedResponse>(
        'RecordSettlementMessage',
        RecordSettlementMessage(channelId: _ghost, settlementTxHex: '00'),
      );
    });

    test('ExpireChannelMessage', () async {
      await answersFailure<ChannelExpiredResponse>(
        'ExpireChannelMessage',
        ExpireChannelMessage(channelId: _ghost, observedBy: 'test'),
      );
    });

    test('ClaimRefundMessage', () async {
      await answersFailure<ChannelRefundClaimedResponse>(
        'ClaimRefundMessage',
        ClaimRefundMessage(channelId: _ghost),
      );
    });

    test('QueryChannelStateMessage', () async {
      await answersFailure<ChannelStateResponse>(
        'QueryChannelStateMessage',
        QueryChannelStateMessage(channelId: _ghost),
      );
    });

    test('ChannelDetailsQueryMessage', () async {
      await answersFailure<FullChannelStateResponse>(
        'ChannelDetailsQueryMessage',
        ChannelDetailsQueryMessage(channelId: _ghost),
      );
    });
  });

  test('the list above covers every request the manager dispatches', () {
    // The guard on the guard, and it reads the DISPATCH, not itself: a
    // message type added to onMessage without a case above would otherwise
    // go unanswered-and-untested, which is the drift this file exists to
    // catch. Dart has no reflection over a switch, so the source is the
    // source of truth -- the same shape as the pinned event-type-name
    // tables, except that this one cannot go stale silently.
    const covered = {
      'RecordServerAcceptanceMessage',
      'BuildRefundTransactionMessage',
      'SignRefundTransactionMessage',
      'RecordRefundSignatureMessage',
      'OpenChannelMessage',
      'RetryChannelFundingMessage',
      'ResendChannelOpenMessage',
      'RecordPaymentMessage',
      'AcknowledgePaymentMessage',
      'CloseChannelMessage',
      'RecordSettlementMessage',
      'ExpireChannelMessage',
      'ClaimRefundMessage',
      'QueryChannelStateMessage',
      'ChannelDetailsQueryMessage',
    };
    // Dispatched but not covered above, each for a stated reason:
    const notCovered = {
      // Creates its channel rather than looking one up, so "unknown channel"
      // is not a failure it can have. Its failure replies are exercised by
      // payment_channel_manager_rejection_test.
      'InitiateChannelMessage',
      'AcceptChannelMessage',
      // The manager's reply to its own signing round trip, not a request.
      'MultisigTransactionSignedResponse',
    };
    expect(covered.intersection(notCovered), isEmpty,
        reason: 'a type cannot be both covered and excused');

    final source = File('lib/src/actors/payment_channel_manager_actor.dart')
        .readAsStringSync();
    final onMessage = source.substring(source.indexOf('Future<void> onMessage'),
        source.indexOf('/// Client initiates a new payment channel'));
    final dispatched = RegExp(r'case final (\w+) ')
        .allMatches(onMessage)
        .map((m) => m.group(1)!)
        .toSet();
    expect(dispatched, isNotEmpty, reason: 'the dispatch was not found');

    expect(dispatched.difference(covered.union(notCovered)), isEmpty,
        reason: 'onMessage dispatches a message type this file neither '
            'covers nor excuses: add a test for it above, or a reason in '
            'notCovered saying why it needs none');
    expect(covered.union(notCovered).difference(dispatched), isEmpty,
        reason: 'this file names a message type onMessage no longer '
            'dispatches');
  });
}

/// A wallet manager that never answers: every signing request times out, so
/// the handlers that need one fail in a way they must still report.
class _SilentWallet extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}
