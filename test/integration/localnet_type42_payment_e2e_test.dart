/// A type-42 payment to an offline payee, end to end on the real BSV
/// regtest network against a real ARC (spv-understanding.md, "Payment
/// modes"; bead libspiffy-zxkd; see localnet_harness.dart).
///
/// Carol publishes her wallet's anchor key A for her identity (with the
/// identity and epoch it was issued for), signed, and goes offline. Alice
/// derives a destination C from A with a fresh payer key and an invoice
/// number, pays it, broadcasts the payment herself (it is hers to
/// broadcast: Carol is not there to take it), and follows it to its block.
/// She exports it with its proof and the type-42 hand-off, which names A
/// and its context. Carol comes back on a new node — her wallet restored
/// from its seed, with no record of the anchor — derives A from the context
/// and C from A, imports the payment, and spends it on the network.
///
/// When Carol is online she takes the payment in unproven, with
/// ValidateBEEFCommand and a hand-off naming only A, which her wallet
/// matches to the anchor it issued.
///
/// Tagged `localnet` and skipped by default; run with
///   dart test -P localnet test/integration/localnet_type42_payment_e2e_test.dart
@Tags(['localnet'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/libspiffy.dart';

import 'isar_test_helper.dart';
import 'localnet_harness.dart';
import 'p2p_test_helpers.dart' show kTestXpriv, kTestRootAddress;

void main() {
  late LocalnetNode alice;
  LocalnetNode? carolNode;
  late String aliceWallet;
  late String carolWallet;
  String? unavailable;

  final carolIdentity = utf8.encode('carol-peer|epoch-0');

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
    final ts = DateTime.now().microsecondsSinceEpoch;
    aliceWallet = 'alice-$ts';
    carolWallet = 'carol-$ts';
    await alice.createWallet(aliceWallet, xpriv: kTestXpriv);
    await alice.receiveMined(aliceWallet, kTestRootAddress);
  });

  tearDown(() async {
    if (unavailable != null) return;
    await alice.stop();
    await carolNode?.stop();
    carolNode = null;
  });

  Future<LocalnetNode> carolOnline() async {
    final carol = carolNode = await LocalnetNode.start('carol-peer', timing);
    await carol.createWallet(carolWallet, mnemonic: bobMnemonic);
    await carol.headersAt(await tipHeight());
    return carol;
  }

  /// Carol's anchor key, and her signature binding it to her identity.
  Future<String> publishAnchor(LocalnetNode carol) async {
    final key =
        await carol.coordinator.ask(IssueAnchorKeyCommand(walletId: carolWallet, anchorContext: carolIdentity));

    final message = utf8.encode('overmedia:register_payment_pubkey:carol-peer:${key.publicKey}');
    final signature = await carol.coordinator
        .ask(SignWithAnchorKeyCommand(walletId: carolWallet, anchorContext: carolIdentity, message: message));
    expect(
        DartSVCryptoService().verifySignature(dartsv.SVPublicKey.fromHex(key.publicKey!),
            dartsv.SVSignature.fromDER(signature.signatureDer!), Uint8List.fromList(dartsv.sha256(message))),
        isTrue);
    return key.publicKey!;
  }

  Future<Type42Destination> derive(String anchor, {List<int>? context}) async =>
      (await alice.coordinator.ask(
              DeriveType42DestinationCommand(walletId: aliceWallet, anchorPublicKey: anchor, anchorContext: context)))
          .destination!;

  Future<PaymentReadyEvent> pay(LocalnetNode payer, String walletId, String invoiceId, String address, int amount) =>
      payer.coordinator.ask(PayInvoiceCommand(
        walletId: walletId,
        invoiceId: invoiceId,
        addresses: [address],
        amount: BigInt.from(amount),
      ));

  Future<(String, String)> invoice(LocalnetNode payee, String walletId, int amount) async {
    final event = await payee.coordinator.ask(CreateInvoiceCommand(
      walletId: walletId,
      amount: BigInt.from(amount),
      description: 'localnet',
      expiresInSeconds: 3600,
    ));
    return (event.invoiceId, event.addresses.first);
  }

  /// [payee] validates [beef]. A payment refused is answered too: one test
  /// expects it refused.
  Future<BEEFValidationResultEvent> receive(LocalnetNode payee, String walletId, String? invoiceId, List<int> beef,
          {List<Type42Derivation> type42 = const []}) =>
      answer(payee.coordinator, ValidateBEEFCommand(
        walletId: walletId,
        beefHex: hex.encode(beef),
        invoiceId: invoiceId,
        type42Derivations: type42,
      ));

  /// Carol spends [amount] of what she holds back to Alice, and the network
  /// takes her signature with the anchor key's type-42 child.
  Future<void> carolSpends(LocalnetNode carol, int amount) async {
    final (aliceInvoice, aliceAddress) = await invoice(alice, aliceWallet, amount);
    final spend = await pay(carol, carolWallet, aliceInvoice, aliceAddress, amount);
    final back = await receive(alice, aliceWallet, aliceInvoice, spend.beefBytes);
    expect(back.valid, isTrue, reason: back.error);
    expect(back.broadcasted, isTrue, reason: back.broadcastError);
    await arcHolds(spend.txid);
    final carolConfirmed =
        carol.next<TransactionConfirmedEvent>((e) => e.txid == spend.txid, timeout: const Duration(minutes: 2));
    await mine();
    expect((await carolConfirmed).blockHeight, await minedAt(spend.txid));
    expect((await carol.balance(carolWallet)).confirmedBalance, spend.changeAmount);
  }

  test('Alice pays offline Carol at a type-42 destination of her anchor key, broadcasts it herself, and hands '
      'it over mined; Carol imports it and spends it', () async {
    if (unavailable != null) return;

    // Carol publishes her anchor key, then goes offline.
    final firstCarol = await carolOnline();
    final anchor = await publishAnchor(firstCarol);
    await firstCarol.stop();
    carolNode = null;

    // Alice derives the destination from the published record, pays it, and
    // broadcasts the payment.
    final destination = await derive(anchor, context: carolIdentity);
    final payment = await pay(alice, aliceWallet, destination.derivation.invoiceNumber, destination.address, 40000);
    expect(await arcStatus(payment.txid), isNull, reason: 'nobody has broadcast it yet');
    await alice.coordinator.ask(BroadcastDeferredPaymentCommand(walletId: aliceWallet, txid: payment.txid));
    await arcHolds(payment.txid);

    final aliceConfirmed =
        alice.next<TransactionConfirmedEvent>((e) => e.txid == payment.txid, timeout: const Duration(minutes: 2));
    await mine();
    final minedIn = await minedAt(payment.txid);
    expect((await aliceConfirmed).blockHeight, minedIn);

    // Alice exports it: the proof, and the hand-off from her own journal.
    final export = await alice.coordinator.ask(ExportTransactionQuery(walletId: aliceWallet, txid: payment.txid));
    expect(export.type42Derivations, [destination.derivation]);

    // Carol comes back on a new node, restored from her seed, and is handed
    // it: the context in the hand-off gives her anchor again.
    final carol = await carolOnline();
    await carol.headersAt(minedIn!);
    final import = await carol.coordinator.ask(ImportTransactionCommand(
      walletId: carolWallet,
      beef: export.beef!,
      type42Derivations: export.type42Derivations,
    ));
    expect(import.transactionId, payment.txid);
    expect((await carol.balance(carolWallet)).confirmedBalance, BigInt.from(40000));

    await carolSpends(carol, 15000);
    for (final node in [alice, carol]) {
      expect(node.events.whereType<ErrorEvent>(), isEmpty, reason: node.trace());
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('online Carol takes an unproven type-42 payment in with the hand-off; it is confirmed and she spends it',
      () async {
    if (unavailable != null) return;
    final carol = await carolOnline();
    final anchor = await publishAnchor(carol);
    final destination = await derive(anchor);
    final payment = await pay(alice, aliceWallet, destination.derivation.invoiceNumber, destination.address, 30000);

    // Without the hand-off it is not Carol's: refused as unrelated.
    final unrelated = await receive(carol, carolWallet, null, payment.beefBytes);
    expect(unrelated.valid, isFalse);

    final received = await receive(carol, carolWallet, null, payment.beefBytes, type42: [destination.derivation]);
    expect(received.valid, isTrue, reason: received.error);
    expect(received.broadcasted, isTrue, reason: received.broadcastError);
    await arcHolds(payment.txid);

    final carolConfirmed =
        carol.next<TransactionConfirmedEvent>((e) => e.txid == payment.txid, timeout: const Duration(minutes: 2));
    await mine();
    expect((await carolConfirmed).blockHeight, await minedAt(payment.txid));
    expect((await carol.balance(carolWallet)).confirmedBalance, BigInt.from(30000));

    await carolSpends(carol, 10000);
    for (final node in [alice, carol]) {
      expect(node.events.whereType<ErrorEvent>(), isEmpty, reason: node.trace());
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
