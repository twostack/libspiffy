/// Bead libspiffy-bg7n: the size of a signed wallet transaction, known
/// before it is signed, and the fee ARC's policy rate asks for it.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/core/wallet/transaction_size.dart';
import 'package:libspiffy/src/models/fee_rate.dart';
import 'package:test/test.dart';

void main() {
  final key = dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST).publicKey;
  final other = dartsv.SVPrivateKey.fromHex('33' * 32, dartsv.NetworkType.TEST).publicKey;
  final third = dartsv.SVPrivateKey.fromHex('44' * 32, dartsv.NetworkType.TEST).publicKey;

  final p2pkh = dartsv.P2PKHLockBuilder.fromAddress(key.toAddress(dartsv.NetworkType.TEST)).getScriptPubkey().toHex();
  final p2pk = dartsv.SVScript.fromString('33 0x${key.toHex()} OP_CHECKSIG').toHex();
  String multisig(int m) => dartsv.P2MSLockBuilder([key, other, third], m, sorting: false).getScriptPubkey().toHex();

  group('TransactionSize', () {
    test('a signed input carries its outpoint, sequence and the unlocking script the wallet writes', () {
      // 36 + 4 + 1 + <sig> <key> (73 + 34)
      expect(TransactionSize.input(p2pkh), 148);
      // <sig> alone
      expect(TransactionSize.input(p2pk), 36 + 4 + 1 + 73);
      // OP_0 and one signature per required key
      expect(TransactionSize.input(multisig(1)), 36 + 4 + 1 + 1 + 73);
      expect(TransactionSize.input(multisig(2)), 36 + 4 + 1 + 1 + 2 * 73);
      expect(TransactionSize.input(multisig(3)), 36 + 4 + 1 + 1 + 3 * 73);
    });

    test('an output is its amount, script length and script', () {
      expect(TransactionSize.output(TransactionSize.p2pkhScriptBytes), 34);
      expect(TransactionSize.output(252), 8 + 1 + 252);
      expect(TransactionSize.output(253), 8 + 3 + 253, reason: 'a length of 253 or more takes a 3-byte varint');
    });

    test('a one-input P2PKH payment with change is the familiar 226 bytes', () {
      expect(
          TransactionSize.of(inputLockingScripts: [p2pkh], outputScriptBytes: const [25, 25]), 226);
    });

    test('the counts are varints too', () {
      final small = TransactionSize.of(inputLockingScripts: List.filled(252, p2pkh), outputScriptBytes: const [25]);
      final large = TransactionSize.of(inputLockingScripts: List.filled(253, p2pkh), outputScriptBytes: const [25]);
      expect(large - small, 148 + 2, reason: 'one more input, and its count grows from 1 byte to 3');
    });

    test('a locking script the wallet writes no unlocking script for has no size to guess', () {
      expect(() => TransactionSize.input('6a0568656c6c6f'), throwsArgumentError);
    });

    test('never smaller than the transaction dartsv signs', () {
      final signing = dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST);
      final parent = dartsv.Transaction()
        ..addOutput(dartsv.TransactionOutput(BigInt.from(100000), dartsv.SVScript.fromHex(p2pkh)));
      final signer = dartsv.DefaultTransactionSigner(dartsv.SighashType.SIGHASH_FORKID.value | dartsv.SighashType.SIGHASH_ALL.value, signing);
      for (var attempt = 0; attempt < 20; attempt++) {
        final tx = dartsv.TransactionBuilder()
            .spendFromTxnWithSigner(signer, parent, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER,
                dartsv.P2PKHUnlockBuilder(signing.publicKey))
            .spendToPKH(other.toAddress(dartsv.NetworkType.TEST), BigInt.from(1000 + attempt))
            .sendChangeToPKH(key.toAddress(dartsv.NetworkType.TEST))
            .withFee(BigInt.from(100))
            .build(false);
        expect(tx.serialize().length ~/ 2,
            lessThanOrEqualTo(TransactionSize.of(inputLockingScripts: [p2pkh], outputScriptBytes: const [25, 25])));
      }
    });
  });

  group('FeeRate', () {
    test('the fee is rounded up: a truncated fee undercuts the policy', () {
      expect(const FeeRate(satoshis: 1, bytes: 1000).feeFor(523), BigInt.one);
      expect(const FeeRate(satoshis: 5, bytes: 100).feeFor(1675), BigInt.from(84));
      expect(const FeeRate(satoshis: 50, bytes: 1000).feeFor(423), BigInt.from(22));
      expect(const FeeRate(satoshis: 100, bytes: 1000).feeFor(1000), BigInt.from(100));
    });

    test('satoshis per kilobyte', () {
      expect(const FeeRate(satoshis: 5, bytes: 100).satoshisPerKb, 50);
    });
  });
}
