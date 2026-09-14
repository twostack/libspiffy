// Audit 2026-09-14 M8: journal event types are stored under stable
// identifiers, not Dart class names, and journals written under the old
// class names still load.
import 'dart:io';

import 'package:eventador/eventador.dart';
import 'package:isar/isar.dart';
import 'package:libspiffy/internals.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:test/test.dart';

import '../integration/isar_test_helper.dart';

/// The pinned journal identifiers, keyed by the class name each type was
/// stored under before M8 (and still registered as an alias).
///
/// Changing a value here breaks every existing journal: add an alias
/// instead. A class rename must not change this table.
const goldenTypeNames = <String, String>{
  // Wallet
  'WalletCreatedEvent': 'wallet.created',
  'WalletConfigurationUpdatedEvent': 'wallet.configuration_updated',
  'WalletDeletedEvent': 'wallet.deleted',
  'AddressGeneratedEvent': 'wallet.address.generated',
  'AddressLabelUpdatedEvent': 'wallet.address.label_updated',
  'AddressDiscoveredEvent': 'wallet.address.discovered',
  'UTXOReceivedEvent': 'wallet.utxo.received',
  'UTXOMarkedAvailableEvent': 'wallet.utxo.marked_available',
  'UTXOSpentEvent': 'wallet.utxo.spent',
  'UTXOConfirmationUpdatedEvent': 'wallet.utxo.confirmation_updated',
  'UTXOReservedEvent': 'wallet.utxo.reserved',
  'UTXOReleasedEvent': 'wallet.utxo.released',
  'UTXOReservationRenewedEvent': 'wallet.utxo.reservation_renewed',
  'UTXOReservationPlacedEvent': 'wallet.utxo_reservation.placed',
  'UTXOReservationReleasedEvent': 'wallet.utxo_reservation.released',
  'UTXOReservationExpiredEvent': 'wallet.utxo_reservation.expired',
  'TransactionSignedEvent': 'wallet.transaction.signed',
  'TransactionBroadcastEvent': 'wallet.transaction.broadcast',
  'TransactionImportedEvent': 'wallet.transaction.imported',
  'TransactionRecordedEvent': 'wallet.transaction.recorded',
  'TransactionConfirmedEvent': 'wallet.transaction.confirmed',
  'TransactionStatusUpdatedEvent': 'wallet.transaction.status_updated',
  'TransactionConfirmationRevertedEvent': 'wallet.transaction.confirmation_reverted',
  'UTXOSplitInitiatedEvent': 'wallet.utxo_split.initiated',
  'UTXOSplitCompletedEvent': 'wallet.utxo_split.completed',
  'AllUTXOsSplitCompletedEvent': 'wallet.utxo_split.all_completed',
  // Invoice
  'InvoiceCreatedEvent': 'invoice.created',
  'InvoiceStatusChangedEvent': 'invoice.status_changed',
  'InvoicePaidEvent': 'invoice.paid',
  'InvoiceExpiredEvent': 'invoice.expired',
  'InvoiceCancelledEvent': 'invoice.cancelled',
  // Payment channel
  'ChannelRequestedEvent': 'channel.requested',
  'ChannelAcceptedEvent': 'channel.accepted',
  'ChannelRejectedEvent': 'channel.rejected',
  'ServerAcceptanceRecordedEvent': 'channel.server_acceptance_recorded',
  'RefundBuiltEvent': 'channel.refund.built',
  'RefundCountersignedEvent': 'channel.refund.countersigned',
  'FundingBroadcastStartedEvent': 'channel.funding.broadcast_started',
  'FundingBroadcastFailedEvent': 'channel.funding.broadcast_failed',
  'ChannelOpenedEvent': 'channel.opened',
  'PaymentRecordedEvent': 'channel.payment.recorded',
  'PaymentAcknowledgedEvent': 'channel.payment.acknowledged',
  'ChannelClosingEvent': 'channel.closing',
  'ChannelClosedEvent': 'channel.closed',
  'RefundClaimedEvent': 'channel.refund.claimed',
  'ChannelExpiredEvent': 'channel.expired',
};

final _t = DateTime.utc(2026, 1, 2, 3, 4, 5);
const _w = 'wallet-1';
const _c = 'channel-1';
const _i = 'invoice-1';
const _txid = 'aa00000000000000000000000000000000000000000000000000000000000001';

/// One instance of every journal event type, keyed by its legacy (class)
/// name. The keys are literals, not `runtimeType.toString()`.
Map<String, Event> sampleEvents() => <String, Event>{
      'WalletCreatedEvent': WalletCreatedEvent(
          walletId: _w, walletName: 'n', rootAddress: 'addr',
          walletType: WalletType.hd, walletMetadata: {'network': 'test'},
          timestamp: _t, version: 1),
      'WalletConfigurationUpdatedEvent': WalletConfigurationUpdatedEvent(
          walletId: _w, newName: 'm', timestamp: _t, version: 2),
      'WalletDeletedEvent': WalletDeletedEvent(
          walletId: _w, reason: 'r', timestamp: _t, version: 3),
      'AddressGeneratedEvent': AddressGeneratedEvent(
          walletId: _w, address: 'addr', derivationIndex: 1, label: 'l',
          purpose: 'receiving', timestamp: _t, version: 4),
      'AddressLabelUpdatedEvent': AddressLabelUpdatedEvent(
          walletId: _w, address: 'addr', newLabel: 'b', oldLabel: 'a',
          timestamp: _t, version: 5),
      'AddressDiscoveredEvent': AddressDiscoveredEvent(
          walletId: _w, address: 'addr', derivationIndex: 2, isChange: false,
          transactionCount: 1, timestamp: _t, version: 6),
      'UTXOReceivedEvent': UTXOReceivedEvent(
          walletId: _w, txid: _txid, vout: 0, satoshis: 1000,
          scriptPubKey: '76a9', address: 'addr', blockHeight: 10,
          confirmations: 1, timestamp: _t, version: 7),
      'UTXOMarkedAvailableEvent': UTXOMarkedAvailableEvent(
          walletId: _w, txid: _txid, vout: 0, timestamp: _t, version: 8),
      'UTXOSpentEvent': UTXOSpentEvent(
          walletId: _w, txid: _txid, vout: 0, spentInTxId: _txid,
          timestamp: _t, version: 9),
      'UTXOConfirmationUpdatedEvent': UTXOConfirmationUpdatedEvent(
          walletId: _w, txid: _txid, vout: 0, confirmations: 2,
          blockHeight: 11, timestamp: _t, version: 10),
      'UTXOReservedEvent': UTXOReservedEvent(
          walletId: _w, txid: _txid, vout: 0, reservedByTxId: 'x',
          expiresAt: _t, timestamp: _t, version: 11),
      'UTXOReleasedEvent': UTXOReleasedEvent(
          walletId: _w, txid: _txid, vout: 0, releaseReason: 'r',
          timestamp: _t, version: 12),
      'UTXOReservationRenewedEvent': UTXOReservationRenewedEvent(
          walletId: _w, txid: _txid, vout: 0, newExpiresAt: _t,
          oldExpiresAt: _t, timestamp: _t, version: 13),
      'UTXOReservationPlacedEvent': UTXOReservationPlacedEvent(
          walletId: _w, utxoIdentifiers: [{'txid': _txid, 'vout': 0}],
          reservationId: 'res', expiresAt: _t, timestamp: _t, version: 14),
      'UTXOReservationReleasedEvent': UTXOReservationReleasedEvent(
          walletId: _w, reservationId: 'res',
          utxoIdentifiers: [{'txid': _txid, 'vout': 0}], timestamp: _t,
          version: 15),
      'UTXOReservationExpiredEvent': UTXOReservationExpiredEvent(
          walletId: _w, reservationId: 'res',
          utxoIdentifiers: [{'txid': _txid, 'vout': 0}], timestamp: _t,
          version: 16),
      'TransactionSignedEvent': TransactionSignedEvent(
          walletId: _w, txid: _txid, signedRawHex: '01', timestamp: _t,
          version: 17),
      'TransactionBroadcastEvent': TransactionBroadcastEvent(
          walletId: _w, txid: _txid, broadcastResponse: 'ok', timestamp: _t,
          version: 18),
      'TransactionImportedEvent': TransactionImportedEvent(
          walletId: _w, txid: _txid, rawHex: '01', blockHeight: 5,
          bumpProof: 'bump', totalOutputSats: 10, numInputs: 1, numOutputs: 1,
          txVersion: 1, txLockTime: 0, walletReceivingAddresses: ['addr'],
          walletReceivedSats: 10, totalInputSats: 11,
          sendingAddresses: ['other'], timestamp: _t, version: 19),
      'TransactionRecordedEvent': TransactionRecordedEvent(
          walletId: _w, txid: _txid, rawHex: '01', totalInputSats: 11,
          totalOutputSats: 10, fee: 1, numInputs: 1, numOutputs: 1,
          txVersion: 1, txLockTime: 0, spentUtxoKeys: ['$_txid:0'],
          recipientAddresses: ['other'], paymentAmount: '10', timestamp: _t,
          version: 20),
      'TransactionConfirmedEvent': TransactionConfirmedEvent(
          walletId: _w, txid: _txid, blockHeight: 12, blockHash: 'h',
          timestamp: _t, version: 21),
      'TransactionStatusUpdatedEvent': TransactionStatusUpdatedEvent(
          walletId: _w, txid: _txid, newStatus: TransactionStatus.broadcast,
          timestamp: _t, version: 22),
      'TransactionConfirmationRevertedEvent': TransactionConfirmationRevertedEvent(
          walletId: _w, txid: _txid, blockHeight: 12, blockHash: 'h',
          merkleProof: ['00'], reason: 'reorg', timestamp: _t, version: 100),
      'UTXOSplitInitiatedEvent': UTXOSplitInitiatedEvent(
          walletId: _w, utxoKeysToSplit: ['$_txid:0'], targetUtxoCount: 3,
          feeRate: BigInt.one, timestamp: _t, version: 23),
      'UTXOSplitCompletedEvent': UTXOSplitCompletedEvent(
          walletId: _w, originalUtxoKey: '$_txid:0', originalAmount: '100',
          splitTxid: _txid, outputsCreated: 3, feePaid: '1', timestamp: _t,
          version: 24),
      'AllUTXOsSplitCompletedEvent': AllUTXOsSplitCompletedEvent(
          walletId: _w, totalUtxosSplit: 1, totalOutputsCreated: 3,
          totalFeesPaid: '1', transactionIds: [_txid], timestamp: _t,
          version: 25),
      'InvoiceCreatedEvent': InvoiceCreatedEvent(
          invoiceId: _i, walletId: _w, addresses: ['addr'],
          amount: BigInt.from(10), description: 'd', timestamp: _t,
          version: 1),
      'InvoiceStatusChangedEvent': InvoiceStatusChangedEvent(
          invoiceId: _i, walletId: _w, oldStatus: InvoiceStatus.pending,
          newStatus: InvoiceStatus.paid, timestamp: _t, version: 2),
      'InvoicePaidEvent': InvoicePaidEvent(
          invoiceId: _i, walletId: _w, txid: _txid,
          amountReceived: BigInt.from(10), addressesPaidTo: ['addr'],
          paidAt: _t, timestamp: _t, version: 3),
      'InvoiceExpiredEvent': InvoiceExpiredEvent(
          invoiceId: _i, walletId: _w, timestamp: _t, version: 4),
      'InvoiceCancelledEvent': InvoiceCancelledEvent(
          invoiceId: _i, walletId: _w, reason: 'r', timestamp: _t,
          version: 5),
      'ChannelRequestedEvent': ChannelRequestedEvent(
          channelId: _c, walletId: _w, clientPeerId: 'cp', serverPeerId: 'sp',
          clientPubKeyHex: '02', clientAddressB58: 'ca', derivationIndex: 1,
          fundingAmountSats: BigInt.from(1000), lockTimeUnix: 99,
          timestamp: _t, version: 1),
      'ChannelAcceptedEvent': ChannelAcceptedEvent(
          channelId: _c, walletId: _w, clientPeerId: 'cp',
          clientPubKeyHex: '02', clientAddressB58: 'ca',
          serverPubKeyHex: '03', serverAddressB58: 'sa', derivationIndex: 1,
          fundingAmountSats: BigInt.from(1000), lockTimeUnix: 99,
          timestamp: _t, version: 2),
      'ChannelRejectedEvent': ChannelRejectedEvent(
          channelId: _c, reason: 'r', timestamp: _t, version: 3),
      'ServerAcceptanceRecordedEvent': ServerAcceptanceRecordedEvent(
          channelId: _c, serverPubKeyHex: '03', serverAddressB58: 'sa',
          timestamp: _t, version: 4),
      'RefundBuiltEvent': RefundBuiltEvent(
          channelId: _c, fundingTxId: _txid, fundingOutputIndex: 0,
          fundingTxHex: '01', refundTxHex: '02', clientSignatureHex: '30',
          fundingInputSats: 1100, timestamp: _t, version: 5),
      'RefundCountersignedEvent': RefundCountersignedEvent(
          channelId: _c, serverSignatureHex: '30', signedRefundTxHex: '03',
          timestamp: _t, version: 6),
      'FundingBroadcastStartedEvent': FundingBroadcastStartedEvent(
          channelId: _c, fundingTxId: _txid, attempt: 1, timestamp: _t,
          version: 6),
      'FundingBroadcastFailedEvent': FundingBroadcastFailedEvent(
          channelId: _c, fundingTxId: _txid, error: 'e', walletRecorded: true,
          timestamp: _t, version: 6),
      'ChannelOpenedEvent': ChannelOpenedEvent(
          channelId: _c, fundingTxId: _txid, fundingOutputIndex: 0,
          fundingTxHex: '01', fundingAncestorTxids: [_txid],
          initialClientBalanceSats: BigInt.from(900),
          initialServerBalanceSats: BigInt.zero, timestamp: _t, version: 7),
      'PaymentRecordedEvent': PaymentRecordedEvent(
          channelId: _c, amountSats: BigInt.from(10),
          newClientBalanceSats: BigInt.from(890),
          newServerBalanceSats: BigInt.from(10), sequenceNumber: 1,
          paymentTxHex: '01', paymentTxId: _txid, clientSignatureHex: '30',
          timestamp: _t, version: 8),
      'PaymentAcknowledgedEvent': PaymentAcknowledgedEvent(
          channelId: _c, amountSats: BigInt.from(10), sequenceNumber: 1,
          newClientBalanceSats: BigInt.from(890),
          newServerBalanceSats: BigInt.from(10),
          fullySignedPaymentTxHex: '01', serverSignatureHex: '30',
          timestamp: _t, version: 9),
      'ChannelClosingEvent': ChannelClosingEvent(
          channelId: _c, initiator: 'client',
          clientBalanceSats: BigInt.from(890),
          serverBalanceSats: BigInt.from(10), timestamp: _t, version: 10),
      'ChannelClosedEvent': ChannelClosedEvent(
          channelId: _c, settlementTxId: _txid,
          finalClientBalanceSats: BigInt.from(890),
          finalServerBalanceSats: BigInt.from(10), timestamp: _t,
          version: 11),
      'RefundClaimedEvent': RefundClaimedEvent(
          channelId: _c, refundTxId: _txid,
          refundAmountSats: BigInt.from(900), timestamp: _t, version: 12),
      'ChannelExpiredEvent': ChannelExpiredEvent(
          channelId: _c, observedBy: 'client', timestamp: _t, version: 13),
    };

/// Stands in for a row written by a release that stored the class name:
/// the payload's `type` and the envelope's eventType are [legacyName].
class _StoredUnderLegacyName extends Event {
  final String legacyName;
  final Map<String, dynamic> payload;

  _StoredUnderLegacyName(this.legacyName, Event original)
      : payload = original.toMap()..['type'] = legacyName,
        super(
          eventId: original.eventId,
          timestamp: original.timestamp,
          version: original.version,
        );

  @override
  String get typeName => legacyName;

  @override
  Map<String, dynamic> toMap() => payload;
}

void main() {
  setUp(() {
    EventRegistry.clear();
    LibSpiffyActorSystem.registerEventTypes();
  });

  test('the samples cover every registered journal event type', () {
    expect(sampleEvents().keys.toSet(), goldenTypeNames.keys.toSet());
    for (final entry in sampleEvents().entries) {
      // Holds in a non-obfuscated test build; guards the table's keys.
      expect(entry.value.runtimeType.toString(), entry.key);
    }
  });

  test('every journal event declares the pinned stable typeName, not its class name', () {
    for (final entry in sampleEvents().entries) {
      final event = entry.value;
      expect(event.typeName, goldenTypeNames[entry.key],
          reason: '${entry.key}.typeName is not the pinned identifier');
      expect(event.typeName, isNot(event.runtimeType.toString()),
          reason: '${entry.key} is stored under its class name');
      expect(event.toMap()['type'], goldenTypeNames[entry.key]);
    }
  });

  test('the registry holds exactly the pinned identifiers', () {
    expect(EventRegistry.getRegisteredTypes().toSet(),
        goldenTypeNames.values.toSet());
  });

  test('every journal event round-trips through the registry (map and CBOR)', () {
    for (final entry in sampleEvents().entries) {
      final event = entry.value;
      final fromMap = EventRegistry.fromMap(event.toMap());
      expect(fromMap.runtimeType, event.runtimeType, reason: entry.key);
      expect(fromMap.toMap(), event.toMap(), reason: entry.key);

      final fromCbor = CborSerializer.deserializeEvent(
          CborSerializer.serializeEvent(event), event.typeName);
      expect(fromCbor.runtimeType, event.runtimeType, reason: entry.key);
      expect(fromCbor.toMap(), event.toMap(), reason: entry.key);
    }
  });

  test('a row stored under the old class name still deserializes', () {
    for (final entry in sampleEvents().entries) {
      final stored = _StoredUnderLegacyName(entry.key, entry.value);
      final restored = CborSerializer.deserializeEvent(
          CborSerializer.serializeEvent(stored), entry.key);
      expect(restored.runtimeType, entry.value.runtimeType, reason: entry.key);
      expect(restored.eventId, entry.value.eventId, reason: entry.key);
      // Re-serializing writes the stable identifier.
      expect(restored.toMap()['type'], goldenTypeNames[entry.key]);
    }
  });

  group('Isar journal', () {
    late Directory dir;
    late IsarEventStore store;

    setUpAll(ensureIsarInitialized);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('lane3_event_names_');
      store = await IsarEventStore.create(
          directory: dir.path,
          name: 'names_${DateTime.now().microsecondsSinceEpoch}');
    });

    tearDown(() async {
      await store.close();
      await dir.delete(recursive: true);
    });

    test('an old journal (class-name rows) replays, and new rows use stable ids', () async {
      final samples = sampleEvents().entries.toList();
      for (var n = 0; n < samples.length; n++) {
        await store.persistEvent('legacy',
            _StoredUnderLegacyName(samples[n].key, samples[n].value), n);
      }
      final restored = await store.getEvents('legacy');
      expect(restored.map((e) => e.runtimeType).toList(),
          samples.map((e) => e.value.runtimeType).toList());

      final created = sampleEvents()['WalletCreatedEvent']!;
      await store.persistEvent('fresh', created, 0);
      final envelopes = await store.isar.eventEnvelopes
          .filter()
          .persistenceIdEqualTo('fresh')
          .findAll();
      expect(envelopes.single.eventType, 'wallet.created');
      expect((await store.getEvents('fresh')).single, isA<WalletCreatedEvent>());
    });
  });
}
