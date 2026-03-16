/// Full TSL1 NFT Token Lifecycle via Coordinator API
///
/// Models tstokenlib's integration_test.dart:
///   Issue → Witness → Transfer → Witness → Transfer → Witness → Burn
///
/// Two parties (Bob and Alice), each with their own LibSpiffy instance.
/// Every token operation goes through PayInvoiceCommand with PluginOutputSpec.
/// The plugin receives a CallbackTransactionSigner — private keys never
/// leave the wallet aggregate.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar/isar.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';
import 'package:tstokenlib/src/crypto/rabin.dart';

import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/coordinator.dart';

import 'package:libspiffy/internals.dart' as internal;

import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

/// Fund a wallet with a synthetic UTXO at a unique txid.
Future<void> addSyntheticUtxo({
  required ActorRef walletManager,
  required String walletId,
  required String address,
  required int index,
}) async {
  final fakeTxid = 'synthetic${index.toString().padLeft(56, '0')}';
  walletManager.tell(WalletCommandMessage(
    walletId,
    internal.ReceiveUTXOCommand(
      walletId: walletId,
      txid: fakeTxid,
      vout: 0,
      satoshis: BigInt.from(1000000000),
      scriptPubKey: '76a914${address}88ac',
      address: address,
      blockHeight: 100000,
      confirmations: 10,
      initialStatus: UTXOStatus.available,
    ),
  ));
  await Future.delayed(const Duration(milliseconds: 100));
}

/// Extract the raw transaction bytes from a minimal BEEF wrapper.
/// Format: version(4) + nBUMPs(1) + nTxs(1) + hasBUMP(1) + rawTx
Uint8List _extractTxFromMinimalBeef(Uint8List beef) {
  // Skip: 4 bytes version + 1 byte nBUMPs + 1 byte nTxs + 1 byte hasBUMP = 7 bytes
  return Uint8List.fromList(beef.sublist(7));
}

Stream<T> ofType<T extends CoordinatorEvent>(Stream<CoordinatorEvent> stream) {
  final controller = StreamController<T>.broadcast();
  stream.listen((e) {
    if (e is T) controller.add(e);
  });
  return controller.stream;
}

// ==========================================================================
// Plugin: handles all four token actions
// ==========================================================================

class TsTokenNftPlugin extends TransactionBuilderPlugin {
  final TokenTool _tokenTool;
  final List<int> rabinPubKeyHash;
  final List<int> rabinNBytes;
  final List<int> rabinSBytes;
  final int rabinPaddingValue;
  final List<int> identityTxId;
  final List<int> ed25519PubKey;

  TsTokenNftPlugin({
    dartsv.NetworkType networkType = dartsv.NetworkType.TEST,
    required this.rabinPubKeyHash,
    required this.rabinNBytes,
    required this.rabinSBytes,
    required this.rabinPaddingValue,
    required this.identityTxId,
    required this.ed25519PubKey,
  }) : _tokenTool = TokenTool(networkType: networkType);

  @override
  String get pluginId => 'tstoken_nft';
  @override
  String get displayName => 'TSL1 NFT Tokens';
  @override
  List<String> get scriptTypes => ['pp1_nft', 'pp2', 'pp3_witness'];
  @override
  List<String> get supportedActions => ['issuance', 'witness', 'transfer', 'burn'];

  @override
  String? identifyScript(dartsv.SVScript script) {
    try { PP1NftLockBuilder.fromScript(script); return 'pp1_nft'; } catch (_) {}
    try { PP2LockBuilder.fromScript(script); return 'pp2'; } catch (_) {}
    return null;
  }

  @override
  Map<String, dynamic>? extractMetadata(dartsv.SVScript script) {
    try {
      final builder = PP1NftLockBuilder.fromScript(script);
      return {
        'pluginId': pluginId,
        'scriptType': 'pp1_nft',
        'tokenId': builder.tokenId != null ? hex.encode(builder.tokenId!) : null,
        'ownerAddress': builder.recipientAddress?.toBase58(),
      };
    } catch (_) {}
    return null;
  }

  @override
  dartsv.LockingScriptBuilder? createLockBuilder(PluginOutputSpec spec) => null;

  @override
  dartsv.UnlockingScriptBuilder? createUnlockBuilder(PluginUnlockSpec spec) => null;

  @override
  Future<dartsv.Transaction> buildTransaction(PluginTransactionRequest request) async {
    final action = request.params['action'] as String;
    final signer = request.signer;
    final signerPub = request.publicKeys.first;

    switch (action) {
      case 'issuance':
        final fundingTxHex = request.params['fundingTxHex'] as String;
        final ownerAddress = request.params['ownerAddress'] as String;
        final fundingTx = dartsv.Transaction.fromHex(fundingTxHex);
        return await _tokenTool.createTokenIssuanceTxn(
          fundingTx, signer, signerPub,
          dartsv.Address.fromBase58(ownerAddress),
          fundingTx.hash, rabinPubKeyHash,
        );

      case 'witness':
        final fundingTxHex = request.params['fundingTxHex'] as String;
        final tokenTxHex = request.params['tokenTxHex'] as String;
        final parentTokenTxHex = request.params['parentTokenTxHex'] as String?;
        final tokenChangePKH = request.params['tokenChangePKH'] as String;
        final tokenAction = request.params['tokenAction'] as String;
        final fundingTx = dartsv.Transaction.fromHex(fundingTxHex);
        final tokenTx = dartsv.Transaction.fromHex(tokenTxHex);
        final parentBytes = parentTokenTxHex != null
            ? hex.decode(parentTokenTxHex)
            : List<int>.empty();
        return _tokenTool.createWitnessTxn(
          signer, fundingTx, tokenTx, parentBytes,
          signerPub, tokenChangePKH,
          tokenAction == 'ISSUANCE' ? TokenAction.ISSUANCE : TokenAction.TRANSFER,
          rabinN: tokenAction == 'ISSUANCE' ? rabinNBytes : null,
          rabinS: tokenAction == 'ISSUANCE' ? rabinSBytes : null,
          rabinPadding: tokenAction == 'ISSUANCE' ? rabinPaddingValue : null,
          identityTxId: tokenAction == 'ISSUANCE' ? identityTxId : null,
          ed25519PubKey: tokenAction == 'ISSUANCE' ? ed25519PubKey : null,
        );

      case 'transfer':
        final fundingTxHex = request.params['fundingTxHex'] as String;
        final prevWitnessTxHex = request.params['prevWitnessTxHex'] as String;
        final prevTokenTxHex = request.params['prevTokenTxHex'] as String;
        final recipientAddress = request.params['recipientAddress'] as String;
        final recipientWitnessFundingTxHex = request.params['recipientWitnessFundingTxHex'] as String;
        final tokenIdHex = request.params['tokenIdHex'] as String;
        final fundingTx = dartsv.Transaction.fromHex(fundingTxHex);
        final prevWitnessTx = dartsv.Transaction.fromHex(prevWitnessTxHex);
        final prevTokenTx = dartsv.Transaction.fromHex(prevTokenTxHex);
        final recipientFundingTx = dartsv.Transaction.fromHex(recipientWitnessFundingTxHex);
        return _tokenTool.createTokenTransferTxn(
          prevWitnessTx, prevTokenTx, signerPub,
          dartsv.Address.fromBase58(recipientAddress),
          fundingTx, signer, signerPub,
          recipientFundingTx.hash, hex.decode(tokenIdHex),
        );

      case 'burn':
        final fundingTxHex = request.params['fundingTxHex'] as String;
        final tokenTxHex = request.params['tokenTxHex'] as String;
        final fundingTx = dartsv.Transaction.fromHex(fundingTxHex);
        final tokenTx = dartsv.Transaction.fromHex(tokenTxHex);
        return _tokenTool.createBurnTokenTxn(
          tokenTx, signer, signerPub,
          fundingTx, signer, signerPub,
        );

      default:
        throw ArgumentError('Unsupported action: $action');
    }
  }

  @override
  bool validateTransactionStructure(dartsv.Transaction tx, String action) {
    if (action == 'issuance') return tx.outputs.length == 5;
    if (action == 'witness') return tx.outputs.length == 1;
    if (action == 'transfer') return tx.outputs.length == 5;
    if (action == 'burn') return tx.outputs.length == 1;
    return false;
  }
}

// ==========================================================================
// Test helpers
// ==========================================================================

/// Send a token operation through the coordinator and await the result
Future<PaymentReadyEvent> tokenOp(
  ActorRef coordinator,
  Stream<CoordinatorEvent> events,
  String walletId,
  String action,
  Map<String, dynamic> params,
) async {
  final ready = ofType<PaymentReadyEvent>(events)
      .first
      .timeout(const Duration(seconds: 30));

  coordinator.tell(PayInvoiceCommand(
    walletId: walletId,
    invoiceId: 'token-$action-${DateTime.now().microsecondsSinceEpoch}',
    addresses: [],
    amount: BigInt.from(546),
    outputs: [
      PluginOutputSpec(
        pluginId: 'tstoken_nft',
        pluginScriptType: 'pp1_nft',
        params: {'action': action, ...params},
        amount: BigInt.from(546),
      ),
    ],
  ));

  return ready;
}

// ==========================================================================
// Test
// ==========================================================================

void main() {
  // Bob's system
  late LibSpiffyActorSystem bobSystem;
  late ActorRef bobCoordinator;
  late Stream<CoordinatorEvent> bobEvents;
  late Directory bobDir;
  late Isar bobIsar;
  late LocalActorSystem bobActorSystem;

  // Alice's system
  late LibSpiffyActorSystem aliceSystem;
  late ActorRef aliceCoordinator;
  late Stream<CoordinatorEvent> aliceEvents;
  late Directory aliceDir;
  late Isar aliceIsar;
  late LocalActorSystem aliceActorSystem;

  // Key material (same as tstokenlib integration test)
  final bobWif = 'cStLVGeWx7fVYKKDXYWVeEbEcPZEC4TD73DjQpHCks2Y8EAjVDSS';
  final bobPrivateKey = dartsv.SVPrivateKey.fromWIF(bobWif);
  final bobPub = bobPrivateKey.publicKey;
  final bobAddress = dartsv.Address.fromPublicKey(bobPub, dartsv.NetworkType.TEST);
  final bobPubkeyHash = '650c4adb156f19e36a755c820d892cda108299c4';

  final aliceWif = 'cRHYFwjjw2Xn2gjxdGw6RRgKJZqipZx7j8i64NdwzxcD6SezEZV5';
  final alicePrivateKey = dartsv.SVPrivateKey.fromWIF(aliceWif);
  final alicePub = alicePrivateKey.publicKey;
  final aliceAddress = dartsv.Address.fromPublicKey(alicePub, dartsv.NetworkType.TEST);
  final alicePubkeyHash = 'f5d33ee198ad13840ce410ba96e149e463a6c352';

  // Funding tx hex (same as tstokenlib)
  final bobFundingTxHex =
      '0200000001cf5ae107ead0a5117ea2124aacb61d0d700de05a937ed3e48c9245bfab19dd8c000000004847304402206edac55dd4f791a611e05a6d946862ca45d914d0cdf391bfd982399c3d84ea4602205a196505d536b3646834051793acd5d9e820249979c94d0a4252298d0ffe9a7041feffffff0200196bee000000001976a914da217dfa3513d4224802556228d07b278af36b0388ac00ca9a3b000000001976a914650c4adb156f19e36a755c820d892cda108299c488ac65000000';
  final aliceFundingTxHex =
      '0200000001be954a6129f555008a8678e9654ab14feb5b38c8cafa64c8aad29131a3c40f2e000000004948304502210092f4c484895bc20b938d109b871e7f860560e6dc72c684a41a28a9863645637202204f86ab76eb5ac67d678f6a426f917e356d5ec15f7f79c210fd4ac6d40644772641feffffff0200196bee000000001976a91490dca3b694773f8cbed80fe7634c6ee3807ca81588ac00ca9a3b000000001976a914f5d33ee198ad13840ce410ba96e149e463a6c35288ac6b000000';

  // Rabin key material
  late List<int> rabinPubKeyHash;
  late List<int> rabinNBytes;
  late List<int> rabinSBytes;
  late int rabinPaddingValue;
  late List<int> dummyIdentityTxId;
  late List<int> dummyEd25519PubKey;

  setUpAll(() async {
    await ensureIsarInitialized();

    final kp = Rabin.generateKeyPair(1024);
    rabinNBytes = Rabin.bigIntToScriptNum(kp.n).toList();
    rabinPubKeyHash = dartsv.hash160(rabinNBytes);
    dummyIdentityTxId = List<int>.generate(32, (i) => i + 1);
    dummyEd25519PubKey = List<int>.generate(32, (i) => i + 0x41);
    final messageBytes = [...dummyIdentityTxId, ...dummyEd25519PubKey];
    final messageHash = Rabin.sha256ToScriptInt(messageBytes);
    final sig = Rabin.sign(messageHash, kp.p, kp.q);
    rabinSBytes = Rabin.bigIntToScriptNum(sig.s).toList();
    rabinPaddingValue = sig.padding;
  });

  setUp(() async {
    PluginRegistry().register(TsTokenNftPlugin(
      rabinPubKeyHash: rabinPubKeyHash,
      rabinNBytes: rabinNBytes,
      rabinSBytes: rabinSBytes,
      rabinPaddingValue: rabinPaddingValue,
      identityTxId: dummyIdentityTxId,
      ed25519PubKey: dummyEd25519PubKey,
    ));

    // Bob
    bobDir = await Directory.systemTemp.createTemp('bob_lifecycle_');
    bobActorSystem = LocalActorSystem(ActorSystemConfig());
    bobIsar = await Isar.open(LibSpiffySchemas.allSchemas,
        directory: bobDir.path, name: 'bob_${DateTime.now().microsecondsSinceEpoch}');
    bobSystem = LibSpiffyActorSystem();
    await bobSystem.initialize(
        actorSystem: bobActorSystem, isar: bobIsar,
        dataDirectory: bobDir.path, enableP2P: false,
        secureStorage: InMemorySecureStorage());
    await setupTestHeaders(bobSystem.walletStorage as IsarWalletStorage);
    bobCoordinator = bobSystem.coordinator;
    bobEvents = bobSystem.coordinatorEvents!;

    // Alice
    aliceDir = await Directory.systemTemp.createTemp('alice_lifecycle_');
    aliceActorSystem = LocalActorSystem(ActorSystemConfig());
    aliceIsar = await Isar.open(LibSpiffySchemas.allSchemas,
        directory: aliceDir.path, name: 'alice_${DateTime.now().microsecondsSinceEpoch}');
    aliceSystem = LibSpiffyActorSystem();
    await aliceSystem.initialize(
        actorSystem: aliceActorSystem, isar: aliceIsar,
        dataDirectory: aliceDir.path, enableP2P: false,
        secureStorage: InMemorySecureStorage());
    await setupTestHeaders(aliceSystem.walletStorage as IsarWalletStorage);
    aliceCoordinator = aliceSystem.coordinator;
    aliceEvents = aliceSystem.coordinatorEvents!;
  });

  tearDown(() async {
    await bobSystem.shutdown();
    await aliceSystem.shutdown();
    PluginRegistry().clear();
    if (await bobDir.exists()) await bobDir.delete(recursive: true);
    if (await aliceDir.exists()) await aliceDir.delete(recursive: true);
  });

  group('Full token lifecycle via coordinator', () {
    test('Issue → Witness → Transfer → Witness → Transfer → Witness → Burn',
        timeout: Timeout(Duration(minutes: 2)), () async {
      final ts = DateTime.now().microsecondsSinceEpoch;
      final bobWalletId = 'bob-$ts';
      final aliceWalletId = 'alice-$ts';

      // Create wallets
      final bobCreated = ofType<WalletCreatedEvent>(bobEvents)
          .where((e) => e.walletId == bobWalletId).first.timeout(const Duration(seconds: 10));
      bobCoordinator.tell(CreateWalletCommand(walletId: bobWalletId, name: 'Bob', wif: bobWif));
      expect((await bobCreated).success, isTrue);

      final aliceCreated = ofType<WalletCreatedEvent>(aliceEvents)
          .where((e) => e.walletId == aliceWalletId).first.timeout(const Duration(seconds: 10));
      aliceCoordinator.tell(CreateWalletCommand(walletId: aliceWalletId, name: 'Alice', wif: aliceWif));
      expect((await aliceCreated).success, isTrue);

      // Fund both wallets with enough UTXOs for all operations.
      // Bob: issuance, witness, transfer, witness, burn = 5 ops
      // Alice: witness, transfer = 2 ops
      for (var i = 0; i < 5; i++) {
        await addSyntheticUtxo(walletManager: bobSystem.walletManager,
            walletId: bobWalletId, address: bobAddress.toBase58(), index: i);
      }
      for (var i = 0; i < 2; i++) {
        await addSyntheticUtxo(walletManager: aliceSystem.walletManager,
            walletId: aliceWalletId, address: aliceAddress.toBase58(), index: 100 + i);
      }

      // ================================================================
      // Step 1: Bob issues a token
      // ================================================================
      final issuanceResult = await tokenOp(bobCoordinator, bobEvents, bobWalletId, 'issuance', {
        'fundingTxHex': bobFundingTxHex,
        'ownerAddress': bobAddress.toBase58(),
      });
      expect(issuanceResult.success, isTrue, reason: 'Issuance failed: ${issuanceResult.error}');

      final issuanceTx = dartsv.Transaction.fromHex(hex.encode(_extractTxFromMinimalBeef(issuanceResult.beefBytes)));
      expect(issuanceTx.outputs.length, equals(5));

      final pp1Lock = PP1NftLockBuilder.fromScript(issuanceTx.outputs[1].script);
      final tokenId = pp1Lock.tokenId!;
      expect(tokenId.length, equals(32));
      final tokenIdHex = hex.encode(tokenId);

      // ================================================================
      // Step 2: Bob creates issuance witness
      // ================================================================
      final witnessResult1 = await tokenOp(bobCoordinator, bobEvents, bobWalletId, 'witness', {
        'fundingTxHex': bobFundingTxHex,
        'tokenTxHex': issuanceTx.serialize(),
        'tokenChangePKH': dartsv.Address.fromPublicKey(bobPub, dartsv.NetworkType.TEST).pubkeyHash160,
        'tokenAction': 'ISSUANCE',
      });
      expect(witnessResult1.success, isTrue, reason: 'Witness 1 failed: ${witnessResult1.error}');

      final issuanceWitnessTx = dartsv.Transaction.fromHex(hex.encode(_extractTxFromMinimalBeef(witnessResult1.beefBytes)));
      expect(issuanceWitnessTx.outputs.length, equals(1));

      // ================================================================
      // Step 3: Bob transfers to Alice
      // ================================================================
      final transfer1Result = await tokenOp(bobCoordinator, bobEvents, bobWalletId, 'transfer', {
        'fundingTxHex': bobFundingTxHex,
        'prevWitnessTxHex': issuanceWitnessTx.serialize(),
        'prevTokenTxHex': issuanceTx.serialize(),
        'recipientAddress': aliceAddress.toBase58(),
        'recipientWitnessFundingTxHex': aliceFundingTxHex,
        'tokenIdHex': tokenIdHex,
      });
      expect(transfer1Result.success, isTrue, reason: 'Transfer 1 failed: ${transfer1Result.error}');

      final firstTransferTx = dartsv.Transaction.fromHex(hex.encode(_extractTxFromMinimalBeef(transfer1Result.beefBytes)));
      expect(firstTransferTx.outputs.length, equals(5));

      // Verify ownership transferred to Alice
      final pp1AfterTransfer1 = PP1NftLockBuilder.fromScript(firstTransferTx.outputs[1].script);
      expect(pp1AfterTransfer1.recipientAddress?.toBase58(), equals(aliceAddress.toBase58()));

      // ================================================================
      // Step 4: Alice creates transfer witness
      // ================================================================
      final witnessResult2 = await tokenOp(aliceCoordinator, aliceEvents, aliceWalletId, 'witness', {
        'fundingTxHex': aliceFundingTxHex,
        'tokenTxHex': firstTransferTx.serialize(),
        'parentTokenTxHex': issuanceTx.serialize(),
        'tokenChangePKH': bobPubkeyHash,
        'tokenAction': 'TRANSFER',
      });
      expect(witnessResult2.success, isTrue, reason: 'Witness 2 failed: ${witnessResult2.error}');

      final aliceWitnessTx = dartsv.Transaction.fromHex(hex.encode(_extractTxFromMinimalBeef(witnessResult2.beefBytes)));
      expect(aliceWitnessTx.outputs.length, equals(1));

      // ================================================================
      // Step 5: Alice transfers back to Bob
      // ================================================================
      final transfer2Result = await tokenOp(aliceCoordinator, aliceEvents, aliceWalletId, 'transfer', {
        'fundingTxHex': aliceFundingTxHex,
        'prevWitnessTxHex': aliceWitnessTx.serialize(),
        'prevTokenTxHex': firstTransferTx.serialize(),
        'recipientAddress': bobAddress.toBase58(),
        'recipientWitnessFundingTxHex': bobFundingTxHex,
        'tokenIdHex': tokenIdHex,
      });
      expect(transfer2Result.success, isTrue, reason: 'Transfer 2 failed: ${transfer2Result.error}');

      final secondTransferTx = dartsv.Transaction.fromHex(hex.encode(_extractTxFromMinimalBeef(transfer2Result.beefBytes)));
      expect(secondTransferTx.outputs.length, equals(5));

      // Verify ownership back to Bob
      final pp1AfterTransfer2 = PP1NftLockBuilder.fromScript(secondTransferTx.outputs[1].script);
      expect(pp1AfterTransfer2.recipientAddress?.toBase58(), equals(bobAddress.toBase58()));

      // ================================================================
      // Step 6: Bob creates transfer witness
      // ================================================================
      final witnessResult3 = await tokenOp(bobCoordinator, bobEvents, bobWalletId, 'witness', {
        'fundingTxHex': bobFundingTxHex,
        'tokenTxHex': secondTransferTx.serialize(),
        'parentTokenTxHex': firstTransferTx.serialize(),
        'tokenChangePKH': alicePubkeyHash,
        'tokenAction': 'TRANSFER',
      });
      expect(witnessResult3.success, isTrue, reason: 'Witness 3 failed: ${witnessResult3.error}');

      final bobWitnessTx = dartsv.Transaction.fromHex(hex.encode(_extractTxFromMinimalBeef(witnessResult3.beefBytes)));
      expect(bobWitnessTx.outputs.length, equals(1));

      // ================================================================
      // Step 7: Bob burns the token
      // ================================================================
      final burnResult = await tokenOp(bobCoordinator, bobEvents, bobWalletId, 'burn', {
        'fundingTxHex': bobFundingTxHex,
        'tokenTxHex': secondTransferTx.serialize(),
      });
      expect(burnResult.success, isTrue, reason: 'Burn failed: ${burnResult.error}');

      final burnTx = dartsv.Transaction.fromHex(hex.encode(_extractTxFromMinimalBeef(burnResult.beefBytes)));
      expect(burnTx.outputs.length, equals(1), reason: 'Burn tx should have 1 output (change only)');
      expect(burnTx.inputs.length, equals(4), reason: 'Burn tx should have 4 inputs (funding, PP1, PP2, PartialWitness)');

      // ================================================================
      // Verify: token ID is consistent across entire lifecycle
      // ================================================================
      final pp1Issuance = PP1NftLockBuilder.fromScript(issuanceTx.outputs[1].script);
      final pp1Transfer1 = PP1NftLockBuilder.fromScript(firstTransferTx.outputs[1].script);
      final pp1Transfer2 = PP1NftLockBuilder.fromScript(secondTransferTx.outputs[1].script);
      expect(hex.encode(pp1Transfer1.tokenId!), equals(hex.encode(pp1Issuance.tokenId!)));
      expect(hex.encode(pp1Transfer2.tokenId!), equals(hex.encode(pp1Issuance.tokenId!)));
    });
  });
}
