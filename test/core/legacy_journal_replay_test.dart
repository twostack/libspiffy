// Data retention for the lane-3 serialization changes (audit 2026-09-14 M8,
// L2, KM-8): a journal written in the old format replays to exactly the state
// the same history reaches in the new format.
//
// Old format, as written by the releases before these fixes:
// - M8: every row's `type` (and envelope eventType) is the Dart class name;
// - L2: channel rows carry raw metadata (a stringified replyTo ActorRef) and
//   no aggregateId / aggregateType;
// - KM-8: WalletCreatedEvent rows carry `hdPublicKeyXpub`.
import 'dart:io';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/internals.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/models/invoice_state.dart';
import 'package:test/test.dart';

import '../integration/isar_test_helper.dart';
import 'event_type_names_test.dart' show goldenTypeNames, sampleEvents;

const _mnemonic =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

/// Class name each stable id was stored under before M8.
final _legacyNameOf = {
  for (final e in goldenTypeNames.entries) e.value: e.key,
};

/// A row exactly as an earlier release stored it.
class _OldRow extends Event {
  final Map<String, dynamic> payload;

  _OldRow(this.payload, Event original)
      : super(
          eventId: original.eventId,
          timestamp: original.timestamp,
          version: original.version,
        );

  @override
  String get typeName => payload['type'] as String;

  @override
  Map<String, dynamic> toMap() => payload;
}

/// The map the pre-fix code wrote for [event].
Map<String, dynamic> oldFormat(Event event, {String? xpub}) {
  final legacyName = _legacyNameOf[event.typeName]!;
  if (event is ChannelEvent) {
    // Pre-L2 ChannelEvent.toMap(): raw metadata, no aggregate keys.
    return {
      'type': legacyName,
      'eventId': event.eventId,
      'timestamp': event.timestamp.toIso8601String(),
      'version': event.version,
      'channelId': event.channelId,
      'metadata': {
        ...event.metadata,
        'replyTo': 'Instance of \'LocalActorRef\'',
      },
      ...event.getChannelEventData(),
    };
  }
  final map = event.toMap()..['type'] = legacyName;
  if (event is WalletCreatedEvent && xpub != null) {
    map['hdPublicKeyXpub'] = xpub;
  }
  return map;
}

void main() {
  final crypto = DartSVCryptoService();
  final dirs = <Directory>[];
  final stores = <IsarEventStore>[];

  setUpAll(ensureIsarInitialized);

  setUp(() {
    EventRegistry.clear();
    LibSpiffyActorSystem.registerEventTypes();
  });

  tearDown(() async {
    for (final s in stores) {
      await s.close();
    }
    for (final d in dirs) {
      await d.delete(recursive: true);
    }
    stores.clear();
    dirs.clear();
  });

  Future<IsarEventStore> newStore() async {
    final dir = await Directory.systemTemp.createTemp('lane3_legacy_');
    dirs.add(dir);
    final store = await IsarEventStore.create(
        directory: dir.path,
        name: 'legacy_${DateTime.now().microsecondsSinceEpoch}');
    stores.add(store);
    return store;
  }

  /// Copies [persistenceId] from [from] into [to] in the old row format.
  Future<void> copyAsOldJournal(IsarEventStore from, IsarEventStore to,
      String persistenceId, {String? xpub}) async {
    final events = await from.getEvents(persistenceId);
    expect(events, isNotEmpty);
    for (var i = 0; i < events.length; i++) {
      await to.persistEvent(persistenceId,
          _OldRow(oldFormat(events[i], xpub: xpub), events[i]), i);
    }
    // The copy really is in the old format.
    final stored = await to.isar.eventEnvelopes.where().findAll();
    expect(stored.map((e) => e.eventType),
        everyElement(isIn(goldenTypeNames.keys)));
  }

  test('M8 + KM-8: an old wallet journal replays to the same wallet state', () async {
    const walletId = 'legacy-wallet';
    final secrets = InMemorySecureStorage();
    final hd = await crypto.mnemonicToHDPrivateKey(_mnemonic,
        network: dartsv.NetworkType.TEST);
    final xpub = crypto.deriveHDPublicKey(hd).xpubkey;

    BitcoinWalletAggregate aggregateOn(EventStore store) => BitcoinWalletAggregate(
          aggregateId: walletId,
          aggregateType: 'Wallet',
          eventStore: store,
          cryptoService: crypto,
          secureStorage: secrets,
        );

    final current = await newStore();
    final writer = aggregateOn(current);
    await writer.preStart();
    await writer.commandHandler(CreateWalletCommand(
        walletId: walletId, walletName: 'history', mnemonic: _mnemonic));
    await writer.commandHandler(GenerateAddressCommand(walletId: walletId));
    await writer.commandHandler(UpdateWalletConfigurationCommand(
        walletId: walletId, newName: 'renamed'));
    await writer.commandHandler(ReceiveUTXOCommand(
      walletId: walletId,
      txid: 'aa00000000000000000000000000000000000000000000000000000000000001',
      vout: 0,
      satoshis: BigInt.from(5000),
      scriptPubKey: '76a914000000000000000000000000000000000000000088ac',
      address: writer.currentState.rootAddress!,
      blockHeight: 100,
      confirmations: 1,
      initialStatus: UTXOStatus.available, // proven: it has a height (bead libspiffy-5ry)
      derivationIndex: 0,
    ));

    final old = await newStore();
    await copyAsOldJournal(current, old, 'Wallet_$walletId', xpub: xpub);

    final fromCurrent = aggregateOn(current);
    await fromCurrent.preStart();
    final fromOld = aggregateOn(old);
    await fromOld.preStart();

    expect(fromOld.currentState.isCreated, isTrue);
    expect(fromOld.currentState.utxos, hasLength(1));
    expect(_walletSummary(fromOld.currentState),
        _walletSummary(fromCurrent.currentState));

    // Still a working wallet: it derives its next address.
    await fromOld.commandHandler(GenerateAddressCommand(walletId: walletId));
    expect(fromOld.currentState.nextDerivationIndex,
        fromCurrent.currentState.nextDerivationIndex + 1);
  });

  test('M8 + L2: an old channel journal (raw metadata, class names) replays to the same channel state', () async {
    const channelId = 'channel-1';
    final samples = sampleEvents();
    // A client-side lifecycle, with the sample events renumbered 1..n.
    final lifecycle = [
      'ChannelRequestedEvent',
      'ServerAcceptanceRecordedEvent',
      'RefundBuiltEvent',
      'RefundCountersignedEvent',
      'ChannelOpenedEvent',
      'PaymentRecordedEvent',
      'PaymentAcknowledgedEvent',
      'ChannelClosingEvent',
      'ChannelClosedEvent',
    ];
    final current = await newStore();
    for (var i = 0; i < lifecycle.length; i++) {
      final sample = samples[lifecycle[i]]!;
      final map = sample.toMap()
        ..['version'] = i + 1
        ..['metadata'] = {'correlationId': 'corr-$i'};
      await current.persistEvent(
          'PaymentChannel_$channelId', EventRegistry.fromMap(map), i);
    }

    final old = await newStore();
    await copyAsOldJournal(current, old, 'PaymentChannel_$channelId');

    Future<PaymentChannelAggregate> replay(EventStore store) async {
      final aggregate = PaymentChannelAggregate(
          aggregateId: channelId, eventStore: store, cryptoService: crypto);
      await aggregate.preStart();
      return aggregate;
    }

    final a = (await replay(current)).currentState;
    final b = (await replay(old)).currentState;
    expect(b.status, ChannelStatus.closed);
    expect(_channelSummary(b), _channelSummary(a));

    // The old rows' stringified replyTo is not resurrected as a live ref.
    final oldEvents = await old.getEvents('PaymentChannel_$channelId');
    expect(oldEvents.first.replyTo, isNull);
    expect(oldEvents.first, isA<ChannelRequestedEvent>());
  });

  test('M8: an old invoice journal replays to the same invoice state', () async {
    const invoiceId = 'invoice-1';
    final samples = sampleEvents();
    final current = await newStore();
    final lifecycle = [
      'InvoiceCreatedEvent',
      'InvoiceStatusChangedEvent',
      'InvoicePaidEvent',
    ];
    for (var i = 0; i < lifecycle.length; i++) {
      await current.persistEvent(
          'Invoice_$invoiceId', samples[lifecycle[i]]!, i);
    }
    final old = await newStore();
    await copyAsOldJournal(current, old, 'Invoice_$invoiceId');

    Future<InvoiceState> replay(EventStore store) async {
      final aggregate = InvoiceAggregate(
          aggregateId: invoiceId, aggregateType: 'Invoice', eventStore: store);
      await aggregate.preStart();
      return aggregate.currentState;
    }

    final a = await replay(current);
    final b = await replay(old);
    expect(b.status, InvoiceStatus.paid);
    expect(_invoiceSummary(b), _invoiceSummary(a));
  });
}

/// [WalletState.toMap] minus the UTXO wall-clock stamps: the aggregate sets a
/// UTXO's createdAt/updatedAt from DateTime.now() when it applies the event,
/// so they differ between any two replays of the same journal.
Map<String, dynamic> _walletSummary(WalletState s) {
  final map = s.toMap();
  final utxos = (map['utxos'] as Map).map((key, value) {
    final utxo = Map<String, dynamic>.from(value as Map)
      ..remove('createdAt')
      ..remove('updatedAt');
    return MapEntry(key, utxo);
  });
  return map..['utxos'] = utxos;
}

Map<String, Object?> _channelSummary(ChannelState s) => {
      'walletId': s.walletId,
      'status': s.status,
      'role': s.role,
      'clientPeerId': s.clientPeerId,
      'serverPeerId': s.serverPeerId,
      'clientPubKeyHex': s.clientPubKeyHex,
      'serverPubKeyHex': s.serverPubKeyHex,
      'clientAddressB58': s.clientAddressB58,
      'serverAddressB58': s.serverAddressB58,
      'derivationIndex': s.derivationIndex,
      'fundingAmountSats': s.fundingAmountSats,
      'fundingTxId': s.fundingTxId,
      'fundingTxHex': s.fundingTxHex,
      'fundingOutputIndex': s.fundingOutputIndex,
      'fundingAncestorTxids': s.fundingAncestorTxids,
      'lockTimeUnix': s.lockTimeUnix,
      'refundTxHex': s.refundTxHex,
      'refundClientSigHex': s.refundClientSigHex,
      'refundServerSigHex': s.refundServerSigHex,
      'clientBalanceSats': s.clientBalanceSats,
      'serverBalanceSats': s.serverBalanceSats,
      'latestSequenceNumber': s.latestSequenceNumber,
      'latestPaymentTxHex': s.latestPaymentTxHex,
      'latestPaymentTxId': s.latestPaymentTxId,
      'context': s.context,
      'createdAt': s.createdAt,
      'closedAt': s.closedAt,
      'version': s.version,
      'lastModified': s.lastModified,
    };

Map<String, Object?> _invoiceSummary(InvoiceState s) => {
      'isCreated': s.isCreated,
      'walletId': s.walletId,
      'addresses': s.addresses,
      'amount': s.amount,
      'description': s.description,
      'status': s.status,
      'createdAt': s.createdAt,
      'expiresAt': s.expiresAt,
      'paidAt': s.paidAt,
      'paymentTxid': s.paymentTxid,
      'amountReceived': s.amountReceived,
      'metadata': s.metadata,
      'version': s.version,
      'lastModified': s.lastModified,
    };
