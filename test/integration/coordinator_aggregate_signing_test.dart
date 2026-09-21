/// Audit 2026-09-14 A-H8 (libspiffy-leo) and its consequences KM-4
/// (libspiffy-y4b), KM-5 (libspiffy-0im) and libspiffy-bu7.
///
/// PaymentCoordinatorActor and BenfordCoordinatorActor used to read key
/// material from secure storage and derive private keys themselves:
///   * the plugin path signed every funding input with the key of the first
///     selected UTXO (KM-4);
///   * only `xpriv ?? wif` was consulted, so wallets created from a mnemonic
///     (with or without a BIP39 passphrase) could not sign there (KM-5);
///   * keys and public keys were always derived on the receive chain
///     (m/0/i), whatever the address's chain (bu7).
///
/// Signing now goes through the wallet aggregate (the only holder of key
/// material). Each test drives the real WalletManagerActor and wallet
/// aggregate, and checks every signed input with the script interpreter.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar/isar.dart';
import 'package:spiffynode/spiffy_node.dart' show BlockHeader, Hash;
import 'package:test/test.dart';

import 'package:libspiffy/coordinator.dart' as coord;
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/benford_coordinator_actor.dart';
import 'package:libspiffy/src/actors/payment_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/plugin/provisioned_transaction.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';

import 'isar_test_helper.dart';
import '../mocks/network_arc.dart';
import 'package:libspiffy/src/core/wallet/transaction_size.dart';
import 'p2p_test_helpers.dart' show kTestXpriv, setupTestHeaders;

const _mnemonic =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const _passphrase = 'correct horse battery staple';
const _externalAddress = 'n4VQ5YdHf7hLQ2gWQYYrcxoE5B7nWuDFNF'; // testnet, not ours
const _pluginId = 'test_spend_all';

String _p2pkhScriptHex(String address) =>
    '76a914${dartsv.Address.fromBase58(address).pubkeyHash160}88ac';

String _fakeTxid(int n) => n.toRadixString(16).padLeft(64, 'c');

void main() {
  late Directory testDir;
  late Isar isar;
  late LocalActorSystem actorSystem;
  late LibSpiffyActorSystem libspiffy;
  late NetworkArc arc;

  /// Funded outpoints by key, so every signed input can be verified.
  late Map<String, ({String scriptHex, int satoshis})> funded;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    PluginRegistry().register(_SpendAllPlugin());
    funded = {};
    testDir = await Directory.systemTemp.createTemp('coordinator_signing_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: testDir.path,
      name: 'signing_${DateTime.now().microsecondsSinceEpoch}',
    );
    actorSystem = LocalActorSystem(ActorSystemConfig());
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: testDir.path,
      enableP2P: false,
      arcService: arc = NetworkArc(),
      secureStorage: InMemorySecureStorage(),
    );
    await setupTestHeaders(libspiffy.walletStorage as IsarWalletStorage);
  });

  tearDown(() async {
    PluginRegistry().unregister(_pluginId);
    await libspiffy.shutdown();
    if (await testDir.exists()) {
      await testDir.delete(recursive: true);
    }
  });

  // ---------------------------------------------------------------------------
  // Harness
  // ---------------------------------------------------------------------------

  Future<void> eventually(Future<bool> Function() condition, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for $what');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Creates a wallet from a mnemonic WITH a BIP39 passphrase. The wallet
  /// manager's CreateWalletMessage has no passphrase field, so the wallet is
  /// created by a short-lived aggregate on the shared journal; the wallet
  /// manager then loads it from the journal like any existing wallet.
  Future<String> createMnemonicWallet(String walletId) async {
    final seed = await actorSystem.spawn(
      'seed-wallet-$walletId',
      () => BitcoinWalletAggregate(
        aggregateId: walletId,
        aggregateType: 'BitcoinWallet',
        eventStore: libspiffy.eventStore,
        cryptoService: libspiffy.cryptoService,
        secureStorage: libspiffy.secureStorage,
      ),
    );
    final created = await _tellAndAwait<WalletCreatedResponse>(
      actorSystem,
      seed,
      CreateWalletCommand(
        walletId: walletId,
        walletName: 'Mnemonic + passphrase',
        mnemonic: _mnemonic,
        passphrase: _passphrase,
      ),
    );
    expect(created.success, isTrue, reason: created.error);
    await actorSystem.stop(seed);
    await eventually(
        () async => await libspiffy.walletStorage.getWallet(walletId) != null,
        'wallet $walletId in the read model');
    return created.rootAddress;
  }

  Future<String> createXprivWallet(String walletId) async {
    final created = await _tellAndAwait<WalletCreatedMessage>(
      actorSystem,
      libspiffy.walletManager,
      CreateWalletMessage(walletId, 'Xpriv wallet', xpriv: kTestXpriv),
    );
    expect(created.success, isTrue, reason: created.error);
    await eventually(
        () async => await libspiffy.walletStorage.getWallet(walletId) != null,
        'wallet $walletId in the read model');
    return created.rootAddress;
  }

  Future<String> generateAddress(String walletId, {String? purpose}) async {
    final response = await _tellAndAwait<AddressGeneratedResponse>(
      actorSystem,
      libspiffy.walletManager,
      WalletCommandMessage(walletId, GenerateAddressCommand(walletId: walletId, purpose: purpose)),
    );
    expect(response.success, isTrue, reason: response.error);
    await eventually(
        () async =>
            await libspiffy.walletStorage.getAddressMetadata(walletId, response.address) != null,
        'address ${response.address} in the read model');
    return response.address;
  }

  /// Gives [address] a spendable UTXO at a synthetic outpoint, locked by
  /// [scriptHex] (P2PKH to [address] by default).
  Future<String> fund(String walletId, String address,
      {required String txid, int vout = 0, required int satoshis, String? scriptHex}) async {
    final script = scriptHex ?? _p2pkhScriptHex(address);
    final received = await _tellAndAwait<UTXOReceivedResponse>(
      actorSystem,
      libspiffy.walletManager,
      WalletCommandMessage(
        walletId,
        ReceiveUTXOCommand(
          walletId: walletId,
          txid: txid,
          vout: vout,
          satoshis: BigInt.from(satoshis),
          scriptPubKey: script,
          address: address,
          blockHeight: 1239645,
          confirmations: 10,
          initialStatus: UTXOStatus.available,
        ),
      ),
    );
    expect(received.success, isTrue, reason: received.error);
    final key = '$txid:$vout';
    funded[key] = (scriptHex: script, satoshis: satoshis);
    await eventually(
        () async => (await libspiffy.walletStorage.getPaymentUTXOs(walletId))
            .any((u) => u.key == key),
        'UTXO $key to be spendable');
    return key;
  }

  /// Imports a confirmed parent (with a merkle proof) paying [satoshis] to
  /// [address] and makes its output spendable. Returns the parent txid.
  Future<String> fundWithImportedParent(String walletId, String address,
      {required int satoshis, int seed = 99, String? scriptHex}) async {
    final parent = dartsv.Transaction()
      ..version = 2
      ..nLockTime = 0;
    parent.inputs.add(
        dartsv.TransactionInput(_fakeTxid(seed), 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    parent.outputs.add(dartsv.TransactionOutput(
        BigInt.from(satoshis), dartsv.SVScript.fromHex(scriptHex ?? _p2pkhScriptHex(address))));
    final parentTxid = parent.id;
    // The parent is made up, so its block is too: a header of its own at a
    // height no test header uses, committing to the parent's BUMP. (At
    // 1239645, where the real testnet header is stored, the proof is one the
    // header chain contradicts and never goes into a BEEF: bead azl.)
    final blockHeight = 3000000 + seed;
    final bump = CryptoUtils.createBumpFromTscProof({
      'index': 0,
      'txOrId': parentTxid,
      'target': '00' * 32,
      'nodes': ['ab' * 32],
    }, blockHeight);
    await libspiffy.walletStorage.storeBlockHeader(
        BlockHeader(
          version: 536870912,
          prevBlock: Hash.fromHex('00' * 32),
          merkleRoot: Hash.fromBytes(bump.computeMerkleRoot(Uint8List.fromList(hex.decode(parentTxid).reversed.toList()))),
          timestamp: DateTime.utc(2026, 9, 15),
          bits: 0x1d00ffff,
          nonce: seed,
        ),
        blockHeight);
    libspiffy.walletManager.tell(WalletCommandMessage(
      walletId,
      RecordImportedTransactionCommand(
        walletId: walletId,
        txid: parentTxid,
        rawHex: parent.serialize(),
        blockHeight: blockHeight,
        bumpProofHex: hex.encode(bump.serialize()),
        totalOutputSats: satoshis,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 2,
        txLockTime: 0,
        walletReceivingAddresses: [address],
        walletReceivedSats: satoshis,
        totalInputSats: satoshis + 1000,
        sendingAddresses: const [],
      ),
    ));
    await eventually(
        () async =>
            (await libspiffy.walletStorage.getMerkleProofsBatch([parentTxid]))[parentTxid] !=
                null &&
            await libspiffy.walletStorage.getTransaction(parentTxid) != null,
        'the imported parent in the read model');
    await fund(walletId, address, txid: parentTxid, satoshis: satoshis, scriptHex: scriptHex);
    return parentTxid;
  }

  /// Makes the outputs of [tx] known to [verifyInputs], for transactions
  /// that spend other transactions built in the same payment.
  void registerOutputs(dartsv.Transaction tx) {
    for (var vout = 0; vout < tx.outputs.length; vout++) {
      funded['${tx.id}:$vout'] = (
        scriptHex: tx.outputs[vout].script.toHex(),
        satoshis: tx.outputs[vout].satoshis.toInt(),
      );
    }
  }

  /// Every input of [tx] must spend a funded outpoint and pass the script
  /// interpreter. Returns one line per failing input.
  List<String> verifyInputs(dartsv.Transaction tx) {
    final problems = <String>[];
    for (var i = 0; i < tx.inputs.length; i++) {
      final input = tx.inputs[i];
      final key = '${input.prevTxnId}:${input.prevTxnOutputIndex}';
      final spent = funded[key];
      if (spent == null) {
        problems.add('input $i spends $key, which the test did not fund');
        continue;
      }
      try {
        dartsv.Interpreter().correctlySpends(
          input.script!,
          dartsv.SVScript.fromHex(spent.scriptHex),
          tx,
          i,
          {dartsv.VerifyFlag.SIGHASH_FORKID, dartsv.VerifyFlag.UTXO_AFTER_GENESIS},
          dartsv.Coin.ofSat(BigInt.from(spent.satoshis)),
        );
      } catch (e) {
        problems.add('input $i ($key): $e');
      }
    }
    return problems;
  }

  Future<BEEFPaymentResponse> pay(PayInvoiceMessage message) =>
      _tellAndAwait<BEEFPaymentResponse>(
        actorSystem,
        libspiffy.paymentCoordinator,
        message,
        timeout: const Duration(seconds: 30),
      );

  PayInvoiceMessage pluginPayment(String walletId, int amount) => PayInvoiceMessage(
        walletId: walletId,
        invoiceId: 'plugin-${DateTime.now().microsecondsSinceEpoch}',
        addresses: const [],
        amount: BigInt.from(amount),
        outputs: [
          PluginOutputSpec(
            pluginId: _pluginId,
            pluginScriptType: 'p2pkh',
            params: const {'action': 'spend', 'to': _externalAddress},
            amount: BigInt.from(amount),
          ),
        ],
      );

  dartsv.Transaction primaryTx(BEEFPaymentResponse response) =>
      dartsv.Transaction.fromHex(hex.encode(BEEF.parse(response.beefBytes).txs.last));

  // ---------------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------------

  group('A-H8: coordinators sign through the wallet aggregate', () {
    test('(a) KM-5: a mnemonic wallet with a passphrase pays through the plugin path', () async {
      const walletId = 'mnemonic-plugin';
      final root = await createMnemonicWallet(walletId);
      await fund(walletId, root, txid: _fakeTxid(1), satoshis: 60000);

      final response = await pay(pluginPayment(walletId, 10000));
      expect(response.success, isTrue, reason: response.error);

      final tx = primaryTx(response);
      expect(tx.inputs, hasLength(1));
      expect(verifyInputs(tx), isEmpty);
    });

    test('(a) a mnemonic wallet with a passphrase pays an invoice on the standard BEEF path',
        () async {
      const walletId = 'mnemonic-standard';
      await createMnemonicWallet(walletId);
      final change = await generateAddress(walletId, purpose: 'change');
      // A confirmed parent with a proof, so the ancestor chain is complete.
      await fundWithImportedParent(walletId, change, satoshis: 60000);

      final response = await pay(PayInvoiceMessage(
        walletId: walletId,
        invoiceId: 'standard-${DateTime.now().microsecondsSinceEpoch}',
        addresses: const [_externalAddress],
        amount: BigInt.from(20000),
      ));
      expect(response.success, isTrue, reason: response.error);

      final tx = primaryTx(response);
      expect(tx.inputs, hasLength(1));
      expect(verifyInputs(tx), isEmpty);
    });

    test('(b) KM-4: a plugin payment funded from two addresses signs each input with its own key',
        () async {
      const walletId = 'xpriv-two-inputs';
      final root = await createXprivWallet(walletId);
      final second = await generateAddress(walletId);
      expect(second, isNot(equals(root)));
      await fund(walletId, root, txid: _fakeTxid(2), satoshis: 30000);
      await fund(walletId, second, txid: _fakeTxid(3), satoshis: 30000);

      final response = await pay(pluginPayment(walletId, 50000));
      expect(response.success, isTrue, reason: response.error);

      final tx = primaryTx(response);
      expect(tx.inputs, hasLength(2), reason: 'both UTXOs are needed for 50 000 sats');
      expect(verifyInputs(tx), isEmpty);
    });

    test('(c) bu7: a payment funded from a change address signs with the change-chain key',
        () async {
      const walletId = 'xpriv-change-input';
      await createXprivWallet(walletId);
      final change = await generateAddress(walletId, purpose: 'change');
      final metadata = await libspiffy.walletStorage.getAddressMetadata(walletId, change);
      expect(metadata!.isChange, isTrue);
      await fund(walletId, change, txid: _fakeTxid(4), satoshis: 60000);

      final response = await pay(pluginPayment(walletId, 10000));
      expect(response.success, isTrue, reason: response.error);

      final tx = primaryTx(response);
      expect(tx.inputs, hasLength(1));
      expect(verifyInputs(tx), isEmpty);
    });

    test('auto-provisioned plugin funding (split, earmarks, payment) is signed end to end',
        () async {
      // The plugin needs two funding UTXOs but one is selected, so the
      // coordinator builds a split and two earmark transactions first. The
      // earmarks spend the split and the payment spends the earmarks, so
      // their signatures depend on each other's txids.
      PluginRegistry().unregister(_pluginId);
      PluginRegistry().register(_SpendAllPlugin(requiredFunding: 2));

      const walletId = 'mnemonic-auto-provision';
      final root = await createMnemonicWallet(walletId);
      await fundWithImportedParent(walletId, root, satoshis: 80000);

      final response = await pay(pluginPayment(walletId, 10000));
      expect(response.success, isTrue, reason: response.error);

      final txs = BEEF
          .parse(response.beefBytes)
          .txs
          .map((bytes) => dartsv.Transaction.fromHex(hex.encode(bytes)))
          .toList();
      expect(txs, hasLength(4), reason: 'split, two earmarks, payment');
      final problems = <String>[];
      for (final tx in txs) {
        problems.addAll(verifyInputs(tx).map((p) => '${tx.id}: $p'));
        registerOutputs(tx);
      }
      expect(problems, isEmpty);
      expect(txs.last.inputs, hasLength(2));
    });

    // Bead libspiffy-lph4: the transactions the coordinator provisions for
    // a plugin pay ARC's policy rate on their signed size, the rate the
    // payment asked ARC for. They used 148-byte guesses at a hardcoded
    // 100 sat/kB, under a comment naming a different rate.
    test('lph4: the auto-provisioned split and earmarks pay ARC\'s policy rate on their signed size', () async {
      const rate = FeeRate(satoshis: 500, bytes: 1000);
      arc.miningFee = rate;
      PluginRegistry().unregister(_pluginId);
      PluginRegistry().register(_SpendAllPlugin(requiredFunding: 2));

      const walletId = 'lph4-auto-provision';
      final root = await createMnemonicWallet(walletId);
      await fundWithImportedParent(walletId, root, satoshis: 80000);

      final response = await pay(pluginPayment(walletId, 10000));
      expect(response.success, isTrue, reason: response.error);

      final txs = BEEF
          .parse(response.beefBytes)
          .txs
          .map((bytes) => dartsv.Transaction.fromHex(hex.encode(bytes)))
          .toList();
      expect(txs, hasLength(4), reason: 'split, two earmarks, payment');
      txs.forEach(registerOutputs);
      // The split and the two earmarks; the payment's fee is the plugin's.
      for (final tx in txs.take(3)) {
        final spent = tx.inputs.fold<BigInt>(BigInt.zero,
            (sum, i) => sum + BigInt.from(funded['${i.prevTxnId}:${i.prevTxnOutputIndex}']!.satoshis));
        final paid = spent - tx.outputs.fold<BigInt>(BigInt.zero, (sum, o) => sum + o.satoshis);
        final signedBytes = tx.serialize().length ~/ 2;
        // Old code: 100 sat/kB whatever ARC published.
        expect(paid, greaterThanOrEqualTo(rate.feeFor(signedBytes)),
            reason: '${tx.id}: a $signedBytes-byte signed transaction pays $paid');
        expect(paid, lessThanOrEqualTo(rate.feeFor(signedBytes + 2 * tx.inputs.length)),
            reason: '${tx.id}: paid for bytes the transaction does not have');
      }
    });

    test('ProvisionFundingMessage: a plugin provision from a mnemonic wallet is signed', () async {
      final plugin = _SpendAllPlugin();
      PluginRegistry().unregister(_pluginId);
      PluginRegistry().register(plugin);

      const walletId = 'mnemonic-provision';
      final root = await createMnemonicWallet(walletId);
      await fund(walletId, root, txid: _fakeTxid(6), satoshis: 50000);

      final response = await _tellAndAwait<ProvisionFundingResponse>(
        actorSystem,
        libspiffy.paymentCoordinator,
        ProvisionFundingMessage(walletId: walletId, pluginId: _pluginId, pluginParams: const {}),
        timeout: const Duration(seconds: 30),
      );
      expect(response.success, isTrue, reason: response.error);
      expect(response.transactionCount, equals(1));

      final split = plugin.lastProvision!;
      expect(await libspiffy.walletStorage.getTransaction(split.id), isNotNull,
          reason: 'the signed provision is recorded');
      expect(verifyInputs(split), isEmpty);
    });

    test('(d) KM-5: a Benford split from a mnemonic wallet with a passphrase is signed', () async {
      const walletId = 'mnemonic-benford';
      final root = await createMnemonicWallet(walletId);
      final sourceKey = await fund(walletId, root, txid: _fakeTxid(5), satoshis: 100000);

      final arc = _Recorder();
      final arcRef = await actorSystem.spawn('benford-test-arc', () => arc);
      final benford = await actorSystem.spawn(
        'benford-under-test',
        () => BenfordCoordinatorActor(
          walletManager: libspiffy.walletManager,
          arcActor: arcRef,
          secureStorage: libspiffy.secureStorage,
          storage: libspiffy.walletStorage,
        ),
      );

      final response = await _tellAndAwait<SplitUTXOsResponse>(
        actorSystem,
        benford,
        SplitUTXOsToBenfordCommand(walletId: walletId, targetUtxoCount: 3),
        timeout: const Duration(seconds: 30),
      );
      expect(response.success, isTrue, reason: response.error);
      expect(response.txids, hasLength(1), reason: 'the one funded UTXO must be split');

      final broadcasts = arc.received.whereType<BroadcastDeferredPaymentMessage>().toList();
      expect(broadcasts, hasLength(1));
      final tx = dartsv.Transaction.fromHex(broadcasts.single.rawTxHex);
      expect(tx.id, equals(response.txids!.single));
      expect(tx.outputs, hasLength(3));
      expect('${tx.inputs.single.prevTxnId}:${tx.inputs.single.prevTxnOutputIndex}',
          equals(sourceKey));
      expect(verifyInputs(tx), isEmpty);
    });
  });

  group('nlp: a bare multisig or P2PK UTXO the wallet can spend alone', () {
    /// Gives the wallet a UTXO locked by [scriptHex], attributed to
    /// [firstWalletAddress].
    Future<String> fundScript(String walletId, String scriptHex, String firstWalletAddress,
        {required String txid, required int satoshis}) async {
      final received = await _tellAndAwait<UTXOReceivedResponse>(
        actorSystem,
        libspiffy.walletManager,
        WalletCommandMessage(
          walletId,
          ReceiveUTXOCommand(
            walletId: walletId,
            txid: txid,
            vout: 0,
            satoshis: BigInt.from(satoshis),
            scriptPubKey: scriptHex,
            address: firstWalletAddress,
            blockHeight: 1239645,
            confirmations: 10,
            initialStatus: UTXOStatus.available,
          ),
        ),
      );
      expect(received.success, isTrue, reason: received.error);
      final key = '$txid:0';
      funded[key] = (scriptHex: scriptHex, satoshis: satoshis);
      await eventually(
          () async => (await libspiffy.walletStorage.getPaymentUTXOs(walletId)).any((u) => u.key == key),
          'UTXO $key to be spendable');
      return key;
    }

    /// Gives the wallet a UTXO locked by a bare multisig script over
    /// [keys] (in that order) needing [threshold] signatures.
    Future<String> fundMultisig(String walletId, List<dartsv.SVPublicKey> keys, int threshold,
            {required String txid, required int satoshis}) =>
        fundScript(walletId, dartsv.P2MSLockBuilder(keys, threshold, sorting: false).getScriptPubkey().toHex(),
            keys.first.toAddress(dartsv.NetworkType.TEST).toBase58(),
            txid: txid, satoshis: satoshis);

    final hd = dartsv.HDPrivateKey.fromXpriv(kTestXpriv);
    final rootKey = hd.deriveChildNumber(0).deriveChildNumber(0).privateKey.publicKey;
    final otherKey = dartsv.SVPrivateKey.fromHex('11' * 32, dartsv.NetworkType.TEST).publicKey;

    test('a Benford split of a 1-of-2 multisig UTXO is signed as multisig', () async {
      const walletId = 'nlp-benford';
      await createXprivWallet(walletId);
      final sourceKey = await fundMultisig(walletId, [rootKey, otherKey], 1, txid: _fakeTxid(20), satoshis: 100000);

      final arc = _Recorder();
      final arcRef = await actorSystem.spawn('nlp-benford-arc', () => arc);
      final benford = await actorSystem.spawn(
        'nlp-benford-under-test',
        () => BenfordCoordinatorActor(
          walletManager: libspiffy.walletManager,
          arcActor: arcRef,
          secureStorage: libspiffy.secureStorage,
          storage: libspiffy.walletStorage,
        ),
      );

      final response = await _tellAndAwait<SplitUTXOsResponse>(
        actorSystem,
        benford,
        SplitUTXOsToBenfordCommand(walletId: walletId, targetUtxoCount: 3),
        timeout: const Duration(seconds: 30),
      );
      expect(response.success, isTrue, reason: response.error);
      expect(response.txids, hasLength(1), reason: 'the multisig UTXO must be split');
      final tx = dartsv.Transaction.fromHex(
          arc.received.whereType<BroadcastDeferredPaymentMessage>().single.rawTxHex);
      expect('${tx.inputs.single.prevTxnId}:${tx.inputs.single.prevTxnOutputIndex}', sourceKey);
      expect(verifyInputs(tx), isEmpty);
    });

    test('a plugin payment is funded from P2PKH UTXOs only: plugins sign P2PKH inputs', () async {
      const walletId = 'nlp-plugin';
      final root = await createXprivWallet(walletId);
      await fundMultisig(walletId, [rootKey, otherKey], 1, txid: _fakeTxid(21), satoshis: 90000);
      final p2pkh = await fund(walletId, root, txid: _fakeTxid(22), satoshis: 40000);

      final response = await pay(pluginPayment(walletId, 10000));
      expect(response.success, isTrue, reason: response.error);

      final tx = primaryTx(response);
      expect(tx.inputs.map((i) => '${i.prevTxnId}:${i.prevTxnOutputIndex}'), [p2pkh]);
      expect(verifyInputs(tx), isEmpty);
    });

    test('a plugin payment is funded from a P2PKH UTXO, not a larger P2PK one', () async {
      const walletId = 'nlp-plugin-p2pk';
      final root = await createXprivWallet(walletId);
      await fundScript(walletId, '21${rootKey.toHex()}ac', root, txid: _fakeTxid(26), satoshis: 90000);
      final p2pkh = await fund(walletId, root, txid: _fakeTxid(27), satoshis: 40000);

      final response = await pay(pluginPayment(walletId, 10000));
      expect(response.success, isTrue, reason: response.error);

      final tx = primaryTx(response);
      expect(tx.inputs.map((i) => '${i.prevTxnId}:${i.prevTxnOutputIndex}'), [p2pkh]);
      expect(verifyInputs(tx), isEmpty);
    });

    // Bead libspiffy-0nfk: a plugin that spends its funding through
    // `PluginTransactionRequest.fundingInputs` — each output over its real
    // locking script, with the unlocking script the wallet writes — is
    // funded from bare multisig and P2PK outputs too, and an m-of-n input
    // gets all m of its signatures from the wallet aggregate.
    test('0nfk: a plugin spending through fundingInputs is funded by a 2-of-2 multisig and a P2PK UTXO, every input valid',
        () async {
      final plugin = _AnyOutputPlugin();
      PluginRegistry().unregister(_pluginId);
      PluginRegistry().register(plugin);
      const walletId = 'onfk-plugin';
      final root = await createXprivWallet(walletId);
      final secondAddress = await generateAddress(walletId);
      final secondKey = hd.deriveChildNumber(0).deriveChildNumber(1).privateKey.publicKey;
      expect(secondKey.toAddress(dartsv.NetworkType.TEST).toBase58(), secondAddress);
      final multisig = await fundMultisig(walletId, [rootKey, secondKey], 2, txid: _fakeTxid(40), satoshis: 40000);
      final p2pk = await fundScript(walletId, '21${rootKey.toHex()}ac', root, txid: _fakeTxid(41), satoshis: 40000);

      final response = await pay(pluginPayment(walletId, 60000));

      // Old code: `Insufficient funds ... bare multisig or P2PK UTXO(s)
      // cannot fund a plugin transaction`.
      expect(response.success, isTrue, reason: response.error);
      final tx = primaryTx(response);
      expect(tx.inputs.map((i) => '${i.prevTxnId}:${i.prevTxnOutputIndex}').toSet(), {multisig, p2pk});
      expect(verifyInputs(tx), isEmpty, reason: 'each input unlocks its own locking script');
      final twoOfTwo = tx.inputs.singleWhere((i) => '${i.prevTxnId}:${i.prevTxnOutputIndex}' == multisig);
      expect(twoOfTwo.script!.chunks, hasLength(3), reason: 'OP_0 and both signatures');
      expect(plugin.lastRequest!.fundingInputs.map((i) => i.signatures).toSet(), {2, 1});
      expect(plugin.lastRequest!.feeRate, arc.miningFee, reason: 'the plugin is handed ARC\'s policy rate');
    });

    test('0nfk: a plugin needing two funding UTXOs is auto-provisioned from a 2-of-2 multisig UTXO, every input valid',
        () async {
      final plugin = _AnyOutputPlugin(requiredFunding: 2);
      PluginRegistry().unregister(_pluginId);
      PluginRegistry().register(plugin);
      const walletId = 'onfk-auto-provision';
      await createXprivWallet(walletId);
      await generateAddress(walletId);
      final secondKey = hd.deriveChildNumber(0).deriveChildNumber(1).privateKey.publicKey;
      // A parent of its own: the split spends the source transaction.
      final multisigScript = dartsv.P2MSLockBuilder([rootKey, secondKey], 2, sorting: false).getScriptPubkey().toHex();
      final multisig = '${await fundWithImportedParent(walletId, rootKey.toAddress(dartsv.NetworkType.TEST).toBase58(), satoshis: 90000, seed: 43, scriptHex: multisigScript)}:0';

      final response = await pay(pluginPayment(walletId, 10000));

      expect(response.success, isTrue, reason: response.error);
      final txs = BEEF
          .parse(response.beefBytes)
          .txs
          .map((bytes) => dartsv.Transaction.fromHex(hex.encode(bytes)))
          .toList();
      expect(txs, hasLength(4), reason: 'split, two earmarks, payment');
      expect('${txs.first.inputs.single.prevTxnId}:${txs.first.inputs.single.prevTxnOutputIndex}', multisig);
      final problems = <String>[];
      for (final tx in txs) {
        problems.addAll(verifyInputs(tx).map((p) => '${tx.id}: $p'));
        registerOutputs(tx);
      }
      // The earmarks pay P2PKH: their funding inputs are spent as P2PKH, not
      // over the multisig script of the source they came from.
      expect(problems, isEmpty);
    });

    test('0nfk: a provision spends a 2-of-2 multisig UTXO through fundingInputs', () async {
      final plugin = _AnyOutputPlugin();
      PluginRegistry().unregister(_pluginId);
      PluginRegistry().register(plugin);
      const walletId = 'onfk-provision';
      await createXprivWallet(walletId);
      await generateAddress(walletId);
      final secondKey = hd.deriveChildNumber(0).deriveChildNumber(1).privateKey.publicKey;
      final multisig = await fundMultisig(walletId, [rootKey, secondKey], 2, txid: _fakeTxid(42), satoshis: 90000);

      final response = await _tellAndAwait<ProvisionFundingResponse>(
        actorSystem,
        libspiffy.paymentCoordinator,
        ProvisionFundingMessage(walletId: walletId, pluginId: _pluginId, pluginParams: const {}),
        timeout: const Duration(seconds: 30),
      );

      expect(response.success, isTrue, reason: response.error);
      final tx = plugin.lastProvision!;
      expect('${tx.inputs.single.prevTxnId}:${tx.inputs.single.prevTxnOutputIndex}', multisig);
      expect(verifyInputs(tx), isEmpty);
    });

    test('a plugin payment from a wallet whose only UTXO is multisig fails with the reason', () async {
      const walletId = 'nlp-plugin-only-multisig';
      await createXprivWallet(walletId);
      final multisigKey = await fundMultisig(walletId, [rootKey, otherKey], 1, txid: _fakeTxid(23), satoshis: 90000);

      final response = await pay(pluginPayment(walletId, 10000));
      expect(response.success, isFalse);
      expect(response.error, contains('multisig'));
      final utxo = (await libspiffy.walletStorage.getUTXOs(walletId)).singleWhere((u) => u.key == multisigKey);
      expect(utxo.status, UTXOStatus.available, reason: 'nothing was reserved');
    });

    test('ProvisionFundingMessage provisions from a P2PKH UTXO, not a larger multisig one', () async {
      final plugin = _SpendAllPlugin();
      PluginRegistry().unregister(_pluginId);
      PluginRegistry().register(plugin);

      const walletId = 'nlp-provision';
      final root = await createXprivWallet(walletId);
      await fundMultisig(walletId, [rootKey, otherKey], 1, txid: _fakeTxid(24), satoshis: 90000);
      final p2pkh = await fund(walletId, root, txid: _fakeTxid(25), satoshis: 50000);

      final response = await _tellAndAwait<ProvisionFundingResponse>(
        actorSystem,
        libspiffy.paymentCoordinator,
        ProvisionFundingMessage(walletId: walletId, pluginId: _pluginId, pluginParams: const {}),
        timeout: const Duration(seconds: 30),
      );
      expect(response.success, isTrue, reason: response.error);
      final split = plugin.lastProvision!;
      expect('${split.inputs.single.prevTxnId}:${split.inputs.single.prevTxnOutputIndex}', p2pkh);
      expect(verifyInputs(split), isEmpty);
    });
  });

  group('87a2: UTXOs at watch addresses are watch-only funds', () {
    /// A key the wallet does not hold; its address is watched.
    final watchKey = dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST).publicKey;
    final watchAddress = watchKey.toAddress(dartsv.NetworkType.TEST).toBase58();
    final hd = dartsv.HDPrivateKey.fromXpriv(kTestXpriv);
    final rootKey = hd.deriveChildNumber(0).deriveChildNumber(0).privateKey.publicKey;

    Future<void> watch(String walletId, String address) async {
      final response = await _tellAndAwait<WatchAddressAddedResponse>(
        actorSystem,
        libspiffy.walletManager,
        WalletCommandMessage(walletId, AddWatchAddressCommand(walletId: walletId, address: address, scriptType: 'p2pkh')),
      );
      expect(response.success, isTrue, reason: response.error);
      await eventually(
          () async => (await libspiffy.walletStorage.getAddressMetadata(walletId, address))?.purpose == 'watch',
          'watch address $address in the read model');
    }

    Future<coord.BalanceResponse> balance(String walletId) async {
      final queryId = 'balance-${DateTime.now().microsecondsSinceEpoch}';
      final response = libspiffy.coordinatorEvents!
          .where((e) => e is coord.BalanceResponse && e.queryId == queryId)
          .cast<coord.BalanceResponse>()
          .first
          .timeout(const Duration(seconds: 10));
      libspiffy.coordinator.tell(coord.GetBalanceQuery(walletId: walletId, queryId: queryId));
      return response;
    }

    test('a payment from a wallet with a small derived UTXO and a larger watch-address UTXO spends the derived one',
        () async {
      const walletId = 'watch-standard';
      final root = await createXprivWallet(walletId);
      await watch(walletId, watchAddress);
      final watched = await fundWithImportedParent(walletId, watchAddress, satoshis: 90000, seed: 40);
      final derived = await fundWithImportedParent(walletId, root, satoshis: 40000, seed: 41);

      final response = await pay(PayInvoiceMessage(
        walletId: walletId,
        invoiceId: 'watch-standard-${DateTime.now().microsecondsSinceEpoch}',
        addresses: const [_externalAddress],
        amount: BigInt.from(20000),
      ));
      expect(response.success, isTrue, reason: response.error);

      final tx = primaryTx(response);
      expect(tx.inputs.map((i) => '${i.prevTxnId}:${i.prevTxnOutputIndex}'), ['$derived:0']);
      expect(verifyInputs(tx), isEmpty);
      final watchUtxo = (await libspiffy.walletStorage.getUTXOs(walletId)).singleWhere((u) => u.key == '$watched:0');
      expect(watchUtxo.status, UTXOStatus.available, reason: 'the watch-only UTXO is kept, untouched');
    });

    test('a payment from a wallet whose only UTXO is at a watch address fails naming watch-only funds', () async {
      const walletId = 'watch-only-standard';
      await createXprivWallet(walletId);
      await watch(walletId, watchAddress);
      final watched = await fundWithImportedParent(walletId, watchAddress, satoshis: 90000, seed: 42);

      final started = DateTime.now();
      final response = await pay(PayInvoiceMessage(
        walletId: walletId,
        invoiceId: 'watch-only-${DateTime.now().microsecondsSinceEpoch}',
        addresses: const [_externalAddress],
        amount: BigInt.from(20000),
      ));
      expect(response.success, isFalse);
      expect(response.error, contains('watch-only'));
      expect(response.error, startsWith('Insufficient funds'), reason: 'refused at selection, not at signing');
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 5)));
      final utxo = (await libspiffy.walletStorage.getUTXOs(walletId)).singleWhere((u) => u.key == '$watched:0');
      expect(utxo.status, UTXOStatus.available, reason: 'nothing was reserved');
    });

    test('the balance leaves watch-address UTXOs out of the spendable total and reports them apart', () async {
      const walletId = 'watch-balance';
      final root = await createXprivWallet(walletId);
      await watch(walletId, watchAddress);
      await fund(walletId, watchAddress, txid: _fakeTxid(40), satoshis: 90000);
      await fund(walletId, root, txid: _fakeTxid(41), satoshis: 40000);

      final response = await balance(walletId);
      expect(response.totalBalance, BigInt.from(40000));
      expect(response.confirmedBalance + response.unconfirmedBalance, BigInt.from(40000));
      expect(response.watchOnlyBalance, BigInt.from(90000));
    });

    test('ecy8: the balance counts a UTXO whose plugin metadata names no pluginId and leaves out an earmark',
        () async {
      const walletId = 'plugin-metadata-balance';
      final root = await createXprivWallet(walletId);
      await fund(walletId, root, txid: _fakeTxid(44), satoshis: 40000);
      for (final (n, sats, metadata) in [
        (45, 3000, <String, dynamic>{'purpose': 'label only'}),
        (46, 5000, <String, dynamic>{'pluginId': 'funding-earmark', 'purpose': 'mint'}),
      ]) {
        final received = await _tellAndAwait<UTXOReceivedResponse>(
          actorSystem,
          libspiffy.walletManager,
          WalletCommandMessage(
            walletId,
            ReceiveUTXOCommand(
              walletId: walletId,
              txid: _fakeTxid(n),
              vout: 0,
              satoshis: BigInt.from(sats),
              scriptPubKey: _p2pkhScriptHex(root),
              address: root,
              blockHeight: 1239645,
              confirmations: 10,
              initialStatus: UTXOStatus.available,
              pluginMetadata: metadata,
            ),
          ),
        );
        expect(received.success, isTrue, reason: received.error);
      }
      await eventually(() async => (await libspiffy.walletStorage.getUTXOs(walletId)).length == 3, 'three UTXO rows');

      final response = await balance(walletId);
      expect(response.totalBalance, BigInt.from(43000));
      expect((await libspiffy.walletStorage.getUTXOsByPlugin(walletId, 'funding-earmark')).map((u) => u.key),
          ['${_fakeTxid(46)}:0']);
    });

    test('the wallet refuses to sign an input at a watch address, naming it', () async {
      const walletId = 'watch-sign';
      await createXprivWallet(walletId);
      await watch(walletId, watchAddress);
      final key = await fund(walletId, watchAddress, txid: _fakeTxid(43), satoshis: 90000);

      final unsigned = dartsv.Transaction()
        ..version = 1
        ..nLockTime = 0;
      unsigned.inputs.add(dartsv.TransactionInput(_fakeTxid(43), 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
      unsigned.outputs.add(dartsv.TransactionOutput(
          BigInt.from(80000), dartsv.SVScript.fromHex(_p2pkhScriptHex(_externalAddress))));
      // The read model's path for a watch address row is index 0 on the
      // receive chain, which the aggregate used to sign with.
      final response = await _tellAndAwait<TransactionSignedResponse>(
        actorSystem,
        libspiffy.walletManager,
        WalletCommandMessage(
          walletId,
          SignTransactionCommand(
            walletId: walletId,
            transactionId: unsigned.id,
            rawTransaction: unsigned.serialize(),
            utxoKeys: [key],
            publicKeys: const [],
            addresses: [watchAddress],
            derivationIndices: const [0],
            isChangeFlags: const [false],
          ),
        ),
      );
      expect(response.success, isFalse);
      expect(response.error, contains('watch address $watchAddress'));
      expect(response.error, contains('no key'));
    });

    test('a plugin payment is funded from a derived UTXO, not a larger watch-address one', () async {
      const walletId = 'watch-plugin';
      final root = await createXprivWallet(walletId);
      await watch(walletId, watchAddress);
      await fund(walletId, watchAddress, txid: _fakeTxid(44), satoshis: 90000);
      final derived = await fund(walletId, root, txid: _fakeTxid(45), satoshis: 40000);

      final response = await pay(pluginPayment(walletId, 10000));
      expect(response.success, isTrue, reason: response.error);

      final tx = primaryTx(response);
      expect(tx.inputs.map((i) => '${i.prevTxnId}:${i.prevTxnOutputIndex}'), [derived]);
      expect(verifyInputs(tx), isEmpty);
    });

    test('ProvisionFundingMessage provisions from a derived UTXO, not a larger watch-address one', () async {
      final plugin = _SpendAllPlugin();
      PluginRegistry().unregister(_pluginId);
      PluginRegistry().register(plugin);

      const walletId = 'watch-provision';
      final root = await createXprivWallet(walletId);
      await watch(walletId, watchAddress);
      await fund(walletId, watchAddress, txid: _fakeTxid(46), satoshis: 90000);
      final derived = await fund(walletId, root, txid: _fakeTxid(47), satoshis: 50000);

      final response = await _tellAndAwait<ProvisionFundingResponse>(
        actorSystem,
        libspiffy.paymentCoordinator,
        ProvisionFundingMessage(walletId: walletId, pluginId: _pluginId, pluginParams: const {}),
        timeout: const Duration(seconds: 30),
      );
      expect(response.success, isTrue, reason: response.error);
      final split = plugin.lastProvision!;
      expect('${split.inputs.single.prevTxnId}:${split.inputs.single.prevTxnOutputIndex}', derived);
      expect(verifyInputs(split), isEmpty);
    });

    Future<(SplitUTXOsResponse, _Recorder)> split(String walletId) async {
      final arc = _Recorder();
      final arcRef = await actorSystem.spawn('watch-benford-arc-$walletId', () => arc);
      final benford = await actorSystem.spawn(
        'watch-benford-$walletId',
        () => BenfordCoordinatorActor(
          walletManager: libspiffy.walletManager,
          arcActor: arcRef,
          secureStorage: libspiffy.secureStorage,
          storage: libspiffy.walletStorage,
        ),
      );
      final response = await _tellAndAwait<SplitUTXOsResponse>(
        actorSystem,
        benford,
        SplitUTXOsToBenfordCommand(walletId: walletId, targetUtxoCount: 3),
        timeout: const Duration(seconds: 30),
      );
      return (response, arc);
    }

    test('a Benford split of a wallet whose only UTXO is at a watch address is refused naming watch-only funds',
        () async {
      const walletId = 'watch-benford';
      await createXprivWallet(walletId);
      await watch(walletId, watchAddress);
      await fund(walletId, watchAddress, txid: _fakeTxid(48), satoshis: 90000);

      final (response, arc) = await split(walletId);
      expect(response.success, isFalse);
      expect(response.error, contains('watch-only'));
      expect(arc.received.whereType<BroadcastDeferredPaymentMessage>(), isEmpty);
    });

    test('a 1-of-2 multisig UTXO over a watch address and a wallet key is still spent (the wallet signs it alone)',
        () async {
      const walletId = 'watch-multisig';
      await createXprivWallet(walletId);
      await watch(walletId, watchAddress);
      final scriptHex = dartsv.P2MSLockBuilder([watchKey, rootKey], 1, sorting: false).getScriptPubkey().toHex();
      // Attributed to the first owned key's address, the watch address, as
      // the receive path does.
      final received = await _tellAndAwait<UTXOReceivedResponse>(
        actorSystem,
        libspiffy.walletManager,
        WalletCommandMessage(
          walletId,
          ReceiveUTXOCommand(
            walletId: walletId,
            txid: _fakeTxid(49),
            vout: 0,
            satoshis: BigInt.from(100000),
            scriptPubKey: scriptHex,
            address: watchAddress,
            blockHeight: 1239645,
            confirmations: 10,
            initialStatus: UTXOStatus.available,
          ),
        ),
      );
      expect(received.success, isTrue, reason: received.error);
      final key = '${_fakeTxid(49)}:0';
      funded[key] = (scriptHex: scriptHex, satoshis: 100000);
      await eventually(() async => (await libspiffy.walletStorage.getPaymentUTXOs(walletId)).any((u) => u.key == key),
          'multisig UTXO projected');

      expect((await balance(walletId)).totalBalance, BigInt.from(100000));
      final (response, arc) = await split(walletId);
      expect(response.success, isTrue, reason: response.error);
      final tx = dartsv.Transaction.fromHex(arc.received.whereType<BroadcastDeferredPaymentMessage>().single.rawTxHex);
      expect('${tx.inputs.single.prevTxnId}:${tx.inputs.single.prevTxnOutputIndex}', key);
      expect(verifyInputs(tx), isEmpty);
    });
  });
}

/// Plugin whose transaction spends every funding UTXO to one P2PKH output,
/// signing each input with the signer libspiffy provides.
class _SpendAllPlugin extends TransactionBuilderPlugin {
  final int requiredFunding;

  /// The transaction built by the last [provisionFunding] call.
  dartsv.Transaction? lastProvision;

  _SpendAllPlugin({this.requiredFunding = 1});

  @override
  int requiredFundingUtxoCount(String action) => requiredFunding;

  /// Splits the single funding UTXO into two outputs back to its address.
  @override
  Future<List<ProvisionedTransaction>> provisionFunding(PluginTransactionRequest request) async {
    final utxo = request.fundingUtxos.single;
    final address = dartsv.Address.fromBase58(utxo.address);
    final script = dartsv.P2PKHLockBuilder.fromAddress(address).getScriptPubkey();
    const fee = 500;
    final half = (utxo.satoshis - BigInt.from(fee)) ~/ BigInt.two;
    final tx = (dartsv.TransactionBuilder()
          ..spendFromOutpointWithSigner(
            request.signer,
            dartsv.TransactionOutpoint(utxo.txid, utxo.vout, utxo.satoshis, script),
            dartsv.TransactionInput.MAX_SEQ_NUMBER,
            dartsv.P2PKHUnlockBuilder(request.publicKeys.single),
          )
          ..spendToLockBuilder(dartsv.P2PKHLockBuilder.fromAddress(address), half)
          ..spendToLockBuilder(dartsv.P2PKHLockBuilder.fromAddress(address), half))
        .build(false);
    lastProvision = tx;
    return [
      ProvisionedTransaction(
        txid: tx.id,
        rawHex: tx.serialize(),
        feeSats: fee,
        role: 'split',
        fundingVout: -1,
        fundingSats: -1,
      ),
    ];
  }

  @override
  String get pluginId => _pluginId;
  @override
  String get displayName => 'Spend all (test)';
  @override
  List<String> get scriptTypes => const ['p2pkh'];
  @override
  List<String> get supportedActions => const ['spend'];
  @override
  String? identifyScript(dartsv.SVScript script) => null;
  @override
  Map<String, dynamic>? extractMetadata(dartsv.SVScript script) => null;
  @override
  dartsv.LockingScriptBuilder? createLockBuilder(PluginOutputSpec spec) => null;
  @override
  dartsv.UnlockingScriptBuilder? createUnlockBuilder(PluginUnlockSpec spec) => null;
  @override
  bool validateTransactionStructure(dartsv.Transaction tx, String action) => true;

  @override
  Future<TransactionBuilderResult> buildTransaction(PluginTransactionRequest request) async {
    final builder = dartsv.TransactionBuilder();
    var total = BigInt.zero;
    for (var i = 0; i < request.fundingUtxos.length; i++) {
      final utxo = request.fundingUtxos[i];
      total += utxo.satoshis;
      final script = dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(utxo.address))
          .getScriptPubkey();
      builder.spendFromOutpointWithSigner(
        request.signer,
        dartsv.TransactionOutpoint(utxo.txid, utxo.vout, utxo.satoshis, script),
        dartsv.TransactionInput.MAX_SEQ_NUMBER,
        dartsv.P2PKHUnlockBuilder(request.publicKeys[i]),
      );
    }
    const fee = 500;
    builder.spendToLockBuilder(
      dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(request.params['to'] as String)),
      total - BigInt.from(fee),
    );
    return TransactionBuilderResult(
      primaryTx: builder.build(false),
      primaryFeeSats: BigInt.from(fee),
    );
  }
}

/// A [_SpendAllPlugin] that spends its funding through
/// [PluginTransactionRequest.fundingInputs] and says so (bead
/// libspiffy-0nfk), paying the request's policy rate on its signed size.
class _AnyOutputPlugin extends _SpendAllPlugin {
  _AnyOutputPlugin({super.requiredFunding});

  /// The request of the last [buildTransaction] call.
  PluginTransactionRequest? lastRequest;

  @override
  bool get spendsAnyWalletOutput => true;

  @override
  Future<TransactionBuilderResult> buildTransaction(PluginTransactionRequest request) async {
    lastRequest = request;
    final builder = dartsv.TransactionBuilder();
    var total = BigInt.zero;
    for (final input in request.fundingInputs) {
      total += input.utxo.satoshis;
      builder.spendFromOutpointWithSigner(
          request.signer, input.outpoint, dartsv.TransactionInput.MAX_SEQ_NUMBER, input.newUnlocker());
    }
    final fee = request.feeRate.feeFor(TransactionSize.of(
      inputLockingScripts: [for (final input in request.fundingInputs) input.lockingScript.toHex()],
      outputScriptBytes: const [TransactionSize.p2pkhScriptBytes],
    ));
    builder.spendToLockBuilder(
      dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(request.params['to'] as String)),
      total - fee,
    );
    return TransactionBuilderResult(primaryTx: builder.build(false), primaryFeeSats: fee);
  }

  /// Splits the single funding UTXO into two outputs back to its address.
  @override
  Future<List<ProvisionedTransaction>> provisionFunding(PluginTransactionRequest request) async {
    final input = request.fundingInputs.single;
    final address = dartsv.Address.fromBase58(input.utxo.address);
    final fee = request.feeRate.feeFor(TransactionSize.of(
      inputLockingScripts: [input.lockingScript.toHex()],
      outputScriptBytes: const [TransactionSize.p2pkhScriptBytes, TransactionSize.p2pkhScriptBytes],
    ));
    final half = (input.utxo.satoshis - fee) ~/ BigInt.two;
    final tx = (dartsv.TransactionBuilder()
          ..spendFromOutpointWithSigner(
              request.signer, input.outpoint, dartsv.TransactionInput.MAX_SEQ_NUMBER, input.newUnlocker())
          ..spendToLockBuilder(dartsv.P2PKHLockBuilder.fromAddress(address), half)
          ..spendToLockBuilder(dartsv.P2PKHLockBuilder.fromAddress(address), input.utxo.satoshis - fee - half))
        .build(false);
    lastProvision = tx;
    return [
      ProvisionedTransaction(
        txid: tx.id,
        rawHex: tx.serialize(),
        feeSats: fee.toInt(),
        role: 'split',
        fundingVout: -1,
        fundingSats: -1,
      ),
    ];
  }
}

class _Recorder extends Actor {
  final List<dynamic> received = [];
  @override
  Future<void> onMessage(dynamic message) async {
    received.add(message);
    // ARC's published policy rate, which every split pays (bead
    // libspiffy-lph4).
    if (message is GetFeeRateMessage) {
      // ignore: invalid_use_of_internal_member
      context.sender?.tell(FeeRateQuote(const FeeRate(satoshis: 100, bytes: 1000)));
    }
    // The Benford coordinator waits for ARC's answer (bead libspiffy-wdch).
    if (message is BroadcastDeferredPaymentMessage) {
      // ignore: invalid_use_of_internal_member
      context.sender?.tell(DeferredPaymentNetworkResult(
          walletId: message.walletId, txid: message.txid, success: true, networkStatus: 'SEEN_ON_NETWORK'));
    }
  }
}

/// Sends [message] to [target] from a throwaway receiver and returns the
/// first reply of type [T].
Future<T> _tellAndAwait<T>(ActorSystem system, ActorRef target, Message message,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final completer = Completer<T>();
  final receiver = await system.spawn(
    'receiver-${T.toString()}-${DateTime.now().microsecondsSinceEpoch}',
    () => _TypedReceiver<T>(completer),
  );
  try {
    target.tell(message, sender: receiver);
    return await completer.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException('No $T reply within $timeout'),
    );
  } finally {
    await system.stop(receiver);
  }
}

class _TypedReceiver<T> extends Actor {
  final Completer<T> completer;
  _TypedReceiver(this.completer);

  @override
  Future<void> onMessage(dynamic message) async {
    final payload = message is LocalMessage ? message.payload : message;
    if (payload is T && !completer.isCompleted) {
      completer.complete(payload);
    }
  }
}
