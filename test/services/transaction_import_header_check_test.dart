/// SPV-09 (bead libspiffy-nci), import side: TransactionImportService only
/// checked that the BUMP it built was structurally sound. A data source
/// (WhatsOnChain, a node, anything the user configured) could hand over any
/// proof and the transaction was recorded as confirmed with that proof; the
/// local header chain was never consulted.
///
/// Fixture: a real testnet transaction paying the test xpriv's first
/// receiving address, its real merkle proof and the real header of its
/// block (test/spv/testnet_proof_fixture.dart). "Tampered" flips one hex
/// digit of one sibling.
import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/import_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/blockchain_data_models.dart';
import 'package:libspiffy/src/models/wallet_event.dart';
import 'package:libspiffy/src/services/blockchain_data_source.dart';
import 'package:libspiffy/src/services/transaction_import_service.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';

const _xpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';
const _rootAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';

void main() {
  group('TransactionImportService checks proofs against headers (SPV-09)', () {
    Future<BlockHeader?> Function(int) headers(Map<int, BlockHeader> byHeight) =>
        (height) async => byHeight[height];

    test('a proof whose root matches the stored header imports, marked verified', () async {
      final service = TransactionImportService(
        dataSource: _FixtureDataSource(),
        headerAtHeight: headers({kFixtureHeight: fixtureHeader()}),
      );
      final imported = await service.importTransaction(kFixtureTxid);
      expect(imported.headerVerified, isTrue);
      expect(imported.blockHeight, kFixtureHeight);
    });

    test('a tampered proof is rejected', () async {
      final service = TransactionImportService(
        dataSource: _FixtureDataSource(tamperLevel: 2),
        headerAtHeight: headers({kFixtureHeight: fixtureHeader()}),
      );
      await expectLater(
        service.importTransaction(kFixtureTxid),
        throwsA(isA<TransactionImportException>()
            .having((e) => e.message, 'message', contains('does not match'))),
      );
    });

    test('a genuine proof is rejected when our header at that height differs', () async {
      final service = TransactionImportService(
        dataSource: _FixtureDataSource(),
        headerAtHeight: headers({kFixtureHeight: otherHeaderAtFixtureHeight()}),
      );
      await expectLater(service.importTransaction(kFixtureTxid),
          throwsA(isA<TransactionImportException>()));
    });

    test('a genuine proof attributed to the wrong height is rejected', () async {
      // The BUMP is built at the height the data source claims; the header
      // stored there belongs to another block, whose root is different.
      final service = TransactionImportService(
        dataSource: _FixtureDataSource(claimedHeight: kFixtureHeight + 1),
        headerAtHeight: headers({
          kFixtureHeight: fixtureHeader(),
          kFixtureHeight + 1: otherHeaderAtFixtureHeight(),
        }),
      );
      await expectLater(service.importTransaction(kFixtureTxid),
          throwsA(isA<TransactionImportException>()));
    });

    test('raw transaction data that does not hash to the txid is rejected', () async {
      final service = TransactionImportService(
        dataSource: _FixtureDataSource(rawHex: kFixture2TxHex),
        headerAtHeight: headers({kFixtureHeight: fixtureHeader()}),
      );
      await expectLater(service.importTransaction(kFixtureTxid),
          throwsA(isA<TransactionImportException>()));
    });

    test('header not synced yet: imported but not marked verified', () async {
      final service = TransactionImportService(
        dataSource: _FixtureDataSource(),
        headerAtHeight: headers({}),
      );
      final imported = await service.importTransaction(kFixtureTxid);
      expect(imported.headerVerified, isFalse);
    });

    test('header not synced yet and requireVerifiedHeader: rejected', () async {
      final service = TransactionImportService(
        dataSource: _FixtureDataSource(),
        headerAtHeight: headers({}),
        requireVerifiedHeader: true,
      );
      await expectLater(service.importTransaction(kFixtureTxid),
          throwsA(isA<TransactionImportException>()));
    });
  });

  // Same defect through the wallet importer, using only the ImportActor's
  // public constructor: it has the read-model storage (and so the stored
  // headers) and must not record a transaction whose proof contradicts them.
  group('ImportActor does not record a transaction whose proof contradicts the header (SPV-09)', () {
    late LocalActorSystem system;
    late _RecordingWalletManager walletManager;

    setUp(() {
      system = LocalActorSystem(ActorSystemConfig());
      walletManager = _RecordingWalletManager();
    });

    tearDown(() => system.shutdown());

    Future<WalletEvent> runImport(_FixtureDataSource dataSource) async {
      final walletManagerRef = await system.spawn('wm', () => walletManager);
      final terminal = Completer<WalletEvent>();
      final importer = await system.spawn(
        'importer',
        () => ImportActor(
          dataSource: dataSource,
          storage: _HeaderStorage(walletManager, {kFixtureHeight: fixtureHeader()}),
          walletManagerActor: walletManagerRef,
          eventBroadcaster: (event) {
            if ((event is WalletImportCompletedEvent || event is WalletImportFailedEvent) &&
                !terminal.isCompleted) {
              terminal.complete(event);
            }
          },
        ),
      );
      importer.tell(ImportWalletMessage(
        walletId: 'w',
        xpriv: _xpriv,
        walletName: 'w',
        networkType: 'test',
        addressGapLimit: 2,
      ));
      return terminal.future.timeout(const Duration(seconds: 30));
    }

    test('genuine proof: recorded', () async {
      final end = await runImport(_FixtureDataSource());
      expect(end, isA<WalletImportCompletedEvent>());
      expect(walletManager.recordedTxids, contains(kFixtureTxid));
    });

    test('tampered proof: not recorded', () async {
      final end = await runImport(_FixtureDataSource(tamperLevel: 2));
      expect(end, isA<WalletImportCompletedEvent>());
      expect(walletManager.recordedTxids, isNot(contains(kFixtureTxid)),
          reason: 'a proof that does not reach the stored header root must not be imported');
    });
  });
}

/// Serves the fixture transaction for the root address, with the real
/// proof or a tampered one.
class _FixtureDataSource implements BlockchainDataSource {
  final int? tamperLevel;
  final int claimedHeight;
  final String rawHex;

  _FixtureDataSource({this.tamperLevel, int? claimedHeight, String? rawHex})
      : claimedHeight = claimedHeight ?? kFixtureHeight,
        rawHex = rawHex ?? kFixtureTxHex;

  @override
  String get networkType => 'test';

  @override
  Future<List<TransactionInfo>> getTransactionHistory(String address, {int? limit, int? offset}) async =>
      address == _rootAddress
          ? [TransactionInfo(txid: kFixtureTxid, blockHeight: kFixtureHeight)]
          : const [];

  @override
  Future<String> getRawTransaction(String txid) async {
    if (txid != kFixtureTxid) throw DataSourceException('unknown', txid: txid);
    return rawHex;
  }

  @override
  Future<MerkleProofData> getMerkleProof(String txid) async => MerkleProofData(
        txid: txid,
        blockHeight: claimedHeight,
        merkleRoot: kFixtureBlockHash,
        index: kFixtureIndex,
        nodes: fixtureNodes(tamperLevel: tamperLevel),
        format: 'tsc',
      );

  @override
  Future<List<UtxoInfo>> getUtxos(String address) async => const [];

  @override
  Future<int> getCurrentBlockHeight() async => kFixtureHeight + 10;

  @override
  Future<String> submitTransaction(String rawHex) => throw UnimplementedError();

  @override
  Future<List<AddressScriptInfo>> getAddressScripts(String address) => throw UnimplementedError();

  @override
  Future<List<TransactionInfo>> getScriptHistory(String scriptHash, {int? limit, int? offset}) =>
      throw UnimplementedError();
}

/// Acknowledges commands the way BitcoinWalletAggregate does for the
/// ImportActor (see import_actor_cancellation_test.dart).
class _RecordingWalletManager extends Actor {
  final List<String> registeredAddresses = [];
  final List<String> recordedTxids = [];

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is CreateWalletMessage) {
      context.sender?.tell(LocalMessage(payload: WalletCreatedMessage(message.walletId, 'root', true)));
    } else if (message is WalletCommandMessage) {
      final command = message.command;
      if (command is RegisterDiscoveredAddressCommand) {
        registeredAddresses.add(command.address);
      } else if (command is ReceiveUTXOCommand) {
        context.sender?.tell(UTXOReceivedResponse(
            walletId: command.walletId, txid: command.txid, vout: command.vout, success: true));
      } else if (command is RecordImportedTransactionCommand) {
        recordedTxids.add(command.txid);
        context.sender?.tell(TransactionRecordedResponse(
            walletId: command.walletId, txid: command.txid, success: true));
      }
    }
  }
}

class _HeaderStorage implements ReadModelStorage {
  final _RecordingWalletManager _walletManager;
  final Map<int, BlockHeader> _headers;
  _HeaderStorage(this._walletManager, this._headers);

  @override
  Future<BlockHeader?> getBlockHeaderByHeight(int height) async => _headers[height];

  @override
  Future<int> getAddressCount(String walletId) async => _walletManager.registeredAddresses.length;

  @override
  Future<BitcoinTransaction?> getTransaction(String txid, {String? walletId}) async => null;

  @override
  Future<List<BitcoinUtxo>> getUTXOs(String walletId, {bool includeSpent = false}) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('ReadModelStorage.${invocation.memberName} not expected');
}
