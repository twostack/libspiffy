/// Bead spiffyvault-mnz.1, import side: a seed-phrase import finds the
/// wallet's HODLocker coins. The lock transaction is in the history of the
/// address that funded it (or took its change); every output of it is read,
/// and a HODLocker output whose key is the wallet's is taken on with its
/// lock. The key a coin is locked to has no history of its own, so its
/// address is one the scan found unused: the import registers it with the
/// wallet before the coin.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:hex/hex.dart';
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
  String addressAt(String path) => dartsv.HDPrivateKey.fromXpriv(_xpriv)
      .deriveChildKey(path)
      .privateKey
      .publicKey
      .toAddress(dartsv.NetworkType.TEST)
      .toBase58();
  dartsv.SVScript lockTo(String address) => dartsv.HODLockerLockingScriptBuilder(
        HEX.decode(dartsv.Address.fromBase58(address).pubkeyHash160),
        BigInt.from(_height + 500),
      ).getScriptPubkey();
  dartsv.SVScript p2pkh(String address) =>
      dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey();

  setUp(() {
    system = LocalActorSystem(ActorSystemConfig());
    walletManager = _RecordingWalletManager();
  });

  tearDown(() => system.shutdown());

  /// Imports the wallet whose root address received [tx].
  Future<WalletImportNotification> runImport(dartsv.Transaction tx, {List<String> lockKeyWifs = const []}) async {
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
          lockKeyWifs: lockKeyWifs,
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

  test('a lock to an unused receive address: the address is registered, then the coin, with its lock', () async {
    final lockAddress = addressAt('m/0/1');
    final tx = txWith([(90000, lockTo(lockAddress)), (10000, p2pkh(_rootAddress))]);

    final end = await runImport(tx);

    expect(end, isA<WalletImportCompletedEvent>());
    final received = walletManager.commands.whereType<ReceiveUTXOCommand>().toList();
    expect(received.map((c) => '${c.txid}:${c.vout}'), ['${tx.id}:0', '${tx.id}:1']);
    final lock = received.first;
    expect(lock.address, lockAddress);
    expect(lock.pluginMetadata, {
      'pluginId': 'hodlocker',
      'scriptType': 'hodlocker',
      'lockHeight': _height + 500,
      'ownerAddress': lockAddress,
    });
    expect(received.last.pluginMetadata, isNull);

    final registration = walletManager.commands
        .whereType<RegisterDiscoveredAddressCommand>()
        .singleWhere((c) => c.address == lockAddress);
    expect(registration.derivationIndex, 1);
    expect(walletManager.commands.indexOf(registration), lessThan(walletManager.commands.indexOf(lock)),
        reason: 'the wallet holds the address when it takes the coin on');
  });

  test('a lock to an unused change address is found too', () async {
    final lockAddress = addressAt('m/1/0');
    final tx = txWith([(90000, lockTo(lockAddress)), (10000, p2pkh(_rootAddress))]);

    await runImport(tx);

    final lock = walletManager.commands.whereType<ReceiveUTXOCommand>().firstWhere((c) => c.vout == 0);
    expect(lock.address, lockAddress);
    expect(lock.pluginMetadata?['pluginId'], 'hodlocker');
  });

  test('a lock to a lock key handed over with the import is the wallet\'s (bead spiffyvault-mnz.5)', () async {
    final lockKey = dartsv.SVPrivateKey.fromHex('7a' * 32, dartsv.NetworkType.TEST);
    final lockAddress = lockKey.publicKey.toAddress(dartsv.NetworkType.TEST).toBase58();
    final tx = txWith([(500000000, lockTo(lockAddress)), (10000, p2pkh(_rootAddress))]);

    final end = await runImport(tx, lockKeyWifs: [lockKey.toWIF()]);

    expect(end, isA<WalletImportCompletedEvent>());
    final added = walletManager.commands.whereType<AddLockKeyCommand>().single;
    expect(added.wif, lockKey.toWIF());
    final lock = walletManager.commands.whereType<ReceiveUTXOCommand>().singleWhere((c) => c.vout == 0);
    expect(lock.address, lockAddress);
    expect(lock.pluginMetadata?['pluginId'], 'hodlocker');
    expect(walletManager.commands.indexOf(added), lessThan(walletManager.commands.indexOf(lock)),
        reason: 'the wallet holds the key when it takes the coin on');
  });

  test('a lock to a key that is not the wallet\'s is not imported', () async {
    final tx = txWith([
      (90000, lockTo(otherKey.toAddress(dartsv.NetworkType.TEST).toBase58())),
      (10000, p2pkh(_rootAddress)),
    ]);

    await runImport(tx);

    expect(walletManager.commands.whereType<ReceiveUTXOCommand>().map((c) => c.vout), [1]);
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
      } else if (command is AddLockKeyCommand) {
        context.sender?.tell(LockKeyAddedResponse(
          walletId: command.walletId,
          address: dartsv.SVPrivateKey.fromWIF(command.wif).publicKey.toAddress(dartsv.NetworkType.TEST).toBase58(),
          success: true,
          journaled: true,
        ));
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

  /// Nothing recorded yet, so a (resumed) import skips nothing.
  @override
  Future<List<BitcoinTransaction>> getTransactionHistory(String walletId, {int? limit, int? offset}) async =>
      const [];

  @override
  Future<List<BitcoinUtxo>> getUTXOs(String walletId, {bool includeSpent = false}) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('ReadModelStorage.${invocation.memberName} not expected');
}
