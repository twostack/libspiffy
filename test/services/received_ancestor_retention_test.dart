/// zsh (libspiffy-zsh): the ancestors a received BEEF carries for an
/// unproven transaction are journaled and stored, so its outputs can be
/// spent before it is mined.
///
/// Real testnet data: G and G2 are mined transactions with their real
/// proofs and headers (G2 spends G); U and P are signed spends with the key
/// that owns G2's output 0. The BEEF P arrives in is [G, G2, U, P]: P's
/// ancestors down to proven transactions are U and G2; G is in the BEEF but
/// not needed (G2 is proven).
///
/// The end-to-end flow (receive through the coordinator, pay, restart) is in
/// test/integration/unproven_receive_ancestor_retention_test.dart.
library;

import 'dart:async';
import 'dart:typed_data';

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
import 'package:libspiffy/src/utils/bump.dart';
import 'package:test/test.dart';

import '../actors/in_memory_event_store.dart';
import '../spv/testnet_proof_fixture.dart';

const _xpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';

void main() {
  final key = dartsv.HDPrivateKey.fromXpriv(_xpriv).deriveChildNumber(0).deriveChildNumber(0).privateKey;
  final lock = dartsv.P2PKHLockBuilder.fromAddress(key.publicKey.toAddress(dartsv.NetworkType.TEST));

  dartsv.Transaction spend(dartsv.Transaction parent, int vout, int sats) {
    final out = parent.outputs[vout];
    final builder = dartsv.TransactionBuilder()
      ..spendFromOutpointWithSigner(
        dartsv.DefaultTransactionSigner(
            dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, key),
        dartsv.TransactionOutpoint(parent.id, vout, out.satoshis, out.script),
        dartsv.TransactionInput.MAX_SEQ_NUMBER,
        dartsv.P2PKHUnlockBuilder(key.publicKey),
      )
      ..spendToLockBuilder(lock, BigInt.from(sats))
      ..withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);
    return builder.build(false);
  }

  Uint8List bytes(String txHex) => Uint8List.fromList(hex.decode(txHex));

  final g2 = dartsv.Transaction.fromHex(kFixture2TxHex);
  final u = spend(g2, 0, 199990000);
  final p = spend(u, 0, 199980000);

  BEEF receivedBeef() => BEEF.create(
        bumps: [fixtureBump(), BUMP.fromHex(fixture2BumpHex())],
        txs: [bytes(kFixtureTxHex), bytes(kFixture2TxHex), bytes(u.serialize()), bytes(p.serialize())],
        hasMerkle: [true, true, false, false],
        bumpIndex: [0, 1],
      );

  late LocalActorSystem system;

  setUp(() {
    system = LocalActorSystem(ActorSystemConfig());
  });

  tearDown(() => system.shutdown());

  Future<InMemoryWalletStorage> headers({bool fixture2 = true}) async {
    final storage = InMemoryWalletStorage();
    await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    if (fixture2) await storage.storeBlockHeader(fixture2Header(), kFixture2Height);
    return storage;
  }

  Future<SPVValidationResult> receive(ReadModelStorage storage, String txid, BEEF beef) async {
    final tag = DateTime.now().microsecondsSinceEpoch;
    final sink = await system.spawn('sink-$tag', () => _Sink());
    final spv = await system.spawn(
        'spv-$tag', () => SPVActor(walletManager: sink, invoiceCoordinator: sink, storage: storage));
    final done = Completer<SPVValidationResult>();
    final receiver = await system.spawn('receiver-$tag', () => _Receiver(done));
    spv.tell(
      ReceiveTransactionMessage(transactionId: txid, beef: beef, fromCounterparty: 'alice', targetWalletId: 'w'),
      sender: receiver,
    );
    return done.future.timeout(const Duration(seconds: 10));
  }

  /// The event the wallet aggregate journals for [result]
  /// (WalletManagerActor maps transactionData onto the command field by
  /// field).
  TransactionImportedEvent importedEvent(SPVValidationResult result) {
    final data = result.transactionData!;
    return TransactionImportedEvent(
      walletId: 'w',
      txid: result.txid,
      rawHex: data['rawHex'] as String,
      blockHeight: data['blockHeight'] as int,
      bumpProof: data['bumpProof'] as String,
      totalOutputSats: data['totalOutputSats'] as int,
      numInputs: data['numInputs'] as int,
      numOutputs: data['numOutputs'] as int,
      txVersion: data['txVersion'] as int,
      txLockTime: data['txLockTime'] as int,
      walletReceivingAddresses: List<String>.from(data['walletReceivingAddresses'] as List),
      walletReceivedSats: data['walletReceivedSats'] as int,
      totalInputSats: data['totalInputSats'] as int,
      sendingAddresses: List<String>.from(data['sendingAddresses'] as List),
      ancestors: List<BeefAncestor>.from(data['ancestors'] as List),
      timestamp: DateTime.utc(2026, 9, 14),
      version: 2,
    );
  }

  WalletProjection projectionOn(ReadModelStorage storage) =>
      WalletProjection(projectionId: 'zsh', eventStore: InMemoryEventStore(), storage: storage);

  List<String> idsOf(BEEF beef) => [for (final raw in beef.txs) hex.encode(beef.calculateTxid(raw))];

  test('zsh: SPVActor hands on the ancestors down to proven ones, with their BUMPs, and nothing else', () async {
    final result = await receive(await headers(), p.id, receivedBeef());
    expect(result.isValid, isTrue, reason: result.validationError);
    expect(result.transactionData!['ancestors'], [
      BeefAncestor(txid: kFixture2Txid, rawHex: kFixture2TxHex, bumpHex: fixture2BumpHex()),
      BeefAncestor(txid: u.id, rawHex: u.serialize()),
    ]);

    // A proven transaction needs no ancestors.
    final proven = await receive(await headers(), kFixture2Txid, receivedBeef());
    expect(proven.isValid, isTrue, reason: proven.validationError);
    expect(proven.transactionData!['ancestors'], isEmpty);
  });

  test('zsh: the journaled ancestors are stored apart from wallet transactions, and a BEEF spending P validates',
      () async {
    final storage = await headers();
    final result = await receive(storage, p.id, receivedBeef());
    expect(result.isValid, isTrue, reason: result.validationError);

    // Through the journal's serialization, as a replay reads it.
    final event = TransactionImportedEvent.fromMap(importedEvent(result).toMap());
    expect(event.ancestors, hasLength(2));
    await projectionOn(storage).handle(event);

    expect(await storage.getAncestorTransactionsBatch([kFixtureTxid, kFixture2Txid, u.id, p.id]),
        {kFixture2Txid: kFixture2TxHex, u.id: u.serialize()});
    expect((await storage.getTransactionHistory('w')).map((t) => t.txid), [p.id]);
    expect(await storage.getTransaction(u.id), isNull);
    expect(await storage.getTransactionsBatch([u.id, kFixture2Txid]), isEmpty);
    expect(await storage.getTransactionsByStatus(TransactionStatus.pending), hasLength(1));
    final proof = (await storage.getMerkleProof(kFixture2Txid))!;
    expect((proof.status, proof.blockHash, proof.position),
        (MerkleProofStatus.verified, kFixture2BlockHash, kFixture2Index));
    expect(proof.merkleProof, [fixture2BumpHex()]);
    expect(await storage.getMerkleProof(kFixtureTxid), isNull, reason: 'G is not needed and not kept');

    final chain = await AncestorChainService(storage: storage).collectAncestorChainForUtxos([p.id]);
    expect(chain.isValid, isTrue, reason: chain.error);
    expect(chain.ancestorTransactions.map((t) => t.txid), [kFixture2Txid, u.id, p.id]);

    final q = spend(p, 0, 199970000);
    final built = await AncestorChainService(storage: storage).createBeefWithAncestry(
      newTransaction: _record(q),
      ancestorTransactions: chain.ancestorTransactions,
      merkleProofs: chain.merkleProofs,
    );
    expect(built.success, isTrue, reason: built.error);
    final outgoing = BEEF.parse(built.beefBytes!);
    expect(idsOf(outgoing), [kFixture2Txid, u.id, p.id, q.id]);
    expect(outgoing.hasMerkle, [true, false, false, false]);

    final validation = await receive(await headers(), q.id, outgoing);
    expect(validation.isValid, isTrue, reason: validation.validationError);

    // Replaying the event writes nothing new.
    await projectionOn(storage).handle(event);
    expect((await storage.getMerkleProofHistory(kFixture2Txid)).length, 1);
    expect((await storage.getTransactionHistory('w')).map((t) => t.txid), [p.id]);
  });

  test('zsh: an ancestor BUMP whose header is not stored yet is kept as pendingHeader and still travels', () async {
    final result = await receive(await headers(), p.id, receivedBeef());
    expect(result.isValid, isTrue, reason: result.validationError);

    final storage = await headers(fixture2: false);
    await projectionOn(storage).handle(importedEvent(result));
    final proof = (await storage.getMerkleProof(kFixture2Txid))!;
    expect((proof.status, proof.blockHash), (MerkleProofStatus.pendingHeader, null));
    final chain = await AncestorChainService(storage: storage).collectAncestorChainForUtxos([p.id]);
    expect(chain.isValid, isTrue, reason: chain.error);
    expect(chain.ancestorTransactions.map((t) => t.txid), [kFixture2Txid, u.id, p.id]);
  });

  test('zsh: an ancestor whose raw transaction does not hash to its txid is not stored', () async {
    final storage = await headers();
    final result = await receive(storage, p.id, receivedBeef());
    final forged = importedEvent(result);
    final event = TransactionImportedEvent.fromMap(forged.toMap()
      ..['ancestors'] = [
        {'txid': u.id, 'rawHex': kFixtureTxHex},
        {'txid': kFixture2Txid, 'rawHex': kFixture2TxHex, 'bumpHex': fixture2BumpHex()},
      ]);
    await projectionOn(storage).handle(event);
    expect(await storage.getAncestorTransactionsBatch([u.id, kFixture2Txid]), {kFixture2Txid: kFixture2TxHex});
  });

  test('zsh: a TransactionImportedEvent row journaled before ancestors existed still loads', () {
    final event = importedEventWithoutAncestors();
    final map = event.toMap();
    expect(map.containsKey('ancestors'), isFalse, reason: 'no key is written when there are no ancestors');
    expect(TransactionImportedEvent.fromMap(map).ancestors, isEmpty);
  });
}

TransactionImportedEvent importedEventWithoutAncestors() => TransactionImportedEvent(
      walletId: 'w',
      txid: kFixtureTxid,
      rawHex: kFixtureTxHex,
      blockHeight: kFixtureHeight,
      bumpProof: fixtureBumpHex(),
      totalOutputSats: 1,
      numInputs: 1,
      numOutputs: 2,
      txVersion: 2,
      txLockTime: 0,
      walletReceivingAddresses: const [],
      walletReceivedSats: 0,
      totalInputSats: 0,
      sendingAddresses: const [],
      timestamp: DateTime.utc(2026, 9, 14),
      version: 2,
    );

BitcoinTransaction _record(dartsv.Transaction tx) => BitcoinTransaction(
      txid: tx.id,
      rawHex: tx.serialize(),
      status: TransactionStatus.pending,
      inputValue: BigInt.zero,
      outputValue: BigInt.zero,
      fee: BigInt.zero,
      receivingAddresses: const [],
      sendingAddresses: const [],
      netAmount: BigInt.zero,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      lockTime: 0,
      version: 1,
    );

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
