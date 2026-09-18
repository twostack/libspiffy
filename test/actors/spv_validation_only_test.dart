/// SPVActor: judging a transaction is not receiving it (bead libspiffy-6e5).
///
/// The receive path (`ReceiveTransactionMessage`) unconditionally tells the
/// WalletManager its verdict, because a receive credits a wallet. A caller
/// that only wants a verdict — the server judging the funding transaction of
/// a channel a client asks it to open, whose outputs it owns none of — used
/// that path with `targetWalletId: null`, so the WalletManager was told a
/// result naming no wallet, which it logs and drops on every channel open.
///
/// `ValidateCounterpartyTransactionMessage` runs the same validation and
/// answers the sender only.
library;

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';

import '../spv/testnet_proof_fixture.dart';
import 'channel_test_fixtures.dart';

const _clientPub =
    '02b4632d08485ff1df2db55b9dafd23347d1c47a457072a1e87be26896549a8737';
const _serverPub =
    '03774ae7f858a9411e5ef4246b70c65aac5649980be5c17891bbec17895da008cb';

void main() {
  late TestActorSystem system;
  late _RecordingWalletManager walletManager;
  late _SilentActor probe;
  late ActorRef probeRef;
  late ActorRef spvActor;
  late ({String hex, String txid, String beefHex}) funding;

  setUp(() async {
    system = TestActorSystem();
    walletManager = _RecordingWalletManager();
    probe = _SilentActor();
    final walletRef = await system.spawn('wallet-manager', () => walletManager);
    probeRef = await system.spawn('probe', () => probe);
    final invoiceRef = await system.spawn('invoices', () => _SilentActor());
    spvActor = await system.spawn(
      'spv',
      () => SPVActor(
        walletManager: walletRef,
        invoiceCoordinator: invoiceRef,
        storage: InMemoryWalletStorage(),
      ),
    );
    funding = channelFundingWithBeef(
      clientPubKeyHex: _clientPub,
      serverPubKeyHex: _serverPub,
      amountSats: BigInt.from(100000),
    );
  });

  tearDown(() async {
    await system.shutdown();
  });

  BEEF beef() => BEEF.parse(Uint8List.fromList(hex.decode(funding.beefHex)));

  /// Waits until [probe] has an [SPVValidationResult] for the funding
  /// transaction, and returns it.
  Future<SPVValidationResult> verdict() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (probe.received.whereType<SPVValidationResult>().isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        fail('the SPV actor never answered the sender');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return probe.received.whereType<SPVValidationResult>().first;
  }

  test('a receive naming no wallet still tells the wallet manager (the '
      'behaviour that made a channel open log a rejected result)', () async {
    spvActor.tell(
      ReceiveTransactionMessage(
        transactionId: funding.txid,
        beef: beef(),
        fromCounterparty: 'client-peer',
        targetWalletId: null,
      ),
      sender: probeRef,
    );

    final answer = await verdict();
    expect(answer.txid, funding.txid);
    expect(walletManager.results, hasLength(1),
        reason: 'the receive path always tells the wallet manager, which is '
            'why it is the wrong path for a question');
    expect(walletManager.results.single.targetWalletId, isNull);
  });

  test('a validation request is answered to the sender and to nobody else',
      () async {
    spvActor.tell(
      ValidateCounterpartyTransactionMessage(
        transactionId: funding.txid,
        beef: beef(),
        fromCounterparty: 'client-peer',
        requestId: 'open-chan-1',
      ),
      sender: probeRef,
    );

    final answer = await verdict();
    expect(answer.txid, funding.txid);
    expect(answer.targetWalletId, isNull,
        reason: 'a verdict credits nobody');
    expect(answer.requestId, 'open-chan-1');
    expect(answer.counterpartyMarker, 'client-peer');
    expect(walletManager.messages, isEmpty,
        reason: 'the wallet manager is told nothing about a transaction '
            'nobody is receiving (bead libspiffy-6e5)');
  });

  /// A BEEF carrying a real proof for a block whose header this actor does
  /// not hold: the validation cannot be finished either way.
  BEEF provenBeefWithNoHeader() => BEEF.create(
        bumps: [fixtureBump()],
        txs: [Uint8List.fromList(hex.decode(kFixtureTxHex))],
        hasMerkle: [true],
        bumpIndex: [0],
      );

  test('a verdict that cannot be reached yet does not promise a retry it will '
      'never make', () async {
    spvActor.tell(
      ValidateCounterpartyTransactionMessage(
        transactionId: kFixtureTxid,
        beef: provenBeefWithNoHeader(),
        fromCounterparty: 'client-peer',
      ),
      sender: probeRef,
    );

    final answer = await verdict();
    expect(answer.isValid, isFalse);
    expect(answer.validationError, contains('not synced'),
        reason: 'the header for the proof is genuinely missing');
    expect(answer.validationError, contains('retained'),
        reason: 'the evidence is still kept: the counterparty cannot hand it to us again');
    expect(answer.validationError, isNot(contains('automatically')),
        reason: 'nothing parks a verdict, so no retry happens — saying one does '
            'is telling the caller something untrue (bead libspiffy-6e5)');
  });

  test('a receive that cannot be judged yet does still promise its retry', () async {
    spvActor.tell(
      ReceiveTransactionMessage(
        transactionId: kFixtureTxid,
        beef: provenBeefWithNoHeader(),
        fromCounterparty: 'client-peer',
        targetWalletId: 'w',
      ),
      sender: probeRef,
    );

    final answer = await verdict();
    expect(answer.isValid, isFalse);
    expect(answer.validationError, contains('retried automatically'),
        reason: 'a receive IS parked and replayed when the header arrives');
  });

  test('a validation request for a transaction the BEEF does not carry is '
      'answered, not dropped', () async {
    spvActor.tell(
      ValidateCounterpartyTransactionMessage(
        transactionId: 'ff' * 32,
        beef: beef(),
        fromCounterparty: 'client-peer',
      ),
      sender: probeRef,
    );

    final answer = await verdict();
    expect(answer.isValid, isFalse,
        reason: 'the BEEF does not carry that transaction');
    expect(walletManager.messages, isEmpty);
  });
}

/// Records every message the SPV actor sends the wallet manager.
class _RecordingWalletManager extends Actor {
  final List<dynamic> messages = [];

  List<SPVValidationResult> get results =>
      messages.whereType<SPVValidationResult>().toList();

  @override
  Future<void> onMessage(dynamic message) async => messages.add(message);
}

/// Records everything and answers nothing.
class _SilentActor extends Actor {
  final List<dynamic> received = [];

  @override
  Future<void> onMessage(dynamic message) async => received.add(message);
}
