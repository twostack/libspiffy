// Audit 2026-09-14 L2: channel events persist only persistable metadata and
// are aggregate events; InvoiceStatusChangedEvent.fromMap rejects an unknown
// status with a FormatException instead of a bare StateError.
import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:libspiffy/internals.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:test/test.dart';

class _FakeActorRef implements ActorRef {
  @override
  String get id => 'secret-actor-path';

  @override
  String toString() => 'ActorRef(secret-actor-path)';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChannelRequestedEvent _requested(Map<String, dynamic> metadata) =>
    ChannelRequestedEvent(
      channelId: 'channel-1',
      walletId: 'wallet-1',
      clientPeerId: 'cp',
      serverPeerId: 'sp',
      clientPubKeyHex: '02',
      clientAddressB58: 'ca',
      derivationIndex: 1,
      fundingAmountSats: BigInt.from(1000),
      lockTimeUnix: 99,
      metadata: metadata,
    );

void main() {
  setUp(() {
    EventRegistry.clear();
    LibSpiffyActorSystem.registerEventTypes();
  });

  group('channel events', () {
    test('a replyTo ActorRef in metadata is not written to the journal', () {
      final ref = _FakeActorRef();
      final event = _requested({'replyTo': ref, 'correlationId': 'corr-1'});

      // The live in-memory event still carries the handle.
      expect(event.replyTo, same(ref));

      final map = event.toMap();
      final metadata = map['metadata'] as Map;
      expect(metadata.containsKey('replyTo'), isFalse,
          reason: 'the ActorRef was serialized into the event map');
      expect(metadata['correlationId'], 'corr-1');
      expect(map.toString(), isNot(contains('secret-actor-path')));

      final bytes = CborSerializer.serializeEvent(event);
      final restored = CborSerializer.deserializeEvent(bytes, event.typeName)
          as ChannelRequestedEvent;
      expect(restored.metadata.containsKey('replyTo'), isFalse,
          reason: 'the stored row holds a stringified ActorRef');
      expect(restored.metadata['correlationId'], 'corr-1');
      expect(restored.channelId, 'channel-1');
      expect(restored.fundingAmountSats, BigInt.from(1000));
    });

    test('channel events are aggregate events keyed by the channel id', () {
      final event = _requested(const {});
      expect(event, isA<AggregateEvent>());
      final map = event.toMap();
      expect(map['aggregateId'], 'channel-1');
      expect(map['aggregateType'], 'PaymentChannel');
      expect(map['channelId'], 'channel-1');
      expect(map['type'], ChannelRequestedEvent.stableTypeName);
    });
  });

  group('InvoiceStatusChangedEvent.fromMap', () {
    Map<String, dynamic> stored(String oldStatus, String newStatus) =>
        InvoiceStatusChangedEvent(
          invoiceId: 'invoice-1',
          walletId: 'wallet-1',
          oldStatus: InvoiceStatus.pending,
          newStatus: InvoiceStatus.paid,
        ).toMap()
          ..['oldStatus'] = oldStatus
          ..['newStatus'] = newStatus;

    test('an unknown status is a FormatException naming the field and value', () {
      expect(
        () => InvoiceStatusChangedEvent.fromMap(stored('pending', 'refunded')),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('newStatus'))
            .having((e) => e.message, 'message', contains('refunded'))),
      );
      expect(
        () => InvoiceStatusChangedEvent.fromMap(stored('bogus', 'paid')),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('oldStatus'))),
      );
    });

    test('known statuses still parse', () {
      final event =
          InvoiceStatusChangedEvent.fromMap(stored('expired', 'cancelled'));
      expect(event.oldStatus, InvoiceStatus.expired);
      expect(event.newStatus, InvoiceStatus.cancelled);
    });
  });
}
