/// Bead libspiffy-abwk. `ReceiveUTXOCommand` refuses a bare multisig output
/// the wallet cannot spend alone (beads viy, n0p) but had no equivalent rule
/// for a P2PK output: nothing compared the key the script locks to with the
/// wallet's own, and nothing required the attributed address to have anything
/// to do with the script. V-93 established that this really does let such a
/// row into a wallet, and answered it conservatively — record it honestly,
/// never select it. The decision here is the stricter one: an output the
/// wallet can never satisfy is refused at the door, as an unmeetable multisig
/// already is.
///
/// Two things this must NOT do:
/// * refuse a P2PK output to a WATCH address. The wallet holds no key for it
///   and never will, but tracking exactly that is what watch addresses are
///   for; it is reported as watch-only funds and never selected.
/// * validate anything on REPLAY. A journal written before this guard is
///   still the record, and `applyReceived` deliberately checks no script.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_balances.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _walletId = 'wallet-abwk';
final _network = dartsv.NetworkType.TEST;

String p2pk(String keyHex) => dartsv.SVScript.fromASM('$keyHex OP_CHECKSIG').toHex();

void main() {
  late dartsv.SVPublicKey ownKey;
  late String ownAddress;
  late dartsv.SVPublicKey watchKey;
  late String watchAddress;
  late dartsv.SVPublicKey foreignKey;

  setUpAll(() async {
    final hd = await DartSVCryptoService().mnemonicToHDPrivateKey(_mnemonic);
    ownKey = hd.deriveChildKey('m/0/0').privateKey.publicKey;
    ownAddress = ownKey.toAddress(_network).toBase58();
    watchKey = dartsv.SVPrivateKey.fromHex('22' * 32, _network).publicKey;
    watchAddress = watchKey.toAddress(_network).toBase58();
    foreignKey = dartsv.SVPrivateKey.fromHex('5c' * 32, _network).publicKey;
  });

  Future<BitcoinWalletAggregate> wallet({bool watching = false}) async {
    final w = BitcoinWalletAggregate(
      aggregateId: _walletId,
      aggregateType: 'BitcoinWallet',
      eventStore: InMemoryEventStore(),
      cryptoService: DartSVCryptoService(),
      secureStorage: InMemorySecureStorage(),
    );
    await w.preStart();
    await w.commandHandler(
        CreateWalletCommand(walletId: _walletId, walletName: 'abwk', mnemonic: _mnemonic));
    if (watching) {
      await w.commandHandler(
          AddWatchAddressCommand(walletId: _walletId, address: watchAddress, scriptType: 'p2pkh'));
    }
    return w;
  }

  Future<void> receive(BitcoinWalletAggregate w, String txid, String scriptHex, String address) =>
      w.commandHandler(ReceiveUTXOCommand(
        walletId: _walletId,
        txid: txid,
        vout: 0,
        satoshis: BigInt.from(90000),
        scriptPubKey: scriptHex,
        address: address,
        initialStatus: UTXOStatus.available,
        blockHeight: 800000,
        confirmations: 6,
      ));

  test('a P2PK output locked to a key the wallet does not hold is refused',
      () async {
    final w = await wallet();

    await expectLater(
      receive(w, 'aa' * 32, p2pk(foreignKey.toHex()), ownAddress),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          allOf(contains('${'aa' * 32}:0'), contains('P2PK')))),
    );
    expect(w.currentState.utxos, isEmpty,
        reason: 'the output is not the wallet\'s and is not taken on');
  });

  test('the attributed address does not excuse it', () async {
    final w = await wallet();
    // Filed under the foreign key's own address rather than one of ours:
    // the guard reads the script, not the attribution, as the multisig one
    // does.
    await expectLater(
      receive(w, 'ab' * 32, p2pk(foreignKey.toHex()),
          foreignKey.toAddress(_network).toBase58()),
      throwsA(isA<StateError>()),
    );
  });

  test('a P2PK output to the wallet\'s own key is received', () async {
    final w = await wallet();
    await receive(w, 'bb' * 32, p2pk(ownKey.toHex()), ownAddress);

    final utxo = w.currentState.utxos['${'bb' * 32}:0'];
    expect(utxo, isNotNull);
    expect(WalletBalances.isSpendable(w.currentState, utxo!), isTrue);
  });

  test('a P2PK output pushing the uncompressed encoding of a wallet key is '
      'received, and is spendable', () async {
    final w = await wallet();
    // The same key, the other encoding: the wallet holds it either way, and
    // OP_CHECKSIG decodes both to the same point.
    await receive(w, 'bc' * 32, p2pk(ownKey.getEncoded(false)), ownAddress);

    final utxo = w.currentState.utxos['${'bc' * 32}:0'];
    expect(utxo, isNotNull, reason: 'refusing this would refuse the wallet\'s own money');
    expect(WalletBalances.isSpendable(w.currentState, utxo!), isTrue);
  });

  test('a P2PK output to a watch address is received and reported watch-only',
      () async {
    final w = await wallet(watching: true);
    await receive(w, 'cc' * 32, p2pk(watchKey.toHex()), watchAddress);

    final utxo = w.currentState.utxos['${'cc' * 32}:0'];
    expect(utxo, isNotNull,
        reason: 'tracking an address the wallet holds no key for is what a '
            'watch address is for');
    expect(WalletBalances.isWatchOnly(w.currentState, utxo!), isTrue);
    expect(WalletBalances.isSpendable(w.currentState, utxo), isFalse);
  });

  /// Why [p2pkAddresses] answers with BOTH encodings rather than normalising
  /// to the compressed one. The wallet derives every address of its own from
  /// a compressed key, so for those one form would do. A WATCH address is
  /// whatever the user handed us — an old wallet's uncompressed address is a
  /// perfectly ordinary thing to want to watch — and a P2PK output to that
  /// key pushes the uncompressed bytes. Normalising would refuse it.
  test('a P2PK output to an uncompressed watch address is received', () async {
    final uncompressedWatch =
        dartsv.SVPublicKey.fromHex(watchKey.getEncoded(false)).toAddress(_network).toBase58();
    expect(uncompressedWatch, isNot(watchAddress),
        reason: 'the two encodings of one key have different addresses');

    final w = await wallet();
    await w.commandHandler(AddWatchAddressCommand(
        walletId: _walletId, address: uncompressedWatch, scriptType: 'p2pkh'));

    await receive(w, 'ce' * 32, p2pk(watchKey.getEncoded(false)), uncompressedWatch);

    expect(w.currentState.utxos['${'ce' * 32}:0'], isNotNull,
        reason: 'the user asked to watch exactly this key');
  });

  test('replay still applies a foreign-key P2PK row, because a journal '
      'written before this guard is still the record', () async {
    final w = await wallet();
    w.eventHandler(UTXOReceivedEvent(
      walletId: _walletId,
      txid: 'dd' * 32,
      vout: 0,
      satoshis: 90000,
      scriptPubKey: p2pk(foreignKey.toHex()),
      address: ownAddress,
      initialStatus: UTXOStatus.available,
      blockHeight: 800000,
      confirmations: 6,
      version: w.currentState.version + 1,
    ));

    final utxo = w.currentState.utxos['${'dd' * 32}:0'];
    expect(utxo, isNotNull, reason: 'data already journaled is never dropped');
    expect(WalletBalances.isSpendable(w.currentState, utxo!), isFalse,
        reason: 'kept, and still never selected (V-93)');
  });
}
