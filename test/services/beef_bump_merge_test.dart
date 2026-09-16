/// libspiffy-0lx (part 2): outgoing BEEFs repeated an identical BUMP for
/// every ancestor mined in the same block instead of merging them into one
/// BRC-74 multi-leaf BUMP.
///
/// A BUMP is a merkle path inside ONE block and BRC-74 lets a single BUMP
/// carry the paths of SEVERAL transactions of that block: the levels above
/// the leaves are shared. Emitting one BUMP per ancestor repeats those
/// levels (64 bytes per level for two ancestors) and, for the recipient,
/// says nothing a single merged BUMP would not.
///
/// The block here is real in the only sense that matters for SPV: eight
/// leaves, a merkle root computed by the plain Bitcoin algorithm in this
/// file (not by the library), and a mined regtest header carrying that
/// root. Every assertion about verifiability goes through the receiving
/// path — `BEEF.parse` followed by
/// `BEEF.validateTransactionWithBlockHeader` — exactly as a counterparty
/// would.
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/services/ancestor_chain_service.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/services/payment_channel_builder.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/bump.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';
import 'package:libspiffy/src/utils/hex_utils.dart' as hex_utils;
import 'package:spiffynode/spiffy_node.dart' show BlockHeader, Hash;
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';

const _xpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';

// ---------------------------------------------------------------------------
// Merkle fixture, computed independently of the library
// ---------------------------------------------------------------------------

Uint8List _sha256d(List<int> data) =>
    Uint8List.fromList(sha256.convert(sha256.convert(data).bytes).bytes);

Uint8List _hashPair(Uint8List left, Uint8List right) => _sha256d([...left, ...right]);

/// Merkle root of [leaves] (internal byte order), Bitcoin style: pair up,
/// duplicating the last hash of an odd level.
Uint8List _merkleRoot(List<Uint8List> leaves) {
  var level = List<Uint8List>.of(leaves);
  while (level.length > 1) {
    if (level.length.isOdd) level.add(level.last);
    final next = <Uint8List>[];
    for (var i = 0; i < level.length; i += 2) {
      next.add(_hashPair(level[i], level[i + 1]));
    }
    level = next;
  }
  return level.single;
}

/// TSC-style sibling list for [index]: display hex bottom-up, `"*"` where
/// the sibling is a duplicate of the working hash.
List<String> _tscNodes(List<Uint8List> leaves, int index) {
  var level = List<Uint8List>.of(leaves);
  var idx = index;
  final nodes = <String>[];
  while (level.length > 1) {
    final wasOdd = level.length.isOdd;
    if (wasOdd) level.add(level.last);
    final sib = idx ^ 1;
    nodes.add(wasOdd && sib == level.length - 1
        ? '*'
        : hex_utils.internalToDisplay(level[sib]));
    final next = <Uint8List>[];
    for (var i = 0; i < level.length; i += 2) {
      next.add(_hashPair(level[i], level[i + 1]));
    }
    level = next;
    idx >>= 1;
  }
  return nodes;
}

Uint8List _filler(String seed) => _sha256d(utf8.encode('libspiffy-0lx-$seed'));

void main() {
  final key = dartsv.HDPrivateKey.fromXpriv(_xpriv)
      .deriveChildNumber(0)
      .deriveChildNumber(0)
      .privateKey;
  final address = key.publicKey.toAddress(dartsv.NetworkType.TEST);
  final lock = dartsv.P2PKHLockBuilder.fromAddress(address);
  final sighash =
      dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value;

  dartsv.Transaction spend(List<(dartsv.Transaction, int)> inputs, List<int> outputs) {
    final builder = dartsv.TransactionBuilder();
    for (final (parent, vout) in inputs) {
      final out = parent.outputs[vout];
      builder.spendFromOutpointWithSigner(
        dartsv.DefaultTransactionSigner(sighash, key),
        dartsv.TransactionOutpoint(parent.id, vout, out.satoshis, out.script),
        dartsv.TransactionInput.MAX_SEQ_NUMBER,
        dartsv.P2PKHUnlockBuilder(key.publicKey),
      );
    }
    for (final sats in outputs) {
      builder.spendToLockBuilder(lock, BigInt.from(sats));
    }
    builder.withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);
    return builder.build(false);
  }

  /// A transaction that is already mined as far as this test is concerned:
  /// it spends a made-up outpoint owned by the test key.
  dartsv.Transaction mined(String seed, int sats) {
    final builder = dartsv.TransactionBuilder();
    builder.spendFromOutpointWithSigner(
      dartsv.DefaultTransactionSigner(sighash, key),
      dartsv.TransactionOutpoint(
        hex_utils.internalToDisplay(_filler(seed)),
        0,
        BigInt.from(sats + 1000),
        lock.getScriptPubkey(),
      ),
      dartsv.TransactionInput.MAX_SEQ_NUMBER,
      dartsv.P2PKHUnlockBuilder(key.publicKey),
    );
    builder.spendToLockBuilder(lock, BigInt.from(sats));
    builder.withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);
    return builder.build(false);
  }

  BitcoinTransaction record(dartsv.Transaction tx) => BitcoinTransaction(
        walletId: 'w',
        txid: tx.id,
        rawHex: tx.serialize(),
        status: TransactionStatus.confirmed,
        inputValue: BigInt.zero,
        outputValue: BigInt.zero,
        fee: BigInt.zero,
        receivingAddresses: const [],
        sendingAddresses: const [],
        netAmount: BigInt.zero,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        lockTime: 0,
        version: 1,
      );

  /// The txid as it sits in a merkle tree (internal byte order).
  Uint8List leafOf(dartsv.Transaction tx) => hex_utils.displayToInternal(tx.id);

  /// Display-format txid bytes, which is what [BEEF] indexes by.
  Uint8List txidBytes(dartsv.Transaction tx) =>
      Uint8List.fromList(hex.decode(tx.id));

  BlockHeader baseHeader() => BlockHeader(
        version: 1,
        prevBlock: Hash.zero(),
        merkleRoot: RegtestMiner.merkleRootFor('0lx-base'),
        timestamp: DateTime.utc(2026, 1, 1),
        bits: NetworkParams.regtest.powLimitBits,
        nonce: 0,
      );

  /// A real (cheap proof-of-work) header carrying [root] as its merkle root.
  BlockHeader headerFor(Uint8List root, {BlockHeader? parent}) => RegtestMiner.mine(
        parent: parent ?? baseHeader(),
        merkleRoot: Hash.fromBytes(root),
      );

  MerkleProof proofFor(
    dartsv.Transaction tx,
    List<Uint8List> blockLeaves,
    int index,
    int height,
    BlockHeader header,
  ) {
    expect(hex.encode(blockLeaves[index]), hex.encode(leafOf(tx)),
        reason: 'fixture: leaf $index must be ${tx.id}');
    return MerkleProof(
      blockHash: header.blockHash().toString(),
      txid: tx.id,
      merkleProof: _tscNodes(blockLeaves, index),
      position: index,
      blockHeight: height,
    );
  }

  /// The BEEF the builders produced before this fix: one BUMP per proof.
  Uint8List unmergedBeef(
    List<MerkleProof> proofs,
    List<Uint8List> txs,
    List<bool> hasMerkle,
  ) {
    final bumps = [for (final p in proofs) CryptoUtils.buildBUMPFromMerkleProof(p)];
    final bumpIndex = [for (var i = 0; i < bumps.length; i++) i];
    return BEEF.create(
      bumps: bumps,
      txs: txs,
      hasMerkle: hasMerkle,
      bumpIndex: bumpIndex,
    ).serialize();
  }

  Uint8List rawOf(dartsv.Transaction tx) => Uint8List.fromList(hex.decode(tx.serialize()));

  // ---------------------------------------------------------------------------
  // The fixture block: eight leaves, two of them our ancestors, adjacent so
  // that both upper levels are shared.
  // ---------------------------------------------------------------------------
  late dartsv.Transaction g1, g2, g3, payment;
  late List<Uint8List> blockA, blockB;
  late BlockHeader headerA, headerB;
  late MerkleProof proofG1, proofG2, proofG3;
  late AncestorChainService service;

  const heightA = 812000;
  const heightB = 812001;

  setUp(() {
    g1 = mined('g1', 100000);
    g2 = mined('g2', 200000);
    g3 = mined('g3', 300000);
    payment = spend([(g1, 0), (g2, 0)], [250000]);

    // Block A: g1 at 2 and g2 at 3 — siblings, so levels 1 and 2 are shared.
    blockA = [
      _filler('a0'),
      _filler('a1'),
      leafOf(g1),
      leafOf(g2),
      _filler('a4'),
      _filler('a5'),
      _filler('a6'),
      _filler('a7'),
    ];
    // Block B holds g3 alone among fillers.
    blockB = [_filler('b0'), leafOf(g3), _filler('b2'), _filler('b3')];

    headerA = headerFor(_merkleRoot(blockA));
    headerB = headerFor(_merkleRoot(blockB), parent: headerA);

    proofG1 = proofFor(g1, blockA, 2, heightA, headerA);
    proofG2 = proofFor(g2, blockA, 3, heightA, headerA);
    proofG3 = proofFor(g3, blockB, 1, heightB, headerB);

    service = AncestorChainService(storage: InMemoryWalletStorage());
  });

  group('BEEF BUMP merging (libspiffy-0lx part 2)', () {
    test('ancestors from the same block share one multi-leaf BUMP and the BEEF shrinks',
        () async {
      final result = await service.createBeefWithAncestry(
        newTransaction: record(payment),
        ancestorTransactions: [record(g1), record(g2)],
        merkleProofs: [proofG1, proofG2],
      );
      expect(result.success, isTrue, reason: result.error);

      final beef = BEEF.parse(result.beefBytes!);
      expect(beef.bumps.length, 1,
          reason: 'g1 and g2 were mined in the same block: one BUMP, two leaves');

      final proved = {
        for (final leaf in beef.bumps.single.txidLeaves)
          hex_utils.internalToDisplay(leaf.hash!): leaf.offset,
      };
      expect(proved, {g1.id: 2, g2.id: 3});

      // Both transactions point at the single BUMP.
      expect(beef.findTransactionByTxid(txidBytes(g1))!['bumpIndex'], 0);
      expect(beef.findTransactionByTxid(txidBytes(g2))!['bumpIndex'], 0);

      final unmerged = unmergedBeef(
        [proofG1, proofG2],
        [rawOf(g1), rawOf(g2), rawOf(payment)],
        [true, true, false],
      );
      expect(result.beefBytes!.length, lessThan(unmerged.length),
          reason: 'the shared levels must not be repeated');
    });

    test('every ancestor of the merged BEEF validates against the block header', () async {
      final result = await service.createBeefWithAncestry(
        newTransaction: record(payment),
        ancestorTransactions: [record(g1), record(g2)],
        merkleProofs: [proofG1, proofG2],
      );
      expect(result.success, isTrue, reason: result.error);

      // The receiving path: parse the bytes off the wire, then check each
      // proven ancestor against our own header for that block.
      final beef = BEEF.parse(result.beefBytes!);
      for (final tx in [g1, g2]) {
        expect(await beef.validateTransactionWithBlockHeader(txidBytes(tx), headerA), isTrue,
            reason: '${tx.id} must still walk to block A\'s merkle root');
      }
      // ...and against the wrong block's header it must not.
      expect(await beef.validateTransactionWithBlockHeader(txidBytes(g1), headerB), isFalse);
    });

    test('non-adjacent positions in one block merge and still validate', () async {
      // g1 at 2, g2 at 5: the walks share nothing below the root, which is
      // the case where a careless union of levels loses a sibling.
      final leaves = [
        _filler('c0'),
        _filler('c1'),
        leafOf(g1),
        _filler('c3'),
        _filler('c4'),
        leafOf(g2),
        _filler('c6'),
        _filler('c7'),
      ];
      final header = headerFor(_merkleRoot(leaves));
      final p1 = proofFor(g1, leaves, 2, heightA, header);
      final p2 = proofFor(g2, leaves, 5, heightA, header);

      final result = await service.createBeefWithAncestry(
        newTransaction: record(payment),
        ancestorTransactions: [record(g1), record(g2)],
        merkleProofs: [p1, p2],
      );
      expect(result.success, isTrue, reason: result.error);

      final beef = BEEF.parse(result.beefBytes!);
      expect(beef.bumps.length, 1);
      for (final tx in [g1, g2]) {
        expect(await beef.validateTransactionWithBlockHeader(txidBytes(tx), header), isTrue,
            reason: '${tx.id} must still walk to the merkle root');
      }
    });

    test('ancestors from different blocks keep their own BUMPs and all validate', () async {
      final result = await service.createBeefWithAncestry(
        newTransaction: record(payment),
        ancestorTransactions: [record(g1), record(g2), record(g3)],
        merkleProofs: [proofG1, proofG2, proofG3],
      );
      expect(result.success, isTrue, reason: result.error);

      final beef = BEEF.parse(result.beefBytes!);
      expect(beef.bumps.length, 2, reason: 'block A merged, block B on its own');
      expect(beef.bumps.map((b) => b.blockHeight).toSet(), {heightA, heightB});

      final aBump = beef.bumps.firstWhere((b) => b.blockHeight == heightA);
      final bBump = beef.bumps.firstWhere((b) => b.blockHeight == heightB);
      expect(aBump.txidLeaves.length, 2);
      expect(bBump.txidLeaves.length, 1);

      expect(await beef.validateTransactionWithBlockHeader(txidBytes(g1), headerA), isTrue);
      expect(await beef.validateTransactionWithBlockHeader(txidBytes(g2), headerA), isTrue);
      expect(await beef.validateTransactionWithBlockHeader(txidBytes(g3), headerB), isTrue);
    });

    test('two blocks at the same height are not merged', () async {
      // A proof whose height collides with block A but whose root is another
      // block's: merging them would produce a BUMP that proves neither.
      final other = [_filler('d0'), leafOf(g3), _filler('d2'), _filler('d3')];
      final otherHeader = headerFor(_merkleRoot(other));
      final collide = proofFor(g3, other, 1, heightA, otherHeader);

      final result = await service.createBeefWithAncestry(
        newTransaction: record(payment),
        ancestorTransactions: [record(g1), record(g2), record(g3)],
        merkleProofs: [proofG1, proofG2, collide],
      );
      expect(result.success, isTrue, reason: result.error);

      final beef = BEEF.parse(result.beefBytes!);
      expect(beef.bumps.length, 2, reason: 'the odd block out keeps its own BUMP');
      expect(await beef.validateTransactionWithBlockHeader(txidBytes(g1), headerA), isTrue);
      expect(await beef.validateTransactionWithBlockHeader(txidBytes(g2), headerA), isTrue);
      expect(await beef.validateTransactionWithBlockHeader(txidBytes(g3), otherHeader), isTrue);
    });

    test('PaymentChannelBuilder merges the funding ancestry too', () async {
      final funding = spend([(g1, 0), (g2, 0)], [290000]);
      final channelPayment = spend([(funding, 0)], [280000]);
      final builder = PaymentChannelBuilder(
        cryptoService: DartSVCryptoService(),
        networkType: dartsv.NetworkType.TEST,
      );

      final result = await builder.buildPaymentWithAncestry(
        paymentTx: ChannelTransactionResult(
          transaction: channelPayment,
          transactionHex: channelPayment.serialize(),
          txid: channelPayment.id,
          fee: BigInt.from(10000),
        ),
        fundingTransaction: record(funding),
        fundingAncestors: [record(g1), record(g2)],
        ancestorProofs: [proofG1, proofG2],
      );

      final beef = BEEF.parse(result.beefBytes);
      expect(beef.bumps.length, 1);
      expect(beef.bumps.single.txidLeaves.length, 2);
      for (final tx in [g1, g2]) {
        expect(await beef.validateTransactionWithBlockHeader(txidBytes(tx), headerA), isTrue);
      }
      expect(
        result.beefBytes.length,
        lessThan(unmergedBeef(
          [proofG1, proofG2],
          [rawOf(g1), rawOf(g2), rawOf(funding), rawOf(channelPayment)],
          [true, true, false, false],
        ).length),
      );
    });

    test('a BUMP already proving several txids is reused, not repeated', () async {
      // ARC hands us one BUMP covering both of our transactions; both proofs
      // store the same BUMP hex. The BEEF must carry it once.
      final shared = BUMP.merge([
        CryptoUtils.buildBUMPFromMerkleProof(proofG1),
        CryptoUtils.buildBUMPFromMerkleProof(proofG2),
      ]);
      MerkleProof stored(dartsv.Transaction tx, int index) => MerkleProof(
            blockHash: headerA.blockHash().toString(),
            txid: tx.id,
            merkleProof: [shared.toHex()],
            position: index,
            blockHeight: heightA,
          );

      final result = await service.createBeefWithAncestry(
        newTransaction: record(payment),
        ancestorTransactions: [record(g1), record(g2)],
        merkleProofs: [stored(g1, 2), stored(g2, 3)],
      );
      expect(result.success, isTrue, reason: result.error);

      final beef = BEEF.parse(result.beefBytes!);
      expect(beef.bumps.length, 1);
      expect(await beef.validateTransactionWithBlockHeader(txidBytes(g1), headerA), isTrue);
      expect(await beef.validateTransactionWithBlockHeader(txidBytes(g2), headerA), isTrue);
    });
  });
}
