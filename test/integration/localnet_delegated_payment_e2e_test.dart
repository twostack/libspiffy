/// A payment to an offline payee, end to end on the real BSV regtest network
/// against a real ARC (spv-understanding.md, "Payment modes"; bead
/// libspiffy-m8qu; see localnet_harness.dart).
///
/// Carol registered her xpub with a service, which keeps it as a watch-only
/// wallet. While Carol is offline, Alice asks the service for an invoice:
/// the service answers with an address on Carol's delegated chain (m/2/i),
/// receives Alice's BEEF, submits it to ARC and follows it to its block.
/// Once it is mined the service exports it with its proof and hands it to
/// Carol with the index it issued. Carol's wallet derives the address from
/// its own key, imports the payment, and spends it on the network.
///
/// Tagged `localnet` and skipped by default; run with
///   dart test -P localnet test/integration/localnet_delegated_payment_e2e_test.dart
@Tags(['localnet'])
library;

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
  late LocalnetNode service;
  LocalnetNode? carolNode; // started only once the payment is mined
  late String aliceWallet;
  late String serviceWallet;
  late String carolWallet;
  late dartsv.HDPublicKey carolXpub;
  String? unavailable;

  final crypto = DartSVCryptoService();
  final timing = ChannelTiming(
    settlementMargin: Duration(seconds: 30),
    minimumLifetime: Duration(minutes: 2),
  );

  setUpAll(() async {
    unavailable = await localnetProblem();
    if (unavailable != null) return;
    await ensureIsarInitialized();
    carolXpub = crypto.deriveHDPublicKey(
        await crypto.mnemonicToHDPrivateKey(bobMnemonic, network: dartsv.NetworkType.TEST));
  });

  setUp(() async {
    if (unavailable != null) markTestSkipped(unavailable!);
    if (unavailable != null) return;
    alice = await LocalnetNode.start('alice-peer', timing);
    service = await LocalnetNode.start('service-peer', timing);
    final ts = DateTime.now().microsecondsSinceEpoch;
    aliceWallet = 'alice-$ts';
    serviceWallet = 'carol-at-service-$ts';
    carolWallet = 'carol-$ts';
    await alice.createWallet(aliceWallet, xpriv: kTestXpriv);
    // Carol's registration: the service keeps her xpub, nothing more.
    await service.createWallet(serviceWallet, xpub: carolXpub.xpubkey);
  });

  tearDown(() async {
    if (unavailable != null) return;
    await alice.stop();
    await service.stop();
    await carolNode?.stop();
    carolNode = null;
  });

  Future<(String, String)> invoice(LocalnetNode payee, String walletId, int amount) async {
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

  Future<PaymentReadyEvent> pay(LocalnetNode payer, String walletId, String invoiceId, String address, int amount) async {
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

  Future<BEEFValidationResultEvent> receive(
      LocalnetNode payee, String walletId, String invoiceId, PaymentReadyEvent payment) {
    final result = payee.next<BEEFValidationResultEvent>((e) => e.walletId == walletId && e.txid == payment.txid);
    payee.coordinator.tell(ValidateBEEFCommand(
      walletId: walletId,
      beefHex: hex.encode(payment.beefBytes),
      invoiceId: invoiceId,
    ));
    return result;
  }

  test('the service takes Alice\'s payment for offline Carol on her delegated chain, and Carol, handed it '
      'with its proof and index, imports it and spends it', () async {
    if (unavailable != null) return;
    await alice.receiveMined(aliceWallet, kTestRootAddress);
    await service.headersAt(await rpc('getblockcount') as int);

    // The service answers the invoice request for Carol, on m/2/i.
    final (invoiceId, address) = await invoice(service, serviceWallet, 50000);
    final index = [
      for (var i = 0; i < 20; i++)
        if (crypto.deriveAddress(carolXpub, i, chain: AddressChain.delegated, network: dartsv.NetworkType.TEST) ==
            address)
          i,
    ].single;
    expect(address, isNot(crypto.deriveAddress(carolXpub, index, network: dartsv.NetworkType.TEST)),
        reason: 'the address Carol\'s own wallet issues at that index is a different one');

    // Alice pays and hands the BEEF to the service, which submits it.
    final payment = await pay(alice, aliceWallet, invoiceId, address, 50000);
    expect(await arcStatus(payment.txid), isNull, reason: 'the payer broadcast the payment');
    final received = await receive(service, serviceWallet, invoiceId, payment);
    expect(received.valid, isTrue, reason: received.error);
    expect(received.broadcasted, isTrue, reason: received.broadcastError);
    await arcHolds(payment.txid);

    // The block. The service confirms it against the headers it synced.
    final serviceConfirmed =
        service.next<TransactionConfirmedEvent>((e) => e.txid == payment.txid, timeout: const Duration(minutes: 2));
    final aliceConfirmed =
        alice.next<TransactionConfirmedEvent>((e) => e.txid == payment.txid, timeout: const Duration(minutes: 2));
    await mine();
    final minedIn = await minedAt(payment.txid);
    expect((await serviceConfirmed).blockHeight, minedIn);
    expect((await aliceConfirmed).blockHeight, minedIn);

    // The money is Carol's, not the service's: watch-only, never spendable
    // by the service (bead libspiffy-bfs1).
    final held = await service.balance(serviceWallet);
    expect(held.watchOnlyBalance, BigInt.from(50000));
    expect(held.totalBalance, BigInt.zero);

    // The service exports the payment with its proof.
    final exported =
        service.next<TransactionExportedEvent>((e) => e.walletId == serviceWallet && e.txid == payment.txid);
    service.coordinator.tell(ExportTransactionQuery(walletId: serviceWallet, txid: payment.txid));
    final export = await exported;
    expect(export.success, isTrue, reason: export.error);

    // Carol comes online and is handed the payment and its index.
    final carol = carolNode = await LocalnetNode.start('carol-peer', timing);
    await carol.createWallet(carolWallet, mnemonic: bobMnemonic);
    await carol.headersAt(minedIn!);
    final imported = carol.next<TransactionImportedEvent>((e) => e.walletId == carolWallet);
    carol.coordinator.tell(ImportTransactionCommand(
      walletId: carolWallet,
      beef: export.beef!,
      delegatedIndices: [index],
    ));
    final import = await imported;
    expect(import.success, isTrue, reason: import.error);
    expect(import.transactionId, payment.txid);
    final carolHolds = await carol.balance(carolWallet);
    expect(carolHolds.confirmedBalance, BigInt.from(50000));

    // Carol spends it: the network takes her signature with the key at
    // m/2/index.
    final (aliceInvoice, aliceAddress) = await invoice(alice, aliceWallet, 20000);
    final spend = await pay(carol, carolWallet, aliceInvoice, aliceAddress, 20000);
    final back = await receive(alice, aliceWallet, aliceInvoice, spend);
    expect(back.valid, isTrue, reason: back.error);
    expect(back.broadcasted, isTrue, reason: back.broadcastError);
    await arcHolds(spend.txid);

    final carolConfirmed =
        carol.next<TransactionConfirmedEvent>((e) => e.txid == spend.txid, timeout: const Duration(minutes: 2));
    await mine();
    expect((await carolConfirmed).blockHeight, await minedAt(spend.txid));
    expect((await carol.balance(carolWallet)).confirmedBalance, spend.changeAmount);

    for (final node in [alice, service, carol]) {
      expect(node.events.whereType<ErrorEvent>(), isEmpty, reason: node.trace());
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
