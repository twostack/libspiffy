/// Bead libspiffy-ymi6: the same delivery of a received transaction is
/// journaled once, and a delivery that carries something new is journaled.
///
/// `RecordImportedTransactionCommand` journaled a `TransactionImportedEvent`
/// unconditionally, so a caller that re-issued it — a channel close resumed
/// after a restart, whose read-model guard is a no-op when the manager has no
/// storage — wrote a second event saying exactly what the first one said.
/// `OutgoingTransactions.recordOutgoing` has had that rule since bead
/// libspiffy-viy; this is the same rule for the inbound direction.
///
/// The line is exact equivalence, and the tests below are the guard on it: a
/// delivery carries evidence the wallet's own record does not keep (the raw
/// transaction, the BUMP, the ancestors its BEEF carried, which of our
/// addresses it pays), and the read model is built from these events, so
/// anything that differs must still be journaled. Swallowing a delivery that
/// is not identical would lose exactly what bead libspiffy-nys0/V-80 was
/// fixed to keep.
library;

import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';
import '../spv/testnet_proof_fixture.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _w = 'ymi6-wallet';
const _pid = 'BitcoinWallet_$_w';
final _received = '22' * 32;
final _ancestorTxid = '33' * 32;

void main() {
  late InMemoryEventStore store;
  late BitcoinWalletAggregate wallet;

  WalletState state() => wallet.currentState;
  List<Event> journal() => store.journal[_pid] ?? const [];
  List<TransactionImportedEvent> imports() => journal().whereType<TransactionImportedEvent>().toList();
  Map<dynamic, dynamic> importedRecord() => (state().metadata['importedTransactions'] as Map)[_received] as Map;

  Future<BitcoinWalletAggregate> openWallet() async {
    final aggregate = BitcoinWalletAggregate(
      aggregateId: _w,
      aggregateType: 'BitcoinWallet',
      eventStore: store,
      cryptoService: DartSVCryptoService(),
      secureStorage: InMemorySecureStorage(),
    );
    await aggregate.preStart();
    return aggregate;
  }

  setUp(() async {
    store = InMemoryEventStore();
    wallet = await openWallet();
    await wallet.commandHandler(CreateWalletCommand(
        walletId: _w, walletName: 'ymi6', mnemonic: _mnemonic, walletMetadata: {'network': 'testnet'}));
  });

  /// The delivery of [_received] a counterparty hands this wallet. Every
  /// argument is a piece of what the delivery carries; the defaults are one
  /// unproven receive, and two calls with the same arguments are the same
  /// delivery handed over twice.
  RecordImportedTransactionCommand delivery({
    int? blockHeight,
    String bumpProofHex = '',
    List<String>? receivingAddresses,
    List<BeefAncestor> ancestors = const [],
    String? counterpartyMarker,
    String rawHex = kFixtureTxHex,
  }) =>
      RecordImportedTransactionCommand(
        walletId: _w,
        txid: _received,
        rawHex: rawHex,
        blockHeight: blockHeight,
        bumpProofHex: bumpProofHex,
        totalOutputSats: 200000,
        numInputs: 1,
        numOutputs: 2,
        txVersion: 1,
        txLockTime: 0,
        walletReceivingAddresses: receivingAddresses ?? [state().rootAddress!],
        walletReceivedSats: 200000,
        totalInputSats: 210000,
        sendingAddresses: const ['1SenderAddress'],
        ancestors: ancestors,
        counterpartyMarker: counterpartyMarker,
      );

  group('the same delivery again', () {
    test('journals one TransactionImportedEvent', () async {
      await wallet.commandHandler(delivery());
      final versionAfterFirst = state().version;

      await wallet.commandHandler(delivery());

      expect(imports().length, 1,
          reason: 'the same delivery handed over twice says nothing the wallet does not hold');
      expect(state().version, versionAfterFirst, reason: 'a delivery that journals nothing moves no version');
      expect(importedRecord()['txid'], _received, reason: 'the wallet still holds its record of the transaction');
    });

    test('is dropped after the journal is replayed', () async {
      await wallet.commandHandler(delivery(blockHeight: kFixtureHeight, bumpProofHex: fixtureBumpHex()));

      final replayed = await openWallet();
      await replayed.commandHandler(delivery(blockHeight: kFixtureHeight, bumpProofHex: fixtureBumpHex()));

      expect(imports().length, 1, reason: 'what the wallet holds is what its journal replays');
    });

    test('is dropped whatever it carries, as long as it is the same', () async {
      final ancestors = [BeefAncestor(txid: _ancestorTxid, rawHex: kFixtureTxHex, bumpHex: fixtureBumpHex())];
      await wallet.commandHandler(delivery(ancestors: ancestors, counterpartyMarker: 'alice@example.com'));
      await wallet.commandHandler(delivery(ancestors: ancestors, counterpartyMarker: 'alice@example.com'));

      expect(imports().length, 1);
    });
  });

  group('a delivery that carries something new', () {
    test('a proof the wallet did not have is journaled', () async {
      await wallet.commandHandler(delivery());
      await wallet.commandHandler(delivery(blockHeight: kFixtureHeight, bumpProofHex: fixtureBumpHex()));

      expect(imports().length, 2, reason: 'a proof of the block it is in is evidence the wallet did not have');
      expect(imports().last.bumpProof, isNotEmpty, reason: 'the BUMP reaches the read model only in the event');
      expect(importedRecord()['blockHeight'], kFixtureHeight);
    });

    test('ancestors the first delivery did not carry are journaled', () async {
      await wallet.commandHandler(delivery());
      await wallet.commandHandler(delivery(ancestors: [
        BeefAncestor(txid: _ancestorTxid, rawHex: kFixtureTxHex, bumpHex: fixtureBumpHex()),
      ]));

      expect(imports().length, 2,
          reason: 'the ancestry of an unproven receive is kept nowhere but these events; '
              'the wallet record cannot tell the two deliveries apart and must not try');
      expect(imports().last.ancestors.single.txid, _ancestorTxid);
    });

    test('an output of ours the first delivery did not name is journaled', () async {
      await wallet.commandHandler(delivery(receivingAddresses: const []));
      await wallet.commandHandler(delivery());

      expect(imports().length, 2,
          reason: 'a re-delivery read against a key the wallet did not have then '
              'says an output is ours after all');
      expect(imports().last.walletReceivingAddresses, [state().rootAddress]);
    });

    test('a counterparty marker the first delivery did not name is journaled', () async {
      await wallet.commandHandler(delivery());
      await wallet.commandHandler(delivery(counterpartyMarker: 'alice@example.com'));

      expect(imports().length, 2);
      expect(imports().last.counterpartyMarker, 'alice@example.com');
    });

    test('a proofless re-delivery of a proven transaction is journaled and keeps the height', () async {
      await wallet.commandHandler(delivery(blockHeight: kFixtureHeight, bumpProofHex: fixtureBumpHex()));
      await wallet.commandHandler(delivery());

      expect(imports().length, 2,
          reason: 'a delivery with less evidence than the last one is not the same delivery; '
              'dropping it would be the write model deciding what the read model may see');
      expect(importedRecord()['blockHeight'], kFixtureHeight,
          reason: 'bead libspiffy-nys0/V-80: an absence of evidence is not evidence the proof was wrong');
      expect(importedRecord()['lastImportedAt'], isNotNull, reason: 'the re-delivery is recorded');
    });

    test('the same delivery once more, after a different one, is journaled again', () async {
      final proven = delivery(blockHeight: kFixtureHeight, bumpProofHex: fixtureBumpHex());
      await wallet.commandHandler(proven);
      await wallet.commandHandler(delivery());
      await wallet.commandHandler(
          delivery(blockHeight: kFixtureHeight, bumpProofHex: fixtureBumpHex()));

      expect(imports().length, 3,
          reason: 'the record remembers the last delivery, not every one: an older delivery '
              'handed over again is journaled rather than compared against a growing list');
      expect(imports().last.blockHeight, kFixtureHeight);
      expect(proven.txid, _received);
    });
  });

  group('a transaction the wallet never received', () {
    test('is recorded, whatever another transaction was delivered', () async {
      await wallet.commandHandler(delivery());
      const other = kFixtureTxid;
      await wallet.commandHandler(RecordImportedTransactionCommand(
        walletId: _w,
        txid: other,
        rawHex: kFixtureTxHex,
        blockHeight: null,
        bumpProofHex: '',
        totalOutputSats: 200000,
        numInputs: 1,
        numOutputs: 2,
        txVersion: 1,
        txLockTime: 0,
        walletReceivingAddresses: [state().rootAddress!],
        walletReceivedSats: 200000,
        totalInputSats: 210000,
        sendingAddresses: const ['1SenderAddress'],
      ));

      expect(imports().length, 2);
      expect((state().metadata['importedTransactions'] as Map).keys, [_received, other]);
    });
  });
}
