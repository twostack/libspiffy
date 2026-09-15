/// libspiffy-pgt: behaviour that changed when actor replies moved onto one
/// convention (every reply is a LocalMessage that is its own payload).
///
/// * Replies that implemented Message only could not answer an ask():
///   dactor's temporary reply ref accepts a LocalMessage only and failed the
///   ask with a StateError. They now complete it with the reply.
/// * WalletManagerActor answered a SplitUTXOsToBenfordCommand it could not
///   route (no Benford coordinator) with a `{'error': ...}` Map, which the
///   caller (WalletCoordinatorActor) did not handle. It now answers with the
///   SplitUTXOsResponse the Benford coordinator itself sends on failure.
///
/// These tests use no new API, so they compile against the old code and fail
/// there.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/actors/payment_messages.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import 'in_memory_event_store.dart';

final Map<String, Message Function()> formerlyBareReplies = {
  'WalletCreatedMessage': () => WalletCreatedMessage('w', 'root', false, error: 'boom'),
  'WalletCreatedResponse': () =>
      WalletCreatedResponse(walletId: 'w', rootAddress: '', success: false, error: 'boom'),
  'TransactionSignedResponse': () => TransactionSignedResponse(
      walletId: 'w', txid: 't', signedHex: '', success: false, error: 'boom'),
  'MultisigTransactionSignedResponse': () => MultisigTransactionSignedResponse(
      walletId: 'w', txid: 't', signedHex: '', signatureHex: '', success: false, error: 'boom'),
  'InputSignedResponse': () => InputSignedResponse(walletId: 'w', commandId: 'c', inputIndex: 0,
      signatureHex: '', publicKeyHex: '', success: false, error: 'boom'),
  'FundingTransactionBuiltResponse': () => FundingTransactionBuiltResponse(walletId: 'w',
      correlationId: 'k', channelId: 'ch', fundingTxHex: '', fundingTxId: '',
      fundingOutputIndex: 0, success: false, error: 'boom'),
  'SplitUTXOsResponse': () => SplitUTXOsResponse(walletId: 'w', success: false, error: 'boom'),
  'UTXOReservedResponse': () => UTXOReservedResponse(
      walletId: 'w', utxoKey: 't:0', reservedByTxId: 'r', success: false, error: 'boom'),
  'UTXOReceivedResponse': () =>
      UTXOReceivedResponse(walletId: 'w', txid: 't', vout: 0, success: false, error: 'boom'),
  'TransactionRecordedResponse': () =>
      TransactionRecordedResponse(walletId: 'w', txid: 't', success: false, error: 'boom'),
  'MerkleProofMessage': () => MerkleProofMessage(txid: 't', success: false, error: 'boom'),
  'InvoiceCreatedMessage': () => InvoiceCreatedMessage(invoiceId: 'i', walletId: 'w',
      addresses: const [], amount: BigInt.zero, createdAt: DateTime.utc(2026),
      success: false, error: 'boom'),
  'BEEFPaymentResponse': () => BEEFPaymentResponse.error(invoiceId: 'i', error: 'boom'),
  'ProvisionFundingResponse': () => ProvisionFundingResponse.error(walletId: 'w', error: 'boom'),
};

/// Answers every request with the reply built by [reply].
class _Replier extends Actor {
  final Message Function() reply;
  _Replier(this.reply);

  @override
  // ignore: invalid_use_of_internal_member
  Future<void> onMessage(dynamic message) async => context.sender?.tell(reply());
}

/// Forwards every message it receives to [received].
class _Probe extends Actor {
  final received = StreamController<dynamic>();

  @override
  Future<void> onMessage(dynamic message) async => received.add(message);
}

class _Ping implements Message {
  @override
  String get correlationId => 'ping';
  @override
  Map<String, dynamic> get metadata => const {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

void main() {
  late ActorSystem system;
  setUp(() => system = LocalActorSystem());
  tearDown(() => system.shutdown());

  group('a reply that implemented Message only now answers an ask', () {
    for (final entry in formerlyBareReplies.entries) {
      test(entry.key, () async {
        final built = entry.value();
        final ref = await system.spawn('replier', () => _Replier(() => built));
        final answer = await ref.ask<Object>(_Ping(), const Duration(seconds: 5));
        expect(identical(answer, built), isTrue);
      });
    }
  });

  test('WalletManagerActor without a Benford coordinator answers a split with a failed SplitUTXOsResponse',
      () async {
    final manager = await system.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: InMemoryEventStore(),
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
      ),
    );
    final probe = _Probe();
    final probeRef = await system.spawn('probe', () => probe);

    manager.tell(
      WalletCommandMessage('w1', SplitUTXOsToBenfordCommand(walletId: 'w1', targetUtxoCount: 3)),
      sender: probeRef,
    );
    final reply = await probe.received.stream.first.timeout(const Duration(seconds: 5));

    expect(reply, isA<SplitUTXOsResponse>());
    final split = reply as SplitUTXOsResponse;
    expect(split.walletId, 'w1');
    expect(split.success, isFalse);
    expect(split.error, 'Benford coordinator not available');
  });
}
