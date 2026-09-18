/// Bead libspiffy-nys0, write model and read model: an import with no merkle
/// proof records no block height, rather than the genesis block.
///
/// `TransactionImportedEvent.blockHeight` was a non-nullable int, so an
/// unproven receive journaled height 0 and the wallet's imported-transaction
/// record kept it. Height 0 is block 0; nothing proved the transaction was
/// in it. Where the evidence is missing the honest record is an absence
/// (spv-understanding.md, "What this library is for"), the same rule bead
/// libspiffy-jc3h/V-79 settled for UTXO rows.
///
/// The SPVActor and WalletManagerActor halves are in
/// test/actors/unproven_import_has_no_height_test.dart.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import '../actors/in_memory_event_store.dart';
import '../spv/testnet_proof_fixture.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _w = 'nys0-wallet';
const _pid = 'BitcoinWallet_$_w';
final _received = '11' * 32;

String _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();

void main() {
  late InMemoryEventStore store;
  late BitcoinWalletAggregate wallet;

  WalletState state() => wallet.currentState;
  List<Event> journal() => store.journal[_pid] ?? const [];
  Map<dynamic, dynamic> importedRecord() =>
      (state().metadata['importedTransactions'] as Map)[_received] as Map;

  setUp(() async {
    store = InMemoryEventStore();
    wallet = BitcoinWalletAggregate(
      aggregateId: _w,
      aggregateType: 'BitcoinWallet',
      eventStore: store,
      cryptoService: DartSVCryptoService(),
      secureStorage: InMemorySecureStorage(),
    );
    await wallet.preStart();
    await wallet.commandHandler(CreateWalletCommand(
        walletId: _w, walletName: 'nys0', mnemonic: _mnemonic, walletMetadata: {'network': 'testnet'}));
  });

  Future<void> record({int? blockHeight, String bumpProofHex = ''}) async {
    final root = state().rootAddress!;
    await wallet.commandHandler(ReceiveUTXOCommand(
      walletId: _w,
      txid: _received,
      vout: 0,
      satoshis: BigInt.from(200000),
      scriptPubKey: _p2pkh(root),
      address: root,
      blockHeight: blockHeight,
      initialStatus: blockHeight == null ? UTXOStatus.pending : UTXOStatus.available,
    ));
    await wallet.commandHandler(RecordImportedTransactionCommand(
      walletId: _w,
      txid: _received,
      rawHex: '',
      blockHeight: blockHeight,
      bumpProofHex: bumpProofHex,
      totalOutputSats: 200000,
      numInputs: 1,
      numOutputs: 1,
      txVersion: 1,
      txLockTime: 0,
      walletReceivingAddresses: [root],
      walletReceivedSats: 200000,
      totalInputSats: 210000,
      sendingAddresses: const [],
    ));
  }

  group('the journaled event', () {
    test('a row with no height replays as an absence, not the genesis block', () {
      final event = TransactionImportedEvent.fromMap({
        'walletId': _w,
        'txid': _received,
        'rawHex': '',
        'blockHeight': null,
        'bumpProof': '',
        'totalOutputSats': 1,
        'numInputs': 1,
        'numOutputs': 1,
        'txVersion': 1,
        'txLockTime': 0,
        'walletReceivingAddresses': <String>[],
        'walletReceivedSats': 0,
        'totalInputSats': 0,
        'sendingAddresses': <String>[],
      });
      expect(event.blockHeight, isNull);
    });

    test('an unproven import round-trips through the journal with no height', () async {
      await record();
      final event = journal().whereType<TransactionImportedEvent>().single;
      expect(event.blockHeight, isNull);
      expect(TransactionImportedEvent.fromMap(event.toMap()).blockHeight, isNull);
    });
  });

  group('the wallet record', () {
    test('an unproven import records no block height', () async {
      await record();
      expect(importedRecord().containsKey('blockHeight'), isFalse,
          reason: 'a transaction nothing proves was recorded in a block');
    });

    test('a proven import records the height its proof puts it in', () async {
      await record(blockHeight: kFixtureHeight, bumpProofHex: fixtureBumpHex());
      expect(importedRecord()['blockHeight'], kFixtureHeight);
    });

    test('a re-delivery with no proof does not take away a height already recorded', () async {
      await record(blockHeight: kFixtureHeight, bumpProofHex: fixtureBumpHex());
      await record();

      expect(importedRecord()['blockHeight'], kFixtureHeight,
          reason: 'an absence of evidence is not evidence the earlier proof was wrong');
      expect(importedRecord()['lastImportedAt'], isNotNull, reason: 'the re-delivery is still recorded');
    });

    test('the absence survives a replay of the journal', () async {
      await record();
      final replayed = BitcoinWalletAggregate(
        aggregateId: _w,
        aggregateType: 'BitcoinWallet',
        eventStore: store,
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
      );
      await replayed.preStart();
      final record0 = (replayed.currentState.metadata['importedTransactions'] as Map)[_received] as Map;
      expect(record0.containsKey('blockHeight'), isFalse);
    });
  });

  group('the read model', () {
    test('an unproven import stores a transaction in no block, and not confirmed', () async {
      final storage = InMemoryWalletStorage();
      final projection = WalletProjection(
        projectionId: 'nys0',
        eventStore: InMemoryEventStore(),
        storage: storage,
      );
      await record();
      await projection.handle(journal().whereType<TransactionImportedEvent>().single);

      final row = (await storage.getTransaction(_received))!;
      expect(row.blockHeight, isNull);
      expect(row.isConfirmed, isFalse);
      expect(row.status, TransactionStatus.pending);
    });
  });
}
