/// Beads libspiffy-jc3h and libspiffy-pq8p: one meaning for "confirmed",
/// enforced at every layer.
///
/// spv-understanding.md, "Balances": *"the transaction is in a block whose
/// header we hold on our active chain, and we have the merkle proof that puts
/// it there. Nothing else confirms anything."* A UTXO's `blockHeight` is
/// exactly that evidence — it is written only by a confirmation verified
/// against our own header chain (beads libspiffy-5ry, libspiffy-8oaq,
/// libspiffy-4dja) and a reorganization takes it off again — so
/// `blockHeight != null` **is** the confirmed test everywhere.
///
/// A confirmation *count* is not evidence, and there is deliberately no
/// six-confirmation threshold: a proof on our active chain confirms at depth
/// one exactly as it does at depth six. Waiting for depth is an
/// application's policy, not this library's rule.
///
/// Pinned here:
///
/// * `WalletBalances.bucketOf` and the aggregate's journaled balance totals
///   split confirmed from unconfirmed by the proven height, not by a count.
/// * The read model's wallet row answers the same way, from the same events.
/// * `UpdateUTXOConfirmationsCommand` (deprecated) cannot make an output
///   report as confirmed on either layer: it records the count it was given
///   and no height at all (libspiffy-pq8p, the V-78 residue).
/// * A reorganization that reverts the confirmation takes the amount back
///   out of confirmed balance.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_balances.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import '../actors/in_memory_event_store.dart';

const _w = 'confirmed-means-proven-height';

final _key = dartsv.SVPrivateKey.fromHex('44' * 32, dartsv.NetworkType.TEST);
final _address = _key.publicKey.toAddress(dartsv.NetworkType.TEST).toBase58();
final _script =
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(_address)).getScriptPubkey().toHex();

String _txid(int n) => n.toRadixString(16).padLeft(64, '0');
String _outpoint(int n) => '${_txid(n)}:0';

BitcoinUtxo _utxo({
  int n = 1,
  int sats = 50000,
  UTXOStatus status = UTXOStatus.available,
  int? blockHeight,
  int? confirmations,
}) =>
    BitcoinUtxo(
      txid: _txid(n),
      vout: 0,
      value: dartsv.Coin.ofSat(BigInt.from(sats)),
      scriptPubKey: _script,
      address: _address,
      status: status,
      blockHeight: blockHeight,
      confirmations: confirmations,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

/// Applies a hand-written journal to the wallet aggregate and, event for
/// event, to a fresh read model: the two layers must answer the same way
/// about the same events.
class _BothLayers {
  final InMemoryEventStore store = InMemoryEventStore();
  final InMemoryWalletStorage storage = InMemoryWalletStorage();
  late final BitcoinWalletAggregate aggregate = BitcoinWalletAggregate(
    aggregateId: _w,
    aggregateType: 'BitcoinWallet',
    eventStore: store,
    cryptoService: DartSVCryptoService(),
    secureStorage: InMemorySecureStorage(),
  );
  late final WalletProjection projection =
      WalletProjection(projectionId: 'confirmed-rule', eventStore: store, storage: storage);

  int _version = 0;

  Future<void> created() => apply((v) => WalletCreatedEvent(
        walletId: _w,
        walletName: 'confirmed',
        rootAddress: _address,
        walletType: WalletType.hd,
        walletMetadata: const {'network': 'testnet'},
        version: v,
        timestamp: DateTime.utc(2026),
      ));

  Future<void> apply(Event Function(int version) build) async {
    final event = build(++_version);
    aggregate.eventHandler(event);
    await projection.handle(event);
  }

  /// A receive as `WalletManagerActor` journals it: the height and
  /// `available` together when a verified proof backed the BEEF, neither
  /// when it did not (`ReceiveUTXOCommand` refuses any other combination).
  Future<void> receive(int n, int sats, {int? provenHeight}) => apply((v) => UTXOReceivedEvent(
        walletId: _w,
        txid: _txid(n),
        vout: 0,
        satoshis: sats,
        scriptPubKey: _script,
        address: _address,
        initialStatus: provenHeight == null ? UTXOStatus.pending : UTXOStatus.available,
        blockHeight: provenHeight,
        confirmations: provenHeight == null ? 0 : 1,
        version: v,
        timestamp: DateTime.utc(2026),
      ));

  Future<void> confirmed(int n, int height) => apply((v) => TransactionConfirmedEvent(
        walletId: _w,
        txid: _txid(n),
        blockHeight: height,
        version: v,
        timestamp: DateTime.utc(2026, 1, 2),
      ));

  Future<void> reverted(int n) => apply((v) => TransactionConfirmationRevertedEvent(
        walletId: _w,
        txid: _txid(n),
        reason: 'reorganization',
        version: v,
        timestamp: DateTime.utc(2026, 1, 3),
      ));

  /// The deprecated command's event: a caller's count and height, verified
  /// against nothing.
  Future<void> reportedCount(int n, {required int confirmations, int? blockHeight}) =>
      apply((v) => UTXOConfirmationUpdatedEvent(
            walletId: _w,
            txid: _txid(n),
            vout: 0,
            confirmations: confirmations,
            blockHeight: blockHeight,
            version: v,
            timestamp: DateTime.utc(2026, 1, 2),
          ));

  BitcoinUtxo state(int n) => aggregate.currentState.utxos[_outpoint(n)]!;

  Future<Map<String, dynamic>> row() async =>
      (await storage.getWallet(_w))!['metadata'] as Map<String, dynamic>;

  Future<BitcoinUtxo> stored(int n) async =>
      (await storage.getUTXOs(_w, includeSpent: true)).singleWhere((u) => u.txid == _txid(n));
}

void main() {
  group('jc3h: the bucket rule is the proven height, not a count', () {
    test('a proven height at depth one is confirmed balance', () {
      expect(WalletBalances.bucketOf(_utxo(blockHeight: 900000, confirmations: 1)), BalanceBucket.confirmed);
    });

    test('a proven height with no count at all is confirmed balance', () {
      expect(WalletBalances.bucketOf(_utxo(blockHeight: 900000)), BalanceBucket.confirmed);
    });

    test('a pending UTXO with a proven height is confirmed balance (it is money in a block)', () {
      expect(WalletBalances.bucketOf(_utxo(status: UTXOStatus.pending, blockHeight: 900000)),
          BalanceBucket.confirmed);
    });

    test('a reported count with no proven height is unconfirmed, however deep it claims to be', () {
      for (final count in [1, 6, 100]) {
        expect(WalletBalances.bucketOf(_utxo(confirmations: count)), BalanceBucket.unconfirmed,
            reason: 'a count of $count is not evidence of anything');
      }
    });

    test('reserved still wins over a proven height', () {
      expect(WalletBalances.bucketOf(_utxo(status: UTXOStatus.reserved, blockHeight: 900000)),
          BalanceBucket.reserved);
    });

    test('a voided output with a proven height still counts nowhere (libspiffy-3arz)', () {
      expect(WalletBalances.bucketOf(_utxo(status: UTXOStatus.voided, blockHeight: 900000)), isNull);
    });

    test('BitcoinUtxo.isConfirmed is the proven height alone', () {
      expect(_utxo(blockHeight: 900000).isConfirmed, isTrue,
          reason: 'the height is the evidence; no count has to agree with it');
      expect(_utxo(blockHeight: 900000, confirmations: 0).isConfirmed, isTrue);
      expect(_utxo(confirmations: 6).isConfirmed, isFalse);
      expect(_utxo().isConfirmed, isFalse);
    });

    test('totals put a depth-one proven UTXO in confirmed and a counted one in unconfirmed', () {
      final totals = WalletBalances.totals([
        _utxo(n: 1, sats: 40000, blockHeight: 900000, confirmations: 1),
        _utxo(n: 2, sats: 7000, confirmations: 9),
      ]);
      expect(totals.confirmed, BigInt.from(40000));
      expect(totals.unconfirmed, BigInt.from(7000));
    });
  });

  group('jc3h: both layers answer the same way about the same events', () {
    test('a proven receive at depth one is confirmed balance in the aggregate and the wallet row',
        () async {
      final both = _BothLayers();
      await both.created();
      await both.receive(1, 40000, provenHeight: 900000);

      expect(both.aggregate.currentState.confirmedBalance.getValue(), BigInt.from(40000),
          reason: 'a proof put it in a block on our chain: that is confirmed, at depth one');
      expect(both.aggregate.currentState.unconfirmedBalance.getValue(), BigInt.zero);
      expect((await both.row())['confirmedBalance'], '40000');
      expect((await both.row())['unconfirmedBalance'], '0');
    });

    test('an unproven receive is unconfirmed on both layers', () async {
      final both = _BothLayers();
      await both.created();
      await both.receive(1, 40000);

      expect(both.aggregate.currentState.confirmedBalance.getValue(), BigInt.zero);
      expect(both.aggregate.currentState.unconfirmedBalance.getValue(), BigInt.from(40000));
      expect((await both.row())['confirmedBalance'], '0');
      expect((await both.row())['unconfirmedBalance'], '40000');
    });

    test('a later proof moves the amount into confirmed balance on both layers', () async {
      final both = _BothLayers();
      await both.created();
      await both.receive(1, 40000);
      await both.confirmed(1, 900001);

      expect(both.state(1).blockHeight, 900001);
      expect((await both.stored(1)).blockHeight, 900001);
      expect(both.aggregate.currentState.confirmedBalance.getValue(), BigInt.from(40000));
      expect((await both.row())['confirmedBalance'], '40000',
          reason: 'the wallet row must not lag the write model about the same block');
      expect((await both.row())['unconfirmedBalance'], '0');
    });

    test('a reorganization that reverts the confirmation takes it back out of confirmed', () async {
      final both = _BothLayers();
      await both.created();
      await both.receive(1, 40000, provenHeight: 900000);
      await both.reverted(1);

      expect(both.state(1).blockHeight, isNull);
      expect(both.aggregate.currentState.confirmedBalance.getValue(), BigInt.zero);
      expect(both.aggregate.currentState.unconfirmedBalance.getValue(), BigInt.from(40000));
      expect((await both.row())['confirmedBalance'], '0');
      expect((await both.row())['unconfirmedBalance'], '40000');
    });
  });

  group('pq8p: the deprecated confirmation command cannot make an output report as confirmed', () {
    test('a reported height is not written to the row on either layer', () async {
      final both = _BothLayers();
      await both.created();
      await both.receive(1, 40000);
      await both.reportedCount(1, confirmations: 6, blockHeight: 900000);

      expect(both.state(1).blockHeight, isNull,
          reason: 'this command has no evidence; a height is evidence (libspiffy-pq8p)');
      expect((await both.stored(1)).blockHeight, isNull);
      expect(both.state(1).isConfirmed, isFalse);
      expect((await both.stored(1)).isConfirmed, isFalse);
    });

    test('the amount stays unconfirmed balance on both layers', () async {
      final both = _BothLayers();
      await both.created();
      await both.receive(1, 40000);
      await both.reportedCount(1, confirmations: 6, blockHeight: 900000);

      expect(both.aggregate.currentState.confirmedBalance.getValue(), BigInt.zero);
      expect(both.aggregate.currentState.unconfirmedBalance.getValue(), BigInt.from(40000));
      expect((await both.row())['confirmedBalance'], '0');
      expect((await both.row())['unconfirmedBalance'], '40000');
    });

    test('the count it reported is still recorded: we keep what we were told', () async {
      final both = _BothLayers();
      await both.created();
      await both.receive(1, 40000);
      await both.reportedCount(1, confirmations: 6, blockHeight: 900000);

      expect(both.state(1).confirmations, 6);
      expect((await both.stored(1)).confirmations, 6);
    });

    test('it cannot take a proven height off a confirmed output either', () async {
      final both = _BothLayers();
      await both.created();
      await both.receive(1, 40000, provenHeight: 900000);
      await both.reportedCount(1, confirmations: 0);

      expect(both.state(1).blockHeight, 900000,
          reason: 'only a reorganization revert takes a proven height off (applyConfirmationReverted)');
      expect((await both.stored(1)).blockHeight, 900000);
      expect(both.aggregate.currentState.confirmedBalance.getValue(), BigInt.from(40000));
      expect((await both.row())['confirmedBalance'], '40000');
    });
  });
}
