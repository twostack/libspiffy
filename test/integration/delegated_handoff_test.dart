/// The service-to-payee hand-off through the coordinator (bead
/// libspiffy-m8qu; spv-understanding.md, "Payment modes").
///
/// A service keeps a payee's xpub as a watch-only wallet and answers an
/// invoice request on the payee's delegated chain. Once the payment is
/// mined, the service exports it with its proof (ExportTransactionQuery),
/// and the payee's wallet imports it with the index the service issued
/// (ImportTransactionCommand.delegatedIndices).
///
/// Both wallets live in one process here, so the payee imports a
/// transaction another wallet of the process already holds. The answer to
/// an import used to wait for any wallet's row of the txid, so the payee was
/// told it was imported before its own read model held the payment; every
/// read-model wait of the coordinator now names its wallet.
///
/// The block is made up: one transaction, so its merkle root is the txid and
/// its merkle path is empty. localnet_delegated_payment_e2e_test.dart runs
/// the same hand-off on the real regtest network.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:isar/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/coordinator.dart' as coord;
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/storage/isar_wallet_storage.dart';
import 'package:spiffynode/spiffy_node.dart' as spiffynode;

import 'isar_test_helper.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const _height = 1239700;

void main() {
  final crypto = DartSVCryptoService();
  late Directory dir;
  late Isar isar;
  late LibSpiffyActorSystem libspiffy;
  late IsarWalletStorage storage;
  late dartsv.HDPublicKey accountXpub;

  setUpAll(() async {
    await ensureIsarInitialized();
    accountXpub =
        crypto.deriveHDPublicKey(await crypto.mnemonicToHDPrivateKey(_mnemonic, network: dartsv.NetworkType.TEST));
  });

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('delegated-handoff-');
    isar = await Isar.open(LibSpiffySchemas.allSchemas,
        directory: dir.path, name: 'handoff_${DateTime.now().microsecondsSinceEpoch}');
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: LocalActorSystem(ActorSystemConfig()),
      isar: isar,
      dataDirectory: dir.path,
      enableP2P: false,
      secureStorage: InMemorySecureStorage(),
    );
    storage = libspiffy.walletStorage as IsarWalletStorage;
  });

  tearDown(() async {
    await libspiffy.shutdown();
    await isar.close(deleteFromDisk: true);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<T> next<T extends coord.CoordinatorEvent>(bool Function(T) where) => libspiffy.coordinatorEvents!
      .where((e) => e is T && where(e))
      .cast<T>()
      .first
      .timeout(const Duration(seconds: 20));

  Future<void> createWallet(String walletId, {String? xpub, String? mnemonic}) async {
    final created = next<coord.WalletCreatedEvent>((e) => e.walletId == walletId);
    libspiffy.coordinator
        .tell(coord.CreateWalletCommand(walletId: walletId, name: walletId, xpub: xpub, mnemonic: mnemonic));
    expect((await created).success, isTrue);
  }

  Future<coord.BalanceResponse> balance(String walletId) {
    final answer = next<coord.BalanceResponse>((e) => e.walletId == walletId);
    libspiffy.coordinator.tell(coord.GetBalanceQuery(walletId: walletId));
    return answer;
  }

  Future<coord.TransactionImportedEvent> import(String walletId, List<int> beef, {List<int> delegated = const []}) {
    final imported = next<coord.TransactionImportedEvent>((e) => e.walletId == walletId);
    libspiffy.coordinator
        .tell(coord.ImportTransactionCommand(walletId: walletId, beef: beef, delegatedIndices: delegated));
    return imported;
  }

  Future<coord.TransactionExportedEvent> export(String walletId, String txid) {
    final exported = next<coord.TransactionExportedEvent>((e) => e.walletId == walletId && e.txid == txid);
    libspiffy.coordinator.tell(coord.ExportTransactionQuery(walletId: walletId, txid: txid));
    return exported;
  }

  /// A mined payment of [sats] to [address]: the only transaction of a
  /// block at [_height], whose header is stored.
  Future<(String txid, List<int> beef)> minedPayment(String address, int sats) async {
    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    tx.inputs.add(dartsv.TransactionInput('ee' * 32, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    tx.outputs.add(dartsv.TransactionOutput(
        BigInt.from(sats), dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey()));
    final txid = tx.id;
    await storage.storeBlockHeader(
      spiffynode.BlockHeader(
        version: 536870912,
        prevBlock: spiffynode.Hash.fromHex('00' * 32),
        merkleRoot: spiffynode.Hash.fromHex(txid),
        timestamp: DateTime.utc(2026, 9, 24),
        bits: 0x207fffff,
        nonce: 0,
      ),
      _height,
    );
    final beef = BEEF.create(
      bumps: [BUMP.fromTscProof(blockHeight: _height, txid: txid, index: 0, nodes: const [])],
      txs: [Uint8List.fromList(hex.decode(tx.serialize()))],
      hasMerkle: [true],
      bumpIndex: [0],
    );
    return (txid, beef.serialize().toList());
  }

  test('the service exports the payment it took on the delegated chain, and the payee imports it with the '
      'index and holds it', () async {
    await createWallet('service', xpub: accountXpub.xpubkey);
    await createWallet('payee', mnemonic: _mnemonic);

    Future<IssuedAddress> invoice(String walletId) async {
      final invoiced = next<coord.InvoiceCreatedEvent>((e) => e.walletId == walletId);
      libspiffy.coordinator.tell(coord.CreateInvoiceCommand(walletId: walletId, amount: BigInt.from(70000)));
      final event = await invoiced;
      expect(event.addresses, [event.issuedAddresses.single.address]);
      return event.issuedAddresses.single;
    }

    // The invoice names its payment mode: the payee's own wallet issues on
    // the receive chain, the service's copy of it on the delegated chain.
    final own = await invoice('payee');
    expect(own.chain, AddressChain.receive);
    final issued = await invoice('service');
    expect(issued.chain, AddressChain.delegated);
    final address = issued.address;
    final index = issued.derivationIndex;
    expect(address,
        crypto.deriveAddress(accountXpub, index, chain: AddressChain.delegated, network: dartsv.NetworkType.TEST));
    expect(address, isNot(own.address));

    final (txid, mined) = await minedPayment(address, 70000);
    final serviceImport = await import('service', mined);
    expect(serviceImport.success, isTrue, reason: serviceImport.error);
    final held = await balance('service');
    expect((held.watchOnlyBalance, held.totalBalance), (BigInt.from(70000), BigInt.zero),
        reason: 'the payee\'s money, which the service holds no key for (bead libspiffy-bfs1)');

    final exported = await export('service', txid);
    expect(exported.success, isTrue, reason: exported.error);
    expect(BEEF.parse(Uint8List.fromList(exported.beef!)).carriesProofOf(txid), isTrue);
    expect(exported.delegatedIndices, [index], reason: 'the export carries what the payee imports it with');

    final payeeImport = await import('payee', exported.beef!, delegated: exported.delegatedIndices);
    expect(payeeImport.success, isTrue, reason: payeeImport.error);
    final payee = await balance('payee');
    expect(payee.confirmedBalance, BigInt.from(70000));
    final row = await storage.getAddressMetadata('payee', address);
    expect((row!.chain, row.derivationIndex), (AddressChain.delegated, index));
  });

  test('without the delegated indices the payment is not the payee\'s: the import is refused and nothing is '
      'recorded', () async {
    await createWallet('payee', mnemonic: _mnemonic);
    final address =
        crypto.deriveAddress(accountXpub, 4, chain: AddressChain.delegated, network: dartsv.NetworkType.TEST);
    final (txid, mined) = await minedPayment(address, 30000);

    final refused = await import('payee', mined);
    expect(refused.success, isFalse);
    expect(refused.error, contains('pays none of wallet payee\'s addresses'));
    expect(await storage.getTransaction(txid, walletId: 'payee'), isNull,
        reason: 'a transaction that is not the wallet\'s is not recorded in its history');

    final imported = await import('payee', mined, delegated: [4]);
    expect(imported.success, isTrue, reason: imported.error);
    expect((await balance('payee')).confirmedBalance, BigInt.from(30000));
  });

  test('an export is refused for a transaction the wallet does not hold or holds without a proof', () async {
    await createWallet('service', xpub: accountXpub.xpubkey);
    final unknown = await export('service', 'ab' * 32);
    expect(unknown.success, isFalse);
    expect(unknown.error, contains('is not a transaction of wallet service'));

    final unproven = 'cd' * 32;
    await storage.storeTransaction(
      'service',
      BitcoinTransaction(
        txid: unproven,
        rawHex: '01000000000000000000',
        status: TransactionStatus.pending,
        inputValue: BigInt.zero,
        outputValue: BigInt.zero,
        fee: BigInt.zero,
        receivingAddresses: const [],
        sendingAddresses: const [],
        netAmount: BigInt.zero,
        createdAt: DateTime.utc(2026, 9, 24),
        updatedAt: DateTime.utc(2026, 9, 24),
      ),
    );
    final refused = await export('service', unproven);
    expect(refused.success, isFalse);
    expect(refused.beef, isNull);
  });

  test('a single-key wallet refuses delegated indices, and nothing is imported', () async {
    final wif = dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST);
    final created = next<coord.WalletCreatedEvent>((e) => e.walletId == 'wif');
    libspiffy.coordinator.tell(coord.CreateWalletCommand(walletId: 'wif', name: 'wif', wif: wif.toWIF()));
    expect((await created).success, isTrue);
    final (_, mined) = await minedPayment(wif.toAddress(networkType: dartsv.NetworkType.TEST).toBase58(), 5000);

    final refused = await import('wif', mined, delegated: [1]);
    expect(refused.success, isFalse);
    expect(refused.error, contains('delegated'));
    expect((await balance('wif')).totalBalance, BigInt.zero);
  });
}
