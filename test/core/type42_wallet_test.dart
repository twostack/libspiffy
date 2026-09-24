/// Beads libspiffy-zxkd and libspiffy-fdal: type-42 (BRC-42) payments to an
/// offline payee, in the wallet aggregate (spv-understanding.md, "Payment
/// modes").
///
/// The payee's wallet issues an anchor key A for a context (an identity,
/// say): `m/3'/0'/k1'/k2'`, one per context, so identities sharing a wallet
/// publish unrelated anchors. A payer derives the destination C = A + t·G
/// with a fresh payer key B (`m/3'/1'/n'`) and an invoice number, pays it,
/// and hands over {A, context, B, invoice number}. The payee's wallet finds
/// the anchor's context (its issued anchors first, else the hand-off's,
/// which must give A), derives C itself, records the derivation (never the
/// child key), and signs for C with c = a + t.
///
/// Testnet only: ScriptTypeRegistry is a process-wide singleton pinned to
/// the first network it is built with.
library;

import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet/type42_book.dart';
import 'package:libspiffy/src/core/wallet/wallet_keys.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/crypto/type42.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/key_path.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/utils/bip32.dart';

import '../actors/in_memory_event_store.dart';
import 'snapshot_event_store.dart';

const _payeeMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const _payerMnemonic = 'legal winner thank year wave sausage worth useful legal winner thank yellow';
const _external = 'n4VQ5YdHf7hLQ2gWQYYrcxoE5B7nWuDFNF';
const _invoice = '2-3241645161d8-cHJlZml4 c3VmZml4';

final _identityA = utf8.encode('identity-A|epoch-0');
final _identityARotated = utf8.encode('identity-A|epoch-1');
final _identityB = utf8.encode('identity-B|epoch-0');

class _SnapshottingWallet extends BitcoinWalletAggregate {
  _SnapshottingWallet(EventStore store, InMemorySecureStorage secureStorage, String id)
      : super(
          aggregateId: id,
          aggregateType: 'BitcoinWallet',
          eventStore: store,
          cryptoService: DartSVCryptoService(),
          secureStorage: secureStorage,
        );

  Future<void> snapshotNow() => createSnapshot();
}

void main() {
  final crypto = DartSVCryptoService();
  late InMemoryEventStore store;
  late InMemorySecureStorage secureStorage;
  late dartsv.HDPrivateKey payeeRoot;
  late dartsv.HDPrivateKey payerRoot;

  setUpAll(() async {
    LibSpiffyActorSystem.registerEventTypes();
    payeeRoot = await crypto.mnemonicToHDPrivateKey(_payeeMnemonic, network: dartsv.NetworkType.TEST);
    payerRoot = await crypto.mnemonicToHDPrivateKey(_payerMnemonic, network: dartsv.NetworkType.TEST);
  });

  setUp(() {
    store = InMemoryEventStore();
    secureStorage = InMemorySecureStorage();
  });

  dartsv.SVPrivateKey keyAt(dartsv.HDPrivateKey root, String path) => Bip32.derivePrivatePath(root, path).privateKey;
  dartsv.SVPublicKey anchorOf(dartsv.HDPrivateKey root, List<int> context) =>
      keyAt(root, WalletKeys.anchorPath(context)).publicKey;
  String p2pkh(dartsv.SVPublicKey key) => key.toAddress(dartsv.NetworkType.TEST).toBase58();

  /// A payer's key B and the destination it derives for the payee's anchor
  /// for [context]; the hand-off names the context unless [handOffContext]
  /// is false.
  ({Type42Derivation derivation, String address}) payerDestination(List<int> context,
      {String invoice = _invoice, bool handOffContext = true, String payerPath = "m/7'"}) {
    final anchor = anchorOf(payeeRoot, context);
    final b = keyAt(payerRoot, payerPath);
    return (
      derivation: Type42Derivation(
        anchorPublicKey: anchor.toHex(),
        anchorContext: handOffContext ? context : null,
        senderPublicKey: b.publicKey.toHex(),
        invoiceNumber: invoice,
      ),
      address: p2pkh(Type42.deriveChildPublic(anchor, b, invoice)),
    );
  }

  Future<BitcoinWalletAggregate> open(String walletId, {EventStore? eventStore}) async {
    final wallet = BitcoinWalletAggregate(
      aggregateId: walletId,
      aggregateType: 'BitcoinWallet',
      eventStore: eventStore ?? store,
      cryptoService: crypto,
      secureStorage: secureStorage,
    );
    await wallet.preStart();
    return wallet;
  }

  Future<BitcoinWalletAggregate> created(String walletId, {String? mnemonic, String? xpub, String? wif}) async {
    final wallet = await open(walletId);
    await wallet.commandHandler(
        CreateWalletCommand(walletId: walletId, walletName: walletId, mnemonic: mnemonic, xpub: xpub, wif: wif));
    return wallet;
  }

  List<Event> journal(BitcoinWalletAggregate wallet) => store.journal[wallet.persistenceId]!;

  Future<String> receive(BitcoinWalletAggregate wallet, String address, String txid, int sats) async {
    await wallet.commandHandler(ReceiveUTXOCommand(
      walletId: wallet.aggregateId,
      txid: txid,
      vout: 0,
      satoshis: BigInt.from(sats),
      scriptPubKey: dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex(),
      address: address,
      blockHeight: 900,
      initialStatus: UTXOStatus.available,
    ));
    return '$txid:0';
  }

  /// A transaction spending output 0 of each of [txids], [sats] in all.
  String spend(List<String> txids, int sats) {
    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    for (final txid in txids) {
      tx.inputs.add(dartsv.TransactionInput(txid, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    }
    tx.outputs.add(dartsv.TransactionOutput(
        BigInt.from(sats), dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(_external)).getScriptPubkey()));
    return tx.serialize();
  }

  test('the anchor path is m/3\'/0\'/k1\'/k2\' from SHA-256 of the domain and the context, as pinned', () {
    // Computed independently: SHA-256(b"libspiffy/type42-anchor" + context),
    // its first two big-endian 32-bit words, top bit cleared.
    expect(WalletKeys.anchorPath(_identityA), "m/3'/0'/1625108111'/142083867'");
    expect(() => WalletKeys.anchorPath(const []), throwsArgumentError, reason: 'no default anchor');
  });

  test('a wallet issues one anchor per context: two identities get unrelated anchors, the same context the same '
      'anchor, a new epoch a new one; each is journaled once', () async {
    final payee = await created('payee', mnemonic: _payeeMnemonic);
    for (final context in [_identityA, _identityB, _identityA, _identityARotated]) {
      await payee.commandHandler(IssueAnchorKeyCommand(walletId: 'payee', anchorContext: context));
    }
    final issued = journal(payee).whereType<AnchorKeyIssuedEvent>().toList();
    expect(issued.map((e) => (e.anchorPublicKey, utf8.decode(hex.decode(e.anchorContext)))), [
      (anchorOf(payeeRoot, _identityA).toHex(), 'identity-A|epoch-0'),
      (anchorOf(payeeRoot, _identityB).toHex(), 'identity-B|epoch-0'),
      (anchorOf(payeeRoot, _identityARotated).toHex(), 'identity-A|epoch-1'),
    ]);
    expect(issued.map((e) => e.anchorPublicKey).toSet(), hasLength(3), reason: 'unrelated anchors');
    expect(Type42Book.issuedAnchors(payee.currentState.metadata), hasLength(3));

    await expectLater(payee.commandHandler(IssueAnchorKeyCommand(walletId: 'payee', anchorContext: const [])),
        throwsA(isA<ArgumentError>()));
  });

  test('a payment to an anchor the wallet issued is found without a context in the hand-off; the record keeps '
      'the context, and nothing private is journaled', () async {
    final payee = await created('payee', mnemonic: _payeeMnemonic);
    await payee.commandHandler(IssueAnchorKeyCommand(walletId: 'payee', anchorContext: _identityA));
    final paid = payerDestination(_identityA, handOffContext: false);

    await payee.commandHandler(
        RecordType42AddressesCommand(walletId: 'payee', derivations: [paid.derivation, paid.derivation]));
    final recorded = journal(payee).whereType<Type42AddressRecordedEvent>().toList();
    expect(recorded.map((e) => e.address), [paid.address]);
    expect(recorded.single.derivation.anchorContext, hex.encode(_identityA),
        reason: 'the record names the context signing derives the anchor from');
    expect(Type42Book.addressDerivations(payee.currentState.metadata)[paid.address], recorded.single.derivation);

    final version = payee.currentState.version;
    await payee.commandHandler(RecordType42AddressesCommand(walletId: 'payee', derivations: [paid.derivation]));
    expect(payee.currentState.version, version, reason: 'recorded already: nothing is journaled');

    final anchor = keyAt(payeeRoot, WalletKeys.anchorPath(_identityA));
    final child = Type42.deriveChildPrivate(anchor, dartsv.SVPublicKey.fromHex(paid.derivation.senderPublicKey), _invoice);
    final written = [for (final e in journal(payee)) '${e.toMap()}'].join();
    expect(written, isNot(contains(anchor.privateKey.toRadixString(16))));
    expect(written, isNot(contains(child.privateKey.toRadixString(16))),
        reason: 'c = a + t: with the payer\'s t it gives away a');
  });

  test('a hand-off naming the context of an anchor the wallet never issued is taken when the context gives '
      'the anchor (a restored wallet)', () async {
    final payee = await created('payee', mnemonic: _payeeMnemonic);
    final paid = payerDestination(_identityB);
    await payee.commandHandler(RecordType42AddressesCommand(walletId: 'payee', derivations: [paid.derivation]));
    expect(journal(payee).whereType<Type42AddressRecordedEvent>().single.address, paid.address);
  });

  test('an anchor is never taken on trust: a context that gives another anchor, or none for an anchor the wallet '
      'never issued, is refused and nothing is recorded', () async {
    final payee = await created('payee', mnemonic: _payeeMnemonic);
    final paid = payerDestination(_identityA);
    final wrongContext = Type42Derivation(
      anchorPublicKey: paid.derivation.anchorPublicKey,
      anchorContext: _identityB,
      senderPublicKey: paid.derivation.senderPublicKey,
      invoiceNumber: _invoice,
    );
    await expectLater(
        payee.commandHandler(RecordType42AddressesCommand(walletId: 'payee', derivations: [wrongContext])),
        throwsA(predicate((e) => '$e'.contains('gives wallet payee the anchor'), 'a context mismatch')));
    await expectLater(
        payee.commandHandler(RecordType42AddressesCommand(
            walletId: 'payee', derivations: [payerDestination(_identityA, handOffContext: false).derivation])),
        throwsA(predicate((e) => '$e'.contains('never issued anchor'), 'an unknown anchor')));
    expect(journal(payee).whereType<Type42AddressRecordedEvent>(), isEmpty);
  });

  test('the wallet signs for type-42 addresses of two anchors in one transaction, whatever HD path the caller '
      'names', () async {
    final payee = await created('payee', mnemonic: _payeeMnemonic);
    final toA = payerDestination(_identityA);
    final toB = payerDestination(_identityB, payerPath: "m/8'");
    await payee.commandHandler(
        RecordType42AddressesCommand(walletId: 'payee', derivations: [toA.derivation, toB.derivation]));
    final a = await receive(payee, toA.address, 'aa' * 32, 50000);
    final b = await receive(payee, toB.address, 'ab' * 32, 40000);

    // The aggregate runs the script interpreter over every input it signs:
    // any other key fails it.
    await payee.commandHandler(SignTransactionCommand(
      walletId: 'payee',
      transactionId: 'spend-two-anchors',
      rawTransaction: spend(['aa' * 32, 'ab' * 32], 89000),
      utxoKeys: [a, b],
      publicKeys: const [],
      keyPaths: const [HdKeyPath(0), HdKeyPath(0)],
    ));
    expect(journal(payee).whereType<TransactionSignedEvent>(), hasLength(1));
  });

  test('the payer derives each destination with a fresh payer key at m/3\'/1\'/n\' and passes the anchor\'s '
      'context through; the payee\'s wallet derives the same address', () async {
    final payer = await created('payer', mnemonic: _payerMnemonic);
    final anchor = anchorOf(payeeRoot, _identityA).toHex();

    await payer.commandHandler(DeriveType42DestinationCommand(
        walletId: 'payer', anchorPublicKey: anchor, anchorContext: _identityA, invoiceNumber: _invoice));
    await payer.commandHandler(DeriveType42DestinationCommand(walletId: 'payer', anchorPublicKey: anchor));
    final derived = [for (final e in journal(payer).whereType<Type42DestinationDerivedEvent>()) e.destination];

    expect(derived.map((d) => d.payerKeyIndex), [0, 1]);
    for (final d in derived) {
      expect(d.derivation.senderPublicKey, keyAt(payerRoot, "m/3'/1'/${d.payerKeyIndex}'").publicKey.toHex());
      expect(d.derivation.anchorPublicKey, anchor);
    }
    expect([for (final d in derived) d.derivation.anchorContext], [hex.encode(_identityA), null]);
    expect(derived[0].derivation.senderPublicKey, isNot(derived[1].derivation.senderPublicKey),
        reason: 'a payer key is never used twice');
    expect(derived[0].derivation.invoiceNumber, _invoice);
    expect(derived[1].derivation.invoiceNumber,
        matches(RegExp(r'^2-3241645161d8-[A-Za-z0-9+/]{22}== [A-Za-z0-9+/]{22}==$')),
        reason: 'without an invoice number a BRC-29 one is made up');

    final payee = await created('payee', mnemonic: _payeeMnemonic);
    await payee.commandHandler(IssueAnchorKeyCommand(walletId: 'payee', anchorContext: _identityA));
    await payee.commandHandler(
        RecordType42AddressesCommand(walletId: 'payee', derivations: [for (final d in derived) d.derivation]));
    expect(journal(payee).whereType<Type42AddressRecordedEvent>().map((e) => e.address),
        [for (final d in derived) d.address]);
  });

  test('a restarted payer never reuses a payer key', () async {
    final payer = await created('payer', mnemonic: _payerMnemonic);
    final anchor = anchorOf(payeeRoot, _identityA).toHex();
    await payer.commandHandler(DeriveType42DestinationCommand(walletId: 'payer', anchorPublicKey: anchor));

    final replayStore = InMemoryEventStore();
    await replayStore.persistEvents(
        payer.persistenceId, [for (final e in journal(payer)) EventRegistry.fromMap(e.toMap())], 0);
    final restarted = await open('payer', eventStore: replayStore);
    await restarted.commandHandler(DeriveType42DestinationCommand(walletId: 'payer', anchorPublicKey: anchor));
    expect(
        replayStore.journal[payer.persistenceId]!.whereType<Type42DestinationDerivedEvent>().last.destination.payerKeyIndex,
        1);
  });

  test('a snapshot keeps the type-42 records: the restored payee still knows its anchors and signs for its '
      'type-42 output, and the restored payer takes the next payer key', () async {
    final snapshots = SnapshotEventStore();
    final payee = _SnapshottingWallet(snapshots, secureStorage, 'payee');
    await payee.preStart();
    await payee.commandHandler(CreateWalletCommand(walletId: 'payee', walletName: 'p', mnemonic: _payeeMnemonic));
    await payee.commandHandler(IssueAnchorKeyCommand(walletId: 'payee', anchorContext: _identityA));
    final paid = payerDestination(_identityA, handOffContext: false);
    await payee.commandHandler(RecordType42AddressesCommand(walletId: 'payee', derivations: [paid.derivation]));
    await payee.commandHandler(DeriveType42DestinationCommand(
        walletId: 'payee', anchorPublicKey: anchorOf(payerRoot, _identityB).toHex(), invoiceNumber: _invoice));
    final txid = 'bb' * 32;
    await payee.commandHandler(ReceiveUTXOCommand(
      walletId: 'payee',
      txid: txid,
      vout: 0,
      satoshis: BigInt.from(50000),
      scriptPubKey:
          dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(paid.address)).getScriptPubkey().toHex(),
      address: paid.address,
      blockHeight: 900,
      initialStatus: UTXOStatus.available,
    ));
    await payee.snapshotNow();
    expect(snapshots.snapshots[payee.persistenceId], isNotNull);

    final restored = _SnapshottingWallet(snapshots, secureStorage, 'payee');
    await restored.preStart();
    expect(Type42Book.issuedAnchors(restored.currentState.metadata),
        {anchorOf(payeeRoot, _identityA).toHex(): hex.encode(_identityA)});
    expect(Type42Book.addressDerivations(restored.currentState.metadata).keys, [paid.address]);
    expect(Type42Book.payerKeysUsed(restored.currentState.metadata), 1);

    await restored.commandHandler(SignTransactionCommand(
      walletId: 'payee',
      transactionId: 'spend-after-snapshot',
      rawTransaction: spend([txid], 49000),
      utxoKeys: ['$txid:0'],
      publicKeys: const [],
    ));
    await restored.commandHandler(DeriveType42DestinationCommand(
        walletId: 'payee', anchorPublicKey: anchorOf(payerRoot, _identityB).toHex()));
    final journaled = await snapshots.getEvents(restored.persistenceId);
    expect(journaled.whereType<TransactionSignedEvent>(), hasLength(1));
    expect(journaled.whereType<Type42DestinationDerivedEvent>().last.destination.payerKeyIndex, 1);
  });

  test('a transaction paying a type-42 address the wallet knows is found by its output script', () async {
    final payer = await created('payer', mnemonic: _payerMnemonic);
    await payer.commandHandler(DeriveType42DestinationCommand(
        walletId: 'payer', anchorPublicKey: anchorOf(payeeRoot, _identityA).toHex(), invoiceNumber: _invoice));
    final destination = journal(payer).whereType<Type42DestinationDerivedEvent>().single.destination;

    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    tx.inputs.add(dartsv.TransactionInput('cc' * 32, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    for (final address in [_external, destination.address]) {
      tx.outputs.add(dartsv.TransactionOutput(
          BigInt.from(1000), dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey()));
    }
    expect(Type42Book.paidBy(payer.currentState, tx.serialize()), {destination.address: destination.derivation});
    expect(Type42Book.paidBy(payer.currentState, spend(['cc' * 32], 5)), isEmpty);
  });

  test('an xpub wallet has no anchor key and a WIF wallet no HD tree: both refuse type-42', () async {
    final xpub = await created('service', xpub: crypto.deriveHDPublicKey(payeeRoot).xpubkey);
    final wif = await created('wif', wif: dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST).toWIF());
    final paid = payerDestination(_identityA);
    for (final wallet in [xpub, wif]) {
      final id = wallet.aggregateId;
      await expectLater(wallet.commandHandler(IssueAnchorKeyCommand(walletId: id, anchorContext: _identityA)),
          throwsA(isA<StateError>()));
      await expectLater(
          wallet.commandHandler(RecordType42AddressesCommand(walletId: id, derivations: [paid.derivation])),
          throwsA(isA<StateError>()));
      await expectLater(
          wallet.commandHandler(DeriveType42DestinationCommand(
              walletId: id, anchorPublicKey: anchorOf(payerRoot, _identityB).toHex())),
          throwsA(isA<StateError>()));
      expect(journal(wallet).whereType<Type42AddressRecordedEvent>(), isEmpty);
      expect(journal(wallet).whereType<AnchorKeyIssuedEvent>(), isEmpty);
    }
  });

  test('a destination for something that is not a compressed public key is refused', () async {
    final payer = await created('payer', mnemonic: _payerMnemonic);
    await expectLater(
        payer.commandHandler(DeriveType42DestinationCommand(walletId: 'payer', anchorPublicKey: _external)),
        throwsA(anything));
    expect(journal(payer).whereType<Type42DestinationDerivedEvent>(), isEmpty);
  });
}
