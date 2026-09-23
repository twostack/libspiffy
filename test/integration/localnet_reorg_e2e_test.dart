/// A reorganization of the real BSV regtest chain, end to end.
///
/// `reorg_confirmation_revert_test.dart` drives the same rules with headers
/// handed to the actor directly. This drives them the way they happen: the
/// node drops a block (`invalidateblock`) and builds a longer branch, the
/// headers arrive over P2P as any block's would, and ARC is asked again for
/// the proof of a transaction whose block is gone.
///
/// What a wallet owes its owner here is that it never keeps a confirmation
/// the chain no longer supports. The proof of the block that left is kept
/// with the status orphaned — proofs are never deleted — and the proof of
/// the block that replaced it takes over.
///
/// Tagged `localnet` and skipped by default; run with
///   dart test -P localnet test/integration/localnet_reorg_e2e_test.dart
@Tags(['localnet'])
library;

import 'package:convert/convert.dart';
import 'package:test/test.dart';

import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/libspiffy.dart';

import 'isar_test_helper.dart';
import 'localnet_harness.dart';
import 'p2p_test_helpers.dart' show kTestXpriv, kTestRootAddress;

void main() {
  late LocalnetNode alice;
  late LocalnetNode bob;
  late String aliceWallet;
  late String bobWallet;
  String? unavailable;

  final timing = ChannelTiming(
    settlementMargin: Duration(seconds: 30),
    minimumLifetime: Duration(minutes: 2),
  );

  setUpAll(() async {
    unavailable = await localnetProblem();
    if (unavailable != null) return;
    await ensureIsarInitialized();
  });

  setUp(() async {
    if (unavailable != null) markTestSkipped(unavailable!);
    if (unavailable != null) return;
    alice = await LocalnetNode.start('alice-peer', timing);
    bob = await LocalnetNode.start('bob-peer', timing);
    final ts = DateTime.now().microsecondsSinceEpoch;
    aliceWallet = 'alice-$ts';
    bobWallet = 'bob-$ts';
    await alice.createWallet(aliceWallet, xpriv: kTestXpriv);
    await bob.createWallet(bobWallet, mnemonic: bobMnemonic);
  });

  tearDown(() async {
    if (unavailable != null) return;
    await alice.stop();
    await bob.stop();
  });

  /// Alice pays Bob [amount]; Bob validates the BEEF he is handed and
  /// submits it, as the payee does. Returns the payment.
  Future<PaymentReadyEvent> alicePaysBob(int amount) async {
    await alice.receiveMined(aliceWallet, kTestRootAddress);
    await bob.headersAt(await rpc('getblockcount') as int);

    final created = bob.next<InvoiceCreatedEvent>((e) => e.walletId == bobWallet);
    bob.coordinator.tell(CreateInvoiceCommand(
      walletId: bobWallet,
      amount: BigInt.from(amount),
      description: 'localnet reorg',
      expiresInSeconds: 3600,
    ));
    final invoice = await created;
    expect(invoice.success, isTrue, reason: invoice.error);

    final ready = alice.next<PaymentReadyEvent>((e) => e.invoiceId == invoice.invoiceId);
    alice.coordinator.tell(PayInvoiceCommand(
      walletId: aliceWallet,
      invoiceId: invoice.invoiceId,
      addresses: [invoice.addresses.first],
      amount: BigInt.from(amount),
    ));
    final payment = await ready;
    expect(payment.success, isTrue, reason: payment.error);

    final validated = bob.next<BEEFValidationResultEvent>(
        (e) => e.walletId == bobWallet && e.txid == payment.txid);
    bob.coordinator.tell(ValidateBEEFCommand(
      walletId: bobWallet,
      beefHex: hex.encode(payment.beefBytes),
      invoiceId: invoice.invoiceId,
    ));
    final received = await validated;
    expect(received.valid, isTrue, reason: received.error);
    expect(received.broadcasted, isTrue, reason: received.broadcastError);
    return payment;
  }

  /// Mines a block and waits for both wallets to confirm [txid] in the
  /// block the chain puts it in. Returns that height.
  Future<int> mineAndConfirm(String txid) async {
    final confirmations = [
      for (final node in [alice, bob])
        node.next<TransactionConfirmedEvent>((e) => e.txid == txid,
            timeout: const Duration(minutes: 2)),
    ];
    await mine();
    final height = await minedAt(txid);
    expect(height, isNotNull, reason: 'the node does not hold $txid in a block');
    for (final confirmed in await Future.wait(confirmations)) {
      expect(confirmed.blockHeight, height);
    }
    return height!;
  }

  /// This node's current proof of [txid], read from its own storage.
  Future<MerkleProof?> proofOf(LocalnetNode node, String txid) =>
      IsarWalletStorage(node.isar).getMerkleProof(txid);

  Future<List<MerkleProof>> proofHistory(LocalnetNode node, String txid) =>
      IsarWalletStorage(node.isar).getMerkleProofHistory(txid);

  /// Drops the block at [height] and everything above it, then builds a
  /// branch of [blocks] blocks in its place, so the chain the wallets
  /// follow reorganizes. Returns the new tip height.
  Future<int> reorgFrom(int height, {int blocks = 2}) async {
    final dropped = await rpc('getblockhash', [height]) as String;
    await rpc('invalidateblock', [dropped]);
    return mine(blocks);
  }

  /// The hash of the block the node holds [txid] in.
  Future<String?> blockOf(String txid) async =>
      (await onNode(txid))?['blockhash'] as String?;

  test('the block that confirmed a payment is dropped: the wallets follow the '
      'chain to the block that replaces it, and keep the proof of the one that left',
      () async {
    if (unavailable != null) return;
    final payment = await alicePaysBob(50000);
    final height = await mineAndConfirm(payment.txid);
    final orphanedBlock = await blockOf(payment.txid);
    expect(orphanedBlock, isNotNull);

    final proof = (await proofOf(bob, payment.txid))!;
    expect(proof.status, MerkleProofStatus.verified);
    expect(proof.blockHash, orphanedBlock);
    expect(proof.blockHeight, height);

    // The chain drops that block and builds a longer branch. The payment
    // goes back to the node's mempool and is mined again, in a block of a
    // different hash at the same height.
    final reproven = [
      for (final node in [alice, bob])
        node.next<TransactionConfirmedEvent>((e) => e.txid == payment.txid,
            timeout: const Duration(minutes: 6)),
    ];
    await reorgFrom(height);
    final replacement = await blockOf(payment.txid);
    expect(replacement, isNotNull,
        reason: 'the payment should be mined again on the new branch');
    expect(replacement, isNot(orphanedBlock));
    expect(await minedAt(payment.txid), height,
        reason: 'the branch replaces the block at the same height');

    // Until ARC answers for the block on the chain, the only proof on offer
    // is the one for the block that left, and a wallet is right to refuse
    // it. What this test is about is what each wallet does either side of
    // that: it takes the confirmation back, and it puts it back.
    await arcProves(payment.txid, replacement!, mineWhileWaiting: true);
    await Future.wait(reproven);
    await bob.headersAt(await rpc('getblockcount') as int,
        timeout: const Duration(minutes: 2));

    final after = (await proofOf(bob, payment.txid))!;
    expect(after.blockHash, replacement,
        reason: 'the current proof is the one for the block on the chain');
    expect(after.status, MerkleProofStatus.verified);

    final history = await proofHistory(bob, payment.txid);
    expect(
        history.where((p) => p.blockHash == orphanedBlock).map((p) => p.status),
        [MerkleProofStatus.orphaned],
        reason: 'the proof of the block that left is kept, marked orphaned');

    final held = await bob.balance(bobWallet);
    expect(held.confirmedBalance, BigInt.from(50000));
    expect(held.unconfirmedBalance, BigInt.zero);
    expect((await bob.transaction(bobWallet, payment.txid))!.blockHeight, height);
    expect(bob.events.whereType<ErrorEvent>(), isEmpty, reason: bob.trace());
    expect(alice.events.whereType<ErrorEvent>(), isEmpty, reason: alice.trace());
  }, timeout: const Timeout(Duration(minutes: 12)));

  test('a deeper reorganization moves the payment to another height: the wallets '
      'record the height the chain gives it', () async {
    if (unavailable != null) return;
    final payment = await alicePaysBob(40000);
    final height = await mineAndConfirm(payment.txid);
    await mine(2);

    // Drop the block below the payment's too, so the branch that replaces
    // it mines the payment one height lower than before.
    final reproven = [
      for (final node in [alice, bob])
        node.next<TransactionConfirmedEvent>(
            (e) => e.txid == payment.txid && e.blockHeight != height,
            timeout: const Duration(minutes: 6)),
    ];
    await reorgFrom(height - 1, blocks: 4);

    final moved = await minedAt(payment.txid);
    expect(moved, height - 1,
        reason: 'the payment is mined in the first block of the new branch');
    await arcProves(payment.txid, (await blockOf(payment.txid))!,
        mineWhileWaiting: true);
    for (final confirmed in await Future.wait(reproven)) {
      expect(confirmed.blockHeight, moved);
    }
    await bob.headersAt(await rpc('getblockcount') as int,
        timeout: const Duration(minutes: 2));

    expect((await proofOf(bob, payment.txid))!.blockHeight, moved);
    expect((await bob.transaction(bobWallet, payment.txid))!.blockHeight, moved);
    final held = await bob.balance(bobWallet);
    expect(held.confirmedBalance, BigInt.from(40000));
    expect(bob.events.whereType<ErrorEvent>(), isEmpty, reason: bob.trace());
  }, timeout: const Timeout(Duration(minutes: 12)));
}
