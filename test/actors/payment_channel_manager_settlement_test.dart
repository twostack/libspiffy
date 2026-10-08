/// libspiffy-f5p2: a channel that ends records its return leg in the wallet.
///
/// The funding path already records what left the wallet
/// (`_recordFundingInWallet`). The return leg — the settlement of a
/// cooperative close, the refund of an expiry — reached the wallet nowhere,
/// so the transaction was missing from the history, its outputs were not
/// wallet UTXOs and the balance never showed the funds coming back.
///
/// The return leg is a RECEIVE on both sides: the channel's 2-of-2 funding
/// output is not a wallet UTXO (libspiffy-viy), so nothing of ours is spent
/// and our share arrives as a fresh P2PKH output. It is recorded unproven —
/// no BUMP, no block height, a pending row and pending outputs — because
/// nothing has proved it mined.
library;

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart' show Event, EventStore, SnapshotData;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/actors/payment_channel_manager_actor.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/services/payment_channel_builder.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import 'channel_test_fixtures.dart';
import 'in_memory_event_store.dart';
import 'package:libspiffy/src/models/fee_rate.dart';
import '../mocks/test_channel_timing.dart';

const _channelId = 'chan-settle';
const _walletId = 'wallet';
const _timeout = Duration(seconds: 10);

/// A fully signed settlement: the latest payment transaction of the channel,
/// spending the 2-of-2 funding output and paying both parties.
class _Settlement {
  final String hex;
  final String txid;
  final BigInt serverAmount;
  final BigInt clientAmount;

  _Settlement(this.hex, this.txid, this.serverAmount, this.clientAmount);

  static Future<_Settlement> build(
    ChannelRefundFixture f, {
    required BigInt serverAmountSats,
    int sequenceNumber = 1,
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
      sequenceNumber: sequenceNumber,
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
    return _Settlement(signed.serialize(), signed.id, serverAmountSats,
        f.amountSats - serverAmountSats - built.fee);
  }
}

/// A real wallet aggregate and its projection, so the commands the channel
/// manager sends the wallet can be applied and the result read back off the
/// read model (history row, UTXOs, balance).
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
      projectionId: 'settlement-projection',
      eventStore: _NoopEventStore(),
      storage: wallet.storage,
    );
    await wallet.apply(CreateWalletCommand(
        walletId: _walletId,
        walletName: 'channel',
        mnemonic: channelFixtureMnemonic));
    // m/0/0 .. m/0/3: the channel keys are m/0/1 (client) and m/0/2 (server).
    for (var i = 0; i < 4; i++) {
      await wallet
          .apply(GenerateAddressCommand(walletId: _walletId, purpose: 'receive'));
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

/// The two halves of a payment's 2-of-2 signature, kept apart: the client
/// records the template and its own half, and only learns the server's half
/// when `payment_ack` arrives (bead libspiffy-z2px).
class _PaymentPair {
  final String templateHex;
  final String templateTxId;
  final String clientSignatureHex;
  final String serverSignatureHex;
  final String settlementHex;
  final String settlementTxId;
  final BigInt serverAmount;
  final BigInt clientAmount;

  _PaymentPair({
    required this.templateHex,
    required this.templateTxId,
    required this.clientSignatureHex,
    required this.serverSignatureHex,
    required this.settlementHex,
    required this.settlementTxId,
    required this.serverAmount,
    required this.clientAmount,
  });

  static Future<_PaymentPair> build(
    ChannelRefundFixture f, {
    required BigInt serverAmountSats,
    int sequenceNumber = 1,
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
      sequenceNumber: sequenceNumber,
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
    final clientSig = await sign(f.clientKey);
    final serverSig = await sign(f.serverKey);
    final signed = builder.applyMultisigSignatures(
      transaction: dartsv.Transaction.fromHex(built.transactionHex),
      inputIndex: 0,
      clientSignature: dartsv.SVSignature.fromTxFormat(clientSig),
      serverSignature: dartsv.SVSignature.fromTxFormat(serverSig),
      clientPubKey: f.clientKey.publicKey,
      serverPubKey: f.serverKey.publicKey,
    );
    return _PaymentPair(
      templateHex: built.transactionHex,
      templateTxId: built.txid,
      clientSignatureHex: clientSig,
      serverSignatureHex: serverSig,
      settlementHex: signed.serialize(),
      settlementTxId: signed.id,
      serverAmount: serverAmountSats,
      clientAmount: f.amountSats - serverAmountSats - built.fee,
    );
  }
}

void main() {
  late TestActorSystem system;
  late InMemoryEventStore store;
  late ChannelRefundFixture f;
  late FixtureWalletManager wallet;
  late ActorRef walletRef;
  late ActorRef managerRef;

  /// The manager's ARC: it answers the policy rate and records every
  /// broadcast (bead libspiffy-u6q6: the server broadcasts its settlement).
  late RecordingArcActor arc;

  setUpAll(LibSpiffyActorSystem.registerEventTypes);

  setUp(() async {
    system = TestActorSystem();
    store = InMemoryEventStore();
  });

  tearDown(() async {
    await system.shutdown();
  });

  Future<void> spawn(List<Event> journal, {required dartsv.SVPrivateKey key}) async {
    if (journal.isNotEmpty) {
      await store.persistEvents('PaymentChannel_$_channelId', journal, 0);
    }
    wallet = FixtureWalletManager(key);
    walletRef = await system.spawn('wallet', () => wallet);
    arc = RecordingArcActor();
    final policyArc1 = await system.spawn('arc', () => arc);
    managerRef = await system.spawn(
      'manager',
      () => PaymentChannelManagerActor(timing: testChannelTiming, 
            arcActor: policyArc1,
        walletManager: walletRef,
        eventStore: store,
        cryptoService: DartSVCryptoService(),
        signingTimeout: const Duration(seconds: 2),
      ),
    );
  }

  List<Event> journal() => store.journal['PaymentChannel_$_channelId'] ?? [];

  /// Waits for the wallet stub to have handled everything told to it so far:
  /// its mailbox is FIFO, so an address request it answers comes after every
  /// command the manager already sent. No sleeps, no polling.
  Future<void> flushWallet() async {
    final probe = await system.createProbe();
    walletRef.tell(
      WalletCommandMessage(
          _walletId, GenerateAddressCommand(walletId: _walletId)),
      sender: probe.ref,
    );
    await probe.expectMsgType<AddressGeneratedResponse>(timeout: _timeout);
  }

  List<RecordImportedTransactionCommand> imported() =>
      wallet.commands.whereType<RecordImportedTransactionCommand>().toList();
  List<ReceiveUTXOCommand> received() =>
      wallet.commands.whereType<ReceiveUTXOCommand>().toList();

  /// Replays every wallet command the manager sent into a real wallet.
  Future<_Wallet> readBack() async {
    final w = await _Wallet.create();
    for (final command in wallet.commands) {
      if (command is RecordImportedTransactionCommand ||
          command is ReceiveUTXOCommand) {
        await w.apply(command);
      }
    }
    return w;
  }

  group('libspiffy-f5p2: a cooperative close records the settlement', () {
    late _Settlement settlement;

    /// Server journal: accepted, refund countersigned, opened, one payment
    /// acknowledged with the fully signed settlement.
    Future<List<Event>> serverJournalWithPayment() async {
      settlement =
          await _Settlement.build(f, serverAmountSats: BigInt.from(30000));
      return [
        f.serverAccepted(version: 1),
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
    }

    setUp(() async {
      f = await ChannelRefundFixture.create(channelId: _channelId);
    });

    Future<ChannelClosedResponse> close() =>
        managerRef.ask<ChannelClosedResponse>(
          CloseChannelMessage(channelId: _channelId, reason: 'done'),
          _timeout,
        );

    test('the settlement reaches the wallet as an unproven receive, and the '
        'channel is closed', () async {
      await spawn(await serverJournalWithPayment(), key: f.serverKey);

      final closed = await close();
      expect(closed.success, isTrue, reason: closed.error);
      await flushWallet();

      final record = imported().single;
      expect(record.walletId, _walletId);
      expect(record.txid, settlement.txid);
      expect(record.rawHex, settlement.hex);
      expect(record.blockHeight, isNull,
          reason: 'no proof puts the settlement in a block');
      expect(record.bumpProofHex, isEmpty);
      expect(record.totalInputSats, f.amountSats.toInt(),
          reason: 'the single input is the funding output');
      expect(record.walletReceivingAddresses, [f.serverAddressB58]);
      expect(record.walletReceivedSats, 30000);
      expect(record.sendingAddresses, ['channel:$_channelId'],
          reason: 'the counterpart of the funding record');

      final utxo = received().single;
      expect(utxo.txid, settlement.txid);
      expect(utxo.satoshis, BigInt.from(30000));
      expect(utxo.address, f.serverAddressB58);
      expect(utxo.initialStatus, UTXOStatus.pending);
      expect(utxo.blockHeight, isNull);

      expect(journal().last, isA<ChannelClosedEvent>());
      expect((journal().last as ChannelClosedEvent).settlementTxId,
          settlement.txid);
      expect((journal().last as ChannelClosedEvent).settlementTxHex, settlement.hex,
          reason: 'the server hands the client the settlement it broadcast');
    });

    // Bead libspiffy-u6q6: the settlement is the server's own broadcast. The
    // channel was journaled closed with the settlement only recorded in the
    // wallet; nothing submitted it, and the client's refund took everything
    // back at the lock time.
    test('u6q6: the server broadcasts the settlement before the channel is closed', () async {
      await spawn(await serverJournalWithPayment(), key: f.serverKey);
      arc.onBroadcast = (_) => expect(journal().whereType<ChannelClosedEvent>(), isEmpty,
          reason: 'journaled closed before the settlement was submitted');

      final closed = await close();

      expect(closed.success, isTrue, reason: closed.error);
      // Old code: nothing broadcast.
      expect(arc.broadcasts.map((b) => b.txid), [settlement.txid]);
      expect(arc.broadcasts.single.txHex, settlement.hex);
      expect(arc.broadcasts.single.retryOnFailure, isFalse,
          reason: 'the channel owns the retry: closing again re-sends it');
    });

    test('u6q6: a settlement ARC did not take leaves the channel closing, and closing again closes it', () async {
      await spawn(await serverJournalWithPayment(), key: f.serverKey);
      arc.failWith = 'ARC unavailable';

      final failed = await close();
      await flushWallet();

      expect(failed.success, isFalse);
      expect(failed.error, contains('ARC unavailable'));
      expect(journal().last, isA<ChannelClosingEvent>());
      expect(imported(), isEmpty, reason: 'a settlement the network does not have is not a receive');

      arc.failWith = null;
      final closed = await close();

      expect(closed.success, isTrue, reason: closed.error);
      expect(closed.finalized, isTrue);
      expect(arc.broadcasts, hasLength(2));
      expect(journal().whereType<ChannelClosedEvent>(), hasLength(1));
    });

    test('u6q6: a contested settlement does not close the channel', () async {
      await spawn(await serverJournalWithPayment(), key: f.serverKey);
      arc.networkStatus = 'DOUBLE_SPEND_ATTEMPTED';

      final closed = await close();
      await flushWallet();

      expect(closed.success, isFalse);
      expect(closed.error, contains('contested'));
      expect(journal().whereType<ChannelClosedEvent>(), isEmpty);
      expect(imported(), isEmpty);
    });

    // Bead libspiffy-jh6a, seen on the localnet regtest ARC: a server
    // restarted after the client's refund closed twice at once. The second
    // submission of its settlement reached ARC while the first was in flight
    // and was answered with where ARC had got to, not with a verdict; the
    // server closed on it, and ARC then found the settlement a double spend.
    for (final status in ['RECEIVED', 'STORED', 'SENT_TO_NETWORK', 'ACCEPTED_BY_NETWORK', 'SEEN_IN_ORPHAN_MEMPOOL']) {
      test('jh6a: a settlement ARC answers $status does not close the channel', () async {
        await spawn(await serverJournalWithPayment(), key: f.serverKey);
        arc.networkStatus = status;

        final closed = await close();
        await flushWallet();

        expect(closed.success, isFalse);
        expect(closed.error, contains(status == 'SEEN_IN_ORPHAN_MEMPOOL' ? 'orphan' : status));
        expect(journal().whereType<ChannelClosedEvent>(), isEmpty);
        expect(imported(), isEmpty);
      });
    }

    test('jh6a: a mined settlement closes the channel', () async {
      await spawn(await serverJournalWithPayment(), key: f.serverKey);
      arc.networkStatus = 'MINED';

      final closed = await close();

      expect(closed.success, isTrue, reason: closed.error);
      expect(journal().whereType<ChannelClosedEvent>(), hasLength(1));
    });

    test('the wallet shows the settlement in its history, its share as a '
        'UTXO and the funds in its balance', () async {
      await spawn(await serverJournalWithPayment(), key: f.serverKey);
      expect((await close()).success, isTrue);
      await flushWallet();

      final w = await readBack();

      final tx = await w.storage.getTransaction(settlement.txid, walletId: _walletId);
      expect(tx, isNotNull, reason: 'the settlement is in the history');
      expect(tx!.status, TransactionStatus.pending);
      expect(tx.blockHeight, isNull);
      expect(tx.netAmount, BigInt.from(30000),
          reason: 'the settlement pays the wallet; it spends nothing of ours');

      final utxos = await w.storage.getUTXOs(_walletId);
      final ours = utxos.where((u) => u.txid == settlement.txid).toList();
      expect(ours, hasLength(1));
      expect(ours.single.value.getValue(), BigInt.from(30000));
      expect(ours.single.status, UTXOStatus.pending);
      expect(ours.single.blockHeight, isNull);

      final row =
          (await w.storage.getWallet(_walletId))!['metadata'] as Map<String, dynamic>;
      expect(row['unconfirmedBalance'], '30000',
          reason: 'unproven funds are unconfirmed, not spendable');
      expect(row['confirmedBalance'], '0');
    });

    test('a payment acknowledged live leaves the server holding the fully '
        'signed settlement, which the close then records', () async {
      // Server side, open, no payment yet: the acknowledgment is driven
      // through the manager so the settlement is assembled from the two
      // real signatures rather than handed to the journal ready-made.
      final unsigned = await const PaymentChannelBuilder()
          .buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
        fundingTxId: f.fundingTxId,
        fundingOutputIndex: 0,
        fundingAmountSats: f.amountSats,
        clientPubKey: f.clientKey.publicKey,
        serverPubKey: f.serverKey.publicKey,
        clientAddress: dartsv.Address.fromBase58(f.clientAddressB58),
        serverAddress: dartsv.Address.fromBase58(f.serverAddressB58),
        serverAmountSats: BigInt.from(30000),
        sequenceNumber: 1,
      );
      final clientSignature = (await const PaymentChannelBuilder()
              .signMultisigInput(
        transaction: unsigned.transaction,
        inputIndex: 0,
        privateKey: f.clientKey,
        clientPubKey: f.clientKey.publicKey,
        serverPubKey: f.serverKey.publicKey,
        inputAmountSats: f.amountSats,
      ))
          .signatureHex;

      await spawn([
        f.serverAccepted(version: 1),
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
      ], key: f.serverKey);

      final acked = await managerRef.ask<PaymentAcknowledgedResponse>(
        AcknowledgePaymentMessage(
          channelId: _channelId,
          walletId: _walletId,
          amountSats: BigInt.from(30000),
          paymentTxHex: unsigned.transactionHex,
          clientSignatureHex: clientSignature,
          proposedSequence: 1,
          proposedClientBalance: f.amountSats - BigInt.from(30000),
          proposedServerBalance: BigInt.from(30000),
        ),
        _timeout,
      );
      expect(acked.success, isTrue, reason: acked.error);
      expect(acked.fullySignedPaymentTxHex, isNotEmpty,
          reason: 'the server holds both signatures when it acknowledges');

      final settled =
          dartsv.Transaction.fromHex(acked.fullySignedPaymentTxHex);
      expect(settled.inputs.single.prevTxnId, f.fundingTxId);
      expect(settled.id, isNot(unsigned.txid),
          reason: 'signing changes the txid; the unsigned template names a '
              'transaction that will never exist');
      expect(
          journal()
              .whereType<PaymentAcknowledgedEvent>()
              .single
              .fullySignedPaymentTxHex,
          acked.fullySignedPaymentTxHex);

      expect((await close()).success, isTrue);
      await flushWallet();

      expect(imported().single.txid, settled.id);
      expect(received().single.txid, settled.id);
      expect((journal().last as ChannelClosedEvent).settlementTxId, settled.id);
    });

    test('a re-delivered close records nothing new', () async {
      await spawn(await serverJournalWithPayment(), key: f.serverKey);
      expect((await close()).success, isTrue);
      await flushWallet();
      final after = wallet.commands.length;

      await close();
      await flushWallet();

      expect(imported(), hasLength(1));
      expect(received(), hasLength(1));
      expect(wallet.commands.length, after + 1,
          reason: 'only the flush probe\'s own address request was added');
      expect(journal().whereType<ChannelClosedEvent>(), hasLength(1));
    });
  });

  group('libspiffy-f5p2: nothing is recorded that we do not hold', () {
    setUp(() async {
      f = await ChannelRefundFixture.create(channelId: _channelId);
    });

    test('a client closing cooperatively holds only the unsigned payment '
        'template, so it records nothing and stays closing', () async {
      final unsigned = await const PaymentChannelBuilder()
          .buildPaymentTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
        fundingTxId: f.fundingTxId,
        fundingOutputIndex: 0,
        fundingAmountSats: f.amountSats,
        clientPubKey: f.clientKey.publicKey,
        serverPubKey: f.serverKey.publicKey,
        clientAddress: dartsv.Address.fromBase58(f.clientAddressB58),
        serverAddress: dartsv.Address.fromBase58(f.serverAddressB58),
        serverAmountSats: BigInt.from(30000),
        sequenceNumber: 1,
      );
      await spawn([
        ...f.openClientJournal(walletId: _walletId),
        PaymentRecordedEvent(
          channelId: _channelId,
          amountSats: BigInt.from(30000),
          sequenceNumber: 1,
          paymentTxHex: unsigned.transactionHex,
          paymentTxId: unsigned.txid,
          clientSignatureHex: '30' * 36,
          newClientBalanceSats: f.amountSats - BigInt.from(30000),
          newServerBalanceSats: BigInt.from(30000),
          version: 7,
        ),
      ], key: f.clientKey);

      final closed = await managerRef.ask<ChannelClosedResponse>(
        CloseChannelMessage(channelId: _channelId, reason: 'done'),
        _timeout,
      );
      expect(closed.success, isTrue, reason: closed.error);
      await flushWallet();

      expect(imported(), isEmpty,
          reason: 'the unsigned template names a transaction that will never '
              'exist; the client holds no countersigned settlement');
      expect(received(), isEmpty);
      expect(journal().whereType<ChannelClosedEvent>(), isEmpty,
          reason: 'the close is not finalised with a settlement we do not have');
      expect(journal().last, isA<ChannelClosingEvent>());
    });

    test('a cooperative close never settles with the refund', () async {
      // Open, no payment: the client holds a fully signed refund and nothing
      // else. The refund belongs to the expiry route, not to a close.
      await spawn(f.openClientJournal(walletId: _walletId), key: f.clientKey);

      expect((await managerRef.ask<ChannelClosedResponse>(
              CloseChannelMessage(channelId: _channelId), _timeout))
          .success, isTrue);
      await flushWallet();

      expect(imported(), isEmpty);
      expect(received(), isEmpty);
      expect(journal().whereType<ChannelClosedEvent>(), isEmpty);
    });
  });

  group('libspiffy-pkg5: a countersigned copy journaled before pkg5', () {
    late _PaymentPair pair;

    setUp(() async {
      f = await ChannelRefundFixture.create(channelId: _channelId);
      pair = await _PaymentPair.build(f, serverAmountSats: BigInt.from(30000));
    });

    // Clients journaled the server's countersignature (bead z2px) until the
    // server stopped sending it. Such a journal still replays, and the copy
    // it holds is not a settlement anybody broadcast.
    test('replays, and the client does not close with it', () async {
      await spawn([
        ...f.openClientJournal(walletId: _walletId),
        PaymentRecordedEvent(
          channelId: _channelId,
          amountSats: BigInt.from(30000),
          sequenceNumber: 1,
          paymentTxHex: pair.templateHex,
          paymentTxId: pair.templateTxId,
          clientSignatureHex: pair.clientSignatureHex,
          newClientBalanceSats: f.amountSats - BigInt.from(30000),
          newServerBalanceSats: BigInt.from(30000),
          version: 7,
        ),
        // ignore: deprecated_member_use_from_same_package
        PaymentCountersignedEvent(
          channelId: _channelId,
          sequenceNumber: 1,
          serverSignatureHex: pair.serverSignatureHex,
          fullySignedPaymentTxHex: pair.settlementHex,
          fullySignedPaymentTxId: pair.settlementTxId,
          version: 8,
        ),
      ], key: f.clientKey);

      final closed = await managerRef.ask<ChannelClosedResponse>(
        CloseChannelMessage(channelId: _channelId, reason: 'done'),
        _timeout,
      );

      expect(closed.success, isTrue, reason: closed.error);
      expect(closed.finalized, isFalse,
          reason: 'the client closes with the settlement its server broadcast and hands over');
      expect(journal().whereType<ChannelClosedEvent>(), isEmpty);
      expect(arc.broadcasts, isEmpty);
      await flushWallet();
      expect(imported(), isEmpty);

      // ...and the settlement its server hands over is still recognised as
      // its latest payment.
      final handed = await managerRef.ask<ChannelClosedResponse>(
          RecordSettlementMessage(channelId: _channelId, settlementTxHex: pair.settlementHex), _timeout);
      expect(handed.finalized, isTrue, reason: handed.error);
    });
  });

  group('libspiffy-u6q6: the client closes with the settlement its server broadcast', () {
    late _PaymentPair pair;

    setUp(() async {
      f = await ChannelRefundFixture.create(channelId: _channelId);
      pair = await _PaymentPair.build(f, serverAmountSats: BigInt.from(30000));
    });

    List<Event> clientJournalWithPayment() => [
          ...f.openClientJournal(walletId: _walletId),
          PaymentRecordedEvent(
            channelId: _channelId,
            amountSats: BigInt.from(30000),
            sequenceNumber: 1,
            paymentTxHex: pair.templateHex,
            paymentTxId: pair.templateTxId,
            clientSignatureHex: pair.clientSignatureHex,
            newClientBalanceSats: f.amountSats - BigInt.from(30000),
            newServerBalanceSats: BigInt.from(30000),
            version: 7,
          ),
        ];

    Future<ChannelClosedResponse> handOver(String hex) => managerRef.ask<ChannelClosedResponse>(
        RecordSettlementMessage(channelId: _channelId, settlementTxHex: hex), _timeout);

    test('the settlement handed over closes the channel and reaches the wallet', () async {
      await spawn(clientJournalWithPayment(), key: f.clientKey);

      final closed = await handOver(pair.settlementHex);

      expect(closed.success, isTrue, reason: closed.error);
      expect(closed.finalized, isTrue);
      expect(closed.settlementTxId, pair.settlementTxId);
      expect(journal().whereType<ChannelClosingEvent>(), hasLength(1),
          reason: 'closed from open: channel_close had not arrived');
      final ended = journal().whereType<ChannelClosedEvent>().single;
      expect(ended.settlementTxId, pair.settlementTxId);
      expect(arc.broadcasts, isEmpty, reason: 'the server broadcast it; the client records it');

      await flushWallet();
      final w = await readBack();
      final tx = await w.storage.getTransaction(pair.settlementTxId, walletId: _walletId);
      expect(tx, isNotNull, reason: "the client's return leg reaches its own history");
      expect(tx!.status, TransactionStatus.pending);
      final ours = (await w.storage.getUTXOs(_walletId)).where((u) => u.txid == pair.settlementTxId).toList();
      expect(ours.single.value.getValue(), pair.clientAmount);
      expect(ours.single.status, UTXOStatus.pending);
    });

    test('a channel already closing is closed by it; a second hand-over records nothing', () async {
      await spawn(clientJournalWithPayment(), key: f.clientKey);
      await managerRef.ask<ChannelClosedResponse>(CloseChannelMessage(channelId: _channelId), _timeout);

      expect((await handOver(pair.settlementHex)).finalized, isTrue);
      expect((await handOver(pair.settlementHex)).success, isTrue);
      await flushWallet();

      expect(journal().whereType<ChannelClosingEvent>(), hasLength(1));
      expect(journal().whereType<ChannelClosedEvent>(), hasLength(1));
      expect(imported(), hasLength(1));
    });

    test('a settlement that is not the latest payment is refused', () async {
      await spawn(clientJournalWithPayment(), key: f.clientKey);
      final other = await _PaymentPair.build(f, serverAmountSats: BigInt.from(40000));

      final closed = await handOver(other.settlementHex);

      expect(closed.success, isFalse);
      expect(closed.error, contains('not the latest payment'));
      expect(journal().whereType<ChannelClosedEvent>(), isEmpty);
      await flushWallet();
      expect(imported(), isEmpty);
    });

    test('an unsigned settlement is refused: it is not a transaction the network has', () async {
      await spawn(clientJournalWithPayment(), key: f.clientKey);

      final closed = await handOver(pair.templateHex);

      expect(closed.success, isFalse);
      expect(journal().whereType<ChannelClosedEvent>(), isEmpty);
    });

    test('a server is not handed a settlement', () async {
      await spawn([
        f.serverAccepted(version: 1),
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
      ], key: f.serverKey);

      final closed = await handOver(pair.settlementHex);

      expect(closed.success, isFalse);
      expect(closed.error, contains('Only a client'));
    });
  });

  group('libspiffy-f5p2: an expiry records the refund', () {
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

    /// A server's journal past its lockTime, holding one acknowledged payment.
    Future<({List<Event> journal, _Settlement settlement})> serverPastLockTime() async {
      final settlement = await _Settlement.build(f, serverAmountSats: BigInt.from(30000));
      return (
        settlement: settlement,
        journal: <Event>[
          f.serverAccepted(version: 1),
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
        ],
      );
    }

    // Bead libspiffy-u6q6: at expiry the server's return leg is its
    // settlement, which it recorded in the wallet without submitting it.
    test('u6q6: a server\'s expiry broadcasts its settlement before recording it', () async {
      final server = await serverPastLockTime();
      await spawn(server.journal, key: f.serverKey);

      final expired = await expire();
      await flushWallet();

      expect(expired.success, isTrue, reason: expired.error);
      expect(arc.broadcasts.map((b) => b.txid), [server.settlement.txid]);
      expect(imported().single.txid, server.settlement.txid);
    });

    test('u6q6: a server\'s settlement ARC did not take at expiry is not recorded', () async {
      final server = await serverPastLockTime();
      await spawn(server.journal, key: f.serverKey);
      arc.failWith = 'missing inputs';

      final expired = await expire();
      await flushWallet();

      // Old code: success, with a receive recorded that the refund may
      // already have taken.
      expect(expired.success, isFalse);
      expect(expired.error, contains('missing inputs'));
      expect(imported(), isEmpty);
      expect(journal().whereType<ChannelExpiredEvent>(), hasLength(1),
          reason: 'the expiry is a fact either way');
    });

    test('the fully signed refund reaches the client wallet as an unproven '
        'receive', () async {
      await spawn(f.openClientJournal(walletId: _walletId), key: f.clientKey);
      final refund = dartsv.Transaction.fromHex(f.signedRefundTxHex());

      final expired = await expire();
      expect(expired.success, isTrue, reason: expired.error);
      await flushWallet();

      final record = imported().single;
      expect(record.txid, refund.id);
      expect(record.rawHex, f.signedRefundTxHex());
      expect(record.blockHeight, isNull);
      expect(record.bumpProofHex, isEmpty);
      expect(record.walletReceivingAddresses, [f.clientAddressB58]);
      expect(record.sendingAddresses, ['channel:$_channelId']);

      final utxo = received().single;
      expect(utxo.txid, refund.id);
      expect(utxo.address, f.clientAddressB58);
      expect(utxo.initialStatus, UTXOStatus.pending);
      expect(utxo.blockHeight, isNull);

      final w = await readBack();
      final tx = await w.storage.getTransaction(refund.id, walletId: _walletId);
      expect(tx, isNotNull);
      expect(tx!.status, TransactionStatus.pending);
      expect(tx.netAmount, refund.outputs.first.satoshis);
      final ours = (await w.storage.getUTXOs(_walletId))
          .where((u) => u.txid == refund.id)
          .toList();
      expect(ours, hasLength(1));
      expect(ours.single.status, UTXOStatus.pending);
    });

    /// Bead libspiffy-lfrv. The expiry journals `ChannelExpiredEvent` and
    /// THEN writes the wallet. A crash between the two used to lose the
    /// wallet record for good: the aggregate refuses to expire an
    /// already-terminated channel, so a re-delivered expiry was answered with
    /// an error and nothing ever retried the write. The funding path closed
    /// the same hole with `FundingRecordedInWalletEvent`; this journal has
    /// the expiry and no record of the write, which is the crash.
    test('an expiry interrupted before the wallet write is resumed', () async {
      await spawn([
        ...f.openClientJournal(walletId: _walletId),
        ChannelExpiredEvent(
            channelId: _channelId, observedBy: 'client', version: 7),
      ], key: f.clientKey);
      final refund = dartsv.Transaction.fromHex(f.signedRefundTxHex());

      final expired = await expire();
      expect(expired.success, isTrue, reason: expired.error);
      await flushWallet();

      expect(imported().map((c) => c.txid), [refund.id],
          reason: 'the refund is the money coming back; an expiry that '
              'journaled and crashed must not lose it');
      expect(received(), hasLength(1));
      expect(journal().whereType<ChannelExpiredEvent>(), hasLength(1),
          reason: 'the expiry itself is not journaled twice');
    });

    test('a resumed expiry is not resumed again', () async {
      await spawn([
        ...f.openClientJournal(walletId: _walletId),
        ChannelExpiredEvent(
            channelId: _channelId, observedBy: 'client', version: 7),
      ], key: f.clientKey);

      expect((await expire()).success, isTrue);
      await flushWallet();
      final afterFirst = journal().length;

      expect((await expire()).success, isTrue);
      await flushWallet();

      expect(imported(), hasLength(1));
      expect(received(), hasLength(1));
      expect(journal().length, afterFirst,
          reason: 'the wallet write is journaled, so nothing repeats it');
    });

    test('a re-delivered expiry records nothing new', () async {
      await spawn(f.openClientJournal(walletId: _walletId), key: f.clientKey);
      expect((await expire()).success, isTrue);
      await flushWallet();

      await expire();
      await flushWallet();

      expect(imported(), hasLength(1));
      expect(received(), hasLength(1));
      expect(journal().whereType<ChannelExpiredEvent>(), hasLength(1));
    });
  });
}

class _NoopEventStore implements EventStore {
  @override
  Future<void> persistEvent(String persistenceId, Event event, int expectedVersion) async {}

  @override
  Future<void> persistEvents(String persistenceId, List<Event> events, int expectedVersion) async {}

  @override
  Future<List<Event>> getEvents(String persistenceId, {int fromSequence = 0, int? toSequence}) async => [];

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) async => 0;

  @override
  Future<void> saveSnapshot(String persistenceId, dynamic state, int sequenceNumber) async {}

  @override
  Future<SnapshotData?> loadSnapshot(String persistenceId) async => null;

  @override
  Future<void> deleteOldSnapshots(String persistenceId, int keepCount) async {}

  @override
  Future<void> close() async {}
}
