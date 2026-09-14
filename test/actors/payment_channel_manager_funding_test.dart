/// PaymentChannelManagerActor: the client journals its refund and broadcasts
/// its funding transaction only after the verified refund
/// (libspiffy-b83, libspiffy-9f7).
///
/// The channel aggregate is real, over an in-memory journal. The wallet
/// manager is [FixtureWalletManager] (signs with the fixture client key and
/// records every command) and ARC is [RecordingArcActor]; one shared log
/// records the order in which they are asked.
library;

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart' show Event;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/payment_channel_manager_actor.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import 'channel_test_fixtures.dart';
import 'in_memory_event_store.dart';

const _channelId = 'chan-funding';
const _walletId = 'client-wallet';
const _timeout = Duration(seconds: 10);

void main() {
  late TestActorSystem system;
  late InMemoryEventStore store;
  late ChannelRefundFixture f;
  late FixtureWalletManager wallet;
  late RecordingArcActor arc;
  late ActorRef managerRef;
  late List<String> log;

  setUpAll(LibSpiffyActorSystem.registerEventTypes);

  setUp(() async {
    system = TestActorSystem();
    store = InMemoryEventStore();
    f = await ChannelRefundFixture.create(channelId: _channelId);
    log = [];
  });

  tearDown(() async {
    await system.shutdown();
  });

  Future<void> spawn(List<Event> journal,
      {bool withArc = true, ReadModelStorage? storage}) async {
    if (journal.isNotEmpty) {
      await store.persistEvents('PaymentChannel_$_channelId', journal, 0);
    }
    wallet = FixtureWalletManager(f.clientKey)
      ..onCommand = (c) => log.add(c.runtimeType.toString());
    arc = RecordingArcActor()..onBroadcast = (_) => log.add('broadcast');
    final walletRef = await system.spawn('wallet', () => wallet);
    final arcRef = await system.spawn('arc', () => arc);
    managerRef = await system.spawn(
      'manager',
      () => PaymentChannelManagerActor(
        walletManager: walletRef,
        eventStore: store,
        cryptoService: DartSVCryptoService(),
        arcActor: withArc ? arcRef : null,
        signingTimeout: const Duration(seconds: 2),
        storage: storage,
      ),
    );
  }

  List<Event> journal() => store.journal['PaymentChannel_$_channelId'] ?? [];
  List<String> journalTypes() => journal().map((e) => e.typeName).toList();

  Future<ChannelOpenedResponse> open() => managerRef.ask<ChannelOpenedResponse>(
        OpenChannelMessage(
          channelId: _channelId,
          fundingTxId: f.fundingTxId,
          fundingOutputIndex: 0,
          fundingTxHex: f.fundingTxHex,
        ),
        _timeout,
      );

  /// Client journal up to the verified, countersigned refund.
  List<Event> countersigned() =>
      f.openClientJournal(walletId: _walletId).take(4).toList();

  group('libspiffy-9f7: funding broadcast', () {
    test(
        'records the funding in the wallet, broadcasts it once, spends its '
        'inputs, then opens', () async {
      await spawn(countersigned());

      final opened = await open();

      expect(opened.success, isTrue, reason: opened.error);
      expect(arc.broadcasts, hasLength(1));
      expect(arc.broadcasts.single.txHex, f.fundingTxHex);
      expect(arc.broadcasts.single.txid, f.fundingTxId);
      expect(arc.broadcasts.single.walletId, _walletId);
      expect(log, [
        'RecordOutgoingTransactionCommand',
        'broadcast',
        'SpendUTXOCommand',
      ]);
      expect(journalTypes().sublist(3), [
        RefundCountersignedEvent.stableTypeName,
        FundingBroadcastStartedEvent.stableTypeName,
        FundingRecordedInWalletEvent.stableTypeName,
        ChannelOpenedEvent.stableTypeName,
      ]);

      final record =
          wallet.commands.whereType<RecordOutgoingTransactionCommand>().single;
      expect(record.walletId, _walletId);
      expect(record.txid, f.fundingTxId);
      expect(record.rawHex, f.fundingTxHex);
      expect(record.spentUtxoKeys, ['${'c0' * 32}:0']);
      expect(record.deferSpend, isTrue,
          reason: 'inputs stay reserved until ARC accepts the transaction');
      expect(record.paymentAmount, f.amountSats);
      expect(record.totalOutputSats, 150000);
      expect(record.totalInputSats, 150200);
      expect(record.fee, 200);
      expect(record.changeAmount, BigInt.from(50000));

      // The 2-of-2 output is not reserved: the wallet does not count an
      // output it cannot spend alone (libspiffy-viy).
      expect(wallet.commands.whereType<ReserveUTXOCommand>(), isEmpty);

      final spend = wallet.commands.whereType<SpendUTXOCommand>().single;
      expect(spend.utxoKey, '${'c0' * 32}:0');
      expect(spend.spendingTxId, f.fundingTxId);
    });

    test('broadcasts nothing before the refund is countersigned', () async {
      await spawn(f.clientJournalWithRefund());

      final opened = await open();

      expect(opened.success, isFalse);
      expect(opened.error, contains('Refund not signed'));
      expect(arc.broadcasts, isEmpty);
      expect(wallet.commands, isEmpty);
      expect(journal(), hasLength(3));
    });

    test(
        'broadcasts nothing for a countersigned channel holding no verified '
        'refund', () async {
      await spawn([
        ...f.clientJournalWithRefund(),
        RefundCountersignedEvent(
            channelId: _channelId,
            serverSignatureHex: f.serverSignatureHex,
            version: 4),
      ]);

      final opened = await open();

      expect(opened.success, isFalse);
      expect(opened.error, contains('No fully signed refund retained'));
      expect(arc.broadcasts, isEmpty);
      expect(wallet.commands, isEmpty);
    });

    test(
        'a failed broadcast journals the failure and does not open; a retry '
        'broadcasts the same transaction without recording it again', () async {
      await spawn(countersigned());
      arc.failWith = 'ARC unavailable';

      final failed = await open();

      expect(failed.success, isFalse);
      expect(failed.error, contains('ARC unavailable'));
      expect(journalTypes().last, FundingBroadcastFailedEvent.stableTypeName);
      expect(
          journal()
              .whereType<FundingBroadcastFailedEvent>()
              .single
              .walletRecorded,
          isTrue);
      expect(journal().whereType<ChannelOpenedEvent>(), isEmpty);
      expect(wallet.commands.whereType<SpendUTXOCommand>(), isEmpty,
          reason: 'the inputs stay reserved for this funding transaction');

      arc.failWith = null;
      final retried = await open();

      expect(retried.success, isTrue, reason: retried.error);
      expect(
          arc.broadcasts.map((b) => b.txHex), [f.fundingTxHex, f.fundingTxHex]);
      expect(wallet.commands.whereType<RecordOutgoingTransactionCommand>(),
          hasLength(1));
      expect(wallet.commands.whereType<SpendUTXOCommand>(), hasLength(1));
      expect(
          journal()
              .whereType<FundingBroadcastStartedEvent>()
              .map((e) => e.attempt),
          [1, 2]);
      expect(journalTypes().last, ChannelOpenedEvent.stableTypeName);
    });

    group('libspiffy-fsy: a broadcast interrupted by a restart', () {
      /// Countersigned, and a funding broadcast started that never ended.
      List<Event> interrupted() => [
            ...countersigned(),
            FundingBroadcastStartedEvent(
                channelId: _channelId,
                fundingTxId: f.fundingTxId,
                attempt: 1,
                version: 5),
          ];

      test('resumes without recording the funding in the wallet again when '
          'the journal shows it recorded', () async {
        await spawn([
          ...interrupted(),
          FundingRecordedInWalletEvent(
              channelId: _channelId, fundingTxId: f.fundingTxId, version: 6),
        ]);

        final opened = await open();

        expect(opened.success, isTrue, reason: opened.error);
        expect(wallet.commands.whereType<RecordOutgoingTransactionCommand>(),
            isEmpty,
            reason: 'the wallet already recorded the funding transaction');
        expect(arc.broadcasts.map((b) => b.txHex), [f.fundingTxHex]);
        expect(journal().whereType<FundingRecordedInWalletEvent>(), hasLength(1));
        expect(journalTypes().last, ChannelOpenedEvent.stableTypeName);
      });

      test('does not record the funding again when only the wallet read '
          'model shows it recorded, and journals that it is', () async {
        final storage = InMemoryWalletStorage();
        final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        await storage.storeTransaction(
            _walletId,
            BitcoinTransaction(
              walletId: _walletId,
              txid: f.fundingTxId,
              rawHex: f.fundingTxHex,
              status: TransactionStatus.pending,
              inputValue: BigInt.from(150200),
              outputValue: BigInt.from(150000),
              fee: BigInt.from(200),
              receivingAddresses: const [],
              sendingAddresses: const [],
              netAmount: -f.amountSats,
              createdAt: epoch,
              updatedAt: epoch,
              lockTime: 0,
              version: 1,
            ));
        await spawn(interrupted(), storage: storage);

        final opened = await open();

        expect(wallet.commands.whereType<RecordOutgoingTransactionCommand>(),
            isEmpty,
            reason: 'the wallet read model holds the funding transaction');
        expect(journal().whereType<FundingRecordedInWalletEvent>(), hasLength(1));
        // The fixture's funding input has no ancestors in the read model: no
        // BEEF can be built for the server, so nothing is broadcast.
        expect(opened.success, isFalse);
        expect(opened.error, contains('Cannot build the BEEF'));
        expect(arc.broadcasts, isEmpty);
        expect(
            journal()
                .whereType<FundingBroadcastFailedEvent>()
                .single
                .walletRecorded,
            isTrue);
      });
    });

    test('without an ARC actor the channel does not open', () async {
      await spawn(countersigned(), withArc: false);

      final opened = await open();

      expect(opened.success, isFalse);
      expect(opened.error, contains('No transaction broadcaster'));
      expect(wallet.commands, isEmpty);
      expect(
          journal()
              .whereType<FundingBroadcastFailedEvent>()
              .single
              .walletRecorded,
          isFalse);
      expect(journal().whereType<ChannelOpenedEvent>(), isEmpty);
    });
  });

  group('libspiffy-b83: the client journals the refund it builds', () {
    BuildRefundTransactionMessage build({String? fundingTxHex}) =>
        BuildRefundTransactionMessage(
          channelId: _channelId,
          walletId: _walletId,
          fundingTxId: f.fundingTxId,
          fundingOutputIndex: 0,
          fundingAmountSats: f.amountSats,
          clientPubKeyHex: f.clientPubKeyHex,
          clientAddressB58: f.clientAddressB58,
          serverPubKeyHex: f.serverPubKeyHex,
          serverAddressB58: f.serverAddressB58,
          lockTimeUnix: f.lockTimeUnix,
          fundingTxHex: fundingTxHex,
          fundingInputSats: 150200,
        );

    test('with its own signature and the funding transaction', () async {
      await spawn([
        f.requested(version: 1, walletId: _walletId),
        f.serverAcceptance(version: 2),
      ]);

      final built = await managerRef.ask<RefundTransactionBuiltResponse>(
          build(fundingTxHex: f.fundingTxHex), _timeout);

      expect(built.success, isTrue, reason: built.error);
      final event = journal().whereType<RefundBuiltEvent>().single;
      expect(event.refundTxHex, built.refundTxHex);
      expect(dartsv.Transaction.fromHex(event.refundTxHex).nLockTime,
          f.lockTimeUnix);
      expect(event.fundingTxHex, f.fundingTxHex);
      expect(event.fundingInputSats, 150200);
      final sign =
          wallet.commands.whereType<SignMultisigTransactionCommand>().single;
      expect(sign.walletId, _walletId);
      expect(sign.derivationIndex, 1);

      // The manager built the fixture's refund, so the server's signature on
      // that refund completes one the client accepts.
      expect(built.refundTxHex, f.refundTxHex);
      final recorded = await managerRef.ask<RefundSignatureRecordedResponse>(
          RecordRefundSignatureMessage(
              channelId: _channelId, serverSignatureHex: f.serverSignatureHex),
          _timeout);
      expect(recorded.success, isTrue, reason: recorded.error);
    });

    test('is refused without the funding transaction', () async {
      await spawn([
        f.requested(version: 1, walletId: _walletId),
        f.serverAcceptance(version: 2),
      ]);

      final built = await managerRef.ask<RefundTransactionBuiltResponse>(
          build(), _timeout);

      expect(built.success, isFalse);
      expect(built.error, contains('fundingTxHex'));
      expect(journal(), hasLength(2));
    });
  });
}
