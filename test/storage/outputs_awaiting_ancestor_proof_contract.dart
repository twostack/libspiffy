/// `getOutputsAwaitingAncestorProof` contract, shared by the three
/// [ReadModelStorage] backends (bead libspiffy-czhx).
///
/// When a reorganization takes an ancestor's block off the active chain, the
/// walk back from one of our outputs runs off the end of what we store: the
/// output cannot go into a BEEF and cannot be spent. The wallet says so
/// rather than holding an unspendable output in silence — it names the
/// ancestor, what its last proof said, and **who to ask** for a fresh one
/// (bead libspiffy-a2v3): the counterparty of the transaction *we received*,
/// read off its own row.
///
/// The three backends share [outputsAwaitingAncestorProof], but each
/// overrides `getTransactionsByTxids`, which is where the counterparty marker
/// and the `walletId` the answer is filtered by come from. Two wallets can
/// hold the same transaction with a different counterparty each, so a backend
/// that drops `walletId` there silently drops the marker — and with it the
/// only recovery route besides the block returning. Nothing here is fetched
/// from a service: ARC has no standing to prove a counterparty's transaction.
library;

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import 'read_model_keying_contract.dart' show contractHex64;

/// A raw transaction spending [prevTxid]:0 and paying [sats] to one output:
/// enough for the ancestor walk, which reads inputs and outputs only.
dartsv.Transaction _rawTransaction(Uint8List prevTxid, int sats) {
  final b = BytesBuilder();
  void u32(int v) => b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  u32(1);
  b.addByte(1);
  b.add(prevTxid);
  u32(0);
  b.add([1, 0x51]);
  u32(0xffffffff);
  b.addByte(1);
  final value = ByteData(8)..setUint64(0, sats, Endian.little);
  b.add(value.buffer.asUint8List());
  final script = hex.decode('76a914${'00' * 20}88ac');
  b.addByte(script.length);
  b.add(script);
  u32(0);
  return dartsv.Transaction.fromHex(hex.encode(b.toBytes()));
}

/// The internal (little-endian) form of a display txid.
Uint8List _internal(String displayTxid) =>
    Uint8List.fromList(hex.decode(displayTxid).reversed.toList());

BitcoinTransaction _row(String walletId, dartsv.Transaction tx, String? marker) => BitcoinTransaction(
      walletId: walletId,
      txid: tx.id,
      rawHex: tx.serialize(),
      status: TransactionStatus.pending,
      inputValue: BigInt.from(2000),
      outputValue: BigInt.from(1000),
      fee: BigInt.from(1000),
      receivingAddresses: const ['mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt'],
      sendingAddresses: const [],
      netAmount: BigInt.from(1000),
      createdAt: DateTime.utc(2026, 9, 18, 12),
      updatedAt: DateTime.utc(2026, 9, 18, 12),
      lockTime: 0,
      version: 1,
      counterpartyMarker: marker,
    );

BitcoinUtxo _output(dartsv.Transaction tx) => BitcoinUtxo(
      txid: tx.id,
      vout: 0,
      value: dartsv.Coin.ofSat(BigInt.from(1000)),
      scriptPubKey: tx.outputs[0].script.toHex(),
      address: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
      status: UTXOStatus.available,
      createdAt: DateTime.utc(2026, 9, 18, 12),
      updatedAt: DateTime.utc(2026, 9, 18, 12),
    );

/// Registers the contract tests. [storage] returns the storage for the
/// running test; [unique] a string unique per test run (the Postgres database
/// outlives a run).
void defineOutputsAwaitingAncestorProofContract(
  ReadModelStorage Function() storage, {
  required String Function() unique,
}) {
  /// The ancestor G (proven, then orphaned) and the payment P we received,
  /// which spends it and gave us P:0. Both unique per [tag].
  (dartsv.Transaction, dartsv.Transaction) chain(String tag) {
    final seed = Uint8List.fromList(sha256.convert('awaiting-$tag'.codeUnits).bytes);
    final g = _rawTransaction(seed, 2000);
    return (g, _rawTransaction(_internal(g.id), 1000));
  }

  group('outputs awaiting an ancestor proof (czhx)', () {
    test('czhx: an output whose ancestor lost its proof is named, with the ancestor, the reason and '
        'the counterparty to ask', () async {
      final u = unique();
      final s = storage();
      final wallet = 'awaiting-$u';
      final (g, p) = chain(u);
      final block = contractHex64('awaiting-block-$u');

      await s.storeWallet(wallet, 'W');
      await s.storeTransaction(wallet, _row(wallet, p, 'bob-$u'));
      await s.upsertUTXO(wallet, _output(p));
      await s.storeAncestorTransaction(g.id, g.serialize());
      await s.storeMerkleProof(
          g.id,
          MerkleProof(
            txid: g.id,
            blockHash: block,
            blockHeight: 812345,
            position: 0,
            merkleProof: ['fe${g.id}'],
            status: MerkleProofStatus.verified,
          ));

      expect(await s.getOutputsAwaitingAncestorProof(wallet), isEmpty,
          reason: 'the walk reaches a proof on the active chain, so nothing is blocked');

      // A reorganization takes the ancestor's block off the active chain. The
      // proof row is kept (the block can come back); it just stops counting.
      expect(await s.markMerkleProofOrphaned(g.id, blockHash: block), isTrue);

      final awaiting = await s.getOutputsAwaitingAncestorProof(wallet);
      expect(awaiting.map((o) => o.outpoint).toList(), ['${p.id}:0']);
      final blocked = awaiting.single;
      expect(blocked.counterpartyMarker, 'bob-$u',
          reason: 'who to ask for a fresh BEEF: the counterparty of the transaction we received, '
              "read off this wallet's row for it");
      expect(blocked.ancestors.map((a) => a.txid).toList(), [g.id],
          reason: 'the ancestor whose proof left the chain, not whatever is behind it');
      final ancestor = blocked.ancestors.single;
      expect((ancestor.lastProofStatus, ancestor.blockHeight),
          (MerkleProofStatus.orphaned, 812345),
          reason: 'what its last proof said, so the gap can be explained without another lookup');
      expect(ancestor.reason, allOf(contains('orphaned'), contains('812345')));

      // RETENTION: nothing about the output or the proof was removed.
      expect((await s.getMerkleProofHistory(g.id)).single.status, MerkleProofStatus.orphaned);
      expect((await s.getUTXOs(wallet)).map((utxo) => utxo.key), contains('${p.id}:0'));
    });

    test('czhx: each wallet is answered with its own counterparty for the same transaction', () async {
      final u = unique();
      final s = storage();
      final alice = 'awaiting-alice-$u';
      final carol = 'awaiting-carol-$u';
      final (g, p) = chain('shared-$u');
      final block = contractHex64('awaiting-shared-block-$u');

      for (final (wallet, marker) in [(alice, 'bob-$u'), (carol, 'dave-$u')]) {
        await s.storeWallet(wallet, 'W');
        await s.storeTransaction(wallet, _row(wallet, p, marker));
        await s.upsertUTXO(wallet, _output(p));
      }
      await s.storeAncestorTransaction(g.id, g.serialize());
      await s.storeMerkleProof(
          g.id,
          MerkleProof(
              txid: g.id,
              blockHash: block,
              blockHeight: 7,
              position: 0,
              merkleProof: ['fe${g.id}'],
              status: MerkleProofStatus.verified));
      expect(await s.markMerkleProofOrphaned(g.id, blockHash: block), isTrue);

      // The rows a backend hands the shared walk must say which wallet each
      // belongs to, or a wallet is answered with somebody else's counterparty
      // — or with none at all.
      final rows = await s.getTransactionsByTxids([p.id]);
      expect(rows.map((r) => (r.walletId, r.counterpartyMarker)).toSet(),
          {(alice, 'bob-$u'), (carol, 'dave-$u')},
          reason: 'getTransactionsByTxids must carry walletId on every backend');

      expect((await s.getOutputsAwaitingAncestorProof(alice)).single.counterpartyMarker, 'bob-$u');
      expect((await s.getOutputsAwaitingAncestorProof(carol)).single.counterpartyMarker, 'dave-$u');
    });

    test('czhx: an output of a transaction recorded with no counterparty is named with nobody to ask',
        () async {
      final u = unique();
      final s = storage();
      final wallet = 'awaiting-nomarker-$u';
      final (g, p) = chain('nomarker-$u');
      final block = contractHex64('awaiting-nomarker-block-$u');

      await s.storeWallet(wallet, 'W');
      await s.storeTransaction(wallet, _row(wallet, p, null));
      await s.upsertUTXO(wallet, _output(p));
      await s.storeAncestorTransaction(g.id, g.serialize());
      await s.storeMerkleProof(
          g.id,
          MerkleProof(
              txid: g.id,
              blockHash: block,
              blockHeight: 9,
              position: 0,
              merkleProof: ['fe${g.id}'],
              status: MerkleProofStatus.verified));
      expect(await s.markMerkleProofOrphaned(g.id, blockHash: block), isTrue);

      final blocked = (await s.getOutputsAwaitingAncestorProof(wallet)).single;
      expect(blocked.counterpartyMarker, isNull,
          reason: 'nobody to ask: only the block returning can restore this output');
      expect(blocked.ancestors.single.txid, g.id);
    });
  });
}
