/// Regression test for WalletCoordinatorActor's timestamp broadcast
/// (audit finding A-H1).
///
/// ARCActor hex-decodes `BroadcastBEEFMessage.beefHex`
/// (`BEEF.parse(hex.decode(msg.beefHex))`). The timestamp path used to
/// base64-encode the BEEF bytes into that field, so every timestamp
/// broadcast failed with a FormatException inside ARCActor.
///
/// The coordinator is built directly with probe actors: the payment
/// coordinator probe answers PayInvoiceMessage with a successful
/// BEEFPaymentResponse, and the ARC probe captures what the coordinator
/// asks it to broadcast.
import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/coordinator_messages.dart';
import 'package:libspiffy/src/actors/payment_messages.dart' as pay;
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart' as wm;
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';

void main() {
  late ActorSystem actorSystem;
  late _ProbeActor arcProbe;
  late _PaymentCoordinatorStub paymentStub;
  late ActorRef coordinator;

  /// A syntactically valid BEEF: magic+version, no BUMPs, no transactions.
  final beefBytes = Uint8List.fromList([0x01, 0x00, 0xBE, 0xEF, 0x00, 0x00]);

  setUp(() async {
    actorSystem = LocalActorSystem();
    arcProbe = _ProbeActor();
    paymentStub = _PaymentCoordinatorStub(beefBytes: beefBytes, txid: 'ab' * 32);

    final noop = await actorSystem.spawn('noop', () => _ProbeActor());
    final arc = await actorSystem.spawn('arc', () => arcProbe);
    final payment = await actorSystem.spawn('payment', () => paymentStub);

    coordinator = await actorSystem.spawn(
      'coordinator',
      () => WalletCoordinatorActor(
        walletManager: noop,
        invoiceCoordinator: noop,
        paymentCoordinator: payment,
        spvActor: noop,
        arcActor: arc,
        headerSyncActor: noop,
        benfordCoordinator: noop,
        channelManager: noop,
        walletProjection: noop,
        storage: _UnusedStorage(),
      ),
    );
  });

  tearDown(() async {
    await actorSystem.shutdown();
  });

  test('timestamp payment broadcasts the BEEF hex-encoded, as ARCActor expects', () async {
    coordinator.tell(TimestampCommand(
      archiveId: 'archive-1',
      walletId: 'wallet-1',
      fileHashes: ['deadbeef'],
      archiveTitle: 'test archive',
    ));

    final broadcast = await arcProbe
        .firstOfType<wm.BroadcastBEEFMessage>()
        .timeout(const Duration(seconds: 5));

    expect(paymentStub.invoiceIds, hasLength(1));
    expect(paymentStub.invoiceIds.single, startsWith('timestamp-archive-1-'));
    expect(broadcast.walletId, equals('wallet-1'));
    expect(broadcast.txid, equals('ab' * 32));

    // Exactly what ARCActor._handleBroadcastBEEF does with the field. With
    // the base64 encoding this threw FormatException.
    final decoded = Uint8List.fromList(hex.decode(broadcast.beefHex));
    expect(decoded, equals(beefBytes));
    expect(() => BEEF.parse(decoded), returnsNormally);
  });
}

/// Answers every PayInvoiceMessage with a successful BEEFPaymentResponse.
class _PaymentCoordinatorStub extends Actor {
  final Uint8List beefBytes;
  final String txid;
  final List<String> invoiceIds = [];

  _PaymentCoordinatorStub({required this.beefBytes, required this.txid});

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is pay.PayInvoiceMessage) {
      invoiceIds.add(message.invoiceId);
      context.sender?.tell(pay.BEEFPaymentResponse(
        invoiceId: message.invoiceId,
        beefBytes: beefBytes,
        txid: txid,
        amountPaid: BigInt.zero,
        changeAmount: BigInt.zero,
        ancestorCount: 0,
        success: true,
      ));
    }
  }
}

/// Records every message and lets a test wait for the first of a type.
class _ProbeActor extends Actor {
  final List<dynamic> received = [];
  final StreamController<dynamic> _stream = StreamController.broadcast();

  Future<T> firstOfType<T>() async {
    for (final m in received) {
      if (m is T) return m;
    }
    return (await _stream.stream.firstWhere((m) => m is T)) as T;
  }

  @override
  Future<void> onMessage(dynamic message) async {
    received.add(message);
    _stream.add(message);
  }
}

/// The timestamp path never touches storage; anything else is a test bug.
class _UnusedStorage implements ReadModelStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('ReadModelStorage.${invocation.memberName} not expected');
}
