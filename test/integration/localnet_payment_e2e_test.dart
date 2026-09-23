/// Ordinary payments run end to end on the real BSV regtest network,
/// against a real ARC (see localnet_harness.dart).
///
/// Bob invoices, Alice pays with a BEEF she hands him directly, and Bob,
/// the receiver, validates it and submits it to ARC (spv-understanding.md:
/// the payer does not broadcast). Then the node mines it, ARC reports it
/// MINED with its merkle path, and each wallet records the proof against
/// the header it synced from the node.
///
/// Tagged `localnet` and skipped by default; run with
///   dart test -P localnet test/integration/localnet_payment_e2e_test.dart
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

  /// [payee] invoices [amount]; returns the invoice id and its address.
  Future<(String, String)> invoice(
      LocalnetNode payee, String walletId, int amount) async {
    final created = payee.next<InvoiceCreatedEvent>((e) => e.walletId == walletId);
    payee.coordinator.tell(CreateInvoiceCommand(
      walletId: walletId,
      amount: BigInt.from(amount),
      description: 'localnet',
      expiresInSeconds: 3600,
    ));
    final event = await created;
    expect(event.success, isTrue, reason: event.error);
    return (event.invoiceId, event.addresses.first);
  }

  /// [payer] pays the invoice; returns the payment it hands the payee.
  Future<PaymentReadyEvent> pay(LocalnetNode payer, String walletId,
      String invoiceId, String address, int amount) async {
    final ready = payer.next<PaymentReadyEvent>((e) => e.invoiceId == invoiceId);
    payer.coordinator.tell(PayInvoiceCommand(
      walletId: walletId,
      invoiceId: invoiceId,
      addresses: [address],
      amount: BigInt.from(amount),
    ));
    final payment = await ready;
    expect(payment.success, isTrue, reason: payment.error);
    return payment;
  }

  /// [payee] validates the BEEF it was handed, and submits it.
  Future<BEEFValidationResultEvent> receive(LocalnetNode payee,
      String walletId, String invoiceId, PaymentReadyEvent payment) async {
    final result = payee.next<BEEFValidationResultEvent>(
        (e) => e.walletId == walletId && e.txid == payment.txid);
    payee.coordinator.tell(ValidateBEEFCommand(
      walletId: walletId,
      beefHex: hex.encode(payment.beefBytes),
      invoiceId: invoiceId,
    ));
    return result;
  }

  test('Alice pays Bob\'s invoice; Bob submits it, the node mines it, and both wallets confirm it',
      () async {
    if (unavailable != null) return;
    await alice.receiveMined(aliceWallet, kTestRootAddress);
    await bob.headersAt(await rpc('getblockcount') as int);
    final aliceBefore = await alice.balance(aliceWallet);
    expect(aliceBefore.confirmedBalance, BigInt.from(1000000));

    final (invoiceId, address) = await invoice(bob, bobWallet, 50000);
    final payment = await pay(alice, aliceWallet, invoiceId, address, 50000);

    // Alice hands the payment to Bob; she does not broadcast it.
    expect(await arcStatus(payment.txid), isNull,
        reason: 'the payer broadcast the payment');
    expect(await onNode(payment.txid), isNull);

    final received = await receive(bob, bobWallet, invoiceId, payment);
    expect(received.valid, isTrue, reason: received.error);
    expect(received.broadcasted, isTrue, reason: received.broadcastError);
    expect(received.networkStatus, isIn(const ['SEEN_ON_NETWORK', 'MINED']),
        reason: 'the network holds the payment; a block may have taken it '
            'within ARC\'s wait');
    await arcHolds(payment.txid);
    expect(await onNode(payment.txid), isNotNull,
        reason: 'ARC accepted the payment but the node does not hold it');

    // What each wallet holds before the block. Bob: the payment,
    // unconfirmed. Alice: her input held for the payment, and no change
    // yet, since her own node has not seen the network hold it.
    final fee = aliceBefore.totalBalance -
        BigInt.from(50000) -
        payment.changeAmount;
    expect(fee, greaterThan(BigInt.zero));
    expect(fee, lessThan(BigInt.from(1000)));
    final bobHeld = await bob.balance(bobWallet);
    expect(bobHeld.unconfirmedBalance, BigInt.from(50000));
    expect(bobHeld.confirmedBalance, BigInt.zero);
    final aliceHeld = await alice.balance(aliceWallet);
    expect(aliceHeld.totalBalance, BigInt.zero);
    expect(aliceHeld.reservedBalance, aliceBefore.confirmedBalance);
    expect((await bob.transaction(bobWallet, payment.txid))!.netAmount,
        BigInt.from(50000));

    // The block: ARC reports it MINED with its merkle path, and each wallet
    // records the proof against the header it synced from the node.
    final bobConfirmed = bob.next<TransactionConfirmedEvent>(
        (e) => e.txid == payment.txid, timeout: const Duration(minutes: 2));
    final aliceConfirmed = alice.next<TransactionConfirmedEvent>(
        (e) => e.txid == payment.txid, timeout: const Duration(minutes: 2));
    await mine();
    final minedIn = await minedAt(payment.txid);
    expect(minedIn, isNotNull);
    expect((await bobConfirmed).blockHeight, minedIn);
    expect((await aliceConfirmed).blockHeight, minedIn);
    await arcReports(payment.txid, 'MINED');

    final bobAfter = await bob.balance(bobWallet);
    expect(bobAfter.confirmedBalance, BigInt.from(50000));
    expect(bobAfter.unconfirmedBalance, BigInt.zero);
    final aliceAfter = await alice.balance(aliceWallet);
    expect(aliceAfter.confirmedBalance, payment.changeAmount);
    expect(aliceAfter.unconfirmedBalance, BigInt.zero);

    expect(alice.events.whereType<ErrorEvent>(), isEmpty, reason: alice.trace());
    expect(bob.events.whereType<ErrorEvent>(), isEmpty, reason: bob.trace());
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('Bob pays Alice from a payment not yet mined; ARC takes the chain and one block confirms both',
      () async {
    if (unavailable != null) return;
    await alice.receiveMined(aliceWallet, kTestRootAddress);
    await bob.headersAt(await rpc('getblockcount') as int);

    final (bobInvoice, bobAddress) = await invoice(bob, bobWallet, 60000);
    final first = await pay(alice, aliceWallet, bobInvoice, bobAddress, 60000);
    final received = await receive(bob, bobWallet, bobInvoice, first);
    expect(received.broadcasted, isTrue, reason: received.broadcastError);

    // Bob spends what he has just received, before any block: his BEEF
    // carries Alice's payment as an unproven ancestor.
    final (aliceInvoice, aliceAddress) = await invoice(alice, aliceWallet, 20000);
    final second = await pay(bob, bobWallet, aliceInvoice, aliceAddress, 20000);
    expect(second.ancestorCount, greaterThanOrEqualTo(1));
    final back = await receive(alice, aliceWallet, aliceInvoice, second);
    expect(back.valid, isTrue, reason: back.error);
    expect(back.broadcasted, isTrue, reason: back.broadcastError);
    await arcHolds(second.txid);

    final confirmations = [
      for (final node in [alice, bob])
        for (final txid in [first.txid, second.txid])
          node.next<TransactionConfirmedEvent>((e) => e.txid == txid,
              timeout: const Duration(minutes: 2)),
    ];
    await mine();
    for (final confirmed in await Future.wait(confirmations)) {
      expect(confirmed.blockHeight, await minedAt(confirmed.txid));
    }

    final bobAfter = await bob.balance(bobWallet);
    expect(bobAfter.confirmedBalance, second.changeAmount);
    expect(bobAfter.unconfirmedBalance, BigInt.zero);
    final aliceAfter = await alice.balance(aliceWallet);
    expect(aliceAfter.confirmedBalance, first.changeAmount + BigInt.from(20000));
    expect(aliceAfter.unconfirmedBalance, BigInt.zero);
    expect(alice.events.whereType<ErrorEvent>(), isEmpty, reason: alice.trace());
    expect(bob.events.whereType<ErrorEvent>(), isEmpty, reason: bob.trace());
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a payment handed over twice is received once', () async {
    if (unavailable != null) return;
    await alice.receiveMined(aliceWallet, kTestRootAddress);
    await bob.headersAt(await rpc('getblockcount') as int);

    final (invoiceId, address) = await invoice(bob, bobWallet, 30000);
    final payment = await pay(alice, aliceWallet, invoiceId, address, 30000);
    final once = await receive(bob, bobWallet, invoiceId, payment);
    expect(once.broadcasted, isTrue, reason: once.broadcastError);
    final twice = await receive(bob, bobWallet, invoiceId, payment);
    expect(twice.valid, isTrue, reason: twice.error);

    final bobHeld = await bob.balance(bobWallet);
    expect(bobHeld.totalBalance, BigInt.from(30000));
    expect(bob.events.whereType<ErrorEvent>(), isEmpty, reason: bob.trace());
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('Bob restarts between receiving a payment and its block, and confirms it after',
      () async {
    if (unavailable != null) return;
    await alice.receiveMined(aliceWallet, kTestRootAddress);
    await bob.headersAt(await rpc('getblockcount') as int);

    final (invoiceId, address) = await invoice(bob, bobWallet, 40000);
    final payment = await pay(alice, aliceWallet, invoiceId, address, 40000);
    final received = await receive(bob, bobWallet, invoiceId, payment);
    expect(received.broadcasted, isTrue, reason: received.broadcastError);

    await bob.restart();
    expect((await bob.balance(bobWallet)).unconfirmedBalance,
        BigInt.from(40000));

    final confirmed = bob.next<TransactionConfirmedEvent>(
        (e) => e.txid == payment.txid, timeout: const Duration(minutes: 2));
    final height = await mine();
    await bob.headersAt(height, timeout: const Duration(seconds: 30));
    expect((await confirmed).blockHeight, await minedAt(payment.txid));
    final bobAfter = await bob.balance(bobWallet);
    expect(bobAfter.confirmedBalance, BigInt.from(40000));
    expect(bobAfter.unconfirmedBalance, BigInt.zero);
    expect(bob.events.whereType<ErrorEvent>(), isEmpty, reason: bob.trace());
  }, timeout: const Timeout(Duration(minutes: 5)));
}
