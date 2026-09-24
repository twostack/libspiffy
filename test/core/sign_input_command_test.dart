/// libspiffy-5sr: `SignInputCommand`, the aggregate's per-input signing
/// primitive for plugin-built transactions.
///
/// AggregateSigningClient used `SignMultisigTransactionCommand` (a payment
/// channel command) to sign one input against a subscript and amount, and
/// recovered the signing key's public key from a throwaway signature.
/// `SignInputCommand` signs the input and returns the public key directly.
library;

import 'dart:async';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/models/address_chain.dart';

import '../actors/in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _passphrase = 'correct horse battery staple';
const _externalAddress = 'n4VQ5YdHf7hLQ2gWQYYrcxoE5B7nWuDFNF'; // testnet

dartsv.SVScript _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey();

/// Two-input transaction; the inputs spend arbitrary outpoints.
dartsv.Transaction _unsignedTx() {
  final tx = dartsv.Transaction()
    ..version = 1
    ..nLockTime = 0;
  tx.inputs.add(dartsv.TransactionInput('aa' * 32, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
  tx.inputs.add(dartsv.TransactionInput('bb' * 32, 3, dartsv.TransactionInput.MAX_SEQ_NUMBER));
  tx.outputs.add(dartsv.TransactionOutput(BigInt.from(20000), _p2pkh(_externalAddress)));
  return tx;
}

/// Runs the P2PKH script for input [index] of [tx] with [signature] and
/// [publicKey]; throws when the signature does not satisfy it.
void _verifyP2pkhSpend(dartsv.Transaction tx, int index, String address, BigInt satoshis,
    dartsv.SVSignature signature, dartsv.SVPublicKey publicKey) {
  final unlock = dartsv.P2PKHUnlockBuilder(publicKey)..signatures.add(signature);
  dartsv.Interpreter().correctlySpends(
    unlock.getScriptSig(),
    _p2pkh(address),
    tx,
    index,
    {dartsv.VerifyFlag.SIGHASH_FORKID, dartsv.VerifyFlag.UTXO_AFTER_GENESIS},
    dartsv.Coin.ofSat(satoshis),
  );
}

String _hash160(dartsv.SVPublicKey key) =>
    hex.encode(dartsv.hash160(hex.decode(key.getEncoded(true))));

void main() {
  late InMemoryEventStore store;
  late InMemorySecureStorage secureStorage;
  late DartSVCryptoService crypto;
  late TestActorSystem system;

  setUp(() {
    store = InMemoryEventStore();
    secureStorage = InMemorySecureStorage();
    crypto = DartSVCryptoService();
    system = TestActorSystem();
  });

  tearDown(() async {
    await system.shutdown();
  });

  BitcoinWalletAggregate aggregate(String walletId) => BitcoinWalletAggregate(
        aggregateId: walletId,
        aggregateType: 'BitcoinWallet',
        eventStore: store,
        cryptoService: crypto,
        secureStorage: secureStorage,
      );

  /// Creates [walletId] outside the actor system and returns the aggregate.
  Future<BitcoinWalletAggregate> createWallet(String walletId, CreateWalletCommand create) async {
    final setup = aggregate(walletId);
    await setup.preStart();
    await setup.commandHandler(create);
    return setup;
  }

  var probes = 0;

  /// Sends [command] to a freshly spawned aggregate for its wallet and
  /// returns the reply.
  Future<InputSignedResponse> ask(SignInputCommand command) async {
    final completer = Completer<InputSignedResponse>();
    final probe = await system.spawn('probe-${probes++}', () => _Probe(completer));
    final wallet = await system.spawn(
        'wallet-${command.walletId}-${probes++}', () => aggregate(command.walletId));
    wallet.tell(command, sender: probe);
    return completer.future.timeout(const Duration(seconds: 10));
  }

  SignInputCommand signCommand(String walletId, String address,
          {int index = 0, AddressChain chain = AddressChain.receive, int inputIndex = 1, int sats = 12345}) =>
      SignInputCommand(
        walletId: walletId,
        rawTransaction: _unsignedTx().serialize(),
        inputIndex: inputIndex,
        subscriptHex: _p2pkh(address).toHex(),
        satoshis: BigInt.from(sats),
        derivationIndex: index,
        chain: chain,
      );

  test('mnemonic wallet: receive and change keys sign the input and report their public key',
      () async {
    const walletId = 'sign-input-mnemonic';
    final setup = await createWallet(
        walletId, CreateWalletCommand(walletId: walletId, walletName: 'w', mnemonic: _mnemonic));
    await setup.commandHandler(GenerateAddressCommand(walletId: walletId, label: 'r1'));
    final receive1 = setup.currentState.addresses.keys.last;
    await setup.commandHandler(GenerateAddressCommand(
        walletId: walletId, label: 'c2', purpose: BitcoinWalletAggregate.changePurpose));
    final change2 = setup.currentState.addresses.keys.last;
    final root = setup.currentState.rootAddress!;
    final eventsBefore = store.allEvents.length;

    for (final (address, index, chain) in [
      (root, 0, AddressChain.receive),
      (receive1, 1, AddressChain.receive),
      (change2, 2, AddressChain.change),
    ]) {
      final reply = await ask(signCommand(walletId, address, index: index, chain: chain));
      expect(reply.success, isTrue, reason: '$address: ${reply.error}');
      expect(reply.inputIndex, 1);
      final publicKey = dartsv.SVPublicKey.fromHex(reply.publicKeyHex);
      expect(_hash160(publicKey), dartsv.Address.fromBase58(address).pubkeyHash160,
          reason: 'the reported key is the one at m/${chain.index}/$index');
      final signature = dartsv.SVSignature.fromTxFormat(reply.signatureHex);
      _verifyP2pkhSpend(_unsignedTx(), 1, address, BigInt.from(12345), signature, publicKey);
      expect(
        () => _verifyP2pkhSpend(
            _unsignedTx(), 1, address, BigInt.from(12346), signature, publicKey),
        throwsA(anything),
        reason: 'the signature commits to the amount',
      );
    }
    expect(store.allEvents.length, eventsBefore, reason: 'signing journals nothing');
  });

  test('mnemonic wallet with a BIP39 passphrase signs with the passphrase-derived key', () async {
    const walletId = 'sign-input-passphrase';
    final setup = await createWallet(
        walletId,
        CreateWalletCommand(
            walletId: walletId, walletName: 'w', mnemonic: _mnemonic, passphrase: _passphrase));
    final root = setup.currentState.rootAddress!;

    final reply = await ask(signCommand(walletId, root, inputIndex: 0, sats: 777));
    expect(reply.success, isTrue, reason: reply.error);
    final publicKey = dartsv.SVPublicKey.fromHex(reply.publicKeyHex);
    expect(_hash160(publicKey), dartsv.Address.fromBase58(root).pubkeyHash160);
    _verifyP2pkhSpend(_unsignedTx(), 0, root, BigInt.from(777),
        dartsv.SVSignature.fromTxFormat(reply.signatureHex), publicKey);
  });

  test('WIF wallet signs with its single key whatever the path', () async {
    const walletId = 'sign-input-wif';
    final key = dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST);
    final setup = await createWallet(walletId,
        CreateWalletCommand(walletId: walletId, walletName: 'w', wif: key.toWIF(), walletMetadata: {
      'network': 'testnet',
    }));
    final root = setup.currentState.rootAddress!;

    final reply = await ask(signCommand(walletId, root, index: 9, chain: AddressChain.change));
    expect(reply.success, isTrue, reason: reply.error);
    expect(reply.publicKeyHex, key.publicKey.toHex());
    _verifyP2pkhSpend(_unsignedTx(), 1, root, BigInt.from(12345),
        dartsv.SVSignature.fromTxFormat(reply.signatureHex), key.publicKey);
  });

  test('watch-only (xpub) wallet is refused', () async {
    const walletId = 'sign-input-xpub';
    final hdPriv =
        await crypto.mnemonicToHDPrivateKey(_mnemonic, network: dartsv.NetworkType.TEST);
    final xpub = crypto.deriveHDPublicKey(hdPriv).xpubkey;
    final setup = await createWallet(
        walletId, CreateWalletCommand(walletId: walletId, walletName: 'w', xpub: xpub));

    final reply = await ask(signCommand(walletId, setup.currentState.rootAddress!));
    expect(reply.success, isFalse);
    expect(reply.signatureHex, isEmpty);
    expect(reply.error, contains('watch-only'));

    // Outside an actor system the command fails.
    await expectLater(
      setup.commandHandler(signCommand(walletId, setup.currentState.rootAddress!)),
      throwsA(isA<StateError>()),
    );
  });

  test('an input index outside the transaction is refused', () async {
    const walletId = 'sign-input-range';
    final setup = await createWallet(
        walletId, CreateWalletCommand(walletId: walletId, walletName: 'w', mnemonic: _mnemonic));
    final reply =
        await ask(signCommand(walletId, setup.currentState.rootAddress!, inputIndex: 2));
    expect(reply.success, isFalse);
    expect(reply.error, contains('out of range'));
  });
}

class _Probe extends Actor {
  final Completer<InputSignedResponse> completer;
  _Probe(this.completer);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is InputSignedResponse && !completer.isCompleted) {
      completer.complete(message);
    }
  }
}
