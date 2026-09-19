/// Bead libspiffy-p6ot. `WalletTransactionSigner.unlockFor` checks, for a
/// P2PKH input, that the key it derived for the UTXO's attributed address is
/// the one the script locks to ([WalletTransactionSigner.requireKeyForP2pkh]).
/// The P2PK branch beside it had no such check: it signed with whatever key
/// the attributed address named and returned `<sig>` alone, producing a
/// silently invalid unlocking script — discovered when a node rejects the
/// transaction, not when it is built.
///
/// V-93 (libspiffy-kfvv) keeps such an output out of every SELECTION, so
/// nothing reaches the signer on its own. This is about the remaining way in:
/// a caller naming the outpoint explicitly. A guard, not a selection rule.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _walletId = 'wallet-p6ot';
final _network = dartsv.NetworkType.TEST;

/// `<key> OP_CHECKSIG`.
String p2pk(dartsv.SVPublicKey key) =>
    dartsv.SVScript.fromASM('${key.toHex()} OP_CHECKSIG').toHex();

void main() {
  late dartsv.SVPublicKey ownKey;
  late String ownAddress;
  late dartsv.SVPublicKey foreignKey;

  setUpAll(() async {
    // The wallet's root address is m/0/0 of its own mnemonic.
    final hd = await DartSVCryptoService().mnemonicToHDPrivateKey(_mnemonic);
    ownKey = hd.deriveChildKey('m/0/0').privateKey.publicKey;
    ownAddress = ownKey.toAddress(_network).toBase58();
    foreignKey = dartsv.SVPrivateKey.fromHex('5c' * 32, _network).publicKey;
  });

  late InMemoryEventStore store;

  Future<BitcoinWalletAggregate> wallet() async {
    store = InMemoryEventStore();
    final w = BitcoinWalletAggregate(
      aggregateId: _walletId,
      aggregateType: 'BitcoinWallet',
      eventStore: store,
      cryptoService: DartSVCryptoService(),
      secureStorage: InMemorySecureStorage(),
    );
    await w.preStart();
    await w.commandHandler(
        CreateWalletCommand(walletId: _walletId, walletName: 'p6ot', mnemonic: _mnemonic));
    expect(w.currentState.addresses, contains(ownAddress),
        reason: 'the root address is the one these UTXOs are attributed to');
    return w;
  }

  /// A P2PK output locked to [key], attributed to the wallet's own address —
  /// the state V-93 established is reachable: `ReceiveUTXOCommand` has one
  /// script guard and it is for bare multisig only, so nothing compares a
  /// P2PK script's key with the address it is filed under.
  Future<void> receiveP2pk(BitcoinWalletAggregate w, String txid, dartsv.SVPublicKey key) =>
      w.commandHandler(ReceiveUTXOCommand(
        walletId: _walletId,
        txid: txid,
        vout: 0,
        satoshis: BigInt.from(90000),
        scriptPubKey: p2pk(key),
        address: ownAddress,
        initialStatus: UTXOStatus.available,
        blockHeight: 800000,
        confirmations: 6,
      ));

  String unsignedSpend(String txid) {
    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    tx.inputs.add(dartsv.TransactionInput(txid, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    tx.outputs.add(dartsv.TransactionOutput(
      BigInt.from(80000),
      dartsv.SVScript.fromHex(dartsv.P2PKHLockBuilder.fromAddress(
              dartsv.SVPrivateKey.fromHex('7a' * 32, _network).publicKey.toAddress(_network))
          .getScriptPubkey()
          .toHex()),
    ));
    return tx.serialize();
  }

  Future<dynamic> sign(BitcoinWalletAggregate w, String txid) => w.commandHandler(SignTransactionCommand(
        walletId: _walletId,
        transactionId: 'spend-$txid',
        rawTransaction: unsignedSpend(txid),
        utxoKeys: ['$txid:0'],
        publicKeys: const [],
        derivationIndices: const [],
      ));

  test('a P2PK input locked to a key the wallet does not hold is refused, not signed',
      () async {
    final w = await wallet();
    await receiveP2pk(w, 'aa' * 32, foreignKey);

    await expectLater(
      sign(w, 'aa' * 32),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          allOf(contains('${'aa' * 32}:0'), contains('no key')))),
      reason: 'signing with the key of the attributed address produces an '
          'unlocking script the script can never satisfy; refuse it where it '
          'is built, not when a node rejects the transaction',
    );
  });

  /// The signer has one branch with no guard in front of it, by design: a
  /// script type it has no standard unlocking script for is signed with the
  /// key at the UTXO's address and, in its own words, left for "the
  /// interpreter to judge". That sanity check — every signed input run
  /// through `correctlySpends` — is the only thing standing between that
  /// branch and a transaction no node will accept, and removing it left 422
  /// tests green. This is what pins it.
  test('a script the wallet has no unlocking script for is refused, not '
      'returned unsigned-in-effect', () async {
    final w = await wallet();
    await w.commandHandler(ReceiveUTXOCommand(
      walletId: _walletId,
      txid: 'cc' * 32,
      vout: 0,
      satoshis: BigInt.from(90000),
      // OP_0: whatever is pushed before it, the stack ends empty, so no
      // unlocking script the wallet could build satisfies this output.
      scriptPubKey: '00',
      address: ownAddress,
      initialStatus: UTXOStatus.available,
      blockHeight: 800000,
      confirmations: 6,
    ));

    await expectLater(sign(w, 'cc' * 32), throwsA(isA<StateError>()));
    expect(
        (store.journal['BitcoinWallet_$_walletId'] ?? const [])
            .whereType<TransactionSignedEvent>(),
        isEmpty,
        reason: 'a transaction whose input does not spend its output is not '
            'journaled as signed');
  });

  test('a P2PK input locked to the wallet\'s own key still signs, and the '
      'signature satisfies the script', () async {
    final w = await wallet();
    await receiveP2pk(w, 'bb' * 32, ownKey);

    await sign(w, 'bb' * 32);

    final journaled =
        (store.journal['BitcoinWallet_$_walletId'] ?? const []).whereType<TransactionSignedEvent>();
    expect(journaled, hasLength(1),
        reason: 'the wallet does hold this key, so the signing goes through');

    // The unlocking script must actually spend the output: a guard that
    // refuses everything would pass the test above.
    final signed = dartsv.Transaction.fromHex(journaled.single.signedRawHex);
    expect(
      () => dartsv.Interpreter().correctlySpends(
        signed.inputs.single.script!,
        dartsv.SVScript.fromHex(p2pk(ownKey)),
        signed,
        0,
        {dartsv.VerifyFlag.SIGHASH_FORKID, dartsv.VerifyFlag.UTXO_AFTER_GENESIS},
        dartsv.Coin.ofSat(BigInt.from(90000)),
      ),
      returnsNormally,
      reason: 'a P2PK output the wallet does hold the key for is still spendable',
    );
  });
}
