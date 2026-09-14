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

/// A channel with every field set to a non-default value, so a backend or a
/// projection step that drops any field is visible.
PaymentChannel fullFieldChannel({
  required String channelId,
  required String walletId,
}) =>
    PaymentChannel(
      channelId: channelId,
      walletId: walletId,
      role: PaymentChannelRole.server,
      clientPeerId: contractClientPeerId,
      serverPeerId: contractServerPeerId,
      clientPubKeyHex: contractClientPubKeyHex,
      serverPubKeyHex: contractServerPubKeyHex,
      clientAddressB58: contractClientAddress,
      serverAddressB58: contractServerAddress,
      fundingAmountSats: contractFundingAmount,
      lockTimeUnix: contractLockTimeUnix,
      state: PaymentChannelState.open,
      clientBalanceSats: contractClientBalanceAfterPayment,
      serverBalanceSats: contractServerBalanceAfterPayment,
      fundingTxId: contractFundingTxId,
      fundingTxHex: contractFundingTxHex,
      fundingOutputIndex: contractFundingOutputIndex,
      refundTxHex: '0100000001${'aa' * 60}',
      refundClientSigHex: '3045${'12' * 69}',
      refundServerSigHex: '3045${'34' * 69}',
      latestSequenceNumber: 3,
      latestPaymentTxHex: contractPaymentTxHex,
      latestPaymentTxId: contractPaymentTxId,
      settlementTxId: contractSettlementTxId,
      fundingAncestorTxids: contractAncestorTxids,
      hasFundingMerkleProof: true,
      context: contractContext,
      createdAt: contractCreatedAt,
      closedAt: contractClosedAt,
      errorMessage: 'contract error message',
    );

/// Asserts [actual] carries exactly the field values of [expected].
void expectSameChannelFields(PaymentChannel actual, PaymentChannel expected,
    {String step = ''}) {
  String r(String field) => '$field must survive $step';
  expect(actual.channelId, equals(expected.channelId), reason: r('channelId'));
  expect(actual.walletId, equals(expected.walletId), reason: r('walletId'));
  expect(actual.role, equals(expected.role), reason: r('role'));
  expect(actual.clientPeerId, equals(expected.clientPeerId),
      reason: r('clientPeerId'));
  expect(actual.serverPeerId, equals(expected.serverPeerId),
      reason: r('serverPeerId'));
  expect(actual.clientPubKeyHex, equals(expected.clientPubKeyHex),
      reason: r('clientPubKeyHex'));
  expect(actual.serverPubKeyHex, equals(expected.serverPubKeyHex),
      reason: r('serverPubKeyHex'));
  expect(actual.clientAddressB58, equals(expected.clientAddressB58),
      reason: r('clientAddressB58'));
  expect(actual.serverAddressB58, equals(expected.serverAddressB58),
      reason: r('serverAddressB58'));
  expect(actual.fundingAmountSats, equals(expected.fundingAmountSats),
      reason: r('fundingAmountSats'));
  expect(actual.lockTimeUnix, equals(expected.lockTimeUnix),
      reason: r('lockTimeUnix'));
  expect(actual.state, equals(expected.state), reason: r('state'));
  expect(actual.clientBalanceSats, equals(expected.clientBalanceSats),
      reason: r('clientBalanceSats'));
  expect(actual.serverBalanceSats, equals(expected.serverBalanceSats),
      reason: r('serverBalanceSats'));
  expect(actual.fundingTxId, equals(expected.fundingTxId),
      reason: r('fundingTxId'));
  expect(actual.fundingTxHex, equals(expected.fundingTxHex),
      reason: r('fundingTxHex'));
  expect(actual.fundingOutputIndex, equals(expected.fundingOutputIndex),
      reason: r('fundingOutputIndex'));
  expect(actual.refundTxHex, equals(expected.refundTxHex),
      reason: r('refundTxHex'));
  expect(actual.refundClientSigHex, equals(expected.refundClientSigHex),
      reason: r('refundClientSigHex'));
  expect(actual.refundServerSigHex, equals(expected.refundServerSigHex),
      reason: r('refundServerSigHex'));
  expect(actual.latestSequenceNumber, equals(expected.latestSequenceNumber),
      reason: r('latestSequenceNumber'));
  expect(actual.latestPaymentTxHex, equals(expected.latestPaymentTxHex),
      reason: r('latestPaymentTxHex'));
  expect(actual.latestPaymentTxId, equals(expected.latestPaymentTxId),
      reason: r('latestPaymentTxId'));
  expect(actual.settlementTxId, equals(expected.settlementTxId),
      reason: r('settlementTxId'));
  expect(actual.fundingAncestorTxids, equals(expected.fundingAncestorTxids),
      reason: r('fundingAncestorTxids'));
  expect(actual.hasFundingMerkleProof, equals(expected.hasFundingMerkleProof),
      reason: r('hasFundingMerkleProof'));
  expect(actual.context, equals(expected.context), reason: r('context'));
  expect(actual.createdAt.toUtc(), equals(expected.createdAt.toUtc()),
      reason: r('createdAt'));
  expect(actual.closedAt?.toUtc(), equals(expected.closedAt?.toUtc()),
      reason: r('closedAt'));
  expect(actual.errorMessage, equals(expected.errorMessage),
      reason: r('errorMessage'));
}

/// Data-retention contract for the channel read model (beads 32t, y3b):
/// every field of a stored channel survives the storage round trip, and each
/// projection step and storage update changes only the fields it is about.
/// Funding, refund and payment transaction data in particular must never be
/// dropped by a later event.
Future<void> runChannelFullFieldRetentionContract(
  ReadModelStorage storage, {
  required String channelId,
  required String walletId,
}) async {
  final projection = ChannelProjection(
    projectionId: 'channel-retention-$channelId',
    eventStore: InMemoryEventStore(),
    storage: storage,
  );
  var expected = fullFieldChannel(channelId: channelId, walletId: walletId);

  Future<void> check(String step) async {
    final stored = await storage.getPaymentChannel(channelId);
    expect(stored, isNotNull, reason: 'channel must be stored after $step');
    expectSameChannelFields(stored!, expected, step: step);
    final listed = (await storage.getPaymentChannelsForWallet(walletId))
        .singleWhere((c) => c.channelId == channelId);
    expectSameChannelFields(listed, expected, step: '$step (wallet listing)');
  }

  await storage.storePaymentChannel(expected);
  await check('storePaymentChannel');

  // Re-storing an unchanged read-back channel loses nothing.
  await storage.storePaymentChannel((await storage.getPaymentChannel(channelId))!);
  await check('re-storing the read-back channel');

  await projection.handle(RefundCountersignedEvent(
    channelId: channelId,
    serverSignatureHex: '3045${'56' * 69}',
  ));
  expected = expected.copyWith(
    refundServerSigHex: '3045${'56' * 69}',
    state: PaymentChannelState.opening,
  );
  await check('RefundCountersignedEvent');

  await projection.handle(PaymentAcknowledgedEvent(
    channelId: channelId,
    amountSats: BigInt.from(500),
    sequenceNumber: 4,
    newClientBalanceSats: BigInt.from(97000),
    newServerBalanceSats: BigInt.from(3000),
    fullySignedPaymentTxHex: '0100000001${'bb' * 60}',
    serverSignatureHex: '3045${'78' * 69}',
  ));
  expected = expected.copyWith(
    clientBalanceSats: BigInt.from(97000),
    serverBalanceSats: BigInt.from(3000),
    latestSequenceNumber: 4,
    latestPaymentTxHex: '0100000001${'bb' * 60}',
  );
  await check('PaymentAcknowledgedEvent');

  await projection.handle(ChannelClosingEvent(
    channelId: channelId,
    initiator: 'server',
    clientBalanceSats: BigInt.from(97000),
    serverBalanceSats: BigInt.from(3000),
  ));
  expected = expected.copyWith(state: PaymentChannelState.closing);
  await check('ChannelClosingEvent (updatePaymentChannelState)');

  await storage.updatePaymentChannelBalance(
      channelId, BigInt.from(96000), BigInt.from(4000));
  expected = expected.copyWith(
    clientBalanceSats: BigInt.from(96000),
    serverBalanceSats: BigInt.from(4000),
  );
  await check('updatePaymentChannelBalance');

  final expiredAt = DateTime.utc(2026, 9, 15, 8, 0, 0);
  await projection.handle(ChannelExpiredEvent(
    channelId: channelId,
    observedBy: 'server',
    timestamp: expiredAt,
  ));
  expected = expected.copyWith(
    state: PaymentChannelState.expired,
    closedAt: expiredAt,
  );
  await check('ChannelExpiredEvent without a txid');
}

/// Audit bead libspiffy-y3b: a requested channel has no server key yet. The
/// projection used to store `''` for it, which every backend then returned
/// as a "key". The read model must return `null` until the server accepts,
/// then the key.
Future<void> runRequestedChannelServerKeyContract(
  ReadModelStorage storage, {
  required String channelId,
  required String walletId,
}) async {
  final projection = ChannelProjection(
    projectionId: 'channel-server-key-$channelId',
    eventStore: InMemoryEventStore(),
    storage: storage,
  );

  await projection.handle(ChannelRequestedEvent(
    channelId: channelId,
    walletId: walletId,
    clientPeerId: contractClientPeerId,
    serverPeerId: contractServerPeerId,
    clientPubKeyHex: contractClientPubKeyHex,
    clientAddressB58: contractClientAddress,
    derivationIndex: 0,
    fundingAmountSats: contractFundingAmount,
    lockTimeUnix: contractLockTimeUnix,
    timestamp: contractCreatedAt,
  ));

  final requested = await storage.getPaymentChannel(channelId);
  expect(requested, isNotNull);
  expect(requested!.serverPubKeyHex, isNull,
      reason: 'a requested channel has no server key');
  expect(requested.serverAddressB58, isNull);

  final listed = (await storage.getPaymentChannelsForWallet(walletId))
      .singleWhere((c) => c.channelId == channelId);
  expect(listed.serverPubKeyHex, isNull);

  await projection.handle(ServerAcceptanceRecordedEvent(
    channelId: channelId,
    serverPubKeyHex: contractServerPubKeyHex,
    serverAddressB58: contractServerAddress,
  ));

  final accepted = await storage.getPaymentChannel(channelId);
  expect(accepted!.serverPubKeyHex, equals(contractServerPubKeyHex));
  expect(accepted.serverAddressB58, equals(contractServerAddress));
}
