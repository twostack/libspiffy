/// Payment channel transactions and journals for tests (libspiffy-b83,
/// libspiffy-9f7): the channel aggregate checks funding outputs, refund
/// transactions and signatures, so tests hand it real ones.
library;

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';

import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/services/payment_channel_builder.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/models/fee_rate.dart';

const channelFixtureMnemonic = 'abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon about';

/// A payment's transaction as a client builds it: spends
/// [fundingTxId]:[fundingOutputIndex] and pays the server [server] and the
/// client [client] less [fee] satoshis at their P2PKH addresses (an amount
/// of zero or less gets no output). The server countersigns a payment only
/// when its transaction pays the balances it proposes (bead libspiffy-zj20)
/// and pays ARC's policy rate on its signed size (bead libspiffy-zs4l); the
/// default fee covers the tests' 100 sat/1000 bytes several times over.
String channelPaymentTxHex({
  required String fundingTxId,
  int fundingOutputIndex = 0,
  required String serverAddress,
  required String clientAddress,
  required BigInt server,
  required BigInt client,
  BigInt? fee,
}) {
  client -= fee ?? BigInt.from(100);
  dartsv.SVScript p2pkh(String address) =>
      dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey();
  final tx = dartsv.Transaction()
    ..version = 1
    ..nLockTime = 0;
  tx.inputs.add(dartsv.TransactionInput(fundingTxId, fundingOutputIndex, 1));
  if (server > BigInt.zero) tx.outputs.add(dartsv.TransactionOutput(server, p2pkh(serverAddress)));
  if (client > BigInt.zero) tx.outputs.add(dartsv.TransactionOutput(client, p2pkh(clientAddress)));
  return tx.serialize();
}

/// A funding transaction whose output [outputIndex] locks [amountSats] in
/// the 2-of-2 of the two keys, with a change output. Its input is unsigned:
/// the channel code checks the funding output, not how it was paid for.
({String hex, String txid}) channelFundingTx({
  required String clientPubKeyHex,
  required String serverPubKeyHex,
  required BigInt amountSats,
  int outputIndex = 0,
  String changeAddressB58 = 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
}) {
  final multisig = dartsv.P2MSLockBuilder([
    dartsv.SVPublicKey.fromHex(clientPubKeyHex),
    dartsv.SVPublicKey.fromHex(serverPubKeyHex),
  ], 2, sorting: true)
      .getScriptPubkey();
  final change = dartsv.TransactionOutput(
      BigInt.from(50000),
      dartsv.P2PKHLockBuilder.fromAddress(
              dartsv.Address.fromBase58(changeAddressB58))
          .getScriptPubkey());
  final tx = dartsv.Transaction()..version = 1;
  tx.inputs.add(dartsv.TransactionInput(
      'c0' * 32, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
  final outputs = [change];
  outputs.insert(outputIndex, dartsv.TransactionOutput(amountSats, multisig));
  tx.outputs.addAll(outputs);
  return (hex: tx.serialize(), txid: tx.id);
}

/// Keys, transactions and signatures of one client channel: client key
/// m/0/1 and server key m/0/2 of [channelFixtureMnemonic], a funding
/// transaction locking [amountSats], the refund with nLockTime
/// [lockTimeUnix] and both parties' signatures on it.
class ChannelRefundFixture {
  final String channelId;
  final BigInt amountSats;
  final int lockTimeUnix;
  final dartsv.SVPrivateKey clientKey;
  final dartsv.SVPrivateKey serverKey;
  final String fundingTxHex;
  final String fundingTxId;
  final String refundTxHex;
  final String clientSignatureHex;
  final String serverSignatureHex;

  ChannelRefundFixture._(
    this.channelId,
    this.amountSats,
    this.lockTimeUnix,
    this.clientKey,
    this.serverKey,
    this.fundingTxHex,
    this.fundingTxId,
    this.refundTxHex,
    this.clientSignatureHex,
    this.serverSignatureHex,
  );

  String get clientPubKeyHex => clientKey.publicKey.toString();
  String get serverPubKeyHex => serverKey.publicKey.toString();
  String get clientAddressB58 =>
      clientKey.publicKey.toAddress(dartsv.NetworkType.TEST).toString();
  String get serverAddressB58 =>
      serverKey.publicKey.toAddress(dartsv.NetworkType.TEST).toString();

  static Future<ChannelRefundFixture> create({
    required String channelId,
    BigInt? amountSats,
    int? lockTimeUnix,
  }) async {
    final crypto = DartSVCryptoService();
    final hd = await crypto.mnemonicToHDPrivateKey(channelFixtureMnemonic);
    final clientKey = hd.deriveChildKey('m/0/1').privateKey;
    final serverKey = hd.deriveChildKey('m/0/2').privateKey;
    final amount = amountSats ?? BigInt.from(100000);
    final lockTime = lockTimeUnix ??
        DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
            1000;
    final funding = channelFundingTx(
      clientPubKeyHex: clientKey.publicKey.toString(),
      serverPubKeyHex: serverKey.publicKey.toString(),
      amountSats: amount,
    );
    final builder = const PaymentChannelBuilder();
    final refund = await builder.buildRefundTransaction(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
      fundingTxId: funding.txid,
      fundingOutputIndex: 0,
      fundingAmountSats: amount,
      clientPubKey: clientKey.publicKey,
      serverPubKey: serverKey.publicKey,
      clientAddress: clientKey.publicKey.toAddress(dartsv.NetworkType.TEST),
      lockTimeUnix: lockTime,
    );
    Future<String> sign(dartsv.SVPrivateKey key) async =>
        (await builder.signMultisigInput(
          transaction: refund.transaction,
          inputIndex: 0,
          privateKey: key,
          clientPubKey: clientKey.publicKey,
          serverPubKey: serverKey.publicKey,
          inputAmountSats: amount,
        ))
            .signatureHex;
    return ChannelRefundFixture._(
      channelId,
      amount,
      lockTime,
      clientKey,
      serverKey,
      funding.hex,
      funding.txid,
      refund.transactionHex,
      await sign(clientKey),
      await sign(serverKey),
    );
  }

  /// A valid signature by a key that is not the server's.
  Future<String> forgedServerSignature() async =>
      (await const PaymentChannelBuilder()
              .signMultisigInput(
        transaction: dartsv.Transaction.fromHex(refundTxHex),
        inputIndex: 0,
        privateKey: dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST),
        clientPubKey: clientKey.publicKey,
        serverPubKey: serverKey.publicKey,
        inputAmountSats: amountSats,
      ))
          .signatureHex;

  ChannelRequestedEvent requested(
          {required int version,
          String walletId = 'wallet',
          String? counterpartyMarker}) =>
      ChannelRequestedEvent(
        channelId: channelId,
        walletId: walletId,
        clientPeerId: 'client-peer',
        serverPeerId: 'server-peer',
        clientPubKeyHex: clientPubKeyHex,
        clientAddressB58: clientAddressB58,
        derivationIndex: 1,
        fundingAmountSats: amountSats,
        lockTimeUnix: lockTimeUnix,
        counterpartyMarker: counterpartyMarker,
        version: version,
      );

  ServerAcceptanceRecordedEvent serverAcceptance({required int version}) =>
      ServerAcceptanceRecordedEvent(
        channelId: channelId,
        serverPubKeyHex: serverPubKeyHex,
        serverAddressB58: serverAddressB58,
        version: version,
      );

  RefundBuiltEvent refundBuilt({required int version}) => RefundBuiltEvent(
        channelId: channelId,
        fundingTxId: fundingTxId,
        fundingOutputIndex: 0,
        fundingTxHex: fundingTxHex,
        refundTxHex: refundTxHex,
        clientSignatureHex: clientSignatureHex,
        fundingInputSats: amountSats.toInt() + 50000 + 200,
        version: version,
      );

  /// Client journal: requested, server acceptance recorded, refund built.
  List<Event> clientJournalWithRefund() => [
        requested(version: 1),
        serverAcceptance(version: 2),
        refundBuilt(version: 3),
      ];

  /// The refund with both signatures (what the client journals once the
  /// server signature verified).
  String signedRefundTxHex() =>
      const PaymentChannelBuilder()
          .applyMultisigSignatures(
            transaction: dartsv.Transaction.fromHex(refundTxHex),
            inputIndex: 0,
            clientSignature:
                dartsv.SVSignature.fromTxFormat(clientSignatureHex),
            serverSignature:
                dartsv.SVSignature.fromTxFormat(serverSignatureHex),
            clientPubKey: clientKey.publicKey,
            serverPubKey: serverKey.publicKey,
          )
          .serialize();

  /// Client journal of a channel that is open: requested, acceptance and
  /// refund recorded, refund countersigned (fully signed), funding broadcast
  /// started, opened.
  List<Event> openClientJournal(
          {String walletId = 'wallet', String? counterpartyMarker}) =>
      [
        requested(
            version: 1,
            walletId: walletId,
            counterpartyMarker: counterpartyMarker),
        serverAcceptance(version: 2),
        refundBuilt(version: 3),
        RefundCountersignedEvent(
          channelId: channelId,
          serverSignatureHex: serverSignatureHex,
          signedRefundTxHex: signedRefundTxHex(),
          version: 4,
        ),
        FundingBroadcastStartedEvent(
            channelId: channelId,
            fundingTxId: fundingTxId,
            attempt: 1,
            version: 5),
        ChannelOpenedEvent(
          channelId: channelId,
          fundingTxId: fundingTxId,
          fundingOutputIndex: 0,
          fundingTxHex: fundingTxHex,
          initialClientBalanceSats: amountSats,
          initialServerBalanceSats: BigInt.zero,
          version: 6,
        ),
      ];

  ChannelAcceptedEvent serverAccepted(
          {required int version, String? counterpartyMarker}) =>
      ChannelAcceptedEvent(
        channelId: channelId,
        walletId: 'wallet',
        clientPeerId: 'client-peer',
        clientPubKeyHex: clientPubKeyHex,
        clientAddressB58: clientAddressB58,
        serverPubKeyHex: serverPubKeyHex,
        serverAddressB58: serverAddressB58,
        derivationIndex: 2,
        fundingAmountSats: amountSats,
        lockTimeUnix: lockTimeUnix,
        counterpartyMarker: counterpartyMarker,
        version: version,
      );
}

/// A funding transaction locking [amountSats] in the 2-of-2 of the two keys
/// whose input spends an unproven parent transaction (200000 sats), and the
/// BEEF of the two (libspiffy-fsy). Unsigned: tests pair it with
/// [ScriptedSpvActor], which answers SPV validation as told.
({String hex, String txid, String beefHex}) channelFundingWithBeef({
  required String clientPubKeyHex,
  required String serverPubKeyHex,
  required BigInt amountSats,
}) {
  final payTo = dartsv.P2PKHLockBuilder.fromAddress(
          dartsv.Address.fromBase58('mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt'))
      .getScriptPubkey();
  final parent = dartsv.Transaction()..version = 1;
  parent.inputs.add(dartsv.TransactionInput(
      'd0' * 32, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
  parent.outputs.add(dartsv.TransactionOutput(BigInt.from(200000), payTo));
  final multisig = dartsv.P2MSLockBuilder([
    dartsv.SVPublicKey.fromHex(clientPubKeyHex),
    dartsv.SVPublicKey.fromHex(serverPubKeyHex),
  ], 2, sorting: true)
      .getScriptPubkey();
  final funding = dartsv.Transaction()..version = 1;
  funding.inputs.add(dartsv.TransactionInput(
      parent.id, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
  funding.outputs.add(dartsv.TransactionOutput(amountSats, multisig));
  funding.outputs.add(dartsv.TransactionOutput(
      BigInt.from(200000) - amountSats - BigInt.from(500), payTo));
  final beef = BEEF.create(
    bumps: const [],
    txs: [
      Uint8List.fromList(hex.decode(parent.serialize())),
      Uint8List.fromList(hex.decode(funding.serialize())),
    ],
    hasMerkle: [false, false],
    bumpIndex: const [],
  );
  return (
    hex: funding.serialize(),
    txid: funding.id,
    beefHex: hex.encode(beef.serialize()),
  );
}

/// An SPVActor stand-in: answers every [ValidateCounterpartyTransactionMessage]
/// (and, so a caller that still uses the receive path is answered too, every
/// [ReceiveTransactionMessage]) with a [SPVValidationResult], valid unless
/// [invalidWith] is set, and records every request it was sent in
/// [requests].
class ScriptedSpvActor extends Actor {
  /// Every message this actor was asked to judge, of either kind.
  final List<dynamic> requests = [];

  /// The requests that asked for a receive rather than a verdict: the
  /// server's funding-BEEF check must use none (bead libspiffy-6e5).
  List<ReceiveTransactionMessage> get receives =>
      requests.whereType<ReceiveTransactionMessage>().toList();

  String? invalidWith;

  @override
  Future<void> onMessage(dynamic message) async {
    final String txid;
    final String? targetWalletId;
    switch (message) {
      case final ValidateCounterpartyTransactionMessage msg:
        txid = msg.transactionId;
        targetWalletId = null;
      case final ReceiveTransactionMessage msg:
        txid = msg.transactionId;
        targetWalletId = msg.targetWalletId;
      default:
        return;
    }
    requests.add(message);
    context.sender?.tell(SPVValidationResult(
      txid: txid,
      isValid: invalidWith == null,
      validationError: invalidWith,
      targetWalletId: targetWalletId,
    ));
  }
}

/// An ARCActor stand-in: records every [BroadcastTransactionMessage] and
/// answers it with success, or with [failWith] while that is set; and
/// answers [GetFeeRateMessage] with [feeRate], ARC's published policy rate
/// (bead libspiffy-zs4l).
class RecordingArcActor extends Actor {
  FeeRate feeRate = const FeeRate(satoshis: 100, bytes: 1000);

  final List<BroadcastTransactionMessage> broadcasts = [];

  /// Called when a broadcast arrives, before it is answered.
  void Function(BroadcastTransactionMessage)? onBroadcast;

  String? failWith;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is GetFeeRateMessage) {
      context.sender?.tell(FeeRateQuote(feeRate));
      return;
    }
    if (message is! BroadcastTransactionMessage) return;
    broadcasts.add(message);
    onBroadcast?.call(message);
    final error = failWith;
    context.sender?.tell(error == null
        ? BroadcastSuccessMessage(message.txid, message.txid, networkStatus: 'SEEN_ON_NETWORK')
        : BroadcastFailedMessage(message.txid, error));
  }
}

/// A WalletManager stand-in holding one key: answers address generation with
/// it, signs multisig inputs with it for real, answers UTXO reservations,
/// and records every wallet command it receives (in [commands], with
/// [onCommand] called as each arrives).
class FixtureWalletManager extends Actor {
  final dartsv.SVPrivateKey key;
  final int derivationIndex;
  final List<WalletCommand> commands = [];
  void Function(WalletCommand)? onCommand;

  FixtureWalletManager(this.key, {this.derivationIndex = 1});

  int get signRequests =>
      commands.whereType<SignMultisigTransactionCommand>().length;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! WalletCommandMessage) return;
    final command = message.command;
    commands.add(command);
    onCommand?.call(command);
    if (command is GenerateAddressCommand) {
      context.sender?.tell(AddressGeneratedResponse(
        walletId: command.walletId,
        address: key.publicKey.toAddress(dartsv.NetworkType.TEST).toString(),
        derivationIndex: derivationIndex,
        success: true,
        publicKeyHex: key.publicKey.toString(),
      ));
    } else if (command is SignMultisigTransactionCommand) {
      final chunks = dartsv.SVScript.fromHex(command.redeemScriptHex).chunks;
      final signature =
          await const PaymentChannelBuilder()
              .signMultisigInput(
        transaction: dartsv.Transaction.fromHex(command.rawTransaction),
        inputIndex: command.inputIndex,
        privateKey: key,
        clientPubKey: dartsv.SVPublicKey.fromDER(chunks[1].buf!),
        serverPubKey: dartsv.SVPublicKey.fromDER(chunks[2].buf!),
        inputAmountSats: BigInt.from(command.prevOutValue),
      );
      context.sender?.tell(MultisigTransactionSignedResponse(
        walletId: command.walletId,
        txid: dartsv.Transaction.fromHex(command.rawTransaction).id,
        originalTransactionId: command.transactionId,
        signedHex: command.rawTransaction,
        signatureHex: signature.signatureHex,
        success: true,
      ));
    } else if (command is ReserveUTXOCommand) {
      context.sender?.tell(UTXOReservedResponse(
        walletId: command.walletId,
        utxoKey: command.utxoKey,
        reservedByTxId: command.reservedByTxId,
        success: true,
      ));
    }
  }
}
