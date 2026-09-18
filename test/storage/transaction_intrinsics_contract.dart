/// Transaction intrinsics contract shared by the three [ReadModelStorage]
/// backends (bead libspiffy-zpu7, doc/reachability-sweep-2026-09-18.md D-1):
/// a transaction's `nLockTime` and `version` are read back as they were
/// stored, on every backend.
///
/// These two are consensus fields of the transaction itself — the txid
/// commits to them — so a wallet that answers `lockTime: 0` about a refund
/// locked until 2035 is not merely missing a reading, it is giving the
/// opposite one: "spendable now" about a transaction that is not.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import 'read_model_keying_contract.dart' show contractHex64;

/// A real serialized transaction: version 2, one input, one output,
/// `nLockTime` 500000123 (a block-height-domain lock time far above any
/// plausible tip, so a fabricated 0 cannot be mistaken for it).
const contractTxVersion = 2;
const contractTxLockTime = 500000123;
final contractRawHex = '02000000' // version 2, little endian
    '01${'11' * 32}0000000000feffffff' // one input, non-final sequence
    '011027000000000000' // one output, 10000 sats
    '1976a914${'22' * 20}88ac'
    '7b65cd1d'; // nLockTime 500000123, little endian

/// The txid [contractRawHex] actually hashes to. A row keyed on this txid
/// holds hex that is provably its own transaction, which is what lets the
/// hex overrule a record that disagrees with it.
const contractOwnTxid =
    '67bfea580cfc746d3a7b31a163dcb796dad38df75c56190dd46c7f1135734554';

BitcoinTransaction _tx(
  String txid, {
  String? rawHex,
  int? lockTime = contractTxLockTime,
  int? version = contractTxVersion,
  TransactionStatus status = TransactionStatus.pending,
  int minute = 0,
}) =>
    BitcoinTransaction(
      txid: txid,
      rawHex: rawHex ?? contractRawHex,
      status: status,
      confirmations: 0,
      inputValue: BigInt.from(12000),
      outputValue: BigInt.from(10000),
      fee: BigInt.from(2000),
      receivingAddresses: const [],
      sendingAddresses: const [],
      netAmount: BigInt.from(10000),
      createdAt: DateTime.utc(2026, 9, 18, 12, minute),
      updatedAt: DateTime.utc(2026, 9, 18, 12, minute),
      lockTime: lockTime,
      version: version,
    );

/// Registers the transaction intrinsics contract tests.
///
/// [storage] returns the storage for the running test; [unique] a string
/// unique per test run.
void defineTransactionIntrinsicsContract(
  ReadModelStorage Function() storage, {
  required String Function() unique,
}) {
  group('transaction intrinsics contract (zpu7)', () {
    test('a stored lock time and version are read back, not replaced by 0 and 1', () async {
      final s = storage();
      final u = unique();
      final walletId = 'ti-w-$u';
      final txid = contractHex64('ti-store-$u');
      await s.storeWallet(walletId, 'W');
      await s.storeTransaction(walletId, _tx(txid));

      final read = await s.getTransaction(txid, walletId: walletId);
      expect(read, isNotNull);
      expect(read!.lockTime, contractTxLockTime);
      expect(read.version, contractTxVersion);
    });

    test('a record that disagrees with its own raw hex is stored as the hex says', () async {
      // The txid commits to both fields, so hex that hashes to the row's own
      // txid IS the transaction; a record naming something else is restating
      // it wrongly, the way V-83's funding reply restated a fee and a change
      // beside a transaction instead of reading them off it. Nothing in the
      // library writes a disagreeing record today — which is exactly why the
      // precedence needs pinning rather than leaving to chance.
      final s = storage();
      final u = unique();
      final walletId = 'ti-w-$u';
      await s.storeWallet(walletId, 'W');
      await s.storeTransaction(
        walletId,
        _tx(contractOwnTxid, lockTime: 0, version: 1),
      );

      final read = await s.getTransaction(contractOwnTxid, walletId: walletId);
      expect(read!.lockTime, contractTxLockTime,
          reason: 'the transaction locks until 500000123 whatever the record says');
      expect(read.version, contractTxVersion);
    });

    test('a record carrying neither takes both from its raw hex', () async {
      final s = storage();
      final u = unique();
      final walletId = 'ti-w-$u';
      final txid = contractHex64('ti-recover-$u');
      await s.storeWallet(walletId, 'W');
      await s.storeTransaction(walletId, _tx(txid, lockTime: null, version: null));

      final read = await s.getTransaction(txid, walletId: walletId);
      expect(read!.lockTime, contractTxLockTime, reason: 'the raw hex the wallet keeps carries it');
      expect(read.version, contractTxVersion);
    });

    test('no record value and no readable raw hex: null, not a fabricated 0 and 1', () async {
      final s = storage();
      final u = unique();
      final walletId = 'ti-w-$u';
      final txid = contractHex64('ti-absent-$u');
      await s.storeWallet(walletId, 'W');
      await s.storeTransaction(walletId, _tx(txid, rawHex: '', lockTime: null, version: null));

      final read = await s.getTransaction(txid, walletId: walletId);
      expect(read, isNotNull);
      expect(read!.lockTime, isNull,
          reason: 'a 0 here would say "spendable now" about a transaction nothing says that about');
      expect(read.version, isNull);
    });

    test('a later record neither blanks nor revises the stored lock time and version', () async {
      final s = storage();
      final u = unique();
      final walletId = 'ti-w-$u';
      final txid = contractHex64('ti-setonce-$u');
      await s.storeWallet(walletId, 'W');
      await s.storeTransaction(walletId, _tx(txid));

      // A status update carrying neither field and no raw transaction.
      await s.storeTransaction(walletId,
          _tx(txid, rawHex: '', lockTime: null, version: null, status: TransactionStatus.seenOnNetwork, minute: 1));
      var read = await s.getTransaction(txid, walletId: walletId);
      expect(read!.status, TransactionStatus.seenOnNetwork);
      expect(read.lockTime, contractTxLockTime, reason: 'nothing blanks a consensus field');
      expect(read.version, contractTxVersion);

      // A record naming different values is describing a different
      // transaction: the txid commits to both.
      await s.storeTransaction(walletId,
          _tx(txid, rawHex: '', lockTime: 17, version: 99, status: TransactionStatus.seenOnNetwork, minute: 2));
      read = await s.getTransaction(txid, walletId: walletId);
      expect(read!.lockTime, contractTxLockTime);
      expect(read.version, contractTxVersion);
    });

    test('a reorganization takes the confirmation back and leaves the lock time and version', () async {
      final s = storage();
      final u = unique();
      final walletId = 'ti-w-$u';
      final txid = contractHex64('ti-revert-$u');
      await s.storeWallet(walletId, 'W');
      await s.storeTransaction(walletId, _tx(txid, status: TransactionStatus.confirmed));

      await s.storeRevertedTransaction(
          walletId, _tx(txid, rawHex: '', lockTime: null, version: null, minute: 1));
      final read = await s.getTransaction(txid, walletId: walletId);
      expect(read!.status, TransactionStatus.pending);
      expect(read.lockTime, contractTxLockTime);
      expect(read.version, contractTxVersion);
    });
  });
}
