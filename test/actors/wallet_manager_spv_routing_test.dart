/// WalletManagerActor: SPV results without a target wallet (A-L3,
/// libspiffy-3go, doc/audit-2026-09-14.md).
///
/// A validated SPV result with no targetWalletId was recorded into every
/// loaded wallet: each aggregate got the result's UTXOs and the imported
/// transaction, whoever owned the outputs. SPVActor attributes outputs only
/// to a target wallet, so such a result carries nothing that says which
/// wallet it belongs to; it is now rejected (logged, recorded nowhere).
import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart' as logging;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import 'in_memory_event_store.dart';

const _mnemonicA = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _mnemonicB = 'legal winner thank year wave sausage worth useful '
    'legal winner thank yellow';

void main() {
  late TestActorSystem actorSystem;
  late InMemoryEventStore eventStore;
  late ActorRef walletManager;

  setUp(() async {
    actorSystem = TestActorSystem();
    eventStore = InMemoryEventStore();
    walletManager = await actorSystem.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: eventStore,
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
      ),
    );
  });

  tearDown(() async {
    await actorSystem.shutdown();
  });

  List<Event> journal(String walletId) =>
      eventStore.journal['BitcoinWallet_$walletId'] ?? const [];

  Future<void> waitForTxid(String walletId, String txid) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!journal(walletId)
        .any((e) => e is TransactionImportedEvent && e.txid == txid)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('$walletId never recorded $txid');
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  SPVValidationResult result(String txid, String address,
          {String? targetWalletId}) =>
      SPVValidationResult(
        txid: txid,
        isValid: true,
        targetWalletId: targetWalletId,
        spendableUTXOs: [
          {
            'txid': txid,
            'vout': 0,
            'satoshis': 5000,
            'script': '76a914000000000000000000000000000000000000000088ac',
            'address': address,
          },
        ],
        transactionData: {
          'rawHex': '00',
          'blockHeight': null,
          'bumpProof': '',
          'totalOutputSats': 5000,
          'numInputs': 1,
          'numOutputs': 1,
          'txVersion': 1,
          'txLockTime': 0,
          'walletReceivingAddresses': [address],
          'walletReceivedSats': 5000,
          'totalInputSats': 6000,
          'sendingAddresses': <String>[],
        },
      );

  test('a result without a target wallet is recorded into no wallet',
      () async {
    final a = await walletManager.ask<WalletCreatedMessage>(
      CreateWalletMessage('wallet-a', 'A', mnemonic: _mnemonicA),
      const Duration(seconds: 10),
    );
    final b = await walletManager.ask<WalletCreatedMessage>(
      CreateWalletMessage('wallet-b', 'B', mnemonic: _mnemonicB),
      const Duration(seconds: 10),
    );
    expect(a.success, isTrue, reason: a.error);
    expect(b.success, isTrue, reason: b.error);
    expect(a.rootAddress, isNot(b.rootAddress));

    final records = <logging.LogRecord>[];
    final sub = logging.Logger.root.onRecord.listen(records.add);
    addTearDown(sub.cancel);

    final untargeted = 'aa' * 32;
    final lengthA = journal('wallet-a').length;
    final lengthB = journal('wallet-b').length;

    // Pays only wallet A's root address, but names no wallet.
    walletManager.tell(result(untargeted, a.rootAddress));

    // Barrier: targeted results told afterwards are processed after the
    // untargeted one by the manager and by each aggregate.
    walletManager.tell(
        result('bb' * 32, a.rootAddress, targetWalletId: 'wallet-a'));
    walletManager.tell(
        result('cc' * 32, b.rootAddress, targetWalletId: 'wallet-b'));
    await waitForTxid('wallet-a', 'bb' * 32);
    await waitForTxid('wallet-b', 'cc' * 32);

    bool touches(Event e) =>
        (e is TransactionImportedEvent && e.txid == untargeted) ||
        (e is UTXOReceivedEvent && e.txid == untargeted);

    expect(journal('wallet-b').skip(lengthB).where(touches), isEmpty,
        reason: 'wallet B recorded a result that paid only wallet A');
    expect(journal('wallet-a').skip(lengthA).where(touches), isEmpty,
        reason: 'a result naming no wallet is rejected, not guessed');
    expect(
      records.where((r) =>
          r.loggerName == 'WalletManagerActor' &&
          r.level == logging.Level.WARNING &&
          r.message.contains(untargeted)),
      isNotEmpty,
      reason: 'the rejection must be logged',
    );
  });
}
