/// libspiffy-pgt characterization: the shape of the actor replies that now
/// extend ActorResponse. These tests use no new API; they pass before and
/// after the change.
///
/// * [replies] were LocalMessages already: the payload is the reply itself
///   (so dactor's ask() completes with it), they carry success/error, and
///   keep the metadata they had.
/// * [bareReplies] implemented Message only. Told to another actor (with or
///   without a sender), the receiver gets the very same object, with the
///   correlation id and metadata it always reported.
/// * [failureReplies] can only report failure: the actor answering has no
///   success reply of its own for the request (bead libspiffy-kl4i). They
///   are [FailureResponse]s, so [success] is always false and [error] is
///   never null.
/// * [fixedOutcomeReplies] are replies whose name IS the outcome — a
///   broadcast succeeded, an SPV operation failed — so [success] is fixed
///   by the type rather than passed to the constructor (bead
///   libspiffy-97zj). They are ordinary [ActorResponse]s: unlike a
///   [FailureResponse] they answer a specific request with a specific
///   meaning, and a caller handles them by type.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dactor/dactor.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/header_sync_actor.dart'
    show BlockHeadersProcessedMessage, HeaderSyncStatusMessage;
import 'package:libspiffy/src/actors/import_actor.dart'
    show ImportCancelResponse, ImportProgressMessage;
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/actors/payment_messages.dart';
import 'package:libspiffy/src/actors/spv_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';

/// One reply, built for the failure path ([ok] false, error 'boom') or the
/// success path.
typedef ReplyFactory = LocalMessage Function(bool ok);

String? _err(bool ok) => ok ? null : 'boom';

final Map<String, ReplyFactory> replies = {
  'ChannelInitiatedResponse': (ok) => ChannelInitiatedResponse(
      channelId: 'c', clientPubKeyHex: '02', clientAddressB58: 'a',
      derivationIndex: 1, lockTimeUnix: 2, success: ok, error: _err(ok)),
  'ChannelAcceptedResponse': (ok) => ChannelAcceptedResponse(
      channelId: 'c', serverPubKeyHex: '03', serverAddressB58: 'b',
      derivationIndex: 1, success: ok, error: _err(ok)),
  'ServerAcceptanceRecordedResponse': (ok) =>
      ServerAcceptanceRecordedResponse(channelId: 'c', success: ok, error: _err(ok)),
  'RefundTransactionBuiltResponse': (ok) => RefundTransactionBuiltResponse(
      channelId: 'c', refundTxHex: '00', success: ok, error: _err(ok)),
  'RefundTransactionSignedResponse': (ok) => RefundTransactionSignedResponse(
      channelId: 'c', serverSignatureHex: '30', success: ok, error: _err(ok)),
  'RefundSignatureRecordedResponse': (ok) =>
      RefundSignatureRecordedResponse(channelId: 'c', success: ok, error: _err(ok)),
  'ChannelOpenedResponse': (ok) =>
      ChannelOpenedResponse(channelId: 'c', success: ok, error: _err(ok)),
  'PaymentRecordedResponse': (ok) => PaymentRecordedResponse(
      channelId: 'c', amountSats: BigInt.one, sequenceNumber: 1, paymentTxHex: '00',
      clientSignatureHex: '30', newClientBalanceSats: BigInt.two,
      newServerBalanceSats: BigInt.one, success: ok, error: _err(ok)),
  'PaymentAcknowledgedResponse': (ok) =>
      PaymentAcknowledgedResponse(channelId: 'c', success: ok, error: _err(ok)),
  'ChannelExpiredResponse': (ok) =>
      ChannelExpiredResponse(channelId: 'c', success: ok, error: _err(ok)),
  'ChannelClosedResponse': (ok) =>
      ChannelClosedResponse(channelId: 'c', success: ok, error: _err(ok)),
  'ChannelStateResponse': (ok) =>
      ChannelStateResponse(channelId: 'c', status: 'open', success: ok, error: _err(ok)),
  'FullChannelStateResponse': (ok) => FullChannelStateResponse(
      channelId: 'c', walletId: 'w', status: 'open', clientBalanceSats: BigInt.one,
      serverBalanceSats: BigInt.zero, latestSequenceNumber: 0,
      fundingAmountSats: BigInt.one, success: ok, error: _err(ok)),
  'SpecificHeaderResponseMessage': (ok) =>
      SpecificHeaderResponseMessage(blockHeight: 7, success: ok, error: _err(ok)),
  'AddressGeneratedResponse': (ok) => AddressGeneratedResponse(
      walletId: 'w', address: 'addr', derivationIndex: 3, success: ok, error: _err(ok)),
  'WatchAddressAddedResponse': (ok) =>
      WatchAddressAddedResponse(walletId: 'w', address: 'addr', success: ok, error: _err(ok)),
  'DeferredSpendCancelledResponse': (ok) =>
      DeferredSpendCancelledResponse(walletId: 'w', txid: 't', success: ok, error: _err(ok)),
  'DeferredPaymentNetworkResult': (ok) =>
      DeferredPaymentNetworkResult(walletId: 'w', txid: 't', success: ok, error: _err(ok)),
  'TransactionStatusMessage': (ok) => ok
      ? TransactionStatusMessage(txid: 't', status: 'confirmed', blockHeight: 9)
      : TransactionStatusMessage.failed(txid: 't', error: 'boom'),
  'FeeQuoteMessage': (ok) => ok
      ? FeeQuoteMessage(const {'mining': {'satoshis': 1, 'bytes': 1000}})
      : FeeQuoteMessage.failed('boom'),
  'FeeEstimateMessage': (ok) =>
      ok ? FeeEstimateMessage(BigInt.from(120)) : FeeEstimateMessage.failed('boom'),
  'WalletListMessage': (ok) =>
      WalletListMessage(const ['w'], success: ok, error: _err(ok)),
  'SPVValidationResult': (ok) =>
      SPVValidationResult(txid: 't', isValid: ok, validationError: _err(ok)),
  'SPVStatusMessage': (ok) => SPVStatusMessage(
      currentHeight: 1, networkHeight: 1, isSynced: true, headersCached: 0,
      merkleProofsStored: 0, lastHeaderUpdate: DateTime.utc(2020),
      connectedPeers: const [], isHealthy: true, success: ok, error: _err(ok)),
  'BlockHeadersProcessedMessage': (ok) => BlockHeadersProcessedMessage(
      processed: 2, failed: 0, currentHeight: 9, success: ok, error: _err(ok)),
  'HeaderSyncStatusMessage': (ok) => HeaderSyncStatusMessage(
      requestedHeight: 9, currentHeight: 9, isUpToDate: true, message: 'ok',
      success: ok, error: _err(ok)),
  'InvoiceDetailsResponse': (ok) => InvoiceDetailsResponse(
      invoiceId: 'i', amount: BigInt.one, status: InvoiceStatus.pending,
      createdAt: DateTime.utc(2020), found: ok, error: _err(ok)),
  'InvoiceStatusMessage': (ok) => InvoiceStatusMessage(
      invoiceId: 'i', status: InvoiceStatus.pending, success: ok, error: _err(ok)),
  'InvoicesListMessage': (ok) =>
      InvoicesListMessage(const [], success: ok, error: _err(ok)),
  'ImportCancelResponse': (ok) =>
      ImportCancelResponse(walletId: 'w', accepted: ok, error: _err(ok)),
  'ImportProgressMessage': (ok) => ImportProgressMessage(
      walletId: 'w', message: 'm', progress: 0.5, processedTransactions: 1,
      totalTransactions: 2, success: ok, error: _err(ok)),
  'ChannelCommandResult': (ok) => ok
      ? ChannelCommandResult(commandId: 'cmd', events: const [], success: true)
      : ChannelCommandResult.failed(commandId: 'cmd', error: 'boom'),
};

/// The replies whose name is the outcome: [success] is fixed by the type.
final Map<String, (ActorResponse Function(), bool)> fixedOutcomeReplies = {
  'BroadcastSuccessMessage': (() => BroadcastSuccessMessage('t', 'n'), true),
  'BroadcastFailedMessage': (() => BroadcastFailedMessage('t', 'boom'), false),
  'SPVErrorMessage': (
    () => SPVErrorMessage(operation: 'validate', error: 'boom'),
    false,
  ),
};

/// The replies that report only failure, with the correlation id and
/// metadata each reports.
final Map<String, (FailureResponse Function(), String, Map<String, dynamic>)>
    failureReplies = {
  'WalletManagerFailure': (
    () => WalletManagerFailure(
        error: 'boom', request: 'WalletCommandMessage', walletId: 'w'),
    'wallet-manager-failure-w',
    {'walletId': 'w', 'request': 'WalletCommandMessage'},
  ),
  'WalletManagerFailure (no wallet)': (
    () => WalletManagerFailure(error: 'boom', request: 'CreateWalletMessage'),
    'wallet-manager-failure--',
    {'request': 'CreateWalletMessage'},
  ),
  'WalletCommandFailed': (
    () => WalletCommandFailed(
        walletId: 'w', request: 'ReleaseUTXOCommand', error: 'boom'),
    'wallet-command-failed-w',
    {'walletId': 'w', 'request': 'ReleaseUTXOCommand'},
  ),
};

/// The replies that implemented Message only, with the correlation id and
/// metadata each reported.
final Map<String, (Message Function(bool ok), String, Map<String, dynamic> Function(bool ok))>
    bareReplies = {
  'WalletCreatedMessage': (
    (ok) => WalletCreatedMessage('w', 'root', ok, error: _err(ok)),
    'wallet-created-w',
    (ok) => {},
  ),
  'WalletCreatedResponse': (
    (ok) => WalletCreatedResponse(walletId: 'w', rootAddress: 'root', success: ok, error: _err(ok)),
    'wallet-created-response-w',
    (ok) => {'walletId': 'w'},
  ),
  'TransactionSignedResponse': (
    (ok) => TransactionSignedResponse(
        walletId: 'w', txid: 't', signedHex: '00', success: ok, error: _err(ok)),
    'transaction-signed-response-t',
    (ok) => {'walletId': 'w', 'txid': 't'},
  ),
  'MultisigTransactionSignedResponse': (
    (ok) => MultisigTransactionSignedResponse(walletId: 'w', txid: 't', originalTransactionId: 'o',
        signedHex: '00', signatureHex: '30', success: ok, error: _err(ok)),
    'multisig-signed-response-o',
    (ok) => {'walletId': 'w', 'txid': 't', 'originalTransactionId': 'o'},
  ),
  'InputSignedResponse': (
    (ok) => InputSignedResponse(walletId: 'w', commandId: 'c', inputIndex: 2,
        signatureHex: '30', publicKeyHex: '02', success: ok, error: _err(ok)),
    'input-signed-c',
    (ok) => {'walletId': 'w', 'commandId': 'c', 'inputIndex': 2},
  ),
  'FundingTransactionBuiltResponse': (
    (ok) => FundingTransactionBuiltResponse(walletId: 'w', correlationId: 'k', channelId: 'ch',
        fundingTxHex: '00', fundingTxId: 'f', fundingOutputIndex: 0, success: ok, error: _err(ok)),
    'funding-tx-response-k',
    (ok) => {'walletId': 'w', 'correlationId': 'k', 'channelId': 'ch'},
  ),
  'SplitUTXOsResponse': (
    (ok) => SplitUTXOsResponse(walletId: 'w', success: ok, error: _err(ok)),
    'split-utxos-response-w',
    (ok) => {'walletId': 'w'},
  ),
  'UTXOReservedResponse': (
    (ok) => UTXOReservedResponse(
        walletId: 'w', utxoKey: 't:0', reservedByTxId: 'r', success: ok, error: _err(ok)),
    'utxo-reserved-response-t:0',
    (ok) => {'walletId': 'w', 'utxoKey': 't:0', 'reservedByTxId': 'r'},
  ),
  'UTXOReceivedResponse': (
    (ok) => UTXOReceivedResponse(walletId: 'w', txid: 't', vout: 1, success: ok, error: _err(ok)),
    'utxo-received-response-t:1',
    (ok) => {'walletId': 'w', 'txid': 't', 'vout': 1},
  ),
  'TransactionRecordedResponse': (
    (ok) => TransactionRecordedResponse(walletId: 'w', txid: 't', success: ok, error: _err(ok)),
    'transaction-recorded-response-t',
    (ok) => {'walletId': 'w', 'txid': 't'},
  ),
  'MerkleProofMessage': (
    (ok) => MerkleProofMessage(txid: 't', success: ok, error: _err(ok)),
    'merkle-proof-t',
    (ok) => {'txid': 't', 'success': ok},
  ),
  'InvoiceCreatedMessage': (
    (ok) => InvoiceCreatedMessage(invoiceId: 'i', walletId: 'w', addresses: const ['a'],
        amount: BigInt.one, createdAt: DateTime.utc(2026), success: ok, error: _err(ok)),
    'invoice-created-i',
    (ok) => {'invoiceId': 'i', 'walletId': 'w'},
  ),
  'BEEFPaymentResponse': (
    (ok) => ok
        ? BEEFPaymentResponse(invoiceId: 'i', beefBytes: Uint8List(1), txid: 't',
            amountPaid: BigInt.one, changeAmount: BigInt.zero, ancestorCount: 1, success: true)
        : BEEFPaymentResponse.error(invoiceId: 'i', error: 'boom'),
    'beef-payment-response-i',
    (ok) => {'invoiceId': 'i', 'success': ok, 'txid': ok ? 't' : '', 'ancestorCount': ok ? 1 : 0},
  ),
  'ProvisionFundingResponse': (
    (ok) => ok
        ? ProvisionFundingResponse(walletId: 'w', transactionCount: 1, earmarkCount: 1, success: true)
        : ProvisionFundingResponse.error(walletId: 'w', error: 'boom'),
    'provision-funding-response-w',
    (ok) => {'walletId': 'w', 'success': ok},
  ),
};

/// Metadata each reply put on the LocalMessage before the change.
final Map<String, Map<String, dynamic> Function(bool ok)> expectedMetadata = {
  'AddressGeneratedResponse': (ok) =>
      {'walletId': 'w', 'address': 'addr', 'derivationIndex': 3, 'success': ok},
  'WatchAddressAddedResponse': (ok) => {'walletId': 'w', 'address': 'addr', 'success': ok},
  'DeferredSpendCancelledResponse': (ok) => {'walletId': 'w', 'txid': 't', 'success': ok},
  'DeferredPaymentNetworkResult': (ok) => {'walletId': 'w', 'txid': 't', 'success': ok},
};

/// Answers every request with the reply built by [reply].
class _Replier extends Actor {
  LocalMessage Function() reply;
  _Replier(this.reply);

  @override
  // ignore: invalid_use_of_internal_member
  Future<void> onMessage(dynamic message) async => context.sender?.tell(reply());
}

/// Forwards every message it receives to [received].
class _Probe extends Actor {
  final received = StreamController<dynamic>();

  @override
  Future<void> onMessage(dynamic message) async => received.add(message);
}

class _Ping implements Message {
  @override
  String get correlationId => 'ping';
  @override
  Map<String, dynamic> get metadata => const {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

void main() {
  late ActorSystem system;
  setUpAll(() => system = LocalActorSystem());
  tearDownAll(() => system.shutdown());

  var actorCount = 0;

  for (final entry in replies.entries) {
    final name = entry.key;
    group(name, () {
      for (final ok in [true, false]) {
        final path = ok ? 'success' : 'failure';

        test('$path reply is its own payload and carries success/error', () {
          final reply = entry.value(ok) as dynamic;
          expect(reply, isA<LocalMessage>());
          expect(identical(reply.payload, reply), isTrue);
          expect(reply.success, ok);
          expect(reply.error, _err(ok));
          expect(reply.sender, isNull);
          expect(reply.replyTo, isNull);
          final metadata = expectedMetadata[name];
          if (metadata != null) expect(reply.metadata, metadata(ok));
          if (name == 'SpecificHeaderResponseMessage') {
            expect(reply.correlationId, startsWith('resp_header_'));
            expect(reply.metadata, isEmpty);
          }
        });

        test('$path reply completes an ask with the same object', () async {
          final built = entry.value(ok);
          final ref = await system.spawn('replier-${actorCount++}', () => _Replier(() => built));
          final answer = await ref.ask<Object>(_Ping(), const Duration(seconds: 5));
          expect(identical(answer, built), isTrue);
          expect(answer.runtimeType.toString(), name);
        });
      }
    });
  }

  for (final entry in fixedOutcomeReplies.entries) {
    final name = entry.key;
    final (build, expected) = entry.value;
    test('$name reports success=$expected, fixed by its type', () {
      final reply = build();
      expect(reply.success, expected);
      expect(reply.error, expected ? isNull : isNotNull);
      expect(identical(reply.payload, reply), isTrue);
    });
  }

  for (final entry in failureReplies.entries) {
    final name = entry.key;
    final (build, correlationId, metadata) = entry.value;
    group(name, () {
      test('reports failure, its correlation id and metadata', () {
        final reply = build();
        expect(reply.success, isFalse);
        expect(reply.error, 'boom');
        expect(reply.request, isNotEmpty);
        expect(reply.correlationId, correlationId);
        expect(reply.metadata, metadata);
        expect(reply.replyTo, isNull);
        expect(identical(reply.payload, reply), isTrue);
      });

      test('completes an ask with the same object', () async {
        final built = build();
        final ref = await system.spawn('replier-${actorCount++}', () => _Replier(() => built));
        final answer = await ref.ask<Object>(_Ping(), const Duration(seconds: 5));
        expect(identical(answer, built), isTrue);
      });
    });
  }

  for (final entry in bareReplies.entries) {
    final name = entry.key;
    final (build, correlationId, metadata) = entry.value;
    group(name, () {
      for (final ok in [true, false]) {
        final path = ok ? 'success' : 'failure';

        test('$path reply carries success/error, its correlation id and metadata', () {
          final reply = build(ok) as dynamic;
          expect(reply.success, ok);
          expect(reply.error, _err(ok));
          expect(reply.correlationId, correlationId);
          expect(reply.metadata, metadata(ok));
          expect(reply.replyTo, isNull);
        });

        for (final withSender in [false, true]) {
          test('$path reply told ${withSender ? 'with' : 'without'} a sender arrives as the same object',
              () async {
            final built = build(ok);
            final probe = _Probe();
            final probeRef = await system.spawn('probe-${actorCount++}', () => probe);
            final other = await system.spawn('other-${actorCount++}', () => _Probe());
            probeRef.tell(built, sender: withSender ? other : null);
            final received = await probe.received.stream.first.timeout(const Duration(seconds: 5));
            expect(identical(received, built), isTrue);
          });
        }
      }
    });
  }
}
