/// The type-42 hand-off through the coordinator (bead libspiffy-zxkd;
/// spv-understanding.md, "Payment modes").
///
/// The payee's wallet issues its anchor key for an identity
/// (IssueAnchorKeyCommand) and signs a registration with it
/// (SignWithAnchorKeyCommand). A payer derives a destination from the
/// anchor key (DeriveType42DestinationCommand), and the payee's wallet takes
/// the proven payment in with the hand-off — the anchor and its context,
/// the payer's key and the invoice number
/// (ImportTransactionCommand.type42Derivations) — deriving the address
/// itself, and exports it again with it.
///
/// The block is made up: one transaction, so its merkle root is the txid and
/// its merkle path is empty. localnet_type42_payment_e2e_test.dart runs the
/// whole mode on the real regtest network, the payer's broadcast and export
/// and the unproven path included.
library;

import 'dart:async';
import 'dart:convert';
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

const _payeeMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const _payerMnemonic = 'legal winner thank year wave sausage worth useful legal winner thank yellow';
const _height = 1239700;

final _identity = utf8.encode('carol|epoch-0');
final _otherIdentity = utf8.encode('carol-at-work|epoch-0');

void main() {
  late Directory dir;
  late Isar isar;
  late LibSpiffyActorSystem libspiffy;
  late IsarWalletStorage storage;
  var blocks = 0;

  setUpAll(ensureIsarInitialized);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('type42-handoff-');
    isar = await Isar.open(LibSpiffySchemas.allSchemas,
        directory: dir.path, name: 'type42_${DateTime.now().microsecondsSinceEpoch}');
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

  Future<coord.AnchorPublicKeyEvent> anchorKey(String walletId, [List<int>? context]) {
    final answer = next<coord.AnchorPublicKeyEvent>((e) => e.walletId == walletId);
    libspiffy.coordinator.tell(coord.IssueAnchorKeyCommand(walletId: walletId, anchorContext: context ?? _identity));
    return answer;
  }

  Future<Type42Destination> destinationFor(String payer, String anchor, {List<int>? context}) async {
    final answer = next<coord.Type42DestinationEvent>((e) => e.walletId == payer);
    libspiffy.coordinator.tell(
        coord.DeriveType42DestinationCommand(walletId: payer, anchorPublicKey: anchor, anchorContext: context));
    final event = await answer;
    expect(event.success, isTrue, reason: event.error);
    return event.destination!;
  }

  Future<coord.BalanceResponse> balance(String walletId) {
    final answer = next<coord.BalanceResponse>((e) => e.walletId == walletId);
    libspiffy.coordinator.tell(coord.GetBalanceQuery(walletId: walletId));
    return answer;
  }

  Future<coord.TransactionImportedEvent> import(String walletId, List<int> beef,
      {List<Type42Derivation> type42 = const []}) {
    final imported = next<coord.TransactionImportedEvent>((e) => e.walletId == walletId);
    libspiffy.coordinator
        .tell(coord.ImportTransactionCommand(walletId: walletId, beef: beef, type42Derivations: type42));
    return imported;
  }

  /// A mined payment of [sats] to each of [addresses]: the only transaction
  /// of a block whose header is stored.
  Future<(String txid, List<int> beef)> minedPayment(List<String> addresses, int sats) async {
    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    tx.inputs.add(dartsv.TransactionInput('ee' * 32, blocks, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    for (final address in addresses) {
      tx.outputs.add(dartsv.TransactionOutput(
          BigInt.from(sats), dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey()));
    }
    final txid = tx.id;
    final height = _height + blocks++;
    await storage.storeBlockHeader(
      spiffynode.BlockHeader(
        version: 536870912,
        prevBlock: spiffynode.Hash.fromHex('00' * 32),
        merkleRoot: spiffynode.Hash.fromHex(txid),
        timestamp: DateTime.utc(2026, 9, 24),
        bits: 0x207fffff,
        nonce: 0,
      ),
      height,
    );
    final beef = BEEF.create(
      bumps: [BUMP.fromTscProof(blockHeight: height, txid: txid, index: 0, nodes: const [])],
      txs: [Uint8List.fromList(hex.decode(tx.serialize()))],
      hasMerkle: [true],
      bumpIndex: [0],
    );
    return (txid, beef.serialize().toList());
  }

  test('the payee issues an anchor per identity and signs a registration with it; an xpub wallet has none',
      () async {
    await createWallet('payee', mnemonic: _payeeMnemonic);
    await createWallet('service', xpub: DartSVCryptoService()
        .deriveHDPublicKey(await DartSVCryptoService().mnemonicToHDPrivateKey(_payeeMnemonic))
        .xpubkey);

    final anchor = await anchorKey('payee');
    expect(anchor.success, isTrue, reason: anchor.error);
    expect(anchor.publicKey, hasLength(66));
    expect((await anchorKey('payee')).publicKey, anchor.publicKey, reason: 'the anchor key is stable');
    expect((await anchorKey('payee', _otherIdentity)).publicKey, isNot(anchor.publicKey),
        reason: 'another identity on the same wallet publishes an unrelated anchor');

    final message = utf8.encode('overmedia:register_payment_pubkey:12D3KooWTestPeer:${anchor.publicKey}');
    final signed = next<coord.AnchorSignedEvent>((e) => e.walletId == 'payee');
    libspiffy.coordinator
        .tell(coord.SignWithAnchorKeyCommand(walletId: 'payee', anchorContext: _identity, message: message));
    final signature = await signed;
    expect(signature.success, isTrue, reason: signature.error);
    expect(signature.publicKey, anchor.publicKey);
    final verified = DartSVCryptoService().verifySignature(
      dartsv.SVPublicKey.fromHex(anchor.publicKey!),
      dartsv.SVSignature.fromDER(signature.signatureDer!),
      Uint8List.fromList(dartsv.sha256(message)),
    );
    expect(verified, isTrue, reason: 'the signature is by A over SHA-256 of the message');

    final none = await anchorKey('service');
    expect(none.success, isFalse);
    expect(none.error, contains('watch-only'));
  });

  test('the payee takes a proven payment to a type-42 destination in with the payer\'s key and invoice number, '
      'holds it, and exports it with them', () async {
    await createWallet('payee', mnemonic: _payeeMnemonic);
    await createWallet('payer', mnemonic: _payerMnemonic);
    final anchor = (await anchorKey('payee')).publicKey!;
    final destination = await destinationFor('payer', anchor);

    final (txid, mined) = await minedPayment([destination.address], 60000);
    final imported = await import('payee', mined, type42: [destination.derivation]);
    expect(imported.success, isTrue, reason: imported.error);
    expect((await balance('payee')).confirmedBalance, BigInt.from(60000));
    final row = await storage.getAddressMetadata('payee', destination.address);
    // The record names the context the wallet issued the anchor for: the
    // hand-off did not need to.
    final recorded = destination.derivation.withAnchorContext(hex.encode(_identity));
    expect((row!.type42, row.chain, row.keyPath), (recorded, null, Type42KeyPath(recorded)));

    final exported = next<coord.TransactionExportedEvent>((e) => e.walletId == 'payee' && e.txid == txid);
    libspiffy.coordinator.tell(coord.ExportTransactionQuery(walletId: 'payee', txid: txid));
    final export = await exported;
    expect(export.success, isTrue, reason: export.error);
    expect(export.type42Derivations, [recorded]);
    expect(export.delegatedIndices, isEmpty);
  });

  test('a payment is refused as unrelated without its derivation, with a wrong invoice number, or with another '
      'payer\'s key, and a context that does not give the anchor is refused; nothing is recorded', () async {
    await createWallet('payee', mnemonic: _payeeMnemonic);
    await createWallet('payer', mnemonic: _payerMnemonic);
    final anchor = (await anchorKey('payee')).publicKey!;
    final destination = await destinationFor('payer', anchor);
    final other = await destinationFor('payer', anchor);
    final (txid, mined) = await minedPayment([destination.address], 30000);

    for (final (what, derivations) in [
      ('no derivation', const <Type42Derivation>[]),
      ('a wrong invoice number', [
        Type42Derivation(
            anchorPublicKey: anchor,
            senderPublicKey: destination.derivation.senderPublicKey,
            invoiceNumber: 'wrong')
      ]),
      ('another payer key', [
        Type42Derivation(
            anchorPublicKey: anchor,
            senderPublicKey: other.derivation.senderPublicKey,
            invoiceNumber: destination.derivation.invoiceNumber)
      ]),
      ('the derivation of a destination it does not pay', [other.derivation]),
    ]) {
      final refused = await import('payee', mined, type42: derivations);
      expect(refused.success, isFalse, reason: what);
      expect(refused.error, contains('pays none of wallet payee\'s addresses'), reason: what);
    }
    final wrongContext = await import('payee', mined, type42: [
      Type42Derivation(
        anchorPublicKey: (await anchorKey('payer')).publicKey!,
        anchorContext: _identity,
        senderPublicKey: destination.derivation.senderPublicKey,
        invoiceNumber: destination.derivation.invoiceNumber,
      )
    ]);
    expect(wrongContext.success, isFalse);
    expect(wrongContext.error, contains('gives wallet payee the anchor'),
        reason: 'the context names the payee\'s anchor, not the one the hand-off names');
    expect(await storage.getTransaction(txid, walletId: 'payee'), isNull,
        reason: 'a transaction that is not the wallet\'s is not recorded in its history');
    expect((await balance('payee')).totalBalance, BigInt.zero);
  });

  test('a payment that pays the destination twice is taken in as two outputs', () async {
    await createWallet('payee', mnemonic: _payeeMnemonic);
    await createWallet('payer', mnemonic: _payerMnemonic);
    final destination = await destinationFor('payer', (await anchorKey('payee')).publicKey!);
    final (txid, mined) = await minedPayment([destination.address, destination.address], 20000);

    final imported = await import('payee', mined, type42: [destination.derivation]);
    expect(imported.success, isTrue, reason: imported.error);
    expect((await balance('payee')).confirmedBalance, BigInt.from(40000));
    final utxos = await storage.getUTXOs('payee');
    expect(utxos.where((u) => u.txid == txid).map((u) => u.vout).toSet(), {0, 1});
  });

  test('an xpub wallet refuses a type-42 hand-off, and nothing is imported', () async {
    await createWallet('payer', mnemonic: _payerMnemonic);
    final xpub = DartSVCryptoService()
        .deriveHDPublicKey(await DartSVCryptoService().mnemonicToHDPrivateKey(_payeeMnemonic))
        .xpubkey;
    await createWallet('service', xpub: xpub);
    await createWallet('payee', mnemonic: _payeeMnemonic);
    final destination = await destinationFor('payer', (await anchorKey('payee')).publicKey!);
    final (_, mined) = await minedPayment([destination.address], 10000);

    final refused = await import('service', mined, type42: [destination.derivation]);
    expect(refused.success, isFalse);
    expect(refused.error, contains('watch-only'));
    expect((await balance('service')).watchOnlyBalance, BigInt.zero);

    final validated = next<coord.BEEFValidationResultEvent>((e) => e.walletId == 'service');
    libspiffy.coordinator.tell(coord.ValidateBEEFCommand(
        walletId: 'service', beefHex: hex.encode(mined), type42Derivations: [destination.derivation]));
    final result = await validated;
    expect(result.valid, isFalse);
    expect(result.error, contains('watch-only'));
  });

  test('a wallet restored from its seed alone does not hold a type-42 payment: the import says so, and the '
      'payer\'s hand-off, given again with the anchor\'s context, brings it back', () async {
    await createWallet('payer', mnemonic: _payerMnemonic);
    await createWallet('payee', mnemonic: _payeeMnemonic);
    final anchor = (await anchorKey('payee')).publicKey!;
    final destination = await destinationFor('payer', anchor, context: _identity);
    final (_, mined) = await minedPayment([destination.address], 25000);
    expect((await import('payee', mined, type42: [destination.derivation])).success, isTrue);

    // The same seed, a new journal: nothing on the seed leads to C, and the
    // restored wallet has issued no anchor yet.
    await createWallet('restored', mnemonic: _payeeMnemonic);
    final absent = await import('restored', mined);
    expect(absent.success, isFalse);
    expect(absent.error, contains('pays none of wallet restored\'s addresses'));
    final withoutContext = Type42Derivation(
      anchorPublicKey: anchor,
      senderPublicKey: destination.derivation.senderPublicKey,
      invoiceNumber: destination.derivation.invoiceNumber,
    );
    final unknownAnchor = await import('restored', mined, type42: [withoutContext]);
    expect(unknownAnchor.success, isFalse);
    expect(unknownAnchor.error, contains('never issued anchor'));

    final recovered = await import('restored', mined, type42: [destination.derivation]);
    expect(recovered.success, isTrue, reason: recovered.error);
    expect((await balance('restored')).confirmedBalance, BigInt.from(25000));
    expect((await anchorKey('restored')).publicKey, anchor, reason: 'the seed and the context give the same anchor');
  });
}
