/// Bead libspiffy-yiba (ruggerbot report #1): a payment spending an output
/// the wallet does not own kept none of that output's ancestry.
///
/// A token purchase spends the seller's listing output. The app hands the
/// plugin the listing transaction; the payment is recorded
/// (TransactionRecordedEvent, which carries no ancestors) and settled with a
/// BEEF. Nothing kept the listing, so AncestorChainService failed every
/// spend of the payment's change with "Transaction <listing> not found in
/// storage" until the payment itself was mined and proven.
///
/// A BEEF settled with SettleBEEFCommand now has the ancestry it carries for
/// its subject kept, journaled, and stored as a received BEEF's is. Here the
/// subject is an ordinary payment and the ancestor is its proven funding
/// transaction: what is checked is that the settled BEEF's ancestry reaches
/// the ancestor store, which is where a counterparty's transaction has to
/// be found.
library;

import 'dart:io';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:isar_community/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/src/core/wallet_commands.dart' show RecordTransactionAncestorsCommand;
import 'package:libspiffy/src/core/wallet_events.dart' show BeefAncestor;

import '../mocks/network_arc.dart';
import '../spv/testnet_proof_fixture.dart';
import 'isar_test_helper.dart';
import 'p2p_test_helpers.dart';

const _fundingTxid = 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101';
const _recipient = 'muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg';

void main() {
  late Directory dir;
  late Isar isar;
  late LibSpiffyActorSystem libspiffy;
  late LocalActorSystem actorSystem;
  late InMemoryWalletStorage readModel;
  late Stream<CoordinatorEvent> events;
  const walletId = 'settled-ancestors';

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('settled_ancestors_');
    actorSystem = LocalActorSystem(ActorSystemConfig());
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: dir.path,
      name: 'settled_ancestors_${DateTime.now().microsecondsSinceEpoch}',
    );
    readModel = InMemoryWalletStorage();
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      readModelStorage: readModel,
      dataDirectory: dir.path,
      enableP2P: false,
      arcService: NetworkArc(),
      secureStorage: InMemorySecureStorage(),
    );
    await readModel.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    events = libspiffy.coordinatorEvents!;
    await createWallet(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
      walletName: 'Settled',
      xpriv: kTestXpriv,
    );
    await fundWallet(
      walletManager: libspiffy.walletManager,
      actorSystem: actorSystem,
      walletId: walletId,
      amount: BigInt.from(1000000),
    );
  });

  tearDown(() async {
    await libspiffy.shutdown();
    try {
      await isar.close(deleteFromDisk: true);
    } catch (_) {}
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<T> send<T extends CoordinatorEvent>(Message command, bool Function(T e) where) async {
    final result = events.where((e) => e is T && where(e)).cast<T>().first.timeout(const Duration(seconds: 60));
    libspiffy.coordinator.tell(command);
    return result;
  }

  Future<PaymentReadyEvent> pay(String invoiceId) async {
    final ready = await send<PaymentReadyEvent>(
      PayInvoiceCommand(walletId: walletId, invoiceId: invoiceId, addresses: const [_recipient], amount: BigInt.from(100000)),
      (e) => e.invoiceId == invoiceId,
    );
    expect(ready.success, isTrue, reason: ready.error);
    return ready;
  }

  Future<void> settle(PaymentReadyEvent ready) async {
    final settled = await send<BEEFSettledEvent>(
        SettleBEEFCommand(walletId: walletId, beefHex: hex.encode(ready.beefBytes), txid: ready.txid),
        (e) => e.txid == ready.txid);
    expect(settled.success, isTrue, reason: settled.error);
  }

  test('the ancestry a settled BEEF carries is in the ancestor store, with its proof, once the settlement is done',
      () async {
    final ready = await pay('inv-1');
    expect(await readModel.getAncestorTransactionsBatch([_fundingTxid]), isEmpty,
        reason: 'precondition: nothing has put the funding transaction in the ancestor store');

    await settle(ready);

    // Old code: empty. A counterparty's transaction is found here or nowhere.
    final kept = await readModel.getAncestorTransactionsBatch([_fundingTxid]);
    expect(kept.keys, [_fundingTxid]);
    expect(await readModel.getMerkleProof(_fundingTxid), isNotNull);
  });

  test('the wallet keeps a settled transaction\'s ancestry once, and never for a transaction it did not record',
      () async {
    final ready = await pay('inv-2');
    await settle(ready);
    const ancestor = BeefAncestor(txid: _fundingTxid, rawHex: '00');

    Future<TransactionAncestorsRecordedResponse> record(String txid) => libspiffy.walletManager
        .ask<TransactionAncestorsRecordedResponse>(
            WalletCommandMessage(walletId,
                RecordTransactionAncestorsCommand(walletId: walletId, txid: txid, ancestors: const [ancestor])),
            const Duration(seconds: 10));

    final again = await record(ready.txid);
    expect(again.success, isTrue, reason: again.error);
    expect(again.journaled, isFalse, reason: 'the settlement kept them already');

    final stranger = await record('ee' * 32);
    expect(stranger.success, isTrue, reason: stranger.error);
    expect(stranger.journaled, isFalse, reason: 'not a transaction this wallet recorded');
  });
}
