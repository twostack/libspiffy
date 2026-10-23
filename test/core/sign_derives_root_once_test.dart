/// A transaction is signed with the wallet's HD root derived once, not once
/// per input. Deriving a mnemonic wallet's root stretches the mnemonic with
/// PBKDF2 (about 1.1 s on a phone, with four secure-storage reads); a
/// two-input payment spent 2.65 s signing on a Pixel, a five-input one would
/// spend over five. The root is not kept after the transaction: the next one
/// derives it again.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _walletId = 'wallet-root-once';
final _network = dartsv.NetworkType.TEST;

class _CountingStorage extends InMemorySecureStorage {
  int mnemonicReads = 0;

  @override
  Future<String?> getMnemonic(String walletId) {
    mnemonicReads++;
    return super.getMnemonic(walletId);
  }
}

void main() {
  late _CountingStorage storage;
  late BitcoinWalletAggregate w;
  late String rootAddress;
  late String rootScript;

  setUp(() async {
    final hd = await DartSVCryptoService().mnemonicToHDPrivateKey(_mnemonic);
    final address = hd.deriveChildKey('m/0/0').privateKey.publicKey.toAddress(_network);
    rootAddress = address.toBase58();
    rootScript = dartsv.P2PKHLockBuilder.fromAddress(address).getScriptPubkey().toHex();

    storage = _CountingStorage();
    w = BitcoinWalletAggregate(
      aggregateId: _walletId,
      aggregateType: 'BitcoinWallet',
      eventStore: InMemoryEventStore(),
      cryptoService: DartSVCryptoService(),
      secureStorage: storage,
    );
    await w.preStart();
    await w.commandHandler(CreateWalletCommand(walletId: _walletId, walletName: 'root once', mnemonic: _mnemonic));
  });

  Future<List<String>> receive(int count, int tag) async {
    final keys = <String>[];
    for (var i = 0; i < count; i++) {
      final txid = (tag + i).toRadixString(16).padLeft(2, '0') * 32;
      await w.commandHandler(ReceiveUTXOCommand(
        walletId: _walletId,
        txid: txid,
        vout: 0,
        satoshis: BigInt.from(10000),
        scriptPubKey: rootScript,
        address: rootAddress,
        initialStatus: UTXOStatus.available,
        blockHeight: 800000,
        confirmations: 6,
      ));
      keys.add('$txid:0');
    }
    return keys;
  }

  Future<dynamic> sign(List<String> utxoKeys) {
    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    for (final key in utxoKeys) {
      tx.inputs.add(dartsv.TransactionInput(key.split(':').first, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    }
    tx.outputs.add(dartsv.TransactionOutput(
      BigInt.from(9000 * utxoKeys.length),
      dartsv.P2PKHLockBuilder.fromAddress(dartsv.SVPrivateKey.fromHex('7a' * 32, _network).publicKey.toAddress(_network))
          .getScriptPubkey(),
    ));
    return w.commandHandler(SignTransactionCommand(
      walletId: _walletId,
      transactionId: 'spend-${utxoKeys.first}',
      rawTransaction: tx.serialize(),
      utxoKeys: utxoKeys,
      publicKeys: const [],
    ));
  }

  test('a three-input transaction reads the mnemonic once, and the next transaction reads it again', () async {
    final first = await receive(3, 0x11);
    final second = await receive(2, 0x21);

    storage.mnemonicReads = 0;
    // The signer checks every input it signs with the script interpreter, so
    // a wrong key for any input fails the command.
    await sign(first);
    expect(storage.mnemonicReads, 1, reason: 'one root derivation for all three inputs');

    await sign(second);
    expect(storage.mnemonicReads, 2, reason: 'the root is not kept between transactions');
  });
}
