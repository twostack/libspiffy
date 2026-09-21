/// 87a2 (libspiffy-87a2), wallet aggregate part: UTXOs at watch addresses.
///
/// A watch address is attributed to the wallet but the wallet holds no key
/// for it. A payment to it is a wallet UTXO; the aggregate's own selectors
/// (channel funding, Benford split initiation) chose it like any other, and
/// SignTransactionCommand signed it with whatever key the caller's
/// derivation index named (m/0/0 for a watch address row) until the script
/// interpreter refused the result.
///
/// Now the aggregate's selectors skip watch-only UTXOs, and signing refuses
/// an input at a watch address with a reason naming it. A bare multisig
/// UTXO over a watch address and enough wallet keys stays spendable, even
/// when it is attributed to the watch address.
library;

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';
import 'package:libspiffy/src/models/fee_rate.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _walletId = 'wallet-watch-only';

void main() {
  late TestActorSystem system;
  var spawned = 0;
  final watchKey = dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST).publicKey;
  final watchAddress = watchKey.toAddress(dartsv.NetworkType.TEST).toBase58();
  final external = dartsv.SVPrivateKey.fromHex('7a' * 32, dartsv.NetworkType.TEST)
      .publicKey
      .toAddress(dartsv.NetworkType.TEST)
      .toBase58();

  setUp(() => system = TestActorSystem());
  tearDown(() => system.shutdown());

  String p2pkh(String address) =>
      dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();

  /// A wallet (journal and aggregate) watching [watchAddress].
  Future<(InMemoryEventStore, InMemorySecureStorage, BitcoinWalletAggregate)> watchingWallet() async {
    final store = InMemoryEventStore();
    final secureStorage = InMemorySecureStorage();
    final wallet = BitcoinWalletAggregate(
      aggregateId: _walletId,
      aggregateType: 'BitcoinWallet',
      eventStore: store,
      cryptoService: DartSVCryptoService(),
      secureStorage: secureStorage,
    );
    await wallet.preStart();
    await wallet.commandHandler(CreateWalletCommand(walletId: _walletId, walletName: 'watching', mnemonic: _mnemonic));
    await wallet.commandHandler(AddWatchAddressCommand(walletId: _walletId, address: watchAddress, scriptType: 'p2pkh'));
    expect(wallet.currentState.watchAddresses, contains(watchAddress));
    return (store, secureStorage, wallet);
  }

  Future<void> receive(BitcoinWalletAggregate wallet, String txid, String scriptHex, String address, int sats,
          {Map<String, dynamic>? pluginMetadata}) =>
      wallet.commandHandler(ReceiveUTXOCommand(
        walletId: _walletId,
        txid: txid,
        vout: 0,
        satoshis: BigInt.from(sats),
        scriptPubKey: scriptHex,
        address: address,
        initialStatus: UTXOStatus.available,
        blockHeight: 800000,
        confirmations: 6,
        pluginMetadata: pluginMetadata,
      ));

  String unsignedSpend(String txid, int sats) {
    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    tx.inputs.add(dartsv.TransactionInput(txid, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    tx.outputs.add(dartsv.TransactionOutput(BigInt.from(sats), dartsv.SVScript.fromHex(p2pkh(external))));
    return tx.serialize();
  }

  Future<FundingTransactionBuiltResponse> buildFunding(
      InMemoryEventStore store, InMemorySecureStorage secureStorage, String changeAddress) async {
    final ActorRef walletRef = await system.spawn(
      'wallet-${spawned++}',
      () => BitcoinWalletAggregate(
        aggregateId: _walletId,
        aggregateType: 'BitcoinWallet',
        eventStore: store,
        cryptoService: DartSVCryptoService(),
        secureStorage: secureStorage,
      ),
    );
    final probe = await system.createProbe();
    walletRef.tell(
      BuildFundingTransactionCommand(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
        walletId: _walletId,
        correlationId: 'corr-$spawned',
        channelId: 'channel-watch',
        clientPubKeyHex: dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST).publicKey.toHex(),
        serverPubKeyHex: dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST).publicKey.toHex(),
        fundingAmountSats: 30000,
        changeAddressBase58: changeAddress,
      ),
      sender: probe.ref,
    );
    return probe.expectMsgType<FundingTransactionBuiltResponse>(timeout: const Duration(seconds: 10));
  }

  /// The aggregate's answer to [WalletSpendableUtxosQuery] (bead
  /// libspiffy-ypp), from a replayed instance.
  Future<WalletSpendableUtxosResponse> spendableUtxos(
      InMemoryEventStore store, InMemorySecureStorage secureStorage) async {
    final ActorRef walletRef = await system.spawn(
      'wallet-${spawned++}',
      () => BitcoinWalletAggregate(
        aggregateId: _walletId,
        aggregateType: 'BitcoinWallet',
        eventStore: store,
        cryptoService: DartSVCryptoService(),
        secureStorage: secureStorage,
      ),
    );
    final probe = await system.createProbe();
    walletRef.tell(WalletSpendableUtxosQuery(walletId: _walletId), sender: probe.ref);
    return probe.expectMsgType<WalletSpendableUtxosResponse>(timeout: const Duration(seconds: 10));
  }

  test('87a2: channel funding spends the derived UTXO, not a larger watch-address one, and the input verifies',
      () async {
    final (store, secureStorage, wallet) = await watchingWallet();
    final root = wallet.currentState.rootAddress!;
    await receive(wallet, 'b' * 64, p2pkh(watchAddress), watchAddress, 90000);
    await receive(wallet, 'c' * 64, p2pkh(root), root, 50000);

    final response = await buildFunding(store, secureStorage, root);

    expect(response.success, isTrue, reason: response.error);
    final tx = dartsv.Transaction.fromHex(response.fundingTxHex);
    expect(tx.inputs.map((i) => '${i.prevTxnId}:${i.prevTxnOutputIndex}'), ['${'c' * 64}:0']);
    dartsv.Interpreter().correctlySpends(tx.inputs.single.script!, dartsv.SVScript.fromHex(p2pkh(root)), tx, 0,
        {dartsv.VerifyFlag.SIGHASH_FORKID, dartsv.VerifyFlag.UTXO_AFTER_GENESIS}, dartsv.Coin.ofSat(BigInt.from(50000)));
  });

  test('87a2: channel funding from a wallet whose only UTXO is at a watch address is refused naming watch-only funds',
      () async {
    final (store, secureStorage, wallet) = await watchingWallet();
    await receive(wallet, 'b' * 64, p2pkh(watchAddress), watchAddress, 90000);

    final response = await buildFunding(store, secureStorage, wallet.currentState.rootAddress!);

    expect(response.success, isFalse);
    expect(response.error, contains('watch-only'));
  });

  test('87a2: SignTransactionCommand refuses an input at a watch address, with or without a derivation index',
      () async {
    final (_, _, wallet) = await watchingWallet();
    await receive(wallet, 'b' * 64, p2pkh(watchAddress), watchAddress, 90000);

    for (final indices in [const <int>[], const [0]]) {
      await expectLater(
        wallet.commandHandler(SignTransactionCommand(
          walletId: _walletId,
          transactionId: 'watch-spend',
          rawTransaction: unsignedSpend('b' * 64, 80000),
          utxoKeys: ['${'b' * 64}:0'],
          publicKeys: const [],
          derivationIndices: indices,
        )),
        throwsA(predicate((e) => '$e'.contains('watch address $watchAddress') && '$e'.contains('no key'),
            'an error naming the watch address')),
        reason: 'derivation indices $indices',
      );
    }
    expect(wallet.currentState.utxos['${'b' * 64}:0']!.status, UTXOStatus.available);
  });

  test('87a2: a P2PKH input whose derivation index names a key that does not control it is refused before signing',
      () async {
    final (_, _, wallet) = await watchingWallet();
    final root = wallet.currentState.rootAddress!;
    await receive(wallet, 'c' * 64, p2pkh(root), root, 50000);

    await expectLater(
      wallet.commandHandler(SignTransactionCommand(
        walletId: _walletId,
        transactionId: 'wrong-index',
        rawTransaction: unsignedSpend('c' * 64, 40000),
        utxoKeys: ['${'c' * 64}:0'],
        publicKeys: const [],
        derivationIndices: const [3], // the root address is m/0/0
      )),
      throwsA(predicate((e) => '$e'.contains('the wallet holds no key for it'), 'an error saying so')),
    );
  });

  test('87a2: a 1-of-2 multisig UTXO attributed to a watch address is signed with the wallet key', () async {
    final (store, _, wallet) = await watchingWallet();
    await wallet.commandHandler(GenerateAddressCommand(walletId: _walletId, includePublicKey: true));
    final walletKey = dartsv.SVPublicKey.fromHex(store.allEvents.whereType<AddressGeneratedEvent>().last.publicKeyHex!);
    final script = dartsv.P2MSLockBuilder([watchKey, walletKey], 1, sorting: false).getScriptPubkey();
    await receive(wallet, 'd' * 64, script.toHex(), watchAddress, 90000);

    // No derivation indices: the aggregate resolves the keys itself.
    await wallet.commandHandler(SignTransactionCommand(
      walletId: _walletId,
      transactionId: 'multisig-spend',
      rawTransaction: unsignedSpend('d' * 64, 80000),
      utxoKeys: ['${'d' * 64}:0'],
      publicKeys: const [],
    ));

    final signed = dartsv.Transaction.fromHex(store.allEvents.whereType<TransactionSignedEvent>().single.signedRawHex);
    dartsv.Interpreter().correctlySpends(signed.inputs.single.script!, script, signed, 0,
        {dartsv.VerifyFlag.SIGHASH_FORKID, dartsv.VerifyFlag.UTXO_AFTER_GENESIS}, dartsv.Coin.ofSat(BigInt.from(90000)));
  });

  test('87a2: a 2-of-2 multisig UTXO over a watch address and one wallet key is watch-only', () async {
    final (store, secureStorage, wallet) = await watchingWallet();
    await wallet.commandHandler(GenerateAddressCommand(walletId: _walletId, includePublicKey: true));
    final walletKey = dartsv.SVPublicKey.fromHex(store.allEvents.whereType<AddressGeneratedEvent>().last.publicKeyHex!);
    final script = dartsv.P2MSLockBuilder([watchKey, walletKey], 2, sorting: false).getScriptPubkey();
    // Not a wallet UTXO at all: the wallet holds one of the two keys it needs.
    await expectLater(receive(wallet, 'e' * 64, script.toHex(), watchAddress, 90000), throwsA(anything));
  });

  test('87a2: the aggregate\'s available UTXOs and Benford split initiation leave watch-address UTXOs out', () async {
    final (store, _, wallet) = await watchingWallet();
    final root = wallet.currentState.rootAddress!;
    await receive(wallet, 'b' * 64, p2pkh(watchAddress), watchAddress, 90000);

    expect(wallet.getAvailableUTXOs(wallet.currentState), isEmpty);
    await expectLater(
      wallet.commandHandler(SplitUTXOsToBenfordCommand(walletId: _walletId, targetUtxoCount: 3)),
      throwsA(predicate((e) => '$e'.contains('watch-only'), 'an error naming watch-only funds')),
    );

    await receive(wallet, 'c' * 64, p2pkh(root), root, 50000);
    expect(wallet.getAvailableUTXOs(wallet.currentState).map((u) => u.key), ['${'c' * 64}:0']);
    await wallet.commandHandler(SplitUTXOsToBenfordCommand(walletId: _walletId, targetUtxoCount: 3));
    expect(store.allEvents.whereType<UTXOSplitInitiatedEvent>().single.utxoKeysToSplit, ['${'c' * 64}:0']);
  });

  // Bead libspiffy-v29l. `WalletSpendableUtxosQuery`'s watch-only listing
  // filtered on `hasPluginMetadata` — any metadata at all — rather than on
  // `isPluginManaged`, the one rule bead libspiffy-ecy8 established for both
  // layers. Script-analysis metadata or a label alone therefore dropped a
  // watch-only UTXO out of the listing that exists to report it.
  test('v29l: the watch-only listing drops a plugin-managed UTXO, not one that merely carries metadata', () async {
    final (store, secureStorage, wallet) = await watchingWallet();
    await receive(wallet, 'b' * 64, p2pkh(watchAddress), watchAddress, 90000,
        pluginMetadata: {'scriptType': 'p2pkh', 'address': watchAddress, 'label': 'donations'});
    await receive(wallet, 'd' * 64, p2pkh(watchAddress), watchAddress, 70000,
        pluginMetadata: {'pluginId': 'token-protocol', 'tokenId': 't1'});

    final response = await spendableUtxos(store, secureStorage);

    expect(response.walletFound, isTrue);
    expect(response.spendable, isEmpty, reason: 'both are at the watch address');
    expect(response.watchOnly.map((u) => u.key), ['${'b' * 64}:0'],
        reason: 'script analysis or a label does not make a UTXO its plugin\'s; a pluginId does');
  });

  // Bead libspiffy-f4qy. The Benford split threw a bare 'No available UTXOs
  // to split' at a wallet whose only funds are a plugin's to spend, while
  // channel funding (V-85) named the exclusion. Both now walk the one reason
  // helper, WalletBalances.noneSelectableReason.
  test('f4qy: a split refused because every UTXO is plugin-managed says so', () async {
    final (_, _, wallet) = await watchingWallet();
    final root = wallet.currentState.rootAddress!;
    await receive(wallet, 'f' * 64, p2pkh(root), root, 90000,
        pluginMetadata: {'pluginId': 'token-protocol', 'tokenId': 't1'});

    expect(wallet.getAvailableUTXOs(wallet.currentState), isEmpty);
    await expectLater(
      wallet.commandHandler(SplitUTXOsToBenfordCommand(walletId: _walletId, targetUtxoCount: 3)),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('plugin-managed'))),
    );
  });
}
