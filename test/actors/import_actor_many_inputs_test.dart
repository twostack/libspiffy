/// A mainnet import stopped at a transaction with 162 inputs: fetching its
/// parents one by one took 94 seconds, and the wait for the wallet to apply
/// the transaction had started before them, so its 30 seconds were over
/// before the transaction was sent. The wait now starts when the first
/// command is sent, and the parents are fetched several at a time, each
/// once.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart' show AwaitEventApplied, AwaitFailed, EventAppliedResponse;
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
const _ackTimeout = Duration(milliseconds: 300);
const _fetchDelay = Duration(milliseconds: 150);

void main() {
  late LocalActorSystem system;
  late _Projection projection;
  late _RecordingWalletManager walletManager;

  setUp(() {
    system = LocalActorSystem(ActorSystemConfig());
    projection = _Projection();
    walletManager = _RecordingWalletManager(projection);
  });

  tearDown(() => system.shutdown());

  // 13 parents, the last spent twice: fetched one by one they take longer
  // than the wait for the wallet, and so do they three rounds at a time.
  final parents = [
    for (var i = 0; i < 13; i++)
      dartsv.Transaction()
        ..version = 1
        ..nLockTime = i
        ..inputs.add(dartsv.TransactionInput('cd' * 32, i, dartsv.TransactionInput.MAX_SEQ_NUMBER))
        ..outputs.add(dartsv.TransactionOutput(BigInt.from(1000), _p2pkh('mzBc4XEFSdzCDcTxAgf6EZXgsZWpztRhef')))
        ..outputs.add(dartsv.TransactionOutput(BigInt.from(2000), _p2pkh('mzBc4XEFSdzCDcTxAgf6EZXgsZWpztRhef'))),
  ];
  final tx = dartsv.Transaction()
    ..version = 1
    ..nLockTime = 0;
  for (final parent in parents) {
    tx.inputs.add(dartsv.TransactionInput(parent.id, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
  }
  tx.inputs.add(dartsv.TransactionInput(parents.last.id, 1, dartsv.TransactionInput.MAX_SEQ_NUMBER));
  tx.outputs.add(dartsv.TransactionOutput(BigInt.from(15000), _p2pkh(_rootAddress)));

  test('a transaction whose parents take longer to fetch than the wait is imported', () async {
    _Projection.txids..clear()..add(tx.id);
    final source = _DataSource(tx, parents);
    final walletManagerRef = await system.spawn('wm', () => walletManager);
    final projectionRef = await system.spawn('projection', () => projection);
    final terminal = Completer<WalletImportNotification>();
    final importer = await system.spawn(
      'importer',
      () => ImportActor(
        dataSource: source,
        storage: _NoHeaderStorage(walletManager),
        walletManagerActor: walletManagerRef,
        walletProjection: projectionRef,
        ackTimeout: _ackTimeout,
        eventBroadcaster: (event) {
          if ((event is WalletImportCompletedEvent || event is WalletImportFailedEvent) && !terminal.isCompleted) {
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

    final end = await terminal.future.timeout(const Duration(seconds: 30));

    expect(end, isA<WalletImportCompletedEvent>(), reason: end is WalletImportFailedEvent ? end.error : '');
    final record = walletManager.commands.whereType<RecordImportedTransactionCommand>().single;
    expect(record.txid, tx.id);
    expect(record.totalInputSats, 13 * 1000 + 2000, reason: 'every input is counted, the twice-spent parent too');
    expect(record.ancestors.map((a) => a.txid), [for (final p in parents) p.id], reason: 'in input order, each once');
    expect(source.fetches.values, everyElement(1), reason: 'each parent is fetched once');
    expect(source.fetches.keys, containsAll([for (final p in parents) p.id]));
    expect(source.mostAtOnce, greaterThan(1), reason: 'parents are fetched several at a time');
  });
}

dartsv.SVScript _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey();

/// Serves [tx] as the root address's only transaction, and its parents
/// after [_fetchDelay] each, counting the fetches.
class _DataSource implements BlockchainDataSource {
  final dartsv.Transaction tx;
  final Map<String, dartsv.Transaction> parents;
  final Map<String, int> fetches = {};
  int _inFlight = 0;
  int mostAtOnce = 0;

  _DataSource(this.tx, List<dartsv.Transaction> parents) : parents = {for (final p in parents) p.id: p};

  @override
  String get networkType => 'test';

  @override
  Future<List<TransactionInfo>> getTransactionHistory(String address, {int? limit, int? offset}) async =>
      address == _rootAddress ? [TransactionInfo(txid: tx.id, blockHeight: _height)] : const [];

  @override
  Future<String> getRawTransaction(String txid) async {
    if (txid == tx.id) return tx.serialize();
    final parent = parents[txid];
    if (parent == null) throw DataSourceException('unknown', txid: txid);
    fetches[txid] = (fetches[txid] ?? 0) + 1;
    _inFlight++;
    if (_inFlight > mostAtOnce) mostAtOnce = _inFlight;
    await Future.delayed(_fetchDelay);
    _inFlight--;
    return parent.serialize();
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

/// A wallet projection whose wait for an imported transaction runs out
/// after its timeout, counted from when the wait is asked for, as
/// eventador's does; the wallet manager applies the transaction when it
/// takes the record command. Every other wait is answered at once.
class _Projection extends Actor {
  final Map<String, Completer<bool>> _waits = {};

  void applied(String txid) => _waits.remove(txid)?.complete(true);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! AwaitEventApplied) return;
    final sender = context.sender;
    final txid = _importedTxid(message);
    if (txid == null) {
      sender?.tell(EventAppliedResponse());
      return;
    }
    final wait = _waits[txid] = Completer<bool>();
    final timer = Timer(message.timeout, () {
      if (!wait.isCompleted) wait.complete(false);
    });
    unawaited(wait.future.then((ok) {
      timer.cancel();
      _waits.remove(txid);
      sender?.tell(ok ? EventAppliedResponse() : AwaitFailed(reason: 'timeout'));
    }));
  }

  /// The transaction [wait] is for, when it waits for an import.
  static String? _importedTxid(AwaitEventApplied wait) {
    for (final txid in _Projection.txids) {
      if (wait.predicate(_imported(txid))) return txid;
    }
    return null;
  }

  static final List<String> txids = [];

  static TransactionImportedEvent _imported(String txid) => TransactionImportedEvent(
        walletId: 'w',
        txid: txid,
        rawHex: '01',
        blockHeight: _height,
        bumpProof: '',
        totalOutputSats: 0,
        numInputs: 0,
        numOutputs: 0,
        txVersion: 1,
        txLockTime: 0,
        walletReceivingAddresses: const [],
        walletReceivedSats: 0,
        totalInputSats: 0,
        sendingAddresses: const [],
      );
}

/// Records wallet commands, acknowledges them the way BitcoinWalletAggregate
/// does, and has the projection apply each recorded transaction.
class _RecordingWalletManager extends Actor {
  final _Projection projection;
  final List<String> registeredAddresses = [];
  final List<Object> commands = [];

  _RecordingWalletManager(this.projection);

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
        projection.applied(command.txid);
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
  Future<List<String>> getWalletAddresses(String walletId) async => _walletManager.registeredAddresses;

  @override
  Future<BitcoinTransaction?> getTransaction(String txid, {String? walletId}) async => null;

  @override
  Future<List<BitcoinTransaction>> getTransactionHistory(String walletId, {int? limit, int? offset}) async =>
      const [];

  @override
  Future<List<BitcoinUtxo>> getUTXOs(String walletId, {bool includeSpent = false}) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('ReadModelStorage.${invocation.memberName} not expected');
}
