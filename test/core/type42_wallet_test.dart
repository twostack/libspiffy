/// Bead libspiffy-zxkd: type-42 (BRC-42) payments to an offline payee, in
/// the wallet aggregate (spv-understanding.md, "Payment modes").
///
/// The payee publishes its anchor key A (`m/3'/0'`). A payer derives the
/// destination C = A + t·G with a fresh payer key B (`m/3'/1'/n'`) and an
/// invoice number, pays it, and hands over {BEEF, B, invoice number}. The
/// payee's wallet derives C itself from its anchor private key a, records
/// the derivation (never the child key), and signs for C with c = a + t.
///
/// Testnet only: ScriptTypeRegistry is a process-wide singleton pinned to
/// the first network it is built with.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet/type42_book.dart';
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
  dartsv.SVPublicKey anchorOf(dartsv.HDPrivateKey root) => keyAt(root, "m/3'/0'").publicKey;
  String p2pkh(dartsv.SVPublicKey key) => key.toAddress(dartsv.NetworkType.TEST).toBase58();

  /// A payer's key B and the destination it derives for [anchor].
  ({Type42Derivation derivation, String address}) payerDestination(dartsv.SVPublicKey anchor,
      {String invoice = _invoice}) {
    final b = keyAt(payerRoot, "m/7'");
    final c = Type42.deriveChildPublic(anchor, b, invoice);
    return (
      derivation: Type42Derivation(senderPublicKey: b.publicKey.toHex(), invoiceNumber: invoice),
      address: p2pkh(c),
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

  String spend(String txid, int sats) {
    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    tx.inputs.add(dartsv.TransactionInput(txid, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    tx.outputs.add(dartsv.TransactionOutput(
        BigInt.from(sats), dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(_external)).getScriptPubkey()));
    return tx.serialize();
  }

  test('the payee\'s wallet records a payer\'s destination from its own anchor key at m/3\'/0\', once, '
      'and journals the derivation, never a private key', () async {
    final payee = await created('payee', mnemonic: _payeeMnemonic);
    final paid = payerDestination(anchorOf(payeeRoot));

    await payee.commandHandler(
        RecordType42AddressesCommand(walletId: 'payee', derivations: [paid.derivation, paid.derivation]));
    final recorded = journal(payee).whereType<Type42AddressRecordedEvent>().toList();
    expect(recorded.map((e) => (e.address, e.derivation)), [(paid.address, paid.derivation)]);
    expect(payee.currentState.addresses.keys, contains(paid.address));
    expect(Type42Book.addressDerivations(payee.currentState.metadata), {paid.address: paid.derivation});

    final version = payee.currentState.version;
    await payee.commandHandler(RecordType42AddressesCommand(walletId: 'payee', derivations: [paid.derivation]));
    expect(payee.currentState.version, version, reason: 'recorded already: nothing is journaled');

    final anchor = keyAt(payeeRoot, "m/3'/0'").privateKey.toRadixString(16);
    final child = Type42.deriveChildPrivate(keyAt(payeeRoot, "m/3'/0'"),
            dartsv.SVPublicKey.fromHex(paid.derivation.senderPublicKey), _invoice)
        .privateKey
        .toRadixString(16);
    final written = [for (final e in journal(payee)) '${e.toMap()}'].join();
    expect(written, isNot(contains(anchor)));
    expect(written, isNot(contains(child)), reason: 'c = a + t: with the payer\'s t it gives away a');
  });

  test('the wallet signs for a type-42 address with the anchor key\'s child, whatever HD path the caller names',
      () async {
    final payee = await created('payee', mnemonic: _payeeMnemonic);
    final paid = payerDestination(anchorOf(payeeRoot));
    await payee.commandHandler(RecordType42AddressesCommand(walletId: 'payee', derivations: [paid.derivation]));
    final txid = 'aa' * 32;
    final utxo = await receive(payee, paid.address, txid, 90000);

    // The aggregate runs the script interpreter over every input it signs:
    // any other key fails it.
    await payee.commandHandler(SignTransactionCommand(
      walletId: 'payee',
      transactionId: 'spend-type42',
      rawTransaction: spend(txid, 89000),
      utxoKeys: [utxo],
      publicKeys: const [],
      keyPaths: const [HdKeyPath(0)],
    ));
    expect(journal(payee).whereType<TransactionSignedEvent>(), hasLength(1));
  });

  test('the payer derives each destination with a fresh payer key at m/3\'/1\'/n\', which the payee\'s wallet '
      'derives the same address from', () async {
    final payer = await created('payer', mnemonic: _payerMnemonic);
    final anchor = anchorOf(payeeRoot);

    await payer.commandHandler(
        DeriveType42DestinationCommand(walletId: 'payer', recipientPublicKey: anchor.toHex(), invoiceNumber: _invoice));
    await payer.commandHandler(DeriveType42DestinationCommand(walletId: 'payer', recipientPublicKey: anchor.toHex()));
    final derived = [for (final e in journal(payer).whereType<Type42DestinationDerivedEvent>()) e.destination];

    expect(derived.map((d) => d.payerKeyIndex), [0, 1]);
    for (final d in derived) {
      expect(d.derivation.senderPublicKey, keyAt(payerRoot, "m/3'/1'/${d.payerKeyIndex}'").publicKey.toHex());
      expect(d.recipientPublicKey, anchor.toHex());
    }
    expect(derived[0].derivation.senderPublicKey, isNot(derived[1].derivation.senderPublicKey),
        reason: 'a payer key is never used twice');
    expect(derived[0].derivation.invoiceNumber, _invoice);
    expect(derived[1].derivation.invoiceNumber, matches(RegExp(r'^2-3241645161d8-[A-Za-z0-9+/]{22}== [A-Za-z0-9+/]{22}==$')),
        reason: 'without an invoice number a BRC-29 one is made up');
    expect(Type42Book.payerKeysUsed(payer.currentState.metadata), 2);

    final payee = await created('payee', mnemonic: _payeeMnemonic);
    await payee.commandHandler(
        RecordType42AddressesCommand(walletId: 'payee', derivations: [for (final d in derived) d.derivation]));
    expect(journal(payee).whereType<Type42AddressRecordedEvent>().map((e) => e.address),
        [for (final d in derived) d.address]);
  });

  test('a restarted payer never reuses a payer key', () async {
    final payer = await created('payer', mnemonic: _payerMnemonic);
    final anchor = anchorOf(payeeRoot).toHex();
    await payer.commandHandler(DeriveType42DestinationCommand(walletId: 'payer', recipientPublicKey: anchor));

    final replayStore = InMemoryEventStore();
    await replayStore.persistEvents(
        payer.persistenceId, [for (final e in journal(payer)) EventRegistry.fromMap(e.toMap())], 0);
    final restarted = await open('payer', eventStore: replayStore);
    await restarted.commandHandler(DeriveType42DestinationCommand(walletId: 'payer', recipientPublicKey: anchor));
    expect(replayStore.journal[payer.persistenceId]!.whereType<Type42DestinationDerivedEvent>().last.destination.payerKeyIndex,
        1);
  });

  test('a snapshot keeps the type-42 records: the restored payee still signs for its type-42 output, and the '
      'restored payer takes the next payer key', () async {
    final snapshots = SnapshotEventStore();
    final payee = _SnapshottingWallet(snapshots, secureStorage, 'payee');
    await payee.preStart();
    await payee.commandHandler(CreateWalletCommand(walletId: 'payee', walletName: 'p', mnemonic: _payeeMnemonic));
    final paid = payerDestination(anchorOf(payeeRoot));
    await payee.commandHandler(RecordType42AddressesCommand(walletId: 'payee', derivations: [paid.derivation]));
    await payee.commandHandler(DeriveType42DestinationCommand(
        walletId: 'payee', recipientPublicKey: anchorOf(payerRoot).toHex(), invoiceNumber: _invoice));
    final txid = 'bb' * 32;
    await payee.commandHandler(ReceiveUTXOCommand(
      walletId: 'payee',
      txid: txid,
      vout: 0,
      satoshis: BigInt.from(50000),
      scriptPubKey: dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(paid.address)).getScriptPubkey().toHex(),
      address: paid.address,
      blockHeight: 900,
      initialStatus: UTXOStatus.available,
    ));
    await payee.snapshotNow();
    expect(snapshots.snapshots[payee.persistenceId], isNotNull);

    final restored = _SnapshottingWallet(snapshots, secureStorage, 'payee');
    await restored.preStart();
    expect(Type42Book.addressDerivations(restored.currentState.metadata), {paid.address: paid.derivation});
    expect(Type42Book.payerKeysUsed(restored.currentState.metadata), 1);

    await restored.commandHandler(SignTransactionCommand(
      walletId: 'payee',
      transactionId: 'spend-after-snapshot',
      rawTransaction: spend(txid, 49000),
      utxoKeys: ['$txid:0'],
      publicKeys: const [],
    ));
    await restored.commandHandler(
        DeriveType42DestinationCommand(walletId: 'payee', recipientPublicKey: anchorOf(payerRoot).toHex()));
    final journaled = await snapshots.getEvents(restored.persistenceId);
    expect(journaled.whereType<TransactionSignedEvent>(), hasLength(1));
    expect(journaled.whereType<Type42DestinationDerivedEvent>().last.destination.payerKeyIndex, 1);
  });

  test('a transaction paying a type-42 address the wallet knows is found by its output script', () async {
    final payer = await created('payer', mnemonic: _payerMnemonic);
    await payer.commandHandler(DeriveType42DestinationCommand(
        walletId: 'payer', recipientPublicKey: anchorOf(payeeRoot).toHex(), invoiceNumber: _invoice));
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
    expect(Type42Book.paidBy(payer.currentState, spend('cc' * 32, 5)), isEmpty);
  });

  test('an xpub wallet has no anchor key and a WIF wallet no HD tree: both refuse type-42', () async {
    final xpub = await created('service', xpub: crypto.deriveHDPublicKey(payeeRoot).xpubkey);
    final wif = await created('wif', wif: dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST).toWIF());
    final paid = payerDestination(anchorOf(payeeRoot));
    for (final wallet in [xpub, wif]) {
      final id = wallet.aggregateId;
      await expectLater(
          wallet.commandHandler(RecordType42AddressesCommand(walletId: id, derivations: [paid.derivation])),
          throwsA(isA<StateError>()));
      await expectLater(
          wallet.commandHandler(
              DeriveType42DestinationCommand(walletId: id, recipientPublicKey: anchorOf(payerRoot).toHex())),
          throwsA(isA<StateError>()));
      expect(journal(wallet).whereType<Type42AddressRecordedEvent>(), isEmpty);
    }
  });

  test('a destination for something that is not a compressed public key is refused', () async {
    final payer = await created('payer', mnemonic: _payerMnemonic);
    await expectLater(
        payer.commandHandler(DeriveType42DestinationCommand(walletId: 'payer', recipientPublicKey: _external)),
        throwsA(anything));
    expect(journal(payer).whereType<Type42DestinationDerivedEvent>(), isEmpty);
  });
}
