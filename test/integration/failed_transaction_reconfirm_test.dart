/// hccp (libspiffy-hccp, from hg0/10r): a transaction in failed state whose
/// merkle proof verifies against the active header chain again is confirmed.
///
/// In the SPV model the proof in a block of our header chain is
/// authoritative: the transaction is mined whatever ARC said earlier (a
/// REJECTED can be stale, or a competing transaction can lose). SPVActor's
/// revival of orphaned and rejected proofs skipped failed rows, so such a
/// transaction stayed failed, and the inputs its failure released stayed
/// spendable although the chain spent them.
///
/// End to end through LibSpiffyActorSystem on regtest with real-PoW header
/// chains: the wallet records the fixture transaction as a deferred payment,
/// a proof for it arrives while the header at its height contradicts it
/// (rejected; the confirmation is taken back), ARC reports it REJECTED (the
/// payment fails, its input is released, the row is failed), and then the
/// branch whose block contains it becomes active.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar/isar.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/spv_messages.dart' show BlockHeadersReceivedMessage;
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import '../spv/regtest_chain_builder.dart';
import '../spv/testnet_proof_fixture.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

/// Output 1 of the fixture transaction pays the kTestXpriv root address.
const _walletVout = 1;
const _walletOutputScript = '76a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac';

void main() {
  final genesis = NetworkParams.regtest.genesisHeader;
  final txidInternal = displayHexToInternal(kFixtureTxid);
  final fixtureInput = dartsv.Transaction.fromHex(kFixtureTxHex).inputs.first;
  final inputKey = '${fixtureInput.prevTxnId}:${fixtureInput.prevTxnOutputIndex}';

  (BUMP, Hash) blockFor(int height) {
    final sibling = Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + height) & 0xff));
    final bump = BUMP.fromMerklePath(blockHeight: height, txid: txidInternal, index: 0, siblings: [sibling]);
    return (bump, Hash.fromBytes(bump.computeMerkleRoot(txidInternal)));
  }

  late Directory dir;
  late LibSpiffyActorSystem libspiffy;
  late LocalActorSystem actorSystem;
  late String walletId;

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('failed_reconfirm_');
    actorSystem = LocalActorSystem(ActorSystemConfig());
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'failed_reconfirm_${DateTime.now().microsecondsSinceEpoch}',
    );
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: dir.path,
      networkType: 'regtest',
      enableP2P: false,
      arcService: _UnknownTxArc(),
    );
    walletId = 'failed-reconfirm-${DateTime.now().microsecondsSinceEpoch}';
    await createWallet(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
      walletName: 'Failed reconfirm',
      xpriv: kTestXpriv,
    );
    await _until(() async => await libspiffy.walletStorage.isWalletAddress(walletId, kTestRootAddress),
        'root address projected');
  });

  tearDown(() async {
    await libspiffy.shutdown();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  ReadModelStorage storage() => libspiffy.walletStorage;

  void tell(WalletCommand command) => libspiffy.walletManager.tell(WalletCommandMessage(walletId, command));

  Future<BitcoinTransaction?> tx() => storage().getTransaction(kFixtureTxid, walletId: walletId);

  Future<BitcoinUtxo?> utxo(String key) async {
    for (final u in await storage().getUTXOs(walletId, includeSpent: true)) {
      if (u.key == key) return u;
    }
    return null;
  }

  Future<void> sendHeaders(List<BlockHeader> headers, int expectedTip) async {
    libspiffy.headerSyncActor.tell(BlockHeadersReceivedMessage(
      peerId: 'peer',
      headers: headers,
      startHeight: 1,
    ) as dynamic);
    await _until(() async => libspiffy.headerChain.bestHeight == expectedTip, 'tip at $expectedTip');
  }

  test('a failed deferred payment whose proof verifies on the chain a reorganization makes active is confirmed, '
      'and the input its failure released is spent by it', () async {
    final (bump, root) = blockFor(2);
    final other = RegtestMiner.mineChain(genesis, 3, seed: 'other');
    await sendHeaders(other.sublist(0, 2), 2); // height 2 does not contain the transaction

    // The wallet holds the fixture transaction's input and pays with it,
    // handing the transaction to its recipient (deferred spend).
    tell(ReceiveUTXOCommand(
      walletId: walletId,
      txid: fixtureInput.prevTxnId,
      vout: fixtureInput.prevTxnOutputIndex,
      satoshis: BigInt.from(300000000),
      scriptPubKey: _walletOutputScript,
      address: kTestRootAddress,
      blockHeight: 1,
      confirmations: 1,
      initialStatus: UTXOStatus.available,
    ));
    tell(RecordOutgoingTransactionCommand(
      walletId: walletId,
      txid: kFixtureTxid,
      rawHex: kFixtureTxHex,
      totalInputSats: 300000000,
      totalOutputSats: 91296559239,
      fee: 0,
      numInputs: 1,
      numOutputs: 2,
      txVersion: 2,
      txLockTime: 0,
      spentUtxoKeys: [inputKey],
      recipientAddresses: const ['recipient'],
      paymentAmount: BigInt.from(1000),
      deferSpend: true,
      purpose: 'invoice-payment',
    ));
    await _until(() async => (await utxo(inputKey))?.status == UTXOStatus.reserved &&
        (await storage().getDeferredPayment(walletId, kFixtureTxid))?.state == DeferredPaymentState.outstanding,
        'payment recorded, input held');

    // A proof arrives (as an import would bring it) while the header at its
    // height contradicts it: rejected, and the next header notification
    // takes the confirmation back.
    tell(RecordImportedTransactionCommand(
      walletId: walletId,
      txid: kFixtureTxid,
      rawHex: kFixtureTxHex,
      blockHeight: 2,
      bumpProofHex: bump.toHex(),
      totalOutputSats: 91296559239,
      numInputs: 1,
      numOutputs: 2,
      txVersion: 2,
      txLockTime: 0,
      walletReceivingAddresses: [kTestRootAddress],
      walletReceivedSats: 200000000,
      totalInputSats: 0,
      sendingAddresses: const [],
    ));
    await _until(() async => (await storage().getMerkleProofHistory(kFixtureTxid)).isNotEmpty &&
        (await tx())?.status == TransactionStatus.confirmed, 'imported');
    expect([for (final p in await storage().getMerkleProofHistory(kFixtureTxid)) p.status.name], ['rejected']);
    await sendHeaders(other, 3);
    await _until(() async => (await tx())?.status == TransactionStatus.pending, 'confirmation taken back');

    // ARC reports it REJECTED: the payment fails, its input is released and
    // the transaction row is failed.
    tell(RecordTransactionNetworkStatusCommand(
        walletId: walletId, txid: kFixtureTxid, networkStatus: DeferredNetworkStatus.rejected));
    tell(UpdateTransactionStatusCommand(walletId: walletId, txid: kFixtureTxid, newStatus: TransactionStatus.failed));
    await _until(() async => (await tx())?.status == TransactionStatus.failed &&
        (await utxo(inputKey))?.status == UTXOStatus.available &&
        (await storage().getDeferredPayment(walletId, kFixtureTxid))?.state == DeferredPaymentState.failed,
        'payment failed, input released');

    // A branch whose block 2 contains the transaction outgrows the other.
    final a1 = RegtestMiner.mine(parent: genesis, seed: 'A1');
    final a2 = RegtestMiner.mine(parent: a1, merkleRoot: root);
    await sendHeaders([a1, a2, ...RegtestMiner.mineChain(a2, 2, seed: 'A')], 4);

    await _until(() async => (await tx())?.status == TransactionStatus.confirmed, 'failed transaction confirmed');
    await _until(() async => (await utxo(inputKey))?.status == UTXOStatus.spent &&
        (await utxo('$kFixtureTxid:$_walletVout'))?.status == UTXOStatus.available &&
        (await storage().getDeferredPayment(walletId, kFixtureTxid))?.state == DeferredPaymentState.mined,
        'input spent, output available, payment mined');

    expect((await tx())!.blockHeight, 2);
    expect((await utxo(inputKey))!.spentInTxId, kFixtureTxid);
    expect([for (final p in await storage().getMerkleProofHistory(kFixtureTxid)) (p.blockHash, p.status)],
        [(a2.blockHash().toString(), MerkleProofStatus.verified)]);

    final events = await libspiffy.eventStore.getEvents('BitcoinWallet_$walletId');
    final failedAt = events.lastIndexWhere((e) => e is DeferredTransactionFailedEvent);
    final after = events.skip(failedAt + 1).toList();
    expect([
      for (final e in after)
        if (e is UTXOSpentEvent) 'spent ${e.txid}:${e.vout} in ${e.spentInTxId}'
        else if (e is TransactionConfirmedEvent) 'confirmed ${e.txid} h=${e.blockHeight} bump=${e.bumpHex}',
    ], ['spent $inputKey in $kFixtureTxid', 'confirmed $kFixtureTxid h=2 bump=${bump.toHex()}'],
        reason: 'journaled, so a replay keeps the confirmation and the spend');
  });
}

Future<void> _until(Future<bool> Function() condition, String what,
    {Duration timeout = const Duration(seconds: 8)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// ARC that knows no transaction.
class _UnknownTxArc extends ArcService {
  _UnknownTxArc() : super(baseUrl: 'fake://arc');

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async {
    throw ArcException('Failed to get transaction: {"status":404}');
  }
}
