/// Audit 2026-09-14 SPV-13 (libspiffy-bfh), PaymentChannelBuilder part:
///
/// * buildRefundTransaction accepted any lockTimeUnix. Below 500,000,000 the
///   consensus rules read nLockTime as a block height, so a "timestamp" in
///   that range yields a refund that is spendable at a (usually long past)
///   block height instead of at the channel expiry.
/// * signMultisigInput replaced the input of the caller's transaction with
///   one carrying its unlock builder, mutating a transaction the caller still
///   owns (and, for a second signer, one that already carried a signature).
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/services/payment_channel_builder.dart';

void main() {
  late PaymentChannelBuilder builder;
  late dartsv.SVPrivateKey clientKey;
  late dartsv.SVPrivateKey serverKey;
  late dartsv.Address clientAddress;
  final fundingTxId = 'ab' * 32;
  final fundingAmount = BigInt.from(100000);

  setUp(() {
    builder = PaymentChannelBuilder(cryptoService: DartSVCryptoService());
    clientKey = dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST);
    serverKey = dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST);
    clientAddress = clientKey.publicKey.toAddress(dartsv.NetworkType.TEST);
  });

  Future<ChannelTransactionResult> refund(int lockTimeUnix) =>
      builder.buildRefundTransaction(
        fundingTxId: fundingTxId,
        fundingOutputIndex: 0,
        fundingAmountSats: fundingAmount,
        clientPubKey: clientKey.publicKey,
        serverPubKey: serverKey.publicKey,
        clientAddress: clientAddress,
        lockTimeUnix: lockTimeUnix,
      );

  group('SPV-13: refund nLockTime domain', () {
    test('rejects a lockTimeUnix that consensus reads as a block height',
        () async {
      await expectLater(
        refund(499999999),
        throwsA(isA<TransactionBuildException>()
            .having((e) => e.code, 'code', 'INVALID_LOCKTIME')),
      );
    });

    test('rejects a lockTimeUnix that does not fit nLockTime (uint32)',
        () async {
      await expectLater(
        refund(0x100000000),
        throwsA(isA<TransactionBuildException>()
            .having((e) => e.code, 'code', 'INVALID_LOCKTIME')),
      );
    });

    test('accepts the smallest timestamp lockTime, 500000000', () async {
      final result = await refund(500000000);
      expect(result.transaction.nLockTime, 500000000);
    });
  });

  group('SPV-13: signMultisigInput', () {
    test("leaves the caller's transaction unchanged", () async {
      final result = await refund(1800000000);
      final tx = result.transaction;
      final hexBefore = tx.serialize();
      final inputBefore = tx.inputs[0];

      final signature = await builder.signMultisigInput(
        transaction: tx,
        inputIndex: 0,
        privateKey: clientKey,
        clientPubKey: clientKey.publicKey,
        serverPubKey: serverKey.publicKey,
        inputAmountSats: fundingAmount,
      );

      expect(signature.signatureHex, isNotEmpty);
      expect(identical(tx.inputs[0], inputBefore), isTrue,
          reason: 'the input of the caller\'s transaction must not be replaced');
      expect(tx.serialize(), hexBefore);
    });

    test('signatures from a shared transaction still complete the spend',
        () async {
      final result = await refund(1800000000);
      final tx = result.transaction;

      Future<dartsv.SVSignature> sign(dartsv.SVPrivateKey key) async =>
          (await builder.signMultisigInput(
            transaction: tx,
            inputIndex: 0,
            privateKey: key,
            clientPubKey: clientKey.publicKey,
            serverPubKey: serverKey.publicKey,
            inputAmountSats: fundingAmount,
          ))
              .signature;

      final clientSig = await sign(clientKey);
      final serverSig = await sign(serverKey);
      final signed = builder.applyMultisigSignatures(
        transaction: dartsv.Transaction.fromHex(tx.serialize()),
        inputIndex: 0,
        clientSignature: clientSig,
        serverSignature: serverSig,
        clientPubKey: clientKey.publicKey,
        serverPubKey: serverKey.publicKey,
      );

      builder.verifyMultisigSpend(
        signedTx: signed,
        redeemScript: builder.buildMultisigRedeemScript(
          clientPubKey: clientKey.publicKey,
          serverPubKey: serverKey.publicKey,
        ),
        inputValueSats: fundingAmount,
      );
    });
  });
}
