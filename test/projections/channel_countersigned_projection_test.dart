/// Bead libspiffy-z2px, the read-model half.
///
/// `PaymentCountersignedEvent` is what tells the client's channel that it
/// holds a settlement both parties signed, in place of the unsigned template
/// it recorded when it made the payment. The aggregate applies it to the
/// write model; this pins that the read model follows, because an event no
/// projection handles is a fact that is journaled and never reaches anyone
/// reading the channel (the reverse half of the libspiffy-1kd5 sweep).
library;

import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/projections/channel_projection.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:test/test.dart';

import '../actors/in_memory_event_store.dart';

const _channelId = 'chan-z2px-proj';
const _walletId = 'wallet-z2px';

void main() {
  late InMemoryWalletStorage storage;
  late ChannelProjection projection;

  setUp(() {
    storage = InMemoryWalletStorage();
    projection = ChannelProjection(
      projectionId: 'z2px-projection',
      eventStore: InMemoryEventStore(),
      storage: storage,
    );
  });

  /// The client's channel up to one payment: it holds the unsigned template.
  Future<void> upToOnePayment(String templateHex) async {
    await projection.handle(ChannelRequestedEvent(
      channelId: _channelId,
      walletId: _walletId,
      clientPeerId: 'client-peer',
      serverPeerId: 'server-peer',
      clientPubKeyHex: '02' * 33,
      clientAddressB58: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
      derivationIndex: 1,
      fundingAmountSats: BigInt.from(100000),
      lockTimeUnix: 1700000000,
      version: 1,
    ));
    await projection.handle(PaymentRecordedEvent(
      channelId: _channelId,
      amountSats: BigInt.from(30000),
      sequenceNumber: 1,
      paymentTxHex: templateHex,
      paymentTxId: 'aa' * 32,
      clientSignatureHex: '30' * 36,
      newClientBalanceSats: BigInt.from(70000),
      newServerBalanceSats: BigInt.from(30000),
      version: 2,
    ));
  }

  test('the countersigned settlement replaces the template in the read model',
      () async {
    await upToOnePayment('deadbeef');
    expect((await storage.getPaymentChannel(_channelId))!.latestPaymentTxHex,
        'deadbeef');

    final handled = await projection.handle(PaymentCountersignedEvent(
      channelId: _channelId,
      sequenceNumber: 1,
      serverSignatureHex: '31' * 36,
      fullySignedPaymentTxHex: 'cafebabe',
      fullySignedPaymentTxId: 'bb' * 32,
      version: 3,
    ));

    expect(handled, isTrue,
        reason: 'an event no projection handles never reaches a reader');
    final row = (await storage.getPaymentChannel(_channelId))!;
    expect(row.latestPaymentTxHex, 'cafebabe');
    expect(row.latestSequenceNumber, 1,
        reason: 'the countersignature settles nothing new: the payment it '
            'signs already moved the balances and the sequence');
    expect(row.clientBalanceSats, BigInt.from(70000));
    expect(row.serverBalanceSats, BigInt.from(30000));
  });

  /// Bead libspiffy-lfrv. The channel's record that its wallet write happened
  /// changes nothing in the channel read model — the wallet read model holds
  /// the transaction — but the projection must still ACKNOWLEDGE it. An event
  /// the projection returns false for is one the checkpoint never passes.
  test('the wallet-write record is acknowledged and changes no channel row',
      () async {
    await upToOnePayment('deadbeef');
    final before = (await storage.getPaymentChannel(_channelId))!;

    final handled = await projection.handle(ReturnLegRecordedInWalletEvent(
      channelId: _channelId,
      txId: 'cc' * 32,
      version: 3,
    ));

    expect(handled, isTrue);
    final after = (await storage.getPaymentChannel(_channelId))!;
    expect(after.state, before.state);
    expect(after.latestPaymentTxHex, before.latestPaymentTxHex);
    expect(after.settlementTxId, before.settlementTxId);
  });

  test('a countersignature for a channel the read model does not have is '
      'acknowledged, not thrown', () async {
    expect(
      await projection.handle(PaymentCountersignedEvent(
        channelId: 'chan-unknown',
        sequenceNumber: 1,
        serverSignatureHex: '31' * 36,
        fullySignedPaymentTxHex: 'cafebabe',
        fullySignedPaymentTxId: 'bb' * 32,
        version: 3,
      )),
      isTrue,
    );
  });
}
