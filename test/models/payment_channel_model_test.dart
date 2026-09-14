/// Beads libspiffy-32t (immutable PaymentChannel) and libspiffy-y3b
/// (nullable server key): copyWith and JSON must carry every field, since
/// the projection now derives each updated channel with copyWith; a field
/// copyWith dropped would be erased from the read model on the next event.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/models/payment_channel.dart';

import '../storage/channel_read_model_contract.dart';

void main() {
  final base = fullFieldChannel(channelId: 'model-channel', walletId: 'w');

  test('the full-field fixture sets every field toJson serializes', () {
    // Every optional field is present only when non-null, so a missing key
    // means the fixture would not detect a dropped field.
    expect(base.toJson().keys, hasLength(30));
  });

  test('copyWith() without arguments keeps every field', () {
    final copy = base.copyWith();
    expectSameChannelFields(copy, base, step: 'copyWith()');
    expect(copy.toJson(), equals(base.toJson()));
  });

  test('copyWith of one field changes exactly that field', () {
    final overrides = <String, PaymentChannel Function(PaymentChannel)>{
      'channelId': (c) => c.copyWith(channelId: 'other'),
      'walletId': (c) => c.copyWith(walletId: 'other'),
      'role': (c) => c.copyWith(role: PaymentChannelRole.client),
      'clientPeerId': (c) => c.copyWith(clientPeerId: 'other'),
      'serverPeerId': (c) => c.copyWith(serverPeerId: 'other'),
      'clientPubKeyHex': (c) => c.copyWith(clientPubKeyHex: '02${'ee' * 32}'),
      'serverPubKeyHex': (c) => c.copyWith(serverPubKeyHex: '02${'ff' * 32}'),
      'clientAddressB58': (c) => c.copyWith(clientAddressB58: 'other'),
      'serverAddressB58': (c) => c.copyWith(serverAddressB58: 'other'),
      'fundingAmountSats': (c) => c.copyWith(fundingAmountSats: BigInt.one),
      'lockTimeUnix': (c) => c.copyWith(lockTimeUnix: 1900000000),
      'state': (c) => c.copyWith(state: PaymentChannelState.failed),
      'clientBalanceSats': (c) => c.copyWith(clientBalanceSats: BigInt.one),
      'serverBalanceSats': (c) => c.copyWith(serverBalanceSats: BigInt.one),
      'fundingTxId': (c) => c.copyWith(fundingTxId: 'other'),
      'fundingTxHex': (c) => c.copyWith(fundingTxHex: 'other'),
      'fundingOutputIndex': (c) => c.copyWith(fundingOutputIndex: 7),
      'refundTxHex': (c) => c.copyWith(refundTxHex: 'other'),
      'refundClientSigHex': (c) => c.copyWith(refundClientSigHex: 'other'),
      'refundServerSigHex': (c) => c.copyWith(refundServerSigHex: 'other'),
      'latestSequenceNumber': (c) => c.copyWith(latestSequenceNumber: 99),
      'latestPaymentTxHex': (c) => c.copyWith(latestPaymentTxHex: 'other'),
      'latestPaymentTxId': (c) => c.copyWith(latestPaymentTxId: 'other'),
      'settlementTxId': (c) => c.copyWith(settlementTxId: 'other'),
      'fundingAncestorTxids': (c) =>
          c.copyWith(fundingAncestorTxids: ['cc' * 32]),
      'hasFundingMerkleProof': (c) => c.copyWith(hasFundingMerkleProof: false),
      'context': (c) => c.copyWith(context: 'other'),
      'createdAt': (c) => c.copyWith(createdAt: DateTime.utc(2020)),
      'closedAt': (c) => c.copyWith(closedAt: DateTime.utc(2020)),
      'errorMessage': (c) => c.copyWith(errorMessage: 'other'),
    };
    expect(overrides.keys.toSet(), equals(base.toJson().keys.toSet()),
        reason: 'every serialized field must have a copyWith case');

    final before = base.toJson();
    for (final entry in overrides.entries) {
      final after = entry.value(base).toJson();
      final changed = after.keys
          .where((k) => '${after[k]}' != '${before[k]}')
          .toSet();
      expect(changed, equals({entry.key}),
          reason: 'copyWith(${entry.key}:) must change only ${entry.key}');
    }
  });

  test('fromJson(toJson()) keeps every field', () {
    expectSameChannelFields(
        PaymentChannel.fromJson(base.toJson()), base, step: 'JSON round trip');
  });

  group('y3b: serverPubKeyHex', () {
    PaymentChannel requested({String? serverPubKeyHex}) => PaymentChannel(
          channelId: 'c',
          walletId: 'w',
          role: PaymentChannelRole.client,
          clientPeerId: 'cp',
          serverPeerId: 'sp',
          clientPubKeyHex: contractClientPubKeyHex,
          serverPubKeyHex: serverPubKeyHex,
          fundingAmountSats: BigInt.from(1000),
          lockTimeUnix: contractLockTimeUnix,
        );

    test('is null for a channel without a server key, and survives JSON', () {
      final channel = requested();
      expect(channel.serverPubKeyHex, isNull);
      expect(channel.toJson().containsKey('serverPubKeyHex'), isFalse);
      expect(PaymentChannel.fromJson(channel.toJson()).serverPubKeyHex, isNull);
      expect(channel.counterpartyPubKeyHex, isNull);
    });

    test("a legacy '' reads as null (constructor and JSON)", () {
      expect(requested(serverPubKeyHex: '').serverPubKeyHex, isNull);
      final json = requested().toJson()..['serverPubKeyHex'] = '';
      expect(PaymentChannel.fromJson(json).serverPubKeyHex, isNull);
    });
  });
}
