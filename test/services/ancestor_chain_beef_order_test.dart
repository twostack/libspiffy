/// SPV-10 (bead libspiffy-ucz): AncestorChainService walked the ancestor
/// graph breadth-first from the UTXO being spent and returned (and packed
/// into BEEFs) the transactions in that order: child first, the proven
/// ancestor last. BRC-62 requires topological order, parents before the
/// children that spend them, so standard BEEF verifiers reject such a BEEF.
///
/// The chain here is real: G is a mined testnet transaction with its real
/// merkle proof and the real header of its block; A, B, C and the payment P
/// are signed spends of it with the key that owns G's output, so the SPV
/// actor runs script verification and header checks on genuine data.
///
///   G (mined) --> A --> B --> C --> P (new payment)
///                 \___________/
///   C spends B:0 and A:1, listing A first, so the breadth-first walk meets A
///   before B although B spends A: simply reversing the walk is not enough.
import 'dart:async';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/ancestor_chain_service.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:spiffynode/spiffy_node.dart' show BlockHeader;
import 'package:test/test.dart';

import '../actors/in_memory_event_store.dart';
import '../spv/testnet_proof_fixture.dart';

const _xpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';

void main() {
  final key = dartsv.HDPrivateKey.fromXpriv(_xpriv).deriveChildNumber(0).deriveChildNumber(0).privateKey;
  final address = key.publicKey.toAddress(dartsv.NetworkType.TEST);
  final lock = dartsv.P2PKHLockBuilder.fromAddress(address);

  dartsv.Transaction spend(List<(dartsv.Transaction, int)> inputs, List<int> outputs) {
    final builder = dartsv.TransactionBuilder();
    for (final (parent, vout) in inputs) {
      final out = parent.outputs[vout];
      builder.spendFromOutpointWithSigner(
        dartsv.DefaultTransactionSigner(
            dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, key),
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

  late InMemoryWalletStorage storage;
  late dartsv.Transaction g, a, b, c, p;
  late AncestorChainService service;

  setUp(() async {
    g = dartsv.Transaction.fromHex(kFixtureTxHex);
    expect(g.outputs[1].script.toHex(), equals(lock.getScriptPubkey().toHex()),
        reason: 'fixture output 1 must belong to the test key');
    a = spend([(g, 1)], [100000000, 99990000]);
    b = spend([(a, 0)], [99980000]);
    c = spend([(a, 1), (b, 0)], [199960000]);
    p = spend([(c, 0)], [199950000]);

    storage = InMemoryWalletStorage();
    await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    for (final tx in [c, b, a, g]) {
      await storage.storeTransaction('w', record(tx));
    }
    await storage.storeMerkleProof(
      g.id,
      MerkleProof(
        blockHash: kFixtureBlockHash,
        txid: g.id,
        merkleProof: [fixtureBumpHex()],
        position: kFixtureIndex,
        blockHeight: kFixtureHeight,
      ),
    );
    service = AncestorChainService(storage: storage);
  });

  List<String> idsOf(BEEF beef) =>
      [for (final raw in beef.txs) dartsv.Transaction.fromHex(hex.encode(raw)).id];

  /// BRC-62: every input that refers to a transaction in the BEEF refers to
  /// one that appears earlier.
  void expectTopological(BEEF beef) {
    final seen = <String>{};
    final all = idsOf(beef).toSet();
    for (final raw in beef.txs) {
      final tx = dartsv.Transaction.fromHex(hex.encode(raw));
      for (final input in tx.inputs) {
        if (all.contains(input.prevTxnId)) {
          expect(seen, contains(input.prevTxnId),
              reason: '${tx.id} spends ${input.prevTxnId}, which must come before it');
        }
      }
      seen.add(tx.id);
    }
  }

  group('AncestorChainService BEEF order (SPV-10)', () {
    test('a 3-deep chain is collected and packed parents first', () async {
      final chain = await service.collectAncestorChainForUtxos([c.id]);
      expect(chain.isValid, isTrue, reason: chain.error);
      expect(chain.ancestorTransactions.map((t) => t.txid), equals([g.id, a.id, b.id, c.id]));

      final result = await service.createBeefWithAncestry(
        newTransaction: record(p),
        ancestorTransactions: chain.ancestorTransactions,
        merkleProofs: chain.merkleProofs,
      );
      expect(result.success, isTrue, reason: result.error);

      final beef = BEEF.parse(result.beefBytes!);
      expect(idsOf(beef), equals([g.id, a.id, b.id, c.id, p.id]));
      expect(beef.hasMerkle, equals([true, false, false, false, false]));
      expectTopological(beef);
    });

    test('createBeefWithMultipleNewTransactions orders child-first input parents first', () async {
      final result = await service.createBeefWithMultipleNewTransactions(
        newTransactions: [record(p)],
        ancestorTransactions: [record(c), record(a), record(b), record(g)],
        merkleProofs: (await storage.getMerkleProofsBatch([g.id])).values.toList(),
      );
      expect(result.success, isTrue, reason: result.error);
      final beef = BEEF.parse(result.beefBytes!);
      expect(idsOf(beef), equals([g.id, a.id, b.id, c.id, p.id]));
      expectTopological(beef);
    });

    test('the SPV actor accepts the payment in the resulting BEEF', () async {
      final chain = await service.collectAncestorChainForUtxos([c.id]);
      final result = await service.createBeefWithAncestry(
        newTransaction: record(p),
        ancestorTransactions: chain.ancestorTransactions,
        merkleProofs: chain.merkleProofs,
      );
      final beef = BEEF.parse(result.beefBytes!);

      final system = LocalActorSystem(ActorSystemConfig());
      addTearDown(system.shutdown);
      final sink = await system.spawn('sink', () => _Sink());
      final spv = await system.spawn(
          'spv', () => SPVActor(walletManager: sink, invoiceCoordinator: sink, storage: storage));
      final done = Completer<SPVValidationResult>();
      final receiver = await system.spawn('receiver', () => _Receiver(done));

      spv.tell(
        ReceiveTransactionMessage(transactionId: p.id, beef: beef, fromCounterparty: 'alice'),
        sender: receiver,
      );
      final validation = await done.future.timeout(const Duration(seconds: 10));
      expect(validation.isValid, isTrue, reason: validation.validationError);
    });

    test('with two proven ancestors the BUMPs follow the transaction order', () async {
      // G2 is a second mined transaction (real proof, real header) that also
      // spends G. The walk from [A, G2] finds G2's proof before G's, but G
      // must come first in the BEEF, so the proofs have to be reordered with
      // the transactions (readers such as SPVActor take the k-th proven
      // transaction's BUMP to be bumps[k]).
      final g2 = dartsv.Transaction.fromHex(kFixture2TxHex);
      await storage.storeBlockHeader(fixture2Header(), kFixture2Height);
      await storage.storeTransaction('w', record(g2));
      await storage.storeMerkleProof(
        g2.id,
        MerkleProof(
          blockHash: kFixture2BlockHash,
          txid: g2.id,
          merkleProof: [fixture2BumpHex()],
          position: kFixture2Index,
          blockHeight: kFixture2Height,
        ),
      );
      final pay = spend([(a, 0), (g2, 0)], [100000000]);

      final chain = await service.collectAncestorChainForUtxos([a.id, g2.id]);
      expect(chain.isValid, isTrue, reason: chain.error);
      expect(chain.ancestorTransactions.map((t) => t.txid), equals([g.id, a.id, g2.id]));
      expect(chain.merkleProofs.map((p) => p.txid), equals([g.id, g2.id]));

      final result = await service.createBeefWithAncestry(
        newTransaction: record(pay),
        ancestorTransactions: chain.ancestorTransactions,
        merkleProofs: chain.merkleProofs,
      );
      final beef = BEEF.parse(result.beefBytes!);
      expectTopological(beef);
      expect(beef.bumps.map((b) => b.blockHeight), equals([kFixtureHeight, kFixture2Height]));
      expect(beef.bumpIndex, equals([0, 1]));

      final system = LocalActorSystem(ActorSystemConfig());
      addTearDown(system.shutdown);
      final sink = await system.spawn('sink', () => _Sink());
      final spv = await system.spawn(
          'spv', () => SPVActor(walletManager: sink, invoiceCoordinator: sink, storage: storage));
      final done = Completer<SPVValidationResult>();
      final receiver = await system.spawn('receiver', () => _Receiver(done));
      spv.tell(
        ReceiveTransactionMessage(transactionId: pay.id, beef: beef, fromCounterparty: 'alice'),
        sender: receiver,
      );
      final validation = await done.future.timeout(const Duration(seconds: 10));
      expect(validation.isValid, isTrue, reason: validation.validationError);
    });
  });

  /// Bead libspiffy-mny: orphaned proofs are kept in storage now, so the
  /// ancestor walk must not take one for a proof.
  group('AncestorChainService with an orphaned proof (mny)', () {
    test('an orphaned proof is never put in a BEEF; the walk continues to the proven ancestor', () async {
      // A was once proven in a block that left the active chain.
      final orphanedBump = 'fe${'ab' * 40}';
      final orphanedBlock = 'cd' * 32;
      await storage.storeMerkleProof(a.id, MerkleProof(
        txid: a.id,
        blockHash: orphanedBlock,
        blockHeight: kFixtureHeight + 1,
        position: 1,
        merkleProof: [orphanedBump],
      ));
      expect(await storage.markMerkleProofOrphaned(a.id, blockHash: orphanedBlock), isTrue);

      final chain = await service.collectAncestorChainForUtxos([c.id]);
      expect(chain.isValid, isTrue, reason: chain.error);
      expect(chain.merkleProofs.map((p) => p.txid), equals([g.id]),
          reason: "A's orphaned proof must not end the walk or enter the BEEF");
      expect(chain.ancestorTransactions.map((t) => t.txid), equals([g.id, a.id, b.id, c.id]));

      final result = await service.createBeefWithAncestry(
        newTransaction: record(p),
        ancestorTransactions: chain.ancestorTransactions,
        merkleProofs: chain.merkleProofs,
      );
      final beef = BEEF.parse(result.beefBytes!);
      expect(beef.hasMerkle, equals([true, false, false, false, false]));
      expect(beef.bumps.map((bump) => bump.toHex()), equals([fixtureBumpHex()]));
      expect((await storage.getMerkleProofHistory(a.id)).single.status, MerkleProofStatus.orphaned,
          reason: 'the orphaned proof is still stored');
    });
  });

  /// Bead libspiffy-azl: a proof whose root contradicts the stored header at
  /// its height was the transaction's current proof (pendingHeader), so the
  /// BEEF carried a proof that does not verify.
  group('AncestorChainService with a proof that contradicts the stored header (azl)', () {
    final tamperedHex = fixtureBumpHex(tamperLevel: 0);

    /// A read model holding A, B, C and G, with G proven only by [bump], as
    /// WalletProjection stores it from a confirmation (headers per [header]).
    Future<InMemoryWalletStorage> projected(String bump, {BlockHeader? header}) async {
      final s = InMemoryWalletStorage();
      await s.storeBlockHeader(header ?? fixtureHeader(), kFixtureHeight);
      for (final tx in [c, b, a, g]) {
        await s.storeTransaction('w', record(tx));
      }
      await WalletProjection(projectionId: 'azl', eventStore: InMemoryEventStore(), storage: s)
          .handle(TransactionConfirmedEvent(
        walletId: 'w',
        txid: g.id,
        blockHeight: kFixtureHeight,
        blockHash: kFixtureBlockHash,
        bumpHex: bump,
        version: 2,
        timestamp: DateTime.utc(2026, 9, 15),
      ));
      return s;
    }

    Future<SPVValidationResult> validate(ReadModelStorage s, BEEF beef, String txid) async {
      final system = LocalActorSystem(ActorSystemConfig());
      addTearDown(system.shutdown);
      final sink = await system.spawn('sink', () => _Sink());
      final spv = await system.spawn('spv', () => SPVActor(walletManager: sink, invoiceCoordinator: sink, storage: s));
      final done = Completer<SPVValidationResult>();
      final receiver = await system.spawn('receiver', () => _Receiver(done));
      spv.tell(ReceiveTransactionMessage(transactionId: txid, beef: beef, fromCounterparty: 'alice'), sender: receiver);
      return done.future.timeout(const Duration(seconds: 10));
    }

    test('the genuine proof, projected, builds a BEEF our own SPV check accepts (control)', () async {
      final s = await projected(fixtureBumpHex());
      final chain = await AncestorChainService(storage: s).collectAncestorChainForUtxos([c.id]);
      expect(chain.isValid, isTrue, reason: chain.error);
      final result = await AncestorChainService(storage: s).createBeefWithAncestry(
        newTransaction: record(p),
        ancestorTransactions: chain.ancestorTransactions,
        merkleProofs: chain.merkleProofs,
      );
      expect((await validate(s, BEEF.parse(result.beefBytes!), p.id)).isValid, isTrue);
    });

    test('a tampered BUMP against the real header never enters a BEEF', () async {
      final s = await projected(tamperedHex);
      final chain = await AncestorChainService(storage: s).collectAncestorChainForUtxos([c.id]);
      if (chain.isValid) {
        // What a counterparty (here our own SPVActor, same headers) makes of
        // the BEEF such a chain produces.
        final result = await AncestorChainService(storage: s).createBeefWithAncestry(
          newTransaction: record(p),
          ancestorTransactions: chain.ancestorTransactions,
          merkleProofs: chain.merkleProofs,
        );
        final validation = await validate(s, BEEF.parse(result.beefBytes!), p.id);
        expect(validation.isValid, isTrue,
            reason: 'a BEEF built from stored proofs must verify: ${validation.validationError}');
      }
      expect(chain.merkleProofs.map((p) => p.merkleProof.join()), isNot(contains(tamperedHex)),
          reason: 'a proof the stored header contradicts is not a proof');
      expect(chain.isValid, isFalse, reason: "G's inputs are not stored, so there is no provable chain");
    });

    test('the genuine BUMP against another header at its height never enters a BEEF', () async {
      final s = await projected(fixtureBumpHex(), header: otherHeaderAtFixtureHeight());
      final chain = await AncestorChainService(storage: s).collectAncestorChainForUtxos([c.id]);
      expect(chain.merkleProofs, isEmpty);
      expect(chain.isValid, isFalse);
    });

    test('a pendingHeader proof stored before the fix, whose header is now stored and differs, is skipped', () async {
      // Read models written before azl hold such rows until SPVActor next
      // checks pendingHeader proofs; a BEEF built meanwhile must not use one.
      final s = InMemoryWalletStorage();
      await s.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      for (final tx in [c, b, a, g]) {
        await s.storeTransaction('w', record(tx));
      }
      await s.storeMerkleProof(g.id, MerkleProof(
        txid: g.id,
        blockHash: null,
        blockHeight: kFixtureHeight,
        position: kFixtureIndex,
        merkleProof: [tamperedHex],
      ));
      expect((await s.getMerkleProof(g.id))!.status, MerkleProofStatus.pendingHeader);

      final chain = await AncestorChainService(storage: s).collectAncestorChainForUtxos([c.id]);
      expect(chain.merkleProofs, isEmpty);
      expect(chain.isValid, isFalse);

      // A pendingHeader proof whose header is still unknown travels (the
      // receiver checks it against its own headers).
      final noHeader = InMemoryWalletStorage();
      for (final tx in [c, b, a, g]) {
        await noHeader.storeTransaction('w', record(tx));
      }
      await noHeader.storeMerkleProof(g.id, MerkleProof(
        txid: g.id,
        blockHash: null,
        blockHeight: kFixtureHeight,
        position: kFixtureIndex,
        merkleProof: [fixtureBumpHex()],
      ));
      final pending = await AncestorChainService(storage: noHeader).collectAncestorChainForUtxos([c.id]);
      expect(pending.isValid, isTrue, reason: pending.error);
      expect(pending.merkleProofs.map((p) => p.txid), [g.id]);
    });
  });
}

class _Sink extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

class _Receiver extends Actor {
  final Completer<SPVValidationResult> done;
  _Receiver(this.done);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is SPVValidationResult && !done.isCompleted) done.complete(message);
  }
}
