/// A-H3 (bead libspiffy-eal): SPVActor hardcoded `NetworkType.TEST` when
/// deriving the address of P2PKH / P2PK outputs, so on mainnet every derived
/// address carried the testnet version byte ('m'/'n' prefix), never matched
/// the wallet's own '1...' addresses, and a validated payment produced no
/// spendable UTXO.
///
/// This test drives a mainnet-configured SPVActor with a BEEF whose subject
/// transaction is proven by a synthetic single-transaction merkle path and a
/// matching stored block header, and pays a mainnet P2PKH address that the
/// wallet owns. Runs in its own file because the SPV actor and dartsv template
/// registry keep process-wide state.
import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';
import 'package:spiffynode/spiffy_node.dart' show BlockHeader, Hash;
import 'package:test/test.dart';

const _walletId = 'mainnet-wallet';
const _blockHeight = 800000;

/// Fixed key so the expected address is stable across runs.
const _privHex =
    '1e99423a4ed27608a15a2616a2b0e9e52ced330ac530edcc32c8ffc6a526aedd';

void main() {
  group('SPVActor on mainnet', () {
    late LocalActorSystem actorSystem;
    late _AddressAwareStorage storage;
    late ActorRef spvActor;
    late ActorRef sink;

    setUp(() async {
      actorSystem = LocalActorSystem(ActorSystemConfig());
      storage = _AddressAwareStorage();
      sink = await actorSystem.spawn('sink', () => _SinkActor());
      spvActor = await actorSystem.spawn(
        'spv-actor-mainnet',
        () => SPVActor(
          walletManager: sink,
          invoiceCoordinator: sink,
          storage: storage,
          networkType: 'main',
        ),
      );
    });

    tearDown(() async {
      await actorSystem.shutdown();
    });

    test('credits a validated P2PKH output to the wallet\'s mainnet address',
        () async {
      final privateKey = dartsv.SVPrivateKey.fromHex(_privHex, dartsv.NetworkType.MAIN);
      final mainnetAddress = dartsv.Address.fromPublicKey(
        privateKey.publicKey,
        dartsv.NetworkType.MAIN,
      ).toBase58();
      expect(mainnetAddress, startsWith('1'),
          reason: 'fixture must be a mainnet P2PKH address');
      storage.ownedAddresses[_walletId] = {mainnetAddress};

      final outputScript = dartsv.P2PKHLockBuilder.fromAddress(
        dartsv.Address(mainnetAddress),
      ).getScriptPubkey();

      final txBytes = _buildRawTransaction(
        prevTxidInternal: Uint8List.fromList(List<int>.generate(32, (i) => 0xa0 + i)),
        prevVout: 0,
        outputScript: Uint8List.fromList(hex.decode(outputScript.toHex())),
        outputSatoshis: 50000,
      );
      final txidHex = dartsv.Transaction.fromHex(hex.encode(txBytes)).id;

      // Two-leaf block: the subject transaction at index 0, one sibling.
      final sibling = hex.encode(List<int>.generate(32, (i) => 0x5a ^ i));
      final bump = CryptoUtils.createBumpFromTscProof(
        {'index': 0, 'txOrId': txidHex, 'nodes': [sibling]},
        _blockHeight,
      );
      final txidInternal =
          Uint8List.fromList(hex.decode(txidHex).reversed.toList());
      final merkleRootInternal = bump.computeMerkleRoot(txidInternal);

      await storage.storeBlockHeader(
        BlockHeader(
          version: 0x20000000,
          prevBlock: Hash.zero(),
          merkleRoot: Hash.fromBytes(merkleRootInternal),
          timestamp: DateTime.fromMillisecondsSinceEpoch(1690000000 * 1000),
          bits: 0x1d00ffff,
          nonce: 1,
        ),
        _blockHeight,
      );

      final beef = BEEF.create(
        bumps: [bump],
        txs: [txBytes],
        hasMerkle: [true],
        bumpIndex: [0],
      );

      final completer = Completer<SPVValidationResult>();
      final receiver = await actorSystem.spawn(
        'validation-receiver',
        () => _ReceiverActor(completer),
      );
      spvActor.tell(
        ReceiveTransactionMessage(
          transactionId: txidHex,
          beef: beef,
          fromCounterparty: 'alice',
          targetWalletId: _walletId,
        ),
        sender: receiver,
      );

      final result = await completer.future.timeout(const Duration(seconds: 10));
      expect(result.isValid, isTrue, reason: result.validationError);

      final credited =
          result.spendableUTXOs.map((u) => u['address'] as String).toList();
      expect(credited, equals([mainnetAddress]),
          reason: 'the P2PKH output must be credited to the wallet\'s mainnet '
              'address; a testnet-encoded address never matches');
      expect(credited.single, startsWith('1'));
    });
  });
}

/// InMemoryWalletStorage stubs `isWalletAddress` to false; the SPV actor's
/// ownership fallback needs a real answer.
class _AddressAwareStorage extends InMemoryWalletStorage {
  final Map<String, Set<String>> ownedAddresses = {};

  @override
  Future<bool> isWalletAddress(String walletId, String address) async =>
      ownedAddresses[walletId]?.contains(address) ?? false;
}

class _SinkActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

class _ReceiverActor extends Actor {
  final Completer<SPVValidationResult> completer;
  _ReceiverActor(this.completer);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is SPVValidationResult && !completer.isCompleted) {
      completer.complete(message);
    }
  }
}

/// Minimal version-1 transaction: one input (empty scriptSig; a proven
/// transaction's inputs are not script-checked) and one output.
Uint8List _buildRawTransaction({
  required Uint8List prevTxidInternal,
  required int prevVout,
  required Uint8List outputScript,
  required int outputSatoshis,
}) {
  final out = BytesBuilder();
  void u32(int v) => out.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  void u64(int v) {
    for (var i = 0; i < 8; i++) {
      out.addByte((v >> (8 * i)) & 0xff);
    }
  }

  u32(1);
  out.addByte(1);
  out.add(prevTxidInternal);
  u32(prevVout);
  out.addByte(0);
  u32(0xffffffff);
  out.addByte(1);
  u64(outputSatoshis);
  out.addByte(outputScript.length);
  out.add(outputScript);
  u32(0);
  return out.toBytes();
}
