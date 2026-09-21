/// libspiffy-bps1: a channel's wallet transactions name their counterparty.
///
/// spv-understanding.md "Core Data Management" requirement 5: every payment
/// the wallet records carries an opaque, app-chosen marker naming the
/// counterparty it was with, in both directions. The channel paths recorded
/// none: the funding a client pays out and the settlement or refund that
/// comes back both landed in the wallet with a blank marker, so a channel
/// payment could not be traced back to the peer it was with — and a later
/// request for a fresh merkle proof had no addressee.
///
/// The marker is supplied by the app on the public command. When it supplies
/// none the channel falls back to the COUNTERPARTY'S PEER ID: on the client
/// the server peer, on the server the client peer. That is a fact the
/// channel holds, never one it invents, and it is resolved in exactly one
/// place (`_counterpartyMarkerFor`) so the funding leg and the return leg of
/// a channel can never disagree.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart' show Event, EventStore, SnapshotData;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/channel_p2p_adapter.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/payment_channel_manager_actor.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/core/channel_state.dart';
import 'package:libspiffy/src/core/payment_channel_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/services/payment_channel_builder.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import 'channel_test_fixtures.dart';
import 'in_memory_event_store.dart';
import 'package:libspiffy/src/models/fee_rate.dart';
import '../mocks/policy_rate_arc.dart';

const _channelId = 'chan-marker';
const _walletId = 'wallet';
const _timeout = Duration(seconds: 10);
const _appMarker = 'app:merchant-42';

/// A real wallet aggregate and its projection, so the wallet commands the
/// channel manager sent can be replayed and the marker read back off the
/// transaction row the app would see.
class _Wallet {
  final storage = InMemoryWalletStorage();
  late final BitcoinWalletAggregate aggregate;
  late final WalletProjection projection;

  WalletState get state => aggregate.state ?? aggregate.createInitialState();

  static Future<_Wallet> create() async {
    final wallet = _Wallet();
    wallet.aggregate = BitcoinWalletAggregate(
      aggregateId: _walletId,
      aggregateType: 'BitcoinWallet',
      eventStore: InMemoryEventStore(),
      cryptoService: DartSVCryptoService(),
      secureStorage: InMemorySecureStorage(),
    );
    wallet.projection = WalletProjection(
      projectionId: 'marker-projection',
      eventStore: _NoopEventStore(),
      storage: wallet.storage,
    );
    await wallet.apply(CreateWalletCommand(
        walletId: _walletId,
        walletName: 'channel',
        mnemonic: channelFixtureMnemonic));
    for (var i = 0; i < 4; i++) {
      await wallet.apply(
          GenerateAddressCommand(walletId: _walletId, purpose: 'receive'));
    }
    return wallet;
  }

  Future<void> apply(WalletCommand command) async {
    final events = await aggregate.handleCommand(state, command);
    for (final event in events) {
      aggregate.eventHandler(event);
      await projection.handle(event);
    }
  }
}

/// A fully signed settlement of [f]: the server's countersigned payment.
Future<({String hex, String txid})> _settlement(
  ChannelRefundFixture f, {
  required BigInt serverAmountSats,
}) async {
  final builder = const PaymentChannelBuilder();
  final built = await builder.buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
    fundingTxId: f.fundingTxId,
    fundingOutputIndex: 0,
    fundingAmountSats: f.amountSats,
    clientPubKey: f.clientKey.publicKey,
    serverPubKey: f.serverKey.publicKey,
    clientAddress: dartsv.Address.fromBase58(f.clientAddressB58),
    serverAddress: dartsv.Address.fromBase58(f.serverAddressB58),
    serverAmountSats: serverAmountSats,
    sequenceNumber: 1,
  );
  Future<String> sign(dartsv.SVPrivateKey key) async =>
      (await builder.signMultisigInput(
        transaction: built.transaction,
        inputIndex: 0,
        privateKey: key,
        clientPubKey: f.clientKey.publicKey,
        serverPubKey: f.serverKey.publicKey,
        inputAmountSats: f.amountSats,
      ))
          .signatureHex;
  final signed = builder.applyMultisigSignatures(
    transaction: dartsv.Transaction.fromHex(built.transactionHex),
    inputIndex: 0,
    clientSignature: dartsv.SVSignature.fromTxFormat(await sign(f.clientKey)),
    serverSignature: dartsv.SVSignature.fromTxFormat(await sign(f.serverKey)),
    clientPubKey: f.clientKey.publicKey,
    serverPubKey: f.serverKey.publicKey,
  );
  return (hex: signed.serialize(), txid: signed.id);
}

void main() {
  late TestActorSystem system;
  late InMemoryEventStore store;
  late ChannelRefundFixture f;
  late FixtureWalletManager wallet;
  late RecordingArcActor arc;
  late ActorRef walletRef;
  late ActorRef managerRef;

  setUpAll(LibSpiffyActorSystem.registerEventTypes);

  setUp(() async {
    system = TestActorSystem();
    store = InMemoryEventStore();
  });

  tearDown(() async {
    await system.shutdown();
  });

  Future<void> spawn(List<Event> journal,
      {required dartsv.SVPrivateKey key}) async {
    if (journal.isNotEmpty) {
      await store.persistEvents('PaymentChannel_$_channelId', journal, 0);
    }
    wallet = FixtureWalletManager(key);
    arc = RecordingArcActor();
    walletRef = await system.spawn('wallet', () => wallet);
    final arcRef = await system.spawn('arc', () => arc);
    managerRef = await system.spawn(
      'manager',
      () => PaymentChannelManagerActor(
        walletManager: walletRef,
        eventStore: store,
        cryptoService: DartSVCryptoService(),
        arcActor: arcRef,
        signingTimeout: const Duration(seconds: 2),
      ),
    );
  }

  List<Event> journal() => store.journal['PaymentChannel_$_channelId'] ?? [];

  /// Waits for the wallet stub to have handled everything told to it so far.
  Future<void> flushWallet() async {
    final probe = await system.createProbe();
    walletRef.tell(
      WalletCommandMessage(
          _walletId, GenerateAddressCommand(walletId: _walletId)),
      sender: probe.ref,
    );
    await probe.expectMsgType<AddressGeneratedResponse>(timeout: _timeout);
  }

  /// Replays the recording commands into a real wallet + projection.
  Future<_Wallet> readBack() async {
    final w = await _Wallet.create();
    for (final command in wallet.commands) {
      if (command is RecordImportedTransactionCommand ||
          command is ReceiveUTXOCommand ||
          command is RecordOutgoingTransactionCommand) {
        await w.apply(command);
      }
    }
    return w;
  }

  RecordOutgoingTransactionCommand outgoing() =>
      wallet.commands.whereType<RecordOutgoingTransactionCommand>().single;
  RecordImportedTransactionCommand imported() =>
      wallet.commands.whereType<RecordImportedTransactionCommand>().single;
  ReceiveUTXOCommand received() =>
      wallet.commands.whereType<ReceiveUTXOCommand>().single;

  group('libspiffy-bps1: the funding a client pays out names its counterparty',
      () {
    setUp(() async {
      f = await ChannelRefundFixture.create(channelId: _channelId);
    });

    Future<ChannelOpenedResponse> open() =>
        managerRef.ask<ChannelOpenedResponse>(
          OpenChannelMessage(
            channelId: _channelId,
            fundingTxId: f.fundingTxId,
            fundingOutputIndex: 0,
            fundingTxHex: f.fundingTxHex,
          ),
          _timeout,
        );

    test('the app-supplied marker reaches the funding transaction row',
        () async {
      await spawn(
          f
              .openClientJournal(
                  walletId: _walletId, counterpartyMarker: _appMarker)
              .take(4)
              .toList(),
          key: f.clientKey);

      expect((await open()).success, isTrue);
      await flushWallet();

      expect(outgoing().counterpartyMarker, _appMarker,
          reason: 'the funding is a payment; requirement 5 says it names who '
              'it was with');

      final w = await readBack();
      final tx =
          await w.storage.getTransaction(f.fundingTxId, walletId: _walletId);
      expect(tx, isNotNull);
      expect(tx!.counterpartyMarker, _appMarker,
          reason: 'the app reads the marker off the wallet transaction row');
    });

    test('without an app marker the funding names the server peer', () async {
      await spawn(f.openClientJournal(walletId: _walletId).take(4).toList(),
          key: f.clientKey);

      expect((await open()).success, isTrue);
      await flushWallet();

      expect(outgoing().counterpartyMarker, 'server-peer',
          reason: 'the client\'s counterparty is the server peer — a fact the '
              'channel holds, not an invention');

      final w = await readBack();
      final tx =
          await w.storage.getTransaction(f.fundingTxId, walletId: _walletId);
      expect(tx!.counterpartyMarker, 'server-peer');
    });
  });

  group('libspiffy-bps1: the refund coming back names its counterparty', () {
    setUp(() async {
      f = await ChannelRefundFixture.create(
        channelId: _channelId,
        lockTimeUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60,
      );
    });

    Future<ChannelExpiredResponse> expire() =>
        managerRef.ask<ChannelExpiredResponse>(
          ExpireChannelMessage(channelId: _channelId, observedBy: 'client'),
          _timeout,
        );

    test('the app-supplied marker reaches the refund row and its output',
        () async {
      await spawn(
          f.openClientJournal(
              walletId: _walletId, counterpartyMarker: _appMarker),
          key: f.clientKey);
      final refundTxId = dartsv.Transaction.fromHex(f.signedRefundTxHex()).id;

      expect((await expire()).success, isTrue);
      await flushWallet();

      expect(imported().counterpartyMarker, _appMarker);
      expect(received().counterpartyMarker, _appMarker,
          reason: 'the UTXO event is the other half of the receive record');

      final w = await readBack();
      final tx = await w.storage.getTransaction(refundTxId, walletId: _walletId);
      expect(tx!.counterpartyMarker, _appMarker);
    });

    test('without an app marker the refund names the server peer', () async {
      await spawn(f.openClientJournal(walletId: _walletId), key: f.clientKey);
      final refundTxId = dartsv.Transaction.fromHex(f.signedRefundTxHex()).id;

      expect((await expire()).success, isTrue);
      await flushWallet();

      expect(imported().counterpartyMarker, 'server-peer');
      expect(received().counterpartyMarker, 'server-peer');

      final w = await readBack();
      final tx = await w.storage.getTransaction(refundTxId, walletId: _walletId);
      expect(tx!.counterpartyMarker, 'server-peer');
    });
  });

  group('libspiffy-bps1: the settlement a server records names its counterparty',
      () {
    late ({String hex, String txid}) settlement;

    setUp(() async {
      f = await ChannelRefundFixture.create(channelId: _channelId);
      settlement = await _settlement(f, serverAmountSats: BigInt.from(30000));
    });

    List<Event> serverJournal({String? counterpartyMarker}) => [
          f.serverAccepted(version: 1, counterpartyMarker: counterpartyMarker),
          RefundCountersignedEvent(
            channelId: _channelId,
            serverSignatureHex: f.serverSignatureHex,
            signedRefundTxHex: f.signedRefundTxHex(),
            version: 2,
          ),
          ChannelOpenedEvent(
            channelId: _channelId,
            fundingTxId: f.fundingTxId,
            fundingOutputIndex: 0,
            fundingTxHex: f.fundingTxHex,
            initialClientBalanceSats: f.amountSats,
            initialServerBalanceSats: BigInt.zero,
            version: 3,
          ),
          PaymentAcknowledgedEvent(
            channelId: _channelId,
            amountSats: BigInt.from(30000),
            sequenceNumber: 1,
            newClientBalanceSats: f.amountSats - BigInt.from(30000),
            newServerBalanceSats: BigInt.from(30000),
            fullySignedPaymentTxHex: settlement.hex,
            serverSignatureHex: f.serverSignatureHex,
            version: 4,
          ),
        ];

    Future<ChannelClosedResponse> close() =>
        managerRef.ask<ChannelClosedResponse>(
          CloseChannelMessage(channelId: _channelId, reason: 'done'),
          _timeout,
        );

    test('the app-supplied marker reaches the settlement row', () async {
      await spawn(serverJournal(counterpartyMarker: _appMarker),
          key: f.serverKey);

      expect((await close()).success, isTrue);
      await flushWallet();

      expect(imported().counterpartyMarker, _appMarker);
      expect(received().counterpartyMarker, _appMarker);

      final w = await readBack();
      final tx =
          await w.storage.getTransaction(settlement.txid, walletId: _walletId);
      expect(tx!.counterpartyMarker, _appMarker);
    });

    test('without an app marker the settlement names the client peer',
        () async {
      await spawn(serverJournal(), key: f.serverKey);

      expect((await close()).success, isTrue);
      await flushWallet();

      expect(imported().counterpartyMarker, 'client-peer',
          reason: "the server's counterparty is the client peer");
      expect(received().counterpartyMarker, 'client-peer');

      final w = await readBack();
      final tx =
          await w.storage.getTransaction(settlement.txid, walletId: _walletId);
      expect(tx!.counterpartyMarker, 'client-peer');
    });
  });

  group('libspiffy-bps1: the marker threads from the public command to the '
      'journal', () {
    setUp(() async {
      f = await ChannelRefundFixture.create(channelId: _channelId);
    });

    test('a client open journals the marker on ChannelRequestedEvent',
        () async {
      await spawn(const [], key: f.clientKey);

      final initiated = await managerRef.ask<ChannelInitiatedResponse>(
        InitiateChannelMessage(
          channelId: _channelId,
          walletId: _walletId,
          clientPeerId: 'client-peer',
          serverPeerId: 'server-peer',
          fundingAmountSats: BigInt.from(100000),
          lockTimeDurationSeconds: 3600,
          counterpartyMarker: _appMarker,
        ),
        _timeout,
      );
      expect(initiated.success, isTrue, reason: initiated.error);

      expect(journal().whereType<ChannelRequestedEvent>().single
          .counterpartyMarker, _appMarker,
          reason: 'a restart must still know who the channel is with');
    });

    test('a server accept journals the marker on ChannelAcceptedEvent',
        () async {
      await spawn(const [], key: f.serverKey);

      final accepted = await managerRef.ask<ChannelAcceptedResponse>(
        AcceptChannelMessage(
          channelId: _channelId,
          walletId: _walletId,
          clientPeerId: 'client-peer',
          clientPubKeyHex: f.clientPubKeyHex,
          clientAddressB58: f.clientAddressB58,
          fundingAmountSats: BigInt.from(100000),
          lockTimeUnix: f.lockTimeUnix,
          counterpartyMarker: _appMarker,
        ),
        _timeout,
      );
      expect(accepted.success, isTrue, reason: accepted.error);

      expect(journal().whereType<ChannelAcceptedEvent>().single
          .counterpartyMarker, _appMarker);
    });
  });

  group('libspiffy-bps1: the marker survives serialisation', () {
    test('the journal events round-trip it', () {
      final requested = ChannelRequestedEvent(
        channelId: _channelId,
        walletId: _walletId,
        clientPeerId: 'client-peer',
        serverPeerId: 'server-peer',
        clientPubKeyHex: '02',
        clientAddressB58: 'ca',
        derivationIndex: 1,
        fundingAmountSats: BigInt.from(1000),
        lockTimeUnix: 99,
        counterpartyMarker: _appMarker,
      );
      expect(
          ChannelRequestedEvent.fromMap(requested.toMap()).counterpartyMarker,
          _appMarker);

      final accepted = ChannelAcceptedEvent(
        channelId: _channelId,
        walletId: _walletId,
        clientPeerId: 'client-peer',
        clientPubKeyHex: '02',
        clientAddressB58: 'ca',
        serverPubKeyHex: '03',
        serverAddressB58: 'sa',
        derivationIndex: 1,
        fundingAmountSats: BigInt.from(1000),
        lockTimeUnix: 99,
        counterpartyMarker: _appMarker,
      );
      expect(ChannelAcceptedEvent.fromMap(accepted.toMap()).counterpartyMarker,
          _appMarker);
    });

    test('a snapshot round-trips it', () async {
      final aggregate = PaymentChannelAggregate(
        aggregateId: _channelId,
        eventStore: InMemoryEventStore(),
        cryptoService: DartSVCryptoService(),
      );
      final map = PaymentChannelAggregate.channelStateToMap(ChannelState(
        channelId: _channelId,
        status: ChannelStatus.open,
        counterpartyMarker: _appMarker,
        version: 3,
        latestSequenceNumber: 0,
      ));
      expect(map['counterpartyMarker'], _appMarker);
      final restored = await aggregate.restoreStateFromMap(map, 3);
      expect(restored.counterpartyMarker, _appMarker,
          reason: 'a channel recovered from a snapshot still knows its '
              'counterparty, so what it records after the restart names them');
    });
  });

  group('libspiffy-bps1: the public command carries the marker to the adapter',
      () {
    late ActorSystem adapterSystem;
    late _RecordingProbe channelManagerProbe;
    late ChannelP2PAdapter adapter;
    late StreamController<ChannelEvent> channelEvents;

    setUp(() async {
      adapterSystem = LocalActorSystem();
      channelManagerProbe = _RecordingProbe();
      final channelManager =
          await adapterSystem.spawn('cm', () => channelManagerProbe);
      final walletManager =
          await adapterSystem.spawn('wm', () => _RecordingProbe());
      channelEvents = StreamController<ChannelEvent>.broadcast();
      adapter = ChannelP2PAdapter(
        channelManager: channelManager,
        walletManager: walletManager,
        arcActor: await adapterSystem.spawn('arc', () => PolicyRateArc()),
        emitEvent: (_) {},
        channelEvents: channelEvents.stream,
        walletId: _walletId,
        myPeerId: 'client-peer',
      );
    });

    tearDown(() async {
      adapter.dispose();
      await channelEvents.close();
      await adapterSystem.shutdown();
    });

    test('OpenChannelCommand carries it to InitiateChannelMessage', () async {
      adapter.handleOpenChannel(coord.OpenChannelCommand(
        walletId: _walletId,
        serverPeerId: 'server-peer',
        fundingAmountSats: 100000,
        lockTimeDurationSeconds: 3600,
        context: 'address-label',
        counterpartyMarker: _appMarker,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final msg = channelManagerProbe.received
          .whereType<InitiateChannelMessage>()
          .single;
      expect(msg.counterpartyMarker, _appMarker);
      expect(msg.context, 'address-label',
          reason: 'context is address-derivation metadata and stays its own '
              'field: one field cannot carry two meanings');
    });

    test('AcceptChannelCommand carries it to AcceptChannelMessage', () async {
      adapter.handleAcceptRequest(coord.AcceptChannelCommand(
        channelId: _channelId,
        walletId: _walletId,
        clientPeerId: 'client-peer',
        clientPubKey: '02' * 33,
        clientAddress: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
        fundingAmountSats: 100000,
        lockTimeUnix: 1700000000,
        counterpartyMarker: _appMarker,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
          channelManagerProbe.received
              .whereType<AcceptChannelMessage>()
              .single
              .counterpartyMarker,
          _appMarker);
    });
  });
}

class _RecordingProbe extends Actor {
  final List<dynamic> received = [];

  @override
  Future<void> onMessage(dynamic message) async {
    received.add(message);
  }
}

class _NoopEventStore implements EventStore {
  @override
  Future<void> persistEvent(
      String persistenceId, Event event, int expectedVersion) async {}

  @override
  Future<void> persistEvents(
      String persistenceId, List<Event> events, int expectedVersion) async {}

  @override
  Future<List<Event>> getEvents(String persistenceId,
          {int fromSequence = 0, int? toSequence}) async =>
      [];

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) async => 0;

  @override
  Future<void> saveSnapshot(
      String persistenceId, dynamic state, int sequenceNumber) async {}

  @override
  Future<SnapshotData?> loadSnapshot(String persistenceId) async => null;

  @override
  Future<void> deleteOldSnapshots(String persistenceId, int keepCount) async {}

  @override
  Future<void> close() async {}
}
