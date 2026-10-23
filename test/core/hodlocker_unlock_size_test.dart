/// Bead spiffyvault-mnz.7: the size of a HODLocker unlock, which an
/// unlock's fee and its quote are both taken on, is the size of the signed
/// transaction the wallet builds, for a lock script of any length.
library;

import 'dart:typed_data';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:hex/hex.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:test/test.dart';

/// [data] as a script push.
List<int> _push(List<int> data) => [
      if (data.length < 0x4c)
        data.length
      else if (data.length <= 0xff) ...[0x4c, data.length]
      else ...[0x4d, data.length & 0xff, data.length >> 8],
      ...data,
    ];

void main() {
  test('the unlock size is the signed unlock\'s, with a 73-byte signature, for every lock height form', () {
    final owner = dartsv.SVPrivateKey.fromHex('5c' * 32, dartsv.NetworkType.MAIN).publicKey;
    final pkh = HEX.decode(owner.toAddress(dartsv.NetworkType.MAIN).pubkeyHash160);
    for (final height in [5, 100, 70000, 810477, 1075018, 400000000]) {
      final lock = dartsv.HODLockerLockingScriptBuilder(pkh, BigInt.from(height)).getScriptPubkey();
      final lockBytes = lock.toHex().length ~/ 2;
      final tx = dartsv.Transaction()
        ..version = 1
        ..nLockTime = height;
      tx.inputs.add(dartsv.TransactionInput('ab' * 32, 0, 0xfffffffe));
      tx.outputs.add(dartsv.TransactionOutput(BigInt.from(1000),
          dartsv.P2PKHLockBuilder.fromAddress(owner.toAddress(dartsv.NetworkType.MAIN)).getScriptPubkey()));
      final sighash = dartsv.Sighash()..hash(tx, 0x41, 0, lock, BigInt.from(5000));
      final Uint8List preimage = sighash.preImage!;
      final unlocking = [..._push(List.filled(73, 1)), ..._push(List.filled(33, 2)), ..._push(preimage)];
      tx.inputs[0].script = dartsv.SVScript.fromHex(HEX.encode(unlocking));

      expect(HodlockerLock.unlockSize(lockBytes), tx.serialize().length ~/ 2, reason: 'height $height');
    }
  });

  test('a 934-byte lock\'s unlock is 1291 bytes: 130 sats at 100 sats a kilobyte', () {
    expect(HodlockerLock.unlockSize(934), 1291);
    expect(const FeeRate(satoshis: 100, bytes: 1000).feeFor(HodlockerLock.unlockSize(934)), BigInt.from(130));
  });
}
