/// PaymentChannelManagerActor surfaces channel aggregate rejections
/// (libspiffy-lhd).
///
/// Since audit M10 the PaymentChannelAggregate rejects invalid commands and
/// answers them with `{'success': false, 'error': ...}`. The manager used to
/// forward several of those rejections to its caller as `success: true`:
/// acknowledging or recording a payment, and completing a refund signature.
/// Other paths lost the aggregate's error text.
///
/// The channel aggregate is real, over an in-memory journal. The WalletManager
/// is a stub that answers address generation with a fixed key and signs every
/// multisig request successfully, so each command reaches the aggregate.

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' show NetworkType;
import 'package:eventador/eventador.dart' show Event;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/channel_p2p_adapter.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/payment_channel_manager_actor.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';

import 'channel_test_fixtures.dart';
import 'in_memory_event_store.dart';

const _walletId = 'channel-wallet';
const _channelId = 'chan-reject';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _timeout = Duration(seconds: 10);
final _funding = BigInt.from(100000);

/// The channel lockTime, one day ahead, fixed when the test starts: the
/// server countersigns only a refund with the channel lockTime
/// (libspiffy-fsy), so every message of a test carries the same value.
late int _lockTime;
int _lockTimeInADay() => _lockTime;

void main() {
  late TestActorSystem actorSystem;
  late DartSVCryptoService cryptoService;
  late PaymentChannelManagerActor manager;
  late ActorRef managerRef;
  late _SigningWalletManager walletStub;
  late List<ChannelEvent> broadcast;
  late StreamController<ChannelEvent> channelEvents;
  late _ReadCountingEventStore eventStore;

  late String clientPubKeyHex;
  late String clientAddressB58;
  late String serverPubKeyHex;
  late String serverAddressB58;

  /// Funding transaction locking [_funding] in the channel 2-of-2, with its
  /// BEEF: the server checks both on open (libspiffy-9f7, libspiffy-fsy).
  late ({String hex, String txid, String beefHex}) fundingTx;
  late ScriptedSpvActor spv;

  setUp(() async {
    _lockTime =
        DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
            1000;
    actorSystem = TestActorSystem();
    cryptoService = DartSVCryptoService();
    final hd = await cryptoService.mnemonicToHDPrivateKey(_mnemonic);
    final client = hd.deriveChildKey('m/0/1').privateKey.publicKey;
    final server = hd.deriveChildKey('m/0/2').privateKey.publicKey;
    clientPubKeyHex = client.toString();
    clientAddressB58 = client.toAddress(NetworkType.TEST).toString();
    serverPubKeyHex = server.toString();
    serverAddressB58 = server.toAddress(NetworkType.TEST).toString();
    fundingTx = channelFundingWithBeef(
        clientPubKeyHex: clientPubKeyHex,
        serverPubKeyHex: serverPubKeyHex,
        amountSats: _funding);
    broadcast = [];
    channelEvents = StreamController<ChannelEvent>.broadcast();
  });

  tearDown(() async {
    await actorSystem.shutdown();
    await channelEvents.close();
  });

  Future<void> spawn({required bool asClient}) async {
    walletStub = _SigningWalletManager(
      pubKeyHex: asClient ? clientPubKeyHex : serverPubKeyHex,
      addressB58: asClient ? clientAddressB58 : serverAddressB58,
    );
    final walletRef =
        await actorSystem.spawn('wallet-manager', () => walletStub);
    spv = ScriptedSpvActor();
    final spvRef = await actorSystem.spawn('spv', () => spv);
    manager = PaymentChannelManagerActor(
      walletManager: walletRef,
      eventStore: eventStore = _ReadCountingEventStore(),
      cryptoService: cryptoService,
      networkType: NetworkType.TEST,
      eventBroadcaster: (event) {
        broadcast.add(event);
        channelEvents.add(event);
      },
      signingTimeout: const Duration(seconds: 2),
      spvActor: spvRef,
    );
    managerRef = await actorSystem.spawn('channel-manager', () => manager);
  }

  Future<ChannelStateResponse> queryState() =>
      managerRef.ask<ChannelStateResponse>(
        QueryChannelStateMessage(channelId: _channelId),
        _timeout,
      );

  Future<void> expectState(
    String status, {
    required int sequence,
    required int client,
    required int server,
  }) async {
    final state = await queryState();
    expect(state.success, isTrue, reason: state.error);
    expect(state.status, equals(status));
    expect(state.latestSequenceNumber, equals(sequence));
    expect(state.clientBalanceSats, equals(BigInt.from(client)));
    expect(state.serverBalanceSats, equals(BigInt.from(server)));
  }

  Future<ChannelAcceptedResponse> acceptChannel() =>
      managerRef.ask<ChannelAcceptedResponse>(
        AcceptChannelMessage(
          channelId: _channelId,
          walletId: _walletId,
          clientPeerId: 'client-peer',
          clientPubKeyHex: clientPubKeyHex,
          clientAddressB58: clientAddressB58,
          fundingAmountSats: _funding,
          lockTimeUnix: _lockTimeInADay(),
        ),
        _timeout,
      );

  Future<String> buildRefund() async {
    final built = await managerRef.ask<RefundTransactionBuiltResponse>(
      BuildRefundTransactionMessage(
        channelId: _channelId,
        walletId: _walletId,
        fundingTxId: fundingTx.txid,
        fundingOutputIndex: 0,
        fundingAmountSats: _funding,
        clientPubKeyHex: clientPubKeyHex,
        clientAddressB58: clientAddressB58,
        serverPubKeyHex: serverPubKeyHex,
        serverAddressB58: serverAddressB58,
        lockTimeUnix: _lockTimeInADay(),
      ),
      _timeout,
    );
    expect(built.success, isTrue, reason: built.error);
    return built.refundTxHex;
  }

  Future<RefundTransactionSignedResponse> signRefund(String refundTxHex) =>
      managerRef.ask<RefundTransactionSignedResponse>(
        SignRefundTransactionMessage(
          channelId: _channelId,
          walletId: _walletId,
          refundTxHex: refundTxHex,
          clientPubKeyHex: clientPubKeyHex,
          serverPubKeyHex: serverPubKeyHex,
          serverAddressB58: serverAddressB58,
          derivationIndex: 2,
          fundingAmountSats: _funding,
          lockTimeUnix: _lockTimeInADay(),
        ),
        _timeout,
      );

  Future<ChannelOpenedResponse> openChannel() =>
      managerRef.ask<ChannelOpenedResponse>(
        OpenChannelMessage(
          channelId: _channelId,
          fundingTxId: fundingTx.txid,
          fundingOutputIndex: 0,
          fundingTxHex: fundingTx.hex,
          fundingBeefHex: fundingTx.beefHex,
        ),
        _timeout,
      );

  Future<PaymentAcknowledgedResponse> acknowledge({
    required int sequence,
    required int client,
    required int server,
  }) =>
      managerRef.ask<PaymentAcknowledgedResponse>(
        AcknowledgePaymentMessage(
          channelId: _channelId,
          walletId: _walletId,
          amountSats: BigInt.from(1000),
          paymentTxHex: 'ab' * 40,
          clientSignatureHex: '30' * 36,
          proposedSequence: sequence,
          proposedClientBalance: BigInt.from(client),
          proposedServerBalance: BigInt.from(server),
        ),
        _timeout,
      );

  /// Server side: accepted, refund countersigned, opened.
  Future<void> openServerChannel() async {
    await spawn(asClient: false);
    final accepted = await acceptChannel();
    expect(accepted.success, isTrue, reason: accepted.error);
    final signed = await signRefund(await buildRefund());
    expect(signed.success, isTrue, reason: signed.error);
    final opened = await openChannel();
    expect(opened.success, isTrue, reason: opened.error);
  }

  /// Client side: requested, acceptance and refund signature recorded.
  Future<void> initiateClientChannel({int lockTimeDurationSeconds = 86400}) async {
    await spawn(asClient: true);
    final initiated = await managerRef.ask<ChannelInitiatedResponse>(
      InitiateChannelMessage(
        channelId: _channelId,
        walletId: _walletId,
        clientPeerId: 'client-peer',
        serverPeerId: 'server-peer',
        fundingAmountSats: _funding,
        lockTimeDurationSeconds: lockTimeDurationSeconds,
      ),
      _timeout,
    );
    expect(initiated.success, isTrue, reason: initiated.error);
  }

  /// Client side: a journal of an open channel (verified refund, funding
  /// broadcast), as the client flow leaves it (libspiffy-b83, 9f7).
  Future<void> openClientChannelFromJournal({required int lockTimeUnix}) async {
    await spawn(asClient: true);
    final fixture = await ChannelRefundFixture.create(
        channelId: _channelId, lockTimeUnix: lockTimeUnix);
    await eventStore.persistEvents('PaymentChannel_$_channelId',
        fixture.openClientJournal(walletId: _walletId), 0);
  }

  group('6e5: the server validates the funding BEEF, it does not receive it',
      () {
    test('the SPV actor is asked for a verdict, never for a receive',
        () async {
      await openServerChannel();

      expect(spv.requests, hasLength(1),
          reason: 'the server SPV-validates the funding transaction once');
      expect(spv.receives, isEmpty,
          reason: 'a receive tells the WalletManager its result. The server '
              'owns nothing in the client funding transaction, so that '
              'result names no wallet and the WalletManager logs and drops '
              'it on every channel open (bead libspiffy-6e5)');
      final request =
          spv.requests.single as ValidateCounterpartyTransactionMessage;
      expect(request.transactionId, fundingTx.txid);
      expect(request.fromCounterparty, 'client-peer');
    });

    test('a funding transaction the SPV actor refuses does not open the '
        'channel', () async {
      await spawn(asClient: false);
      spv.invalidWith = 'merkle proof does not match our chain';
      final accepted = await acceptChannel();
      expect(accepted.success, isTrue, reason: accepted.error);
      final signed = await signRefund(await buildRefund());
      expect(signed.success, isTrue, reason: signed.error);

      final opened = await openChannel();

      expect(opened.success, isFalse);
      expect(opened.error, contains('merkle proof does not match our chain'));
      expect(spv.receives, isEmpty);
    });
  });

  group('lhd: rejected commands fail the caller', () {
    test('server: acknowledging a payment whose balances do not sum to the '
        'funding amount fails, and a valid acknowledgement still works',
        () async {
      await openServerChannel();
      broadcast.clear();

      final rejected =
          await acknowledge(sequence: 1, client: 100000, server: 1000);

      expect(rejected.success, isFalse,
          reason: 'the aggregate rejected the acknowledgement');
      expect(rejected.error, contains('do not sum to the funding amount'));
      expect(broadcast, isEmpty);
      expect(manager.pendingSignatureCount, equals(0));
      await expectState('open', sequence: 0, client: 100000, server: 0);

      final valid = await acknowledge(sequence: 1, client: 99000, server: 1000);

      expect(valid.success, isTrue, reason: valid.error);
      expect(valid.sequenceNumber, equals(1));
      expect(broadcast.whereType<PaymentAcknowledgedEvent>(), hasLength(1));
      expect(manager.pendingSignatureCount, equals(0));
      await expectState('open', sequence: 1, client: 99000, server: 1000);
    });

    test('a rejected command costs no journal recovery: the same channel '
        'aggregate serves the next command (libspiffy-201)', () async {
      await openServerChannel();
      final aggregate = actorSystem.getActor('channel-$_channelId');
      final recoveries = eventStore.reads('PaymentChannel_$_channelId');
      expect(recoveries, equals(1));

      final rejected =
          await acknowledge(sequence: 1, client: 100000, server: 1000);
      expect(rejected.success, isFalse);
      final valid = await acknowledge(sequence: 1, client: 99000, server: 1000);
      expect(valid.success, isTrue, reason: valid.error);

      // 14d1b52 stopped the aggregate on every rejection and recovered a new
      // one from the journal for the next command.
      expect(eventStore.reads('PaymentChannel_$_channelId'), equals(recoveries),
          reason: 'a rejection must not trigger a journal recovery');
      expect(identical(actorSystem.getActor('channel-$_channelId'), aggregate),
          isTrue);
    });

    test('a journal write failure fails the command, and the next command is '
        'served by an aggregate recovered from the journal (libspiffy-u0x)',
        () async {
      await openServerChannel();
      final recoveries = eventStore.reads('PaymentChannel_$_channelId');

      eventStore.failPersist = true;
      final failed = await acknowledge(sequence: 1, client: 99000, server: 1000);
      expect(failed.success, isFalse);
      expect(failed.error, contains('journal unavailable'));

      eventStore.failPersist = false;
      // The out-of-service aggregate is retired, not told this command.
      final valid = await acknowledge(sequence: 1, client: 99000, server: 1000);
      expect(valid.success, isTrue, reason: valid.error);
      expect(eventStore.reads('PaymentChannel_$_channelId'), equals(recoveries + 1));
      await expectState('open', sequence: 1, client: 99000, server: 1000);
    });

    test('client: recording a payment the aggregate rejects fails, and the '
        'channel still closes', () async {
      // A lock time of "now": the channel is expired as soon as it exists.
      // The manager does not check expiry; the aggregate does.
      await openClientChannelFromJournal(
          lockTimeUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000);
      await expectState('open', sequence: 0, client: 100000, server: 0);
      broadcast.clear();

      final paid = await managerRef.ask<PaymentRecordedResponse>(
        RecordPaymentMessage(
          channelId: _channelId,
          walletId: _walletId,
          amountSats: BigInt.from(1000),
        ),
        _timeout,
      );

      expect(walletStub.signRequests, equals(1),
          reason: 'the payment was signed and sent to the aggregate');
      expect(paid.success, isFalse,
          reason: 'the aggregate rejected the payment');
      expect(paid.error, contains('Channel has expired'));
      expect(broadcast, isEmpty);
      expect(manager.pendingSignatureCount, equals(0));
      await expectState('open', sequence: 0, client: 100000, server: 0);

      final closed = await managerRef.ask<ChannelClosedResponse>(
        CloseChannelMessage(channelId: _channelId, reason: 'expired'),
        _timeout,
      );
      expect(closed.success, isTrue, reason: closed.error);
      expect(broadcast.whereType<ChannelClosingEvent>(), hasLength(1));
    });

    test('server: countersigning the refund of a channel that is no longer '
        'accepted fails, and the channel still opens', () async {
      await spawn(asClient: false);
      final accepted = await acceptChannel();
      expect(accepted.success, isTrue, reason: accepted.error);
      final refundTxHex = await buildRefund();
      final first = await signRefund(refundTxHex);
      expect(first.success, isTrue, reason: first.error);
      broadcast.clear();

      final second = await signRefund(refundTxHex);

      // The channel is no longer accepted: the request is refused before a
      // signature is produced (libspiffy-36f reads the channel state first).
      expect(walletStub.signRequests, equals(1));
      expect(second.success, isFalse,
          reason: 'the channel is refundSigned, not accepted');
      expect(second.error, contains('Channel not in accepted state'));
      expect(broadcast, isEmpty);
      expect(manager.pendingSignatureCount, equals(0));
      await expectState('refundSigned', sequence: 0, client: 100000, server: 0);

      final opened = await openChannel();
      expect(opened.success, isTrue, reason: opened.error);
      await expectState('open', sequence: 0, client: 100000, server: 0);
    });

    test('client: recording server acceptance twice answers the second with '
        'the rejection', () async {
      await initiateClientChannel();

      final first = await managerRef.ask<ServerAcceptanceRecordedResponse>(
        RecordServerAcceptanceMessage(
          channelId: _channelId,
          serverPubKeyHex: serverPubKeyHex,
          serverAddressB58: serverAddressB58,
        ),
        const Duration(seconds: 3),
      );
      expect(first.success, isTrue, reason: first.error);
      broadcast.clear();

      final second = await managerRef.ask<ServerAcceptanceRecordedResponse>(
        RecordServerAcceptanceMessage(
          channelId: _channelId,
          serverPubKeyHex: serverPubKeyHex,
          serverAddressB58: serverAddressB58,
        ),
        const Duration(seconds: 3),
      );

      expect(second.success, isFalse);
      expect(second.error, contains('Channel not in pending state'));
      expect(broadcast, isEmpty);
      await expectState('accepted', sequence: 0, client: 100000, server: 0);
    });

    test('server: accepting a channel twice reports the aggregate error',
        () async {
      await spawn(asClient: false);
      final first = await acceptChannel();
      expect(first.success, isTrue, reason: first.error);

      final second = await acceptChannel();

      expect(second.success, isFalse);
      expect(second.error, contains('Channel not in pending state'));
    });

    test('a rejected channel request reports the aggregate error, and a '
        'payment on it reports the channel as not found', () async {
      await spawn(asClient: true);
      final initiated = await managerRef.ask<ChannelInitiatedResponse>(
        InitiateChannelMessage(
          channelId: _channelId,
          walletId: _walletId,
          clientPeerId: 'client-peer',
          serverPeerId: 'server-peer',
          fundingAmountSats: BigInt.zero,
          lockTimeDurationSeconds: 86400,
        ),
        _timeout,
      );
      expect(initiated.success, isFalse);
      expect(initiated.error, contains('Funding amount must be positive'));
      expect(broadcast, isEmpty);
      // A rejected aggregate keeps running (libspiffy-201); one that holds no
      // channel is not kept, or every rejected request would leave an actor.
      expect(actorSystem.getActor('channel-$_channelId'), isNull);

      final paid = await managerRef.ask<PaymentRecordedResponse>(
        RecordPaymentMessage(
          channelId: _channelId,
          walletId: _walletId,
          amountSats: BigInt.from(1000),
        ),
        _timeout,
      );
      expect(paid.success, isFalse);
      expect(paid.error, contains('not found'));
      expect(walletStub.signRequests, equals(0));
    });
  });

  group('lhd: ChannelP2PAdapter over a rejecting manager', () {
    test('a payment_update the server rejects gets no payment_ack; a valid '
        'one does', () async {
      await spawn(asClient: false);
      final emitted = <coord.CoordinatorEvent>[];
      final adapter = ChannelP2PAdapter(
        channelManager: managerRef,
        walletManager: await actorSystem.spawn(
            'unused-wallet', () => _SigningWalletManager(pubKeyHex: '', addressB58: '')),
        emitEvent: emitted.add,
        channelEvents: channelEvents.stream,
        walletId: _walletId,
        myPeerId: 'server-peer',
      );
      addTearDown(adapter.dispose);

      List<Map<String, dynamic>> sent(String type) => emitted
          .whereType<coord.ChannelP2PMessageToSendEvent>()
          .where((e) => e.messageType == type)
          .map((e) => e.payload)
          .toList();

      Future<void> waitFor(bool Function() condition) async {
        final deadline = DateTime.now().add(_timeout);
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            fail('timed out; emitted: $emitted');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      adapter.handleP2PMessage('client-peer', 'channel_request', {
        'channelId': _channelId,
        'clientPubKey': clientPubKeyHex,
        'clientAddress': clientAddressB58,
        'fundingAmountSats': 100000,
        'lockTimeUnix': _lockTimeInADay(),
        'context': null,
      });
      adapter.handleAcceptRequest(coord.AcceptChannelCommand(
        channelId: _channelId,
        walletId: _walletId,
        clientPeerId: 'client-peer',
        clientPubKey: clientPubKeyHex,
        clientAddress: clientAddressB58,
        fundingAmountSats: 100000,
        lockTimeUnix: _lockTimeInADay(),
      ));
      await waitFor(() => sent('channel_accept').isNotEmpty);

      adapter.handleP2PMessage('client-peer', 'refund_sign_request', {
        'channelId': _channelId,
        'refundTxHex': await buildRefund(),
        'fundingTxId': fundingTx.txid,
        'fundingOutputIndex': 0,
        'fundingTxHex': fundingTx.hex,
        'clientSignatureHex': '',
      });
      await waitFor(() => sent('refund_signed').isNotEmpty);

      adapter.handleP2PMessage('client-peer', 'channel_open', {
        'channelId': _channelId,
        'fundingTxId': fundingTx.txid,
        'fundingOutputIndex': 0,
        'fundingTxHex': fundingTx.hex,
        'fundingBeef': fundingTx.beefHex,
      });
      await waitFor(() => emitted.whereType<coord.ChannelOpenedEvent>().isNotEmpty);

      Map<String, dynamic> paymentUpdate(int client, int server) => {
            'channelId': _channelId,
            'amountSats': 1000,
            'paymentTxHex': 'ab' * 40,
            'clientSignatureHex': '30' * 36,
            'proposedSequence': 1,
            'proposedClientBalance': client,
            'proposedServerBalance': server,
          };

      // Rejected by the aggregate (balances sum to 101000), then a valid one
      // with the same sequence number. The manager handles them in order.
      adapter.handleP2PMessage(
          'client-peer', 'payment_update', paymentUpdate(100000, 1000));
      adapter.handleP2PMessage(
          'client-peer', 'payment_update', paymentUpdate(99000, 1000));
      await waitFor(() => sent('payment_ack').isNotEmpty);
      await expectState('open', sequence: 1, client: 99000, server: 1000);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(sent('payment_ack'), hasLength(1),
          reason: 'only the accepted payment is acknowledged to the peer');
      expect(sent('payment_ack').single['sequenceNumber'], equals(1));
      expect(emitted.whereType<coord.ChannelPaymentEvent>(), hasLength(1));
      expect(emitted.whereType<coord.ChannelPaymentEvent>().single.serverBalance,
          equals(1000));
      expect(manager.pendingSignatureCount, equals(0));
    });
  });
}

/// Answers address generation with a fixed key and signs every multisig
/// request successfully (with a placeholder signature).
class _SigningWalletManager extends Actor {
  final String pubKeyHex;
  final String addressB58;
  int signRequests = 0;

  _SigningWalletManager({required this.pubKeyHex, required this.addressB58});

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! WalletCommandMessage) return;
    final command = message.command;
    if (command is GenerateAddressCommand) {
      context.sender?.tell(AddressGeneratedResponse(
        walletId: command.walletId,
        address: addressB58,
        derivationIndex: 2,
        success: true,
        publicKeyHex: pubKeyHex,
      ));
    } else if (command is SignMultisigTransactionCommand) {
      signRequests++;
      context.sender?.tell(MultisigTransactionSignedResponse(
        walletId: command.walletId,
        txid: 'c' * 64,
        originalTransactionId: command.transactionId,
        signedHex: command.rawTransaction,
        signatureHex: '30${signRequests.toRadixString(16).padLeft(2, '0')}',
        success: true,
      ));
    }
  }
}

/// In-memory journal that counts event reads (one per aggregate recovery).
class _ReadCountingEventStore extends InMemoryEventStore {
  final Map<String, int> _reads = {};

  /// Makes every journal write fail.
  bool failPersist = false;

  @override
  Future<void> persistEvents(String persistenceId, List<Event> events, int expectedVersion) async {
    if (failPersist) throw StateError('journal unavailable');
    await super.persistEvents(persistenceId, events, expectedVersion);
  }

  @override
  Future<void> persistEvent(String persistenceId, Event event, int expectedVersion) async {
    if (failPersist) throw StateError('journal unavailable');
    await super.persistEvent(persistenceId, event, expectedVersion);
  }

  int reads(String persistenceId) => _reads[persistenceId] ?? 0;

  @override
  Future<List<Event>> getEvents(String persistenceId,
      {int fromSequence = 0, int? toSequence}) {
    _reads[persistenceId] = reads(persistenceId) + 1;
    return super.getEvents(persistenceId,
        fromSequence: fromSequence, toSequence: toSequence);
  }
}
