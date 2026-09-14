/// Bead libspiffy-viy, import side: ImportActor attributed a bare multisig
/// output to the wallet as soon as one of its keys derived to a wallet
/// address. Importing a wallet that funded a payment channel credited the
/// channel's 2-of-2 output as an available wallet UTXO and as received
/// amount, although the wallet cannot spend it without the other party.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/import_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/blockchain_data_models.dart';
import 'package:libspiffy/src/services/blockchain_data_source.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:spiffynode/spiffy_node.dart';

const _xpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';
const _rootAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';
const _height = 1500000;

void main() {
  late LocalActorSystem system;
  late _RecordingWalletManager walletManager;

  final rootKey = dartsv.HDPrivateKey.fromXpriv(_xpriv)
      .deriveChildKey('m/0/0')
      .privateKey
      .publicKey;
  final otherKey = dartsv.SVPrivateKey.fromHex('33' * 32, dartsv.NetworkType.TEST).publicKey;

  setUp(() {
    system = LocalActorSystem(ActorSystemConfig());
    walletManager = _RecordingWalletManager();
  });

  tearDown(() => system.shutdown());

  /// Imports the wallet whose root address received [tx].
  Future<WalletImportNotification> runImport(dartsv.Transaction tx) async {
    final walletManagerRef = await system.spawn('wm', () => walletManager);
    final terminal = Completer<WalletImportNotification>();
    await system.spawn(
      'importer',
      () => ImportActor(
        dataSource: _SingleTxDataSource(tx),
        storage: _NoHeaderStorage(walletManager),
        walletManagerActor: walletManagerRef,
        eventBroadcaster: (event) {
          if ((event is WalletImportCompletedEvent || event is WalletImportFailedEvent) &&
              !terminal.isCompleted) {
            terminal.complete(event);
          }
        },
      ),
    ).then((importer) => importer.tell(ImportWalletMessage(
          walletId: 'w',
          xpriv: _xpriv,
          walletName: 'w',
          networkType: 'test',
          addressGapLimit: 2,
        )));
    return terminal.future.timeout(const Duration(seconds: 30));
  }

  dartsv.Transaction txWith(List<(int, dartsv.SVScript)> outputs) {
    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    tx.inputs.add(dartsv.TransactionInput('ab' * 32, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    for (final (sats, script) in outputs) {
      tx.outputs.add(dartsv.TransactionOutput(BigInt.from(sats), script));
    }
    return tx;
  }

  test('sanity: the root key derives to the root address', () {
    expect(rootKey.toAddress(dartsv.NetworkType.TEST).toBase58(), _rootAddress);
  });

  test(
      'a channel funding transaction: the 2-of-2 output holding the root key is not '
      'imported as a UTXO or as received amount; the transaction is recorded whole',
      () async {
    final tx = txWith([
      (100000, dartsv.P2MSLockBuilder([rootKey, otherKey], 2, sorting: false).getScriptPubkey()),
      (50000, dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(_rootAddress))
          .getScriptPubkey()),
    ]);

    final end = await runImport(tx);

    expect(end, isA<WalletImportCompletedEvent>());
    final received = walletManager.commands.whereType<ReceiveUTXOCommand>().toList();
    expect(received.map((c) => '${c.txid}:${c.vout}'), ['${tx.id}:1'],
        reason: 'only the P2PKH change is spendable by the wallet alone');
    final recorded = walletManager.commands.whereType<RecordImportedTransactionCommand>().single;
    expect(recorded.txid, tx.id);
    expect(recorded.rawHex, tx.serialize());
    expect(recorded.walletReceivedSats, 50000);
  });

  test('a 1-of-2 output holding the root key is imported as the wallet\'s', () async {
    final tx = txWith([
      (100000, dartsv.P2MSLockBuilder([otherKey, rootKey], 1, sorting: false).getScriptPubkey()),
    ]);

    final end = await runImport(tx);

    expect(end, isA<WalletImportCompletedEvent>());
    final received = walletManager.commands.whereType<ReceiveUTXOCommand>().single;
    expect(received.vout, 0);
    expect(received.address, _rootAddress);
  });
}

/// Serves [tx] as the only transaction of the root address, with a proof at
/// a height whose header is not stored (imported unverified).
class _SingleTxDataSource implements BlockchainDataSource {
  final dartsv.Transaction tx;
  _SingleTxDataSource(this.tx);

  @override
  String get networkType => 'test';

  @override
  Future<List<TransactionInfo>> getTransactionHistory(String address, {int? limit, int? offset}) async =>
      address == _rootAddress ? [TransactionInfo(txid: tx.id, blockHeight: _height)] : const [];

  @override
  Future<String> getRawTransaction(String txid) async {
    if (txid != tx.id) throw DataSourceException('unknown', txid: txid);
    return tx.serialize();
  }

  @override
  Future<MerkleProofData> getMerkleProof(String txid) async => MerkleProofData(
        txid: txid,
        blockHeight: _height,
        merkleRoot: 'cd' * 32,
        index: 0,
        nodes: ['ef' * 32],
        format: 'tsc',
      );

  @override
  Future<List<UtxoInfo>> getUtxos(String address) async => const [];

  @override
  Future<int> getCurrentBlockHeight() async => _height + 10;

  @override
  Future<String> submitTransaction(String rawHex) => throw UnimplementedError();

  @override
  Future<List<AddressScriptInfo>> getAddressScripts(String address) => throw UnimplementedError();

  @override
  Future<List<TransactionInfo>> getScriptHistory(String scriptHash, {int? limit, int? offset}) =>
      throw UnimplementedError();
}

/// Records wallet commands and acknowledges them the way
/// BitcoinWalletAggregate does for the ImportActor.
class _RecordingWalletManager extends Actor {
  final List<String> registeredAddresses = [];
  final List<Object> commands = [];

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is CreateWalletMessage) {
      context.sender?.tell(LocalMessage(payload: WalletCreatedMessage(message.walletId, 'root', true)));
    } else if (message is WalletCommandMessage) {
      final command = message.command;
      commands.add(command);
      if (command is RegisterDiscoveredAddressCommand) {
        registeredAddresses.add(command.address);
      } else if (command is ReceiveUTXOCommand) {
        context.sender?.tell(UTXOReceivedResponse(
            walletId: command.walletId, txid: command.txid, vout: command.vout, success: true));
      } else if (command is RecordImportedTransactionCommand) {
        context.sender?.tell(TransactionRecordedResponse(
            walletId: command.walletId, txid: command.txid, success: true));
      }
    }
  }
}

class _NoHeaderStorage implements ReadModelStorage {
  final _RecordingWalletManager _walletManager;
  _NoHeaderStorage(this._walletManager);

  @override
  Future<BlockHeader?> getBlockHeaderByHeight(int height) async => null;

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
