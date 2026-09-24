/// libspiffy-hvp: HD derivation threw `Bad state: Too few elements` for every
/// child private key with a leading zero byte (1 in 256 keys).
///
/// dartsv 3.0.0 `HDPrivateKey._deriveChildPrivateKey` writes the child key
/// with `paddedKey.setRange(1, 33, encodeBigIntSV(childKey))`; `encodeBigIntSV`
/// drops leading zero bytes, so a key below 2^248 is 31 bytes long and the
/// copy into the fixed 32-byte range throws. The public derivation path
/// (xpub, address generation) is not affected, so such a wallet handed out
/// addresses it could not sign for: the root address when m/0 or m/0/0 is
/// short, every change address when m/1 is short.
///
/// Every input below was found by a deterministic search (seeded entropy, a
/// counter over indexes) and throws on dartsv 3.0.0. Expected keys come from
/// the independent reference implementation in bip32_reference.dart.
///
/// These tests use only APIs that existed before the fix, so they run
/// unchanged against the old code.
library;

import 'dart:async';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:test/test.dart';
import 'package:libspiffy/src/models/address_chain.dart';

import '../actors/in_memory_event_store.dart';
import 'bip32_reference.dart';
import 'hd_leading_zero_fixtures.dart';

String _testnetAddress(String compressedPubHex) =>
    dartsv.SVPublicKey.fromHex(compressedPubHex)
        .toAddress(dartsv.NetworkType.TEST)
        .toBase58();

RefNode _refRoot(String mnemonic) =>
    refMaster(dartsv.Mnemonic().toSeedHex(mnemonic, ''));

void main() {
  final crypto = DartSVCryptoService();

  /// Derives m/{chain}/{index} through the service, checks it against the
  /// reference and against the address the wallet hands out for it.
  Future<void> expectServiceKey(dartsv.HDPrivateKey root, RefNode refRoot,
      {required int index, required AddressChain chain}) async {
    final path = 'm/${chain.index}/$index';
    final expected = refDerive(refRoot, path);
    final key = await crypto.derivePrivateKey(root, index, chain: chain);
    expect(key.toHex(), expected.keyHex, reason: 'private key at $path');
    expect(key.publicKey.getEncoded(true), expected.publicKeyHex);

    final xpub = crypto.deriveHDPublicKey(root);
    final handedOut = crypto.deriveAddress(xpub, index, chain: chain);
    expect(handedOut, _testnetAddress(expected.publicKeyHex),
        reason: 'the address the wallet hands out for $path');
    expect(key.toAddress(networkType: dartsv.NetworkType.TEST).toBase58(), handedOut,
        reason: 'the signing key matches the handed-out address');
  }

  group('libspiffy-hvp: child keys with a leading zero byte', () {
    test('a mnemonic whose receive key m/0/0 is short derives that key', () async {
      final root = await crypto.mnemonicToHDPrivateKey(kShortReceive00Mnemonic);
      final ref = _refRoot(kShortReceive00Mnemonic);
      expect(refDerive(ref, 'm/0/0').key.bitLength, lessThanOrEqualTo(248),
          reason: 'fixture: the key has a leading zero byte');
      await expectServiceKey(root, ref, index: 0, chain: AddressChain.receive);
    });

    test('a mnemonic whose receive chain key m/0 is short derives its receive keys',
        () async {
      final root = await crypto.mnemonicToHDPrivateKey(kShortReceiveChainMnemonic);
      final ref = _refRoot(kShortReceiveChainMnemonic);
      expect(refDerive(ref, 'm/0').key.bitLength, lessThanOrEqualTo(248),
          reason: 'fixture: the chain key has a leading zero byte');
      for (final index in [0, 1, 2]) {
        await expectServiceKey(root, ref, index: index, chain: AddressChain.receive);
      }
    });

    test('a mnemonic whose change chain key m/1 is short derives its change keys',
        () async {
      final root = await crypto.mnemonicToHDPrivateKey(kShortChangeChainMnemonic);
      final ref = _refRoot(kShortChangeChainMnemonic);
      expect(refDerive(ref, 'm/1').key.bitLength, lessThanOrEqualTo(248),
          reason: 'fixture: the chain key has a leading zero byte');
      for (final index in [0, 1, 2]) {
        await expectServiceKey(root, ref, index: index, chain: AddressChain.change);
      }
    });

    test('the fixed test mnemonic derives its short receive keys', () async {
      final root = await crypto.mnemonicToHDPrivateKey(kAbandonMnemonic);
      final ref = _refRoot(kAbandonMnemonic);
      for (final index in kAbandonShortReceiveIndexes) {
        expect(refDerive(ref, 'm/0/$index').key.bitLength, lessThanOrEqualTo(248),
            reason: 'fixture: m/0/$index has a leading zero byte');
        await expectServiceKey(root, ref, index: index, chain: AddressChain.receive);
      }
    });

    test('an xpriv wallet (HDPrivateKey.fromXpriv) derives a short key', () async {
      final master = dartsv.HDPrivateKey.fromXpriv(
          (await crypto.mnemonicToHDPrivateKey(kShortReceiveChainMnemonic)).xprivkey);
      await expectServiceKey(master, _refRoot(kShortReceiveChainMnemonic),
          index: 7, chain: AddressChain.receive);
    });

    test('near miss: a receive chain public key with a short x coordinate', () async {
      final root = dartsv.HDPrivateKey.fromSeed(kShortChainPubXSeed, dartsv.NetworkType.TEST);
      final ref = refMaster(kShortChainPubXSeed);
      expect(refDerive(ref, 'm/0').publicKeyHex.substring(2, 4), '00',
          reason: 'fixture: x of m/0 starts with a zero byte');
      for (final index in [0, 1]) {
        await expectServiceKey(root, ref, index: index, chain: AddressChain.receive);
      }
    });

    test('near miss: an imported xpriv whose private key is short', () async {
      final root = dartsv.HDPrivateKey.fromXpriv(
          dartsv.HDPrivateKey.fromSeed(kShortMasterSeed, dartsv.NetworkType.TEST).xprivkey);
      final ref = refMaster(kShortMasterSeed);
      expect(ref.key.bitLength, lessThanOrEqualTo(248),
          reason: 'fixture: the master key has a leading zero byte');
      expect(hex.encode(root.keyBuffer), '00${ref.keyHex}');
      for (final chain in [AddressChain.receive, AddressChain.change]) {
        await expectServiceKey(root, ref, index: 0, chain: chain);
      }
    });
  });

  group('libspiffy-hvp: wallet signing', () {
    late InMemoryEventStore store;
    late InMemorySecureStorage secureStorage;
    late TestActorSystem system;
    var probes = 0;

    setUp(() {
      store = InMemoryEventStore();
      secureStorage = InMemorySecureStorage();
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

    Future<InputSignedResponse> sign(String walletId, String address,
        {required int index, required AddressChain chain}) async {
      final tx = dartsv.Transaction()
        ..version = 1
        ..nLockTime = 0;
      tx.inputs.add(dartsv.TransactionInput('aa' * 32, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
      tx.outputs.add(dartsv.TransactionOutput(
          BigInt.from(1000),
          dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address))
              .getScriptPubkey()));
      final completer = Completer<InputSignedResponse>();
      final probe = await system.spawn('probe-${probes++}', () => _Probe(completer));
      final wallet =
          await system.spawn('wallet-$walletId-${probes++}', () => aggregate(walletId));
      wallet.tell(
          SignInputCommand(
            walletId: walletId,
            rawTransaction: tx.serialize(),
            inputIndex: 0,
            subscriptHex: dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address))
                .getScriptPubkey()
                .toHex(),
            satoshis: BigInt.from(5000),
            derivationIndex: index,
            chain: chain,
          ),
          sender: probe);
      return completer.future.timeout(const Duration(seconds: 10));
    }

    test('a wallet whose m/0 and m/1 keys are short signs for its root and change addresses',
        () async {
      for (final (walletId, mnemonic, isChange) in [
        ('hvp-receive-chain', kShortReceiveChainMnemonic, false),
        ('hvp-change-chain', kShortChangeChainMnemonic, true),
      ]) {
        final setup = aggregate(walletId);
        await setup.preStart();
        await setup.commandHandler(
            CreateWalletCommand(walletId: walletId, walletName: 'w', mnemonic: mnemonic));
        final changeIndex = setup.currentState.nextDerivationIndex;
        if (isChange) {
          await setup.commandHandler(GenerateAddressCommand(
              walletId: walletId, label: 'c', purpose: BitcoinWalletAggregate.changePurpose));
        }
        final address = isChange
            ? setup.currentState.addresses.keys.last
            : setup.currentState.rootAddress!;
        final index = isChange ? changeIndex : 0;
        final expected = refDerive(_refRoot(mnemonic), 'm/${isChange ? 1 : 0}/$index');
        expect(address, _testnetAddress(expected.publicKeyHex));

        final reply = await sign(walletId, address,
            index: index, chain: isChange ? AddressChain.change : AddressChain.receive);
        expect(reply.success, isTrue, reason: '$walletId: ${reply.error}');
        expect(reply.publicKeyHex, expected.publicKeyHex);
      }
    });
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
