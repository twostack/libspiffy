import 'dart:io';

import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/libspiffy.dart'
    show DartSVCryptoService, InMemorySecureStorage, LibSpiffyActorSystem, StorageBackend;

/// The coordinator API: each request returns its own reply with `ask`, a
/// failure throws `CoordinatorFailure`, and `on<E>()` follows what happens
/// without a request.
///
/// Runs offline, with in-memory storage and no network:
///
///     dart run example/coordinator_example.dart
Future<void> main() async {
  final libspiffy = LibSpiffyActorSystem();
  await libspiffy.initialize(
    dataDirectory: Directory.systemTemp.createTempSync('libspiffy_example_').path,
    storageBackend: StorageBackend.inMemory,
    secureStorage: InMemorySecureStorage(),
    enableP2P: false,
  );
  final coordinator = libspiffy.coordinator;

  // What happens without a request: here, the wallet's balance changing.
  final balances = coordinator.on<BalanceUpdatedEvent>(walletId: 'shop').listen((event) {
    print('balance now ${event.totalBalance} sats');
  });

  // The app supplies the key material, and backs it up.
  final mnemonic = await DartSVCryptoService().generateMnemonic();
  final wallet = await coordinator.ask(CreateWalletCommand(walletId: 'shop', name: 'Shop', mnemonic: mnemonic));
  print('created ${wallet.walletId}, root address ${wallet.rootAddress}');

  final invoice = await coordinator.ask(CreateInvoiceCommand(
    walletId: 'shop',
    amount: BigInt.from(50000),
    description: 'Coffee order #42',
  ));
  print('invoice ${invoice.invoiceId}: pay ${invoice.amount} sats to ${invoice.addresses.single}');

  final balance = await coordinator.ask(GetBalanceQuery(walletId: 'shop'));
  print('balance ${balance.totalBalance} sats');

  // A request that fails throws, carrying the reply that said why.
  try {
    await coordinator.ask(PayInvoiceCommand(
      walletId: 'shop',
      invoiceId: invoice.invoiceId,
      addresses: invoice.addresses,
      amount: invoice.amount,
    ));
  } on CoordinatorFailure catch (failure) {
    print('not paid: ${failure.message}');
  }

  await balances.cancel();
  await libspiffy.shutdown();
}
