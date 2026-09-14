/// Shared payment-channel read-model contract for the three
/// [ReadModelStorage] backends (audit 2026-09-14 S-01).
///
/// Drives [ChannelProjection] exactly as production does — the projection is
/// the only writer of the channel read model — through
/// request -> accept -> open -> payment -> closing -> settle, reading the
/// channel back after every step. Postgres, Isar and in-memory must all
/// return a fully populated domain [PaymentChannel].
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/models/payment_channel.dart';
import 'package:libspiffy/src/projections/channel_projection.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import '../actors/in_memory_event_store.dart';

const contractClientPeerId = 'client-peer';
const contractServerPeerId = 'server-peer';
final contractClientPubKeyHex = '02${'ab' * 32}';
final contractServerPubKeyHex = '03${'cd' * 32}';
const contractClientAddress = 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt';
const contractServerAddress = 'n2eMqTT929pb1RDNuqEnxdaLau1rxy3efi';
final contractFundingTxId = 'f1' * 32;
final contractFundingTxHex = '0100000001${'ff' * 40}';
const contractFundingOutputIndex = 1;
final contractAncestorTxids = ['a1' * 32, 'b2' * 32];
final contractPaymentTxHex = '0200000001${'ee' * 40}';
final contractPaymentTxId = 'c3' * 32;
final contractSettlementTxId = 'd4' * 32;
final contractFundingAmount = BigInt.from(100000);
final contractClientBalanceAfterPayment = BigInt.from(97500);
final contractServerBalanceAfterPayment = BigInt.from(2500);
const contractLockTimeUnix = 1800000000;
const contractContext = 'contract:lifecycle';
final contractCreatedAt = DateTime.utc(2026, 9, 14, 12, 0, 0);
final contractClosedAt = DateTime.utc(2026, 9, 14, 13, 30, 0);

/// Runs the full lifecycle against [storage] and returns the settled channel.
///
/// Asserts intermediate state after acceptance (server data recorded, no
/// funding data yet) and after the closing event (the
/// `updatePaymentChannelState` path), then every field of the settled
/// channel and the wallet listing.
Future<PaymentChannel> runChannelLifecycleContract(
  ReadModelStorage storage, {
  required String channelId,
  required String walletId,
}) async {
  final projection = ChannelProjection(
    projectionId: 'channel-contract-$channelId',
    eventStore: InMemoryEventStore(),
    storage: storage,
  );

  Future<void> apply(ChannelEvent event) async {
    final handled = await projection.handle(event);
    expect(handled, isTrue, reason: '${event.runtimeType} must be handled');
  }

  Future<PaymentChannel> read() async {
    final dynamic raw = await storage.getPaymentChannel(channelId);
    expect(raw, isNotNull, reason: 'channel $channelId must be stored');
    expect(raw, isA<PaymentChannel>(),
        reason: 'getPaymentChannel must return the domain PaymentChannel, '
            'got ${raw.runtimeType}');
    return raw as PaymentChannel;
  }

  // 1. Client requests the channel.
  await apply(ChannelRequestedEvent(
    channelId: channelId,
    walletId: walletId,
    clientPeerId: contractClientPeerId,
    serverPeerId: contractServerPeerId,
    clientPubKeyHex: contractClientPubKeyHex,
    clientAddressB58: contractClientAddress,
    derivationIndex: 0,
    fundingAmountSats: contractFundingAmount,
    lockTimeUnix: contractLockTimeUnix,
    context: contractContext,
    timestamp: contractCreatedAt,
  ));

  var channel = await read();
  expect(channel.state, equals(PaymentChannelState.opening));
  expect(channel.role, equals(PaymentChannelRole.client));
  expect(channel.fundingTxId, isNull,
      reason: 'no funding transaction exists at request time');

  // 2. Server accepts: server key and address are recorded on the
  //    existing (client-side) row.
  await apply(ChannelAcceptedEvent(
    channelId: channelId,
    walletId: walletId,
    clientPeerId: contractClientPeerId,
    clientPubKeyHex: contractClientPubKeyHex,
    clientAddressB58: contractClientAddress,
    serverPubKeyHex: contractServerPubKeyHex,
    serverAddressB58: contractServerAddress,
    derivationIndex: 0,
    fundingAmountSats: contractFundingAmount,
    lockTimeUnix: contractLockTimeUnix,
    context: contractContext,
  ));

  channel = await read();
  expect(channel.serverPubKeyHex, equals(contractServerPubKeyHex),
      reason: 'acceptance must update server_pub_key_hex');
  expect(channel.serverAddressB58, equals(contractServerAddress),
      reason: 'acceptance must update server_address_b58');
  expect(channel.state, equals(PaymentChannelState.opening));

  // 3. Funding broadcast: channel opens.
  await apply(ChannelOpenedEvent(
    channelId: channelId,
    fundingTxId: contractFundingTxId,
    fundingOutputIndex: contractFundingOutputIndex,
    fundingTxHex: contractFundingTxHex,
    fundingAncestorTxids: contractAncestorTxids,
    initialClientBalanceSats: contractFundingAmount,
    initialServerBalanceSats: BigInt.zero,
  ));

  channel = await read();
  expect(channel.state, equals(PaymentChannelState.open));
  expect(channel.fundingTxId, equals(contractFundingTxId),
      reason: 'opening must update funding_tx_id');

  // 4. One off-chain payment.
  await apply(PaymentRecordedEvent(
    channelId: channelId,
    amountSats: contractServerBalanceAfterPayment,
    newClientBalanceSats: contractClientBalanceAfterPayment,
    newServerBalanceSats: contractServerBalanceAfterPayment,
    sequenceNumber: 1,
    paymentTxHex: contractPaymentTxHex,
    paymentTxId: contractPaymentTxId,
    clientSignatureHex: '3044${'11' * 68}',
  ));

  // 5. Cooperative close begins (state-only update path).
  await apply(ChannelClosingEvent(
    channelId: channelId,
    initiator: 'client',
    clientBalanceSats: contractClientBalanceAfterPayment,
    serverBalanceSats: contractServerBalanceAfterPayment,
  ));

  channel = await read();
  expect(channel.state, equals(PaymentChannelState.closing),
      reason: 'updatePaymentChannelState must set the closing state');

  // 6. Settlement broadcast.
  await apply(ChannelClosedEvent(
    channelId: channelId,
    settlementTxId: contractSettlementTxId,
    finalClientBalanceSats: contractClientBalanceAfterPayment,
    finalServerBalanceSats: contractServerBalanceAfterPayment,
    timestamp: contractClosedAt,
  ));

  final settled = await read();
  expectSettledChannel(settled, channelId: channelId, walletId: walletId);

  final dynamic listed = await storage.getPaymentChannelsForWallet(walletId);
  expect(listed, isA<List>());
  final match = (listed as List).where((c) => c.channelId == channelId);
  expect(match, hasLength(1),
      reason: 'getPaymentChannelsForWallet must list the channel once');
  expect(match.single, isA<PaymentChannel>());
  expect((match.single as PaymentChannel).state,
      equals(PaymentChannelState.closed));

  return settled;
}

/// Asserts every persisted field of a channel settled by
/// [runChannelLifecycleContract].
void expectSettledChannel(
  PaymentChannel channel, {
  required String channelId,
  required String walletId,
}) {
  expect(channel.channelId, equals(channelId));
  expect(channel.walletId, equals(walletId));
  expect(channel.role, equals(PaymentChannelRole.client));
  expect(channel.clientPeerId, equals(contractClientPeerId));
  expect(channel.serverPeerId, equals(contractServerPeerId));
  expect(channel.clientPubKeyHex, equals(contractClientPubKeyHex));
  expect(channel.serverPubKeyHex, equals(contractServerPubKeyHex));
  expect(channel.clientAddressB58, equals(contractClientAddress));
  expect(channel.serverAddressB58, equals(contractServerAddress));
  expect(channel.fundingAmountSats, equals(contractFundingAmount));
  expect(channel.lockTimeUnix, equals(contractLockTimeUnix));
  expect(channel.state, equals(PaymentChannelState.closed));
  expect(channel.clientBalanceSats, equals(contractClientBalanceAfterPayment));
  expect(channel.serverBalanceSats, equals(contractServerBalanceAfterPayment));
  expect(channel.fundingTxId, equals(contractFundingTxId));
  expect(channel.fundingTxHex, equals(contractFundingTxHex));
  expect(channel.fundingOutputIndex, equals(contractFundingOutputIndex));
  expect(channel.fundingAncestorTxids, equals(contractAncestorTxids));
  expect(channel.latestSequenceNumber, equals(1));
  expect(channel.latestPaymentTxHex, equals(contractPaymentTxHex));
  expect(channel.latestPaymentTxId, equals(contractPaymentTxId),
      reason: 'latest_payment_tx_id must be persisted');
  expect(channel.settlementTxId, equals(contractSettlementTxId),
      reason: 'settlement_tx_id must be persisted');
  expect(channel.context, equals(contractContext));
  expect(channel.createdAt.toUtc(), equals(contractCreatedAt));
  expect(channel.closedAt, isNotNull);
  expect(channel.closedAt!.toUtc(), equals(contractClosedAt));
  expect(channel.errorMessage, isNull);
  expect(channel.hasFundingMerkleProof, isFalse);
}
