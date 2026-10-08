import 'dart:async';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar_community/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/coordinator.dart';

import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';
import '../mocks/network_arc.dart';

/// Bead libspiffy-zjyu: a payment's change went back to the address of its
/// first input, so every payment reused an address. Change now goes to a
/// fresh address on the change chain (m/1/i), which counts its own index:
/// the receive chain keeps no gaps for address discovery to stop at.
void main() {
  late LibSpiffyActorSystem system;
  late ActorRef coordinator;
  late Stream<CoordinatorEvent> events;
  late Directory dir;
  late LocalActorSystem actorSystem;

  final crypto = DartSVCryptoService();
  final hdPublicKey = crypto.deriveHDPublicKey(dartsv.HDPrivateKey.fromXpriv(kTestXpriv));
  String derive(AddressChain chain, int index) => crypto.deriveAddress(hdPublicKey, index, chain: chain);

  // Not this wallet's: m/0/0 of the BIP39 test mnemonic "abandon ... about".
  const payee = 'n4VQ5YdHf7hLQ2gWQYYrcxoE5B7nWuDFNF';

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('change_address_');
    actorSystem = LocalActorSystem(ActorSystemConfig());
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'change_${DateTime.now().microsecondsSinceEpoch}',
    );
    system = LibSpiffyActorSystem();
    await system.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: dir.path,
      enableP2P: false,
      arcService: NetworkArc(),
      secureStorage: InMemorySecureStorage(),
    );
    await setupTestHeaders(system.walletStorage as IsarWalletStorage);
    coordinator = system.coordinator;
    events = system.coordinatorEvents!;
  });

  tearDown(() async {
    await system.shutdown();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<AddressGeneratedEvent> generate(String walletId, {String? purpose}) {
    final requestId = 'gen-${DateTime.now().microsecondsSinceEpoch}';
    final reply = events
        .where((e) => e is AddressGeneratedEvent && e.requestId == requestId)
        .cast<AddressGeneratedEvent>()
        .first
        .timeout(const Duration(seconds: 10));
    coordinator.tell(GenerateAddressCommand(walletId: walletId, purpose: purpose, requestId: requestId));
    return reply;
  }

  test('change goes to a fresh change-chain address, and the receive chain keeps counting', () async {
    final walletId = 'payer-${DateTime.now().microsecondsSinceEpoch}';
    final created = events
        .where((e) => e is WalletCreatedEvent && e.walletId == walletId)
        .first
        .timeout(const Duration(seconds: 10));
    coordinator.tell(CreateWalletCommand(walletId: walletId, name: 'Payer', xpriv: kTestXpriv));
    await created;

    final receiveBefore = await generate(walletId);
    expect(receiveBefore.chain, AddressChain.receive);

    await fundWallet(
      walletManager: system.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
      amount: BigInt.from(200000000),
    );

    final ready = events.where((e) => e is PaymentReadyEvent).cast<PaymentReadyEvent>().first.timeout(
          const Duration(seconds: 15),
        );
    coordinator.tell(PayInvoiceCommand(
      walletId: walletId,
      invoiceId: 'invoice-${DateTime.now().microsecondsSinceEpoch}',
      addresses: [payee],
      amount: BigInt.from(50000),
    ));
    final payment = await ready;
    expect(payment.success, isTrue, reason: 'payment failed: ${payment.error}');

    final rawHex = (await system.walletStorage.getTransaction(payment.txid!, walletId: walletId))!.rawHex;
    final tx = dartsv.Transaction.fromHex(rawHex);
    final outputAddresses = [
      for (final o in tx.outputs)
        dartsv.P2PKHLockBuilder.fromScript(o.script, networkType: dartsv.NetworkType.TEST).address!.toBase58(),
    ];
    expect(outputAddresses, hasLength(2));
    expect(outputAddresses, contains(payee));
    final change = outputAddresses.firstWhere((a) => a != payee);

    expect(change, isNot(kTestRootAddress), reason: 'change must not go back to the input address');
    expect(change, derive(AddressChain.change, 0), reason: 'change takes the first change-chain address');

    // The payment took no index from the receive chain.
    final receiveAfter = await generate(walletId);
    expect(receiveAfter.chain, AddressChain.receive);
    expect(receiveAfter.derivationIndex, receiveBefore.derivationIndex! + 1);

    // The next change address is the next on the change chain.
    final nextChange = await generate(walletId, purpose: 'change');
    expect(nextChange.chain, AddressChain.change);
    expect(nextChange.derivationIndex, 1);
    expect(nextChange.address, derive(AddressChain.change, 1));
  });
}
