/// `WalletCoordinator.ask` (bead libspiffy-xc78.1): a request is answered
/// with its own reply, found by the request id the coordinator echoes on it,
/// whatever else is on the event stream; a failure throws; the coordinator
/// stopping fails what is still waiting.
///
/// The coordinator is built directly, around scripted actors that answer
/// the coordinator's internal requests when and how a test needs them to.
import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart' show GetProjectionInfo;
import 'package:test/test.dart';

import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/src/actors/payment_messages.dart' as pay;
import 'package:libspiffy/src/actors/wallet_messages.dart' as wm;
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/bump.dart';

const _wallet = 'wallet-1';

/// How long a test waits for an answer that should come at once.
const _wait = Duration(seconds: 5);

/// Answers each message [script] has a reply for, [delay] after it arrived,
/// to whoever sent it.
class _ScriptedActor extends Actor {
  final ({Message reply, Duration delay})? Function(Object message) script;

  _ScriptedActor(this.script);

  @override
  Future<void> onMessage(dynamic message) async {
    final answer = script(message as Object);
    final sender = context.sender;
    if (answer == null || sender == null) return;
    unawaited(Future<void>.delayed(answer.delay, () => sender.tell(answer.reply)));
  }
}

/// Storage whose UTXO reads fail.
class _UnreadableStorage extends InMemoryWalletStorage {
  @override
  Future<List<BitcoinUtxo>> getUTXOs(String walletId, {bool includeSpent = false}) =>
      Future.error(StateError('the UTXO table is unreadable'));
}

pay.BEEFPaymentResponse _paid(pay.PayInvoiceMessage m, {bool success = true, String? error}) =>
    pay.BEEFPaymentResponse(
      invoiceId: m.invoiceId,
      beefBytes: Uint8List(0),
      txid: success ? 'tx-paying-${m.amount}' : '',
      amountPaid: success ? m.amount : BigInt.zero,
      changeAmount: BigInt.zero,
      ancestorCount: 0,
      success: success,
      error: error,
    );

void main() {
  late LocalActorSystem system;
  late List<CoordinatorEvent> events;
  StreamSubscription<CoordinatorEvent>? subscription;
  late ActorRef ref;

  Future<WalletCoordinator> coordinatorWith({
    ({Message reply, Duration delay})? Function(Object message)? walletManager,
    ({Message reply, Duration delay})? Function(Object message)? paymentCoordinator,
    ({Message reply, Duration delay})? Function(Object message)? arc,
    ({Message reply, Duration delay})? Function(Object message)? walletProjection,
    ({Message reply, Duration delay})? Function(Object message)? spv,
    InMemoryWalletStorage? storage,
  }) async {
    final silent = await system.spawn('silent', () => _ScriptedActor((_) => null));
    Future<ActorRef> scripted(String name, ({Message reply, Duration delay})? Function(Object)? script) async =>
        script == null ? silent : system.spawn(name, () => _ScriptedActor(script));
    final actor = WalletCoordinatorActor(
      walletManager: await scripted('wallet-manager', walletManager),
      invoiceCoordinator: silent,
      paymentCoordinator: await scripted('payment-coordinator', paymentCoordinator),
      spvActor: await scripted('spv', spv),
      arcActor: await scripted('arc', arc),
      headerSyncActor: silent,
      benfordCoordinator: silent,
      channelManager: silent,
      walletProjection: await scripted('wallet-projection', walletProjection),
      storage: storage ?? InMemoryWalletStorage(),
    );
    subscription = actor.events.listen(events.add);
    ref = await system.spawn('coordinator', () => actor);
    return WalletCoordinator(ref, actor);
  }

  setUp(() {
    system = LocalActorSystem();
    events = [];
  });

  tearDown(() async {
    await subscription?.cancel();
    await system.shutdown();
  });

  test('a request keeps the id it was made with, given or generated', () {
    final given = GetBalanceQuery(walletId: _wallet, requestId: 'mine');
    expect(given.requestId, 'mine');
    expect(given.correlationId, 'mine');

    final generated = CreateInvoiceCommand(walletId: _wallet, amount: BigInt.one);
    expect(generated.requestId, isNotEmpty);
    expect(generated.requestId, generated.requestId, reason: 'read twice, the same id');
    expect(generated.correlationId, generated.requestId);
    expect(CreateInvoiceCommand(walletId: _wallet, amount: BigInt.one).requestId, isNot(generated.requestId));
  });

  test('two payments of one invoice from one wallet, at once, each get their own reply', () async {
    // The first payment is answered last: matching by type, or by wallet and
    // invoice, hands each caller the other's payment.
    final coordinator = await coordinatorWith(
      paymentCoordinator: (m) => m is pay.PayInvoiceMessage
          ? (reply: _paid(m), delay: Duration(milliseconds: m.amount == BigInt.from(1000) ? 200 : 10))
          : null,
    );
    PayInvoiceCommand payment(int sats) => PayInvoiceCommand(
        walletId: _wallet, invoiceId: 'invoice-1', addresses: const ['address'], amount: BigInt.from(sats));
    final first = payment(1000);
    final second = payment(2000);

    final answers = await Future.wait([coordinator.ask(first, timeout: _wait), coordinator.ask(second, timeout: _wait)]);

    expect(answers[0].txid, 'tx-paying-1000');
    expect(answers[0].requestId, first.requestId);
    expect(answers[0].walletId, _wallet);
    expect(answers[1].txid, 'tx-paying-2000');
    expect(answers[1].requestId, second.requestId);
    await Future<void>.delayed(Duration.zero);
    expect(events.whereType<PaymentReadyEvent>().map((e) => e.requestId),
        unorderedEquals([first.requestId, second.requestId]),
        reason: 'the replies are published on the event stream as well');
  });

  test('a failed request throws, carrying the reply that reported it', () async {
    final coordinator = await coordinatorWith(
      paymentCoordinator: (m) => m is pay.PayInvoiceMessage
          ? (reply: _paid(m, success: false, error: 'no spendable UTXOs'), delay: Duration.zero)
          : null,
    );
    final request = PayInvoiceCommand(
        walletId: _wallet, invoiceId: 'invoice-1', addresses: const ['address'], amount: BigInt.from(1000));

    final failure = await coordinator.ask(request, timeout: _wait).then<Object>((_) => 'answered', onError: (Object e) => e);

    expect(failure, isA<CoordinatorFailure>());
    failure as CoordinatorFailure;
    expect(failure.requestId, request.requestId);
    expect(failure.message, 'no spendable UTXOs');
    expect(failure.closed, isFalse);
    expect(failure.event, isA<PaymentReadyEvent>().having((e) => e.requestId, 'requestId', request.requestId));
  });

  test('an ErrorEvent naming the request fails its ask', () async {
    final coordinator = await coordinatorWith(storage: _UnreadableStorage());
    final query = GetBalanceQuery(walletId: _wallet);

    final failure = await coordinator.ask(query, timeout: _wait).then<Object>((_) => 'answered', onError: (Object e) => e);

    expect(failure, isA<CoordinatorFailure>());
    failure as CoordinatorFailure;
    expect(failure.event, isA<ErrorEvent>().having((e) => e.requestId, 'requestId', query.requestId));
    expect(failure.message, contains('the UTXO table is unreadable'));
    expect(failure.stillSent, isFalse);
  });

  test('a failure says whether what failed is still being sent', () {
    ErrorEvent error({required bool stillSent}) =>
        ErrorEvent(source: 'test', message: 'not acknowledged', requestId: 'r1', stillSent: stillSent);

    expect(CoordinatorFailure('r1', 'x', event: error(stillSent: true)).stillSent, isTrue);
    expect(CoordinatorFailure('r1', 'x', event: error(stillSent: false)).stillSent, isFalse);
    expect(const CoordinatorFailure('r1', 'stopped').stillSent, isFalse);
  });

  test('a request still waiting when the coordinator stops fails as closed, and so does one sent after', () async {
    // The wallet manager never answers: the creation waits.
    final coordinator = await coordinatorWith(walletManager: (_) => null);
    final waiting = coordinator
        .ask(CreateWalletCommand(walletId: _wallet, name: 'w'))
        .then<Object>((_) => 'answered', onError: (Object e) => e);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await system.stop(ref);

    final failure = await waiting.timeout(const Duration(seconds: 5));
    expect(failure, isA<CoordinatorFailure>().having((f) => f.closed, 'closed', isTrue));
    expect(
        await coordinator
            .ask(GetBalanceQuery(walletId: _wallet))
            .then<Object>((_) => 'answered', onError: (Object e) => e)
            .timeout(const Duration(seconds: 5)),
        isA<CoordinatorFailure>().having((f) => f.closed, 'closed', isTrue));
  });

  test('a timeout does not cancel the request: its reply still arrives on the event stream', () async {
    final coordinator = await coordinatorWith(
      walletManager: (m) => m is wm.CreateWalletMessage
          ? (reply: wm.WalletCreatedMessage(m.walletId, 'root', false, error: 'refused'), delay: const Duration(milliseconds: 300))
          : null,
    );
    final request = CreateWalletCommand(walletId: _wallet, name: 'w');

    await expectLater(coordinator.ask(request, timeout: const Duration(milliseconds: 50)), throwsA(isA<TimeoutException>()));

    final late = await coordinator
        .on<WalletCreatedEvent>()
        .firstWhere((e) => e.requestId == request.requestId)
        .timeout(const Duration(seconds: 5));
    expect(late.error, 'refused');
  });

  test('a request id cannot be awaited twice at once', () async {
    final coordinator = await coordinatorWith(walletManager: (_) => null);
    final request = CreateWalletCommand(walletId: _wallet, name: 'w', requestId: 'same');
    unawaited(coordinator.ask(request).then<void>((_) {}, onError: (_) {}));

    await expectLater(coordinator.ask(CreateWalletCommand(walletId: 'other', name: 'w', requestId: 'same')),
        throwsA(isA<StateError>()));
  });

  test('on<E> follows the events of one type, of one wallet when named', () async {
    final coordinator = await coordinatorWith(
      walletManager: (m) => m is wm.CreateWalletMessage
          ? (reply: wm.WalletCreatedMessage(m.walletId, '', false, error: 'refused'), delay: Duration.zero)
          : null,
    );
    final seen = <WalletCreatedEvent>[];
    final sub = coordinator.on<WalletCreatedEvent>(walletId: 'b').listen(seen.add);

    coordinator.tell(CreateWalletCommand(walletId: 'a', name: 'a'));
    coordinator.tell(CreateWalletCommand(walletId: 'b', name: 'b'));
    coordinator.tell(GetBalanceQuery(walletId: 'b'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sub.cancel();

    expect(seen.map((e) => e.walletId), ['b']);
  });

  test('a timestamp is answered with ARC\'s answer to its broadcast, not when the broadcast is handed over',
      () async {
    var arcAnswer = 'REJECTED';
    final coordinator = await coordinatorWith(
      paymentCoordinator: (m) => m is pay.PayInvoiceMessage ? (reply: _paid(m), delay: Duration.zero) : null,
      arc: (m) => m is wm.BroadcastBEEFMessage
          ? (
              reply: arcAnswer == 'REJECTED'
                  ? wm.BroadcastFailedMessage(m.txid, 'ARC rejected ${m.txid}', networkStatus: 'REJECTED')
                  : wm.BroadcastSuccessMessage(m.txid, m.txid, networkStatus: arcAnswer),
              delay: const Duration(milliseconds: 100)
            )
          : null,
    );
    TimestampCommand stamp() => TimestampCommand(archiveId: 'a1', walletId: _wallet, fileHashes: const ['hash']);

    final refused = await coordinator.ask(stamp(), timeout: _wait).then<Object>((_) => 'answered', onError: (Object e) => e);
    expect(refused, isA<CoordinatorFailure>());
    expect((refused as CoordinatorFailure).message, contains('ARC rejected tx-paying-0'));

    arcAnswer = 'SEEN_ON_NETWORK';
    final stamped = await coordinator.ask(stamp(), timeout: _wait);
    expect(stamped.transactionId, 'tx-paying-0');
  });

  test('a release is answered once the read model shows the UTXOs it released available', () async {
    final storage = InMemoryWalletStorage();
    final utxo = BitcoinUtxo.create(
      txid: 'aa' * 32,
      vout: 0,
      satoshis: BigInt.from(1000),
      scriptPubKey: '',
      address: 'address',
      status: UTXOStatus.reserved,
    );
    await storage.upsertUTXO(_wallet, utxo);
    final coordinator = await coordinatorWith(
      storage: storage,
      walletManager: (m) => m is wm.WalletCommandMessage
          ? (
              reply: wm.UTXOsReleasedResponse(
                  walletId: _wallet, reservationId: 'r1', releasedUtxoKeys: ['${'aa' * 32}:0'], success: true),
              delay: Duration.zero
            )
          : null,
      // The projection says it is running, and never that it applied the
      // release: only the read model's row can show that.
      walletProjection: (m) => m is GetProjectionInfo ? (reply: LocalMessage(payload: 'running'), delay: Duration.zero) : null,
    );

    await expectLater(
        coordinator.ask(ReleaseUTXOsCommand(walletId: _wallet, reservationId: 'r1'), timeout: const Duration(seconds: 1)),
        throwsA(isA<TimeoutException>()),
        reason: 'the row still says reserved');

    await storage.upsertUTXO(_wallet, utxo.copyWith(status: UTXOStatus.available));
    final released = await coordinator.ask(ReleaseUTXOsCommand(walletId: _wallet, reservationId: 'r1'), timeout: _wait);
    expect(released.releasedUtxoKeys, ['${'aa' * 32}:0']);
  });

  test('a payment waiting for its block header is answered, not failed, and its verdict names the request', () async {
    // A real testnet transaction, unproven, in a BEEF.
    const txHex =
        '02000000013706d29b641d2061b0b7b22c81ec6a5670104826bee4472a7513619f4fc298df000000006a473044022021fb2500cfd69bf3d7eee8f16d2e1d6d49528dbe23e9105744202bd9e5b5789102204ff801667c156b97e92209c19dce9bbdd955ee35cea7b815cf9e3b0c1b6727174121022036646b3fd79dee41351f727f0a6e10d0e7f98585961bc14e7aadaf5f4b66ab0100000002a0443b00000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac96000000000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac00000000';
    final beefHex = hex.encode(BEEF
        .create(
            bumps: const [],
            txs: [Uint8List.fromList(hex.decode(txHex))],
            hasMerkle: const [false],
            bumpIndex: const [])
        .serialize());
    wm.ReceiveTransactionMessage? parked;
    final coordinator = await coordinatorWith(
      spv: (m) => switch (m) {
        wm.ValidateBEEFMessage() => (
            reply: wm.BEEFValidationResult(isValid: true, targetWalletId: _wallet, requestId: m.requestId),
            delay: Duration.zero
          ),
        wm.ReceiveTransactionMessage() => (
            reply: wm.SPVValidationResult(
                txid: (parked = m).transactionId,
                isValid: false,
                validationError: 'Block header(s) at height(s) 900 are not synced yet',
                targetWalletId: _wallet,
                awaitingHeader: true,
                requestId: m.requestId),
            delay: Duration.zero
          ),
        _ => null,
      },
    );
    final request = ValidateBEEFCommand(walletId: _wallet, beefHex: beefHex);

    final waiting = await coordinator.ask(request, timeout: _wait);
    expect(waiting.awaitingHeader, isTrue);
    expect(waiting.valid, isFalse);
    expect(waiting.failure, isNull, reason: 'not decided is not refused');

    // The header arrives and the receive is replayed with its id: here the
    // proof does not match it.
    final verdict = coordinator
        .on<BEEFValidationResultEvent>()
        .firstWhere((e) => !e.awaitingHeader)
        .timeout(_wait);
    ref.tell(wm.SPVValidationResult(
        txid: parked!.transactionId,
        isValid: false,
        validationError: 'the merkle root does not match the header',
        targetWalletId: _wallet,
        requestId: parked!.requestId));
    final decided = await verdict;
    expect(decided.requestId, request.requestId);
    expect(decided.failure, contains('merkle root'));
  });

  test('a failed broadcast nobody waits on says whether ARC queued a retry', () async {
    await coordinatorWith();
    ref.tell(wm.BroadcastFailedMessage('aa' * 32, 'ARC unreachable', willRetry: false));
    ref.tell(wm.BroadcastFailedMessage('bb' * 32, 'ARC unreachable', willRetry: true));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(events.whereType<BroadcastFailureEvent>().map((e) => (e.txid, e.willRetry)),
        [('aa' * 32, false), ('bb' * 32, true)]);
  });

  test('an import whose proof waits for a block header is answered by the verdict the header brings', () async {
    const txHex =
        '02000000013706d29b641d2061b0b7b22c81ec6a5670104826bee4472a7513619f4fc298df000000006a473044022021fb2500cfd69bf3d7eee8f16d2e1d6d49528dbe23e9105744202bd9e5b5789102204ff801667c156b97e92209c19dce9bbdd955ee35cea7b815cf9e3b0c1b6727174121022036646b3fd79dee41351f727f0a6e10d0e7f98585961bc14e7aadaf5f4b66ab0100000002a0443b00000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac96000000000000001976a914f82d58dd8487044d8d0879c15a2a3516a425de2a88ac00000000';
    const txid = 'dd6e7547df0fe893a9a19f66f0377eca72fdcd18fd9f6185fde9c91461a8e8a9';
    // The transaction with its proof: alone in its block, so the proof has
    // no siblings.
    final beef = BEEF.create(
        bumps: [BUMP.fromTscProof(blockHeight: 900, txid: txid, index: 0, nodes: const [])],
        txs: [Uint8List.fromList(hex.decode(txHex))],
        hasMerkle: const [true],
        bumpIndex: const [0]);
    wm.ReceiveTransactionMessage? parked;
    final coordinator = await coordinatorWith(
      spv: (m) => m is wm.ReceiveTransactionMessage
          ? (
              reply: wm.SPVValidationResult(
                  txid: (parked = m).transactionId,
                  isValid: false,
                  validationError: 'Block header(s) at height(s) 900 are not synced yet',
                  targetWalletId: _wallet,
                  awaitingHeader: true,
                  subjectCarriesProof: true,
                  requestId: m.requestId),
              delay: Duration.zero
            )
          : null,
    );
    final request = ImportTransactionCommand(walletId: _wallet, beef: beef.serialize());
    final answer = coordinator
        .ask(request, timeout: _wait)
        .then<Object>((_) => 'answered', onError: (Object e) => e);

    // Nothing answers while the header is missing; then it arrives, and the
    // proof does not match it.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(parked, isNotNull);
    ref.tell(wm.SPVValidationResult(
        txid: txid,
        isValid: false,
        validationError: 'the merkle root does not match the header',
        targetWalletId: _wallet,
        subjectCarriesProof: true,
        requestId: parked!.requestId));

    final failure = await answer;
    expect(failure, isA<CoordinatorFailure>());
    failure as CoordinatorFailure;
    expect(failure.event, isA<TransactionImportedEvent>().having((e) => e.requestId, 'requestId', request.requestId));
    expect(failure.message, contains('merkle root'));
  });
}

