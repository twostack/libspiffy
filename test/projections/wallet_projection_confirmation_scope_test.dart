/// A confirmation, and a confirmation taken back, reach one transaction's
/// outputs and no others.
///
/// Both handlers used to read the wallet's unspent rows and skip the ones
/// whose `txid` did not match; they now ask the read model for that
/// transaction's outputs (`getUTXOsByTxid`, bead libspiffy-36jt), so the
/// scope moved from a filter in Dart to the query. Nothing pinned the old
/// filter either, which is why this exists: with the scope wrong, a single
/// confirmation stamps a proven height onto every unspent row the wallet
/// holds -- outputs of transactions no proof has placed in any block -- and
/// `confirmed` on this layer means exactly "a proof put it in a block"
/// (bead libspiffy-jc3h).
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

const _walletId = 'confirmation-scope-wallet';
const _pubKeyHash = '89abcdefabbaabbaabbaabbaabbaabbaabbaabba';
const _scriptPubKey = '76a914${_pubKeyHash}88ac';
final _address =
    dartsv.Address.fromPubkeyHash(_pubKeyHash, dartsv.NetworkType.TEST).toBase58();

/// The confirmed transaction, and one the wallet also holds outputs of.
final _confirmed = 'aa' * 32;
final _untouched = 'bb' * 32;

void main() {
  late InMemoryWalletStorage storage;
  late WalletProjection projection;
  var version = 0;
  var clock = DateTime.utc(2026, 3, 1);
  DateTime tick() => clock = clock.add(const Duration(minutes: 1));

  Future<BitcoinUtxo?> row(String txid, int vout) =>
      storage.getUTXO(_walletId, txid, vout);

  setUp(() async {
    storage = InMemoryWalletStorage();
    projection = WalletProjection(
      projectionId: 'confirmation-scope',
      eventStore: _NoopEventStore(),
      storage: storage,
    );
    version = 0;
    clock = DateTime.utc(2026, 3, 1);

    await projection.handle(WalletCreatedEvent(
      walletId: _walletId,
      walletName: 'Scope',
      rootAddress: _address,
      walletType: WalletType.hd,
      walletMetadata: {'network': 'testnet'},
      version: ++version,
      timestamp: tick(),
    ));

    // Two outputs of the transaction that gets confirmed, one of another
    // transaction that nothing in these tests mentions.
    for (final (txid, vout) in [(_confirmed, 0), (_confirmed, 1), (_untouched, 0)]) {
      await projection.handle(UTXOReceivedEvent(
        walletId: _walletId,
        txid: txid,
        vout: vout,
        satoshis: 1000,
        scriptPubKey: _scriptPubKey,
        address: _address,
        confirmations: 0,
        version: ++version,
        timestamp: tick(),
      ));
    }
    await storage.storeTransaction(
        _walletId,
        BitcoinTransaction(
          walletId: _walletId,
          txid: _confirmed,
          rawHex: '0100000000000000000000',
          status: TransactionStatus.confirmed,
          blockHeight: 810000,
          confirmations: 1,
          inputValue: BigInt.from(2200),
          outputValue: BigInt.from(2000),
          fee: BigInt.from(200),
          receivingAddresses: [_address],
          sendingAddresses: const [],
          netAmount: BigInt.from(2000),
          createdAt: clock,
          updatedAt: clock,
          lockTime: 0,
          version: 1,
        ));
  });

  test('a proven height reaches that transaction\'s outputs and no others',
      () async {
    await projection.handle(TransactionConfirmedEvent(
      walletId: _walletId,
      txid: _confirmed,
      blockHeight: 810000,
      version: ++version,
      timestamp: tick(),
    ));

    expect((await row(_confirmed, 0))?.blockHeight, 810000);
    expect((await row(_confirmed, 1))?.blockHeight, 810000,
        reason: 'every output of the transaction the proof placed');
    expect((await row(_untouched, 0))?.blockHeight, isNull,
        reason: 'no proof has placed this transaction in any block, so its '
            'output has no height and is not confirmed funds');

    final metadata =
        (await storage.getWallet(_walletId))!['metadata'] as Map<String, dynamic>;
    expect(metadata['confirmedBalance'], '2000',
        reason: 'the two outputs of the confirmed transaction');
    expect(metadata['unconfirmedBalance'], '1000',
        reason: 'and the third, which stays unconfirmed');
  });

  test('a confirmation taken back demotes that transaction\'s outputs and no '
      'others', () async {
    await projection.handle(TransactionConfirmedEvent(
      walletId: _walletId,
      txid: _confirmed,
      blockHeight: 810000,
      version: ++version,
      timestamp: tick(),
    ));
    // The third output is available and unconfirmed: a revert must not touch
    // it, in either direction.
    await projection.handle(UTXOMarkedAvailableEvent(
      walletId: _walletId,
      txid: _untouched,
      vout: 0,
      version: ++version,
      timestamp: tick(),
    ));
    expect((await row(_untouched, 0))?.status, UTXOStatus.available);

    await projection.handle(TransactionConfirmationRevertedEvent(
      walletId: _walletId,
      txid: _confirmed,
      reason: 'reorg',
      version: ++version,
      timestamp: tick(),
    ));

    for (final vout in [0, 1]) {
      final reverted = await row(_confirmed, vout);
      expect(reverted?.blockHeight, isNull, reason: 'output $vout');
      expect(reverted?.status, UTXOStatus.pending,
          reason: 'an output of a transaction no longer in a block is '
              'pending again');
    }
    final untouched = await row(_untouched, 0);
    expect(untouched?.status, UTXOStatus.available,
        reason: 'another transaction\'s output is not demoted by this '
            'reorganization');
    expect(untouched?.blockHeight, isNull);

    final metadata =
        (await storage.getWallet(_walletId))!['metadata'] as Map<String, dynamic>;
    expect(metadata['confirmedBalance'], '0');
    expect(metadata['unconfirmedBalance'], '3000');
  });
}

class _NoopEventStore implements EventStore {
  @override
  Future<void> persistEvent(String persistenceId, Event event, int expectedVersion) async {}

  @override
  Future<void> persistEvents(String persistenceId, List<Event> events, int expectedVersion) async {}

  @override
  Future<List<Event>> getEvents(String persistenceId, {int fromSequence = 0, int? toSequence}) async => [];

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) async => 0;

  @override
  Future<void> saveSnapshot(String persistenceId, dynamic state, int sequenceNumber) async {}

  @override
  Future<SnapshotData?> loadSnapshot(String persistenceId) async => null;

  @override
  Future<void> deleteOldSnapshots(String persistenceId, int keepCount) async {}

  @override
  Future<void> close() async {}
}
