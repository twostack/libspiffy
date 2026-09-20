/// libspiffy-pgt: the common reply base and the one internal messages file.
library;

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

import 'package:libspiffy/libspiffy.dart' as public_api;
import 'package:libspiffy/src/actors/header_sync_actor.dart' as header_sync;
import 'package:libspiffy/src/actors/internal_messages.dart';
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart' as actor_system;
import 'package:libspiffy/src/actors/wallet_messages.dart' as wallet_messages;

import 'actor_reply_shape_characterization_test.dart' as shapes;

/// Stand-in actor reference for the wiring messages.
class _Ref implements ActorRef {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('every actor reply extends ActorResponse', () {
    final builders = <String, Message Function(bool ok)>{
      ...shapes.replies,
      for (final e in shapes.bareReplies.entries) e.key: e.value.$1,
    };
    for (final entry in builders.entries) {
      test(entry.key, () {
        for (final ok in [true, false]) {
          final reply = entry.value(ok);
          expect(reply, isA<ActorResponse>());
          final response = reply as ActorResponse;
          expect(response.success, ok);
          expect(response.error, ok ? isNull : 'boom');
          expect(identical(response.payload, response), isTrue);
        }
      });
    }
  });

  group('every failure-only reply extends FailureResponse', () {
    for (final entry in shapes.failureReplies.entries) {
      test(entry.key, () {
        final reply = entry.value.$1();
        expect(reply, isA<FailureResponse>());
        expect(reply, isA<ActorResponse>());
        expect(reply.success, isFalse);
        expect(reply.error, 'boom');
        expect(identical(reply.payload, reply), isTrue);
      });
    }
  });

  test('the wiring messages are one set of classes, reachable from their old libraries', () {
    final ref = _Ref();
    expect(header_sync.SetSpiffyNodeBridgeMessage('bridge'), isA<SetSpiffyNodeBridgeMessage>());
    expect(header_sync.SetPeerManagerMessage('pm'), isA<SetPeerManagerMessage>());
    expect(header_sync.InitiateHeaderSyncMessage(startHeight: 3), isA<InitiateHeaderSyncMessage>());
    expect(wallet_messages.SetBenfordCoordinatorMessage(ref), isA<SetBenfordCoordinatorMessage>());
    expect(wallet_messages.SetArcActorForSPVMessage(ref), isA<SetArcActorForSPVMessage>());
    expect(wallet_messages.SetHeaderSyncActorMessage(ref), isA<SetHeaderSyncActorMessage>());
    expect(actor_system.SetInvoiceManagerMessage(ref), isA<SetInvoiceManagerMessage>());
    expect(actor_system.SetArcActorMessage(ref), isA<SetArcActorMessage>());

    // The public library exports the base and the wiring messages it
    // exported before.
    expect(public_api.SetInvoiceManagerMessage(ref), isA<SetInvoiceManagerMessage>());
    expect(public_api.SetBenfordCoordinatorMessage(ref), isA<SetBenfordCoordinatorMessage>());
    expect(public_api.TransactionSignedResponse(walletId: 'w', txid: 't', signedHex: '', success: true),
        isA<public_api.ActorResponse>());
  });
}
