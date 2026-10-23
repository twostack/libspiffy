/// Bead spiffyvault-mnz.5: a wallet holds lock keys, private keys outside
/// its HD tree that HODLocker coins may be locked to (RelayX's paymail key,
/// which hodlocker.com locked to). The key stays in secure storage, its
/// address is the wallet's, a lock to it is taken on, and the wallet signs
/// for it with the key.
library;

import 'dart:async';
import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet/wallet_keys.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/key_path.dart';
import 'package:libspiffy/src/models/wallet_event.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import '../actors/in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _walletId = 'wallet-lock-key';
final _network = dartsv.NetworkType.TEST;

dartsv.SVScript _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey();

void main() {
  late InMemoryEventStore store;
  late InMemorySecureStorage secureStorage;
  late BitcoinWalletAggregate wallet;
  late TestActorSystem system;

  final lockKey = dartsv.SVPrivateKey.fromHex('7a' * 32, _network);
  final lockAddress = lockKey.publicKey.toAddress(_network).toBase58();

  BitcoinWalletAggregate aggregate() => BitcoinWalletAggregate(
        aggregateId: _walletId,
        aggregateType: 'BitcoinWallet',
        eventStore: store,
        cryptoService: DartSVCryptoService(),
        secureStorage: secureStorage,
      );

  setUp(() async {
    store = InMemoryEventStore();
    secureStorage = InMemorySecureStorage();
    system = TestActorSystem();
    wallet = aggregate();
    await wallet.preStart();
    await wallet.commandHandler(CreateWalletCommand(walletId: _walletId, walletName: 'Locks', mnemonic: _mnemonic));
  });

  tearDown(() => system.shutdown());

  Future<void> addLockKey([String? wif]) =>
      wallet.commandHandler(AddLockKeyCommand(walletId: _walletId, wif: wif ?? lockKey.toWIF()));

  test('the key goes to secure storage, its address into the journal and the wallet, once', () async {
    await addLockKey();
    await addLockKey();

    final added = store.allEvents.whereType<LockKeyAddedEvent>().toList();
    expect(added.map((e) => e.address), [lockAddress], reason: 'a key held already journals nothing');
    expect(wallet.currentState.addresses.containsKey(lockAddress), isTrue);
    expect(WalletKeys.lockKeyAddresses(wallet.currentState.metadata), {lockAddress});
    final stored = jsonDecode((await secureStorage.getString(WalletKeys.lockKeysKey(_walletId)))!) as Map;
    expect(stored, {lockAddress: lockKey.toWIF()});
    final journal = jsonEncode([for (final e in store.allEvents) (e as WalletEvent).getWalletEventData()]);
    expect(journal, isNot(contains(lockKey.toWIF())), reason: 'the key is never journaled');
  });

  test('a key of another network, or one that is not a key, is refused', () async {
    final mainnetKey = dartsv.SVPrivateKey.fromHex('7a' * 32, dartsv.NetworkType.MAIN).toWIF();
    await expectLater(addLockKey(mainnetKey), throwsArgumentError);
    await expectLater(addLockKey('not a key'), throwsArgumentError);
    expect(store.allEvents.whereType<LockKeyAddedEvent>(), isEmpty);
    expect(await secureStorage.getString(WalletKeys.lockKeysKey(_walletId)), isNull);
  });

  test('a lock to the key is the wallet\'s coin, with its lock', () async {
    await addLockKey();
    final lock = dartsv.HODLockerLockingScriptBuilder(
      hex.decode(lockKey.publicKey.toAddress(_network).pubkeyHash160),
      BigInt.from(1700000),
    ).getScriptPubkey();

    await wallet.commandHandler(ReceiveUTXOCommand(
      walletId: _walletId,
      txid: 'ab' * 32,
      vout: 0,
      satoshis: BigInt.from(500000000),
      scriptPubKey: lock.toHex(),
      address: lockAddress,
      initialStatus: UTXOStatus.available,
      blockHeight: 1690000,
    ));

    final coin = wallet.currentState.utxos['${'ab' * 32}:0']!;
    expect(coin.pluginMetadata?['ownerAddress'], lockAddress);
    expect(coin.pluginMetadata?['lockHeight'], 1700000);
  });

  test('the read model knows the address as a lock key, and the wallet signs for it with the key', () async {
    await addLockKey();
    final storage = InMemoryWalletStorage();
    final projection = WalletProjection(projectionId: 'lock-key-test', eventStore: store, storage: storage);
    for (final event in store.allEvents) {
      await projection.handle(event);
    }
    final row = (await storage.getAddressMetadata(_walletId, lockAddress))!;
    expect(row.purpose, AddressMetadata.lockKeyPurpose);
    expect(row.keyPath, LockKeyPath(lockAddress));

    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    tx.inputs.add(dartsv.TransactionInput('cd' * 32, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    tx.outputs.add(dartsv.TransactionOutput(BigInt.from(1000), _p2pkh(lockAddress)));
    final replied = Completer<InputSignedResponse>();
    final probe = await system.spawn('probe', () => _Probe(replied));
    final actor = await system.spawn('wallet', aggregate);
    actor.tell(
      SignInputCommand(
        walletId: _walletId,
        rawTransaction: tx.serialize(),
        inputIndex: 0,
        subscriptHex: _p2pkh(lockAddress).toHex(),
        satoshis: BigInt.from(2000),
        keyPath: row.keyPath!,
      ),
      sender: probe,
    );
    final signed = await replied.future.timeout(const Duration(seconds: 10));

    expect(signed.success, isTrue, reason: signed.error);
    expect(signed.publicKeyHex, lockKey.publicKey.getEncoded(true));
    final unlock = dartsv.P2PKHUnlockBuilder(dartsv.SVPublicKey.fromHex(signed.publicKeyHex))
      ..signatures.add(dartsv.SVSignature.fromTxFormat(signed.signatureHex));
    dartsv.Interpreter().correctlySpends(
      unlock.getScriptSig(),
      _p2pkh(lockAddress),
      tx,
      0,
      {dartsv.VerifyFlag.SIGHASH_FORKID, dartsv.VerifyFlag.UTXO_AFTER_GENESIS},
      dartsv.Coin.ofSat(BigInt.from(2000)),
    );
  });
}

class _Probe extends Actor {
  final Completer<InputSignedResponse> completer;
  _Probe(this.completer);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is InputSignedResponse && !completer.isCompleted) completer.complete(message);
  }
}
