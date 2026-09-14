/// A-H7 (bead libspiffy-ora): ImportActor ran the whole import inside
/// `onMessage` and paced itself with fixed `Future.delayed` sleeps (10 ms per
/// registered address, 150 ms per transaction, 200 ms storage polls). While an
/// import ran the mailbox was blocked, so `ImportProgressQuery` went
/// unanswered and `CancelImportMessage` was not seen until the import had
/// finished on its own.
///
/// These tests drive the real ImportActor with in-memory fakes (no Isar, no
/// network): a wallet manager that acknowledges commands the way the
/// aggregate does, a data source whose transaction fetches can be gated so
/// the import is provably mid-flight, and an event sink.
///
/// Old vs new on this machine (30 transactions, 3 addresses): the unfixed
/// actor needed ~4.7 s of which 4.53 s were pure sleeps (30 x 150 ms +
/// 3 x 10 ms); the fixed actor finishes the same import in well under a
/// second because every wait is on an actual acknowledgement.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/actors/import_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/blockchain_data_models.dart';
import 'package:libspiffy/src/models/wallet_event.dart';
import 'package:libspiffy/src/services/blockchain_data_source.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:test/test.dart';

/// Testnet xpriv (same fixture as import_actor_test.dart); the fake data
/// source reports history for its first [_kUsedAddresses] receiving addresses.
const _kXpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';
const _kUsedAddresses = 3;
const _kTxsPerAddress = 10;
const _kTotalTxs = _kUsedAddresses * _kTxsPerAddress;
const _kGapLimit = 2;

/// Sleep the unfixed actor performed for this import: 10 ms per registered
/// address and 150 ms per transaction that produced a UTXO.
const _kOldSummedSleeps = Duration(
  milliseconds: _kUsedAddresses * 10 + _kTotalTxs * 150,
);

void main() {
  group('ImportActor without sleeps, cancellable', () {
    late LocalActorSystem system;
    late _FakeWalletManager walletManager;
    late ActorRef walletManagerRef;
    late _GatedDataSource dataSource;
    late ActorRef importActor;
    late List<WalletEvent> events;
    late Completer<WalletEvent> terminal;

    setUp(() async {
      system = LocalActorSystem(ActorSystemConfig());
      walletManager = _FakeWalletManager();
      walletManagerRef = await system.spawn('wallet-manager', () => walletManager);
      dataSource = _GatedDataSource();
      events = [];
      terminal = Completer<WalletEvent>();
      importActor = await system.spawn(
        'import-actor',
        () => ImportActor(
          dataSource: dataSource,
          storage: _FakeStorage(walletManager),
          walletManagerActor: walletManagerRef,
          eventBroadcaster: (event) {
            events.add(event);
            if ((event is WalletImportCompletedEvent ||
                    event is WalletImportFailedEvent) &&
                !terminal.isCompleted) {
              terminal.complete(event);
            }
          },
        ),
      );
    });

    tearDown(() async {
      dataSource.releaseAll();
      await system.shutdown();
    });

    ImportWalletMessage importMessage(String walletId) => ImportWalletMessage(
          walletId: walletId,
          xpriv: _kXpriv,
          walletName: 'w',
          networkType: 'test',
          addressGapLimit: _kGapLimit,
        );

    test('imports $_kTotalTxs transactions far faster than the old summed sleeps',
        () async {
      final stopwatch = Stopwatch()..start();
      importActor.tell(importMessage('fast'));

      final end = await terminal.future.timeout(const Duration(seconds: 30));
      stopwatch.stop();

      expect(end, isA<WalletImportCompletedEvent>(),
          reason: end is WalletImportFailedEvent ? end.error : null);
      expect(walletManager.recordedTxids.length, _kTotalTxs);
      expect(walletManager.registeredAddresses.length, _kUsedAddresses);

      print('import of $_kTotalTxs txs took ${stopwatch.elapsedMilliseconds} ms '
          '(old code slept ${_kOldSummedSleeps.inMilliseconds} ms on top of its work)');
      // Old: >= 4530 ms of sleep alone. Generous bound so a loaded CI box passes.
      expect(stopwatch.elapsed, lessThan(_kOldSummedSleeps ~/ 3),
          reason: 'the import must not be paced by fixed sleeps');
    });

    test('answers a progress query while the import is still running', () async {
      dataSource.gateAtTransaction(txIndex: 4);
      importActor.tell(importMessage('progress'));
      await dataSource.gateReached.future.timeout(const Duration(seconds: 15));
      expect(terminal.isCompleted, isFalse, reason: 'import must still be running');

      // Old code: the mailbox is blocked by the running import, the query is
      // never dequeued and this ask times out.
      final progress = await importActor
          .ask<ImportProgressMessage>(
            LocalMessage(payload: ImportProgressQuery()),
            const Duration(seconds: 2),
          )
          .timeout(const Duration(seconds: 3));

      expect(progress.walletId, 'progress');
      expect(terminal.isCompleted, isFalse,
          reason: 'the answer must arrive while the import is in flight');
      expect(progress.isRunning, isTrue);
      expect(progress.phase, 'import');
      // The gate sits in the collection sub-phase: all $_kTotalTxs are known
      // from discovery, none has been processed yet.
      expect(progress.totalTransactions, _kTotalTxs);
      expect(progress.processedTransactions, 0);
      expect(progress.message, startsWith('Collecting transactions'));
      expect(progress.progress, inExclusiveRange(0.39, 0.56));

      dataSource.releaseAll();
      final end = await terminal.future.timeout(const Duration(seconds: 30));
      expect(end, isA<WalletImportCompletedEvent>());
    });

    test('cancel mid-import stops it, emits a failed event, imports nothing more',
        () async {
      const gateAt = 3;
      dataSource.gateAtTransaction(txIndex: gateAt);
      importActor.tell(importMessage('cancel'));
      await dataSource.gateReached.future.timeout(const Duration(seconds: 15));
      final recordedBeforeCancel = walletManager.recordedTxids.length;
      expect(recordedBeforeCancel, lessThan(_kTotalTxs));

      // Old code: not dequeued until the import has finished on its own.
      importActor.tell(LocalMessage(payload: CancelImportMessage()));
      dataSource.releaseAll();

      final end = await terminal.future.timeout(const Duration(seconds: 30));
      expect(end, isA<WalletImportFailedEvent>(),
          reason: 'a cancelled import must not report completion');
      expect((end as WalletImportFailedEvent).error.toLowerCase(), contains('cancel'));

      final recordedAtCancel = walletManager.recordedTxids.length;
      // The gated transaction may still land; nothing beyond it may.
      expect(recordedAtCancel, lessThanOrEqualTo(gateAt + 1));
      expect(events.whereType<WalletImportCompletedEvent>(), isEmpty);

      // Nothing trickles in afterwards.
      await Future.delayed(const Duration(milliseconds: 300));
      expect(walletManager.recordedTxids.length, recordedAtCancel,
          reason: 'no transaction may be imported after cancellation');
    });

    test('supplementary guard: the actor source contains no fixed sleeps', () {
      final source = File('lib/src/actors/import_actor.dart').readAsStringSync();
      expect(source, isNot(contains('Future.delayed')));
    });
  });
}

// =============================================================================
// FAKES
// =============================================================================

/// Acknowledges commands the way BitcoinWalletAggregate does for the
/// ImportActor's sender: UTXOReceivedResponse per UTXO and
/// TransactionRecordedResponse per recorded transaction.
class _FakeWalletManager extends Actor {
  final List<String> registeredAddresses = [];
  final List<String> recordedTxids = [];

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is CreateWalletMessage) {
      context.sender?.tell(LocalMessage(
        payload: WalletCreatedMessage(message.walletId, 'root', true),
      ));
    } else if (message is WalletCommandMessage) {
      final command = message.command;
      if (command is RegisterDiscoveredAddressCommand) {
        registeredAddresses.add(command.address);
      } else if (command is ReceiveUTXOCommand) {
        context.sender?.tell(UTXOReceivedResponse(
          walletId: command.walletId,
          txid: command.txid,
          vout: command.vout,
          success: true,
        ));
      } else if (command is RecordImportedTransactionCommand) {
        recordedTxids.add(command.txid);
        context.sender?.tell(TransactionRecordedResponse(
          walletId: command.walletId,
          txid: command.txid,
          success: true,
        ));
      }
    }
  }
}

class _FakeStorage implements ReadModelStorage {
  final _FakeWalletManager _walletManager;
  _FakeStorage(this._walletManager);

  @override
  Future<int> getAddressCount(String walletId) async =>
      _walletManager.registeredAddresses.length;

  @override
  Future<BitcoinTransaction?> getTransaction(String txid) async => null;

  @override
  Future<List<BitcoinUtxo>> getUTXOs(String walletId, {bool includeSpent = false}) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('ReadModelStorage.${invocation.memberName} not expected');
}

/// Synthetic testnet history: the first [_kUsedAddresses] receiving addresses
/// of [_kXpriv] each have [_kTxsPerAddress] transactions paying them one
/// P2PKH output. Merkle proofs are structurally valid single-sibling paths
/// (the ImportActor validates BUMP structure, not block headers).
class _GatedDataSource implements BlockchainDataSource {
  final Map<String, List<TransactionInfo>> _history = {};
  final Map<String, String> _rawTx = {};
  final List<String> _txidsInOrder = [];

  int? _gateTxIndex;
  final Completer<void> gateReached = Completer<void>();
  Completer<void>? _gate;

  _GatedDataSource() {
    final hdPublic = dartsv.HDPrivateKey.fromXpriv(_kXpriv).hdPublicKey;
    final receiving = hdPublic.deriveChildNumber(0);
    var height = 1000;
    for (var a = 0; a < _kUsedAddresses; a++) {
      final address = receiving
          .deriveChildNumber(a)
          .publicKey
          .toAddress(dartsv.NetworkType.TEST)
          .toString();
      final script = dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(address))
          .getScriptPubkey();
      final infos = <TransactionInfo>[];
      for (var t = 0; t < _kTxsPerAddress; t++) {
        final serial = a * _kTxsPerAddress + t;
        final raw = _buildRawTransaction(
          prevTxidInternal: Uint8List.fromList(List<int>.generate(32, (i) => (serial + i) & 0xff)),
          prevVout: serial,
          outputScript: Uint8List.fromList(hex.decode(script.toHex())),
          outputSatoshis: 1000 + serial,
        );
        final rawHex = hex.encode(raw);
        final txid = dartsv.Transaction.fromHex(rawHex).id;
        _rawTx[txid] = rawHex;
        _txidsInOrder.add(txid);
        infos.add(TransactionInfo(txid: txid, blockHeight: height++));
      }
      _history[address] = infos;
    }
  }

  /// Block the merkle-proof fetch of the [txIndex]-th transaction (in import
  /// order) until [releaseAll] is called; [gateReached] completes when the
  /// import arrives there.
  void gateAtTransaction({required int txIndex}) {
    _gateTxIndex = txIndex;
    _gate = Completer<void>();
  }

  void releaseAll() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  String get networkType => 'test';

  @override
  Future<List<TransactionInfo>> getTransactionHistory(String address,
          {int? limit, int? offset}) async =>
      List.of(_history[address] ?? const []);

  @override
  Future<String> getRawTransaction(String txid) async {
    final raw = _rawTx[txid];
    if (raw == null) throw DataSourceException('unknown tx', txid: txid);
    return raw;
  }

  @override
  Future<MerkleProofData> getMerkleProof(String txid) async {
    final index = _txidsInOrder.indexOf(txid);
    if (index == _gateTxIndex && _gate != null) {
      if (!gateReached.isCompleted) gateReached.complete();
      await _gate!.future;
    }
    return MerkleProofData(
      txid: txid,
      blockHeight: 1000 + index,
      merkleRoot: '',
      index: 0,
      nodes: [hex.encode(List<int>.generate(32, (i) => (0x5a + index + i) & 0xff))],
    );
  }

  @override
  Future<List<UtxoInfo>> getUtxos(String address) async => const [];

  @override
  Future<int> getCurrentBlockHeight() async => 2000;

  @override
  Future<String> submitTransaction(String rawHex) => throw UnimplementedError();

  @override
  Future<List<AddressScriptInfo>> getAddressScripts(String address) =>
      throw UnimplementedError();

  @override
  Future<List<TransactionInfo>> getScriptHistory(String scriptHash,
          {int? limit, int? offset}) =>
      throw UnimplementedError();
}

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
