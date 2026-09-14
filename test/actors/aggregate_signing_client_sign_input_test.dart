/// libspiffy-5sr: AggregateSigningClient's per-input path (plugin builds and
/// public-key lookup) signed through `SignMultisigTransactionCommand`, a
/// payment-channel command, and recovered the public key from a throwaway
/// signature. It now uses `SignInputCommand`, which returns the signing key's
/// public key.
///
/// The wallet manager is replaced by a forwarder that records every command
/// type it passes on to a real wallet aggregate, so the tests observe which
/// commands the client issues while the signatures stay real.
library;

import 'dart:async';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/aggregate_signing_client.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import 'in_memory_event_store.dart';

const _walletId = 'signing-client-wallet';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _externalAddress = 'n4VQ5YdHf7hLQ2gWQYYrcxoE5B7nWuDFNF'; // testnet

dartsv.SVScript _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey();

/// Stands in for the wallet manager: records each wallet command's type and
/// forwards the command to the aggregate with the original sender.
class _RecordingWalletManager extends Actor {
  final ActorRef wallet;
  final List<String> commandTypes = [];

  _RecordingWalletManager(this.wallet);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletCommandMessage) {
      commandTypes.add(message.command.runtimeType.toString());
      // The reply must reach the client's receiver, as through the real
      // wallet manager.
      // ignore: invalid_use_of_internal_member
      wallet.tell(message.command, sender: context.sender);
    }
  }
}

void main() {
  late TestActorSystem system;
  late _RecordingWalletManager manager;
  late AggregateSigningClient client;
  late String root;
  late String change2;

  setUp(() async {
    final store = InMemoryEventStore();
    final secureStorage = InMemorySecureStorage();
    final crypto = DartSVCryptoService();
    BitcoinWalletAggregate aggregate() => BitcoinWalletAggregate(
          aggregateId: _walletId,
          aggregateType: 'BitcoinWallet',
          eventStore: store,
          cryptoService: crypto,
          secureStorage: secureStorage,
        );

    final setup = aggregate();
    await setup.preStart();
    await setup.commandHandler(
        CreateWalletCommand(walletId: _walletId, walletName: 'client', mnemonic: _mnemonic));
    await setup.commandHandler(GenerateAddressCommand(walletId: _walletId, label: 'r1'));
    await setup.commandHandler(GenerateAddressCommand(
        walletId: _walletId, label: 'c2', purpose: BitcoinWalletAggregate.changePurpose));
    root = setup.currentState.rootAddress!;
    change2 = setup.currentState.addresses.keys.last;

    final storage = InMemoryWalletStorage();
    await storage.storeWallet(_walletId, 'client', rootAddress: root, networkType: 'testnet');
    for (final (address, index, isChange) in [(root, 0, false), (change2, 2, true)]) {
      await storage.upsertAddress(
        _walletId,
        AddressMetadata(
          address: address,
          scriptType: 'p2pkh',
          derivationPath: 'm/${isChange ? 1 : 0}/$index',
          derivationIndex: index,
          isChange: isChange,
          label: null,
          purpose: isChange ? 'change' : 'receive',
          firstUsedAt: null,
          lastUsedAt: null,
          usageCount: 0,
          balance: BigInt.zero,
          createdAt: DateTime.utc(2026),
          isWatched: true,
        ),
      );
    }

    system = TestActorSystem();
    final walletRef = await system.spawn('wallet', aggregate);
    manager = _RecordingWalletManager(walletRef);
    final managerRef = await system.spawn('wallet-manager', () => manager);
    client = AggregateSigningClient(
      system: system,
      walletManager: managerRef,
      storage: storage,
      replyTimeout: const Duration(seconds: 10),
    );
  });

  tearDown(() async {
    await system.shutdown();
  });

  test('publicKeyForAddress asks the aggregate with SignInputCommand', () async {
    final key = await client.publicKeyForAddress(_walletId, change2);

    expect(hex.encode(dartsv.hash160(hex.decode(key.getEncoded(true)))),
        dartsv.Address.fromBase58(change2).pubkeyHash160);
    expect(manager.commandTypes, isNotEmpty);
    expect(manager.commandTypes, isNot(contains('SignMultisigTransactionCommand')),
        reason: 'the payment-channel multisig command is not a signing primitive for '
            'wallet inputs');
    expect(manager.commandTypes.toSet(), {'SignInputCommand'});
  });

  test('a plugin-style build signs every input through SignInputCommand', () async {
    final rootKey = await client.publicKeyForAddress(_walletId, root);
    final changeKey = await client.publicKeyForAddress(_walletId, change2);
    manager.commandTypes.clear();

    final funded = [
      (txid: 'aa' * 32, vout: 1, address: root, key: rootKey, sats: BigInt.from(30000)),
      (txid: 'bb' * 32, vout: 0, address: change2, key: changeKey, sats: BigInt.from(15000)),
    ];

    final tx = await client.buildWithSigner<dartsv.Transaction>(
      walletId: _walletId,
      fallbackPath: const SigningPath(0),
      build: (signer) async {
        final builder = dartsv.TransactionBuilder();
        for (final f in funded) {
          builder.spendFromOutpointWithSigner(
            signer,
            dartsv.TransactionOutpoint(f.txid, f.vout, f.sats, _p2pkh(f.address)),
            dartsv.TransactionInput.MAX_SEQ_NUMBER,
            dartsv.P2PKHUnlockBuilder(f.key),
          );
        }
        builder
          ..spendToLockBuilder(
              dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(_externalAddress)),
              BigInt.from(40000))
          ..sendChangeToPKH(dartsv.Address.fromBase58(root))
          ..withFeePerKb(100);
        return builder.build(false);
      },
    );

    expect(manager.commandTypes, isNotEmpty);
    expect(manager.commandTypes, isNot(contains('SignMultisigTransactionCommand')));
    expect(manager.commandTypes.toSet(), {'SignInputCommand'});

    // Every input really spends its output.
    for (var i = 0; i < funded.length; i++) {
      final input = tx.inputs.indexWhere((inp) => inp.prevTxnId == funded[i].txid);
      dartsv.Interpreter().correctlySpends(
        tx.inputs[input].script!,
        _p2pkh(funded[i].address),
        tx,
        input,
        {dartsv.VerifyFlag.SIGHASH_FORKID, dartsv.VerifyFlag.UTXO_AFTER_GENESIS},
        dartsv.Coin.ofSat(funded[i].sats),
      );
    }
  });
}
