/// Bead libspiffy-m8qu: the delegated chain (m/2/i).
///
/// A service that keeps a payee's xpub as a watch-only wallet answers
/// invoice requests for the offline payee (spv-understanding.md, "Payment
/// modes"). Before, the service's wallet and the payee's own wallet both
/// issued addresses on the receive chain m/0/i, each with its own counter,
/// so they could hand out the same address; and the payee's wallet signs
/// only for addresses it has recorded, so it could not spend what the
/// service took for it. Now the xpub wallet issues on m/2/i, and the payee's
/// wallet records a delegated address from the index it is handed, derives
/// it from its own key, and signs for it.
///
/// Testnet only: ScriptTypeRegistry is a process-wide singleton pinned to
/// the first network it is built with.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet/address_book.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/address_chain.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const _external = 'n4VQ5YdHf7hLQ2gWQYYrcxoE5B7nWuDFNF';

void main() {
  final crypto = DartSVCryptoService();
  late InMemoryEventStore store;
  late InMemorySecureStorage secureStorage;
  late dartsv.HDPublicKey accountXpub;

  setUpAll(() async {
    LibSpiffyActorSystem.registerEventTypes();
    accountXpub =
        crypto.deriveHDPublicKey(await crypto.mnemonicToHDPrivateKey(_mnemonic, network: dartsv.NetworkType.TEST));
  });

  setUp(() {
    store = InMemoryEventStore();
    secureStorage = InMemorySecureStorage();
  });

  String delegated(int index) =>
      crypto.deriveAddress(accountXpub, index, chain: AddressChain.delegated, network: dartsv.NetworkType.TEST);
  String receive(int index) => crypto.deriveAddress(accountXpub, index, network: dartsv.NetworkType.TEST);

  Future<BitcoinWalletAggregate> open(String walletId) async {
    final wallet = BitcoinWalletAggregate(
      aggregateId: walletId,
      aggregateType: 'BitcoinWallet',
      eventStore: store,
      cryptoService: crypto,
      secureStorage: secureStorage,
    );
    await wallet.preStart();
    return wallet;
  }

  /// The service's copy of the payee's wallet: watch-only, from the xpub.
  Future<BitcoinWalletAggregate> serviceWallet() async {
    final wallet = await open('service');
    await wallet.commandHandler(CreateWalletCommand(walletId: 'service', walletName: 's', xpub: accountXpub.xpubkey));
    return wallet;
  }

  /// The payee's own wallet, holding the keys.
  Future<BitcoinWalletAggregate> payeeWallet() async {
    final wallet = await open('payee');
    await wallet.commandHandler(CreateWalletCommand(walletId: 'payee', walletName: 'p', mnemonic: _mnemonic));
    return wallet;
  }

  Future<String> generate(BitcoinWalletAggregate wallet) async {
    await wallet.commandHandler(GenerateAddressCommand(walletId: wallet.aggregateId));
    return store.journal[wallet.persistenceId]!.whereType<AddressGeneratedEvent>().last.address;
  }

  test('AddressChain: the index is the BIP32 child number, and a record without a chain reads its isChange', () {
    expect([for (final c in AddressChain.values) c.index], [0, 1, 2]);
    expect(AddressChain.fromIndex(2), AddressChain.delegated);
    expect(() => AddressChain.fromIndex(3), throwsArgumentError);
    expect(AddressChain.fromRecord(chain: 2, isChange: false), AddressChain.delegated);
    expect(AddressChain.fromRecord(isChange: true), AddressChain.change);
    expect(AddressChain.fromRecord(isChange: false), AddressChain.receive);
    expect(AddressChain.fromRecord(), AddressChain.receive);
  });

  test('an xpub wallet issues on the delegated chain, and the payee\'s own wallet on the receive chain: '
      'the two never hand out the same address', () async {
    final service = await serviceWallet();
    final payee = await payeeWallet();
    final serviceIssued = [await generate(service), await generate(service), await generate(service)];
    final payeeIssued = [await generate(payee), await generate(payee), await generate(payee)];

    expect(serviceIssued, [delegated(1), delegated(2), delegated(3)]);
    expect(payeeIssued, [receive(1), receive(2), receive(3)]);
    expect(serviceIssued.toSet().intersection(payeeIssued.toSet()), isEmpty);
    final generated = store.journal[service.persistenceId]!.whereType<AddressGeneratedEvent>();
    expect(generated.map((e) => e.chain).toSet(), {AddressChain.delegated});
    expect(AddressBook.chainOf(service.currentState, serviceIssued.first), AddressChain.delegated);

    // The chain survives the journal: every event through its map, replayed.
    final replayStore = InMemoryEventStore();
    await replayStore.persistEvents(service.persistenceId,
        [for (final e in store.journal[service.persistenceId]!) EventRegistry.fromMap(e.toMap())], 0);
    final replayed = BitcoinWalletAggregate(
      aggregateId: 'service',
      aggregateType: 'BitcoinWallet',
      eventStore: replayStore,
      cryptoService: crypto,
      secureStorage: secureStorage,
    );
    await replayed.preStart();
    expect(AddressBook.chainOf(replayed.currentState, serviceIssued.last), AddressChain.delegated);
  });

  test('the payee\'s wallet records the delegated addresses it is handed, from its own key, '
      'without moving its own counter, once', () async {
    final payee = await payeeWallet();
    final nextBefore = payee.currentState.nextDerivationIndex;

    await payee.commandHandler(RecordDelegatedAddressesCommand(walletId: 'payee', derivationIndices: [7, 2, 7]));
    final recorded = store.journal[payee.persistenceId]!.whereType<AddressDiscoveredEvent>().toList();
    expect(recorded.map((e) => (e.address, e.derivationIndex, e.chain)),
        [(delegated(7), 7, AddressChain.delegated), (delegated(2), 2, AddressChain.delegated)]);
    expect(payee.currentState.addresses.keys, containsAll([delegated(7), delegated(2)]));
    expect(payee.currentState.nextDerivationIndex, nextBefore,
        reason: 'a delegated address is someone else\'s to issue; the payee\'s own addresses skip nothing');

    final version = payee.currentState.version;
    await payee.commandHandler(RecordDelegatedAddressesCommand(walletId: 'payee', derivationIndices: [2]));
    expect(payee.currentState.version, version, reason: 'recorded already: nothing is journaled');
  });

  test('the payee\'s wallet signs for a delegated address with the key at m/2/i', () async {
    final payee = await payeeWallet();
    await payee.commandHandler(RecordDelegatedAddressesCommand(walletId: 'payee', derivationIndices: [5]));
    final address = delegated(5);
    final txid = 'dd' * 32;
    await payee.commandHandler(ReceiveUTXOCommand(
      walletId: 'payee',
      txid: txid,
      vout: 0,
      satoshis: BigInt.from(90000),
      scriptPubKey: dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex(),
      address: address,
      blockHeight: 900,
      initialStatus: UTXOStatus.available,
    ));
    final tx = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    tx.inputs.add(dartsv.TransactionInput(txid, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    tx.outputs.add(dartsv.TransactionOutput(
        BigInt.from(89000), dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(_external)).getScriptPubkey()));

    // The aggregate runs the script interpreter over every input it signs:
    // a key from any other path fails it.
    await payee.commandHandler(SignTransactionCommand(
      walletId: 'payee',
      transactionId: 'spend-delegated',
      rawTransaction: tx.serialize(),
      utxoKeys: ['$txid:0'],
      publicKeys: const [],
    ));
    expect(store.journal[payee.persistenceId]!.whereType<TransactionSignedEvent>(), hasLength(1));
  });

  test('a single-key (WIF) wallet has no delegated chain', () async {
    final wallet = await open('wif');
    await wallet.commandHandler(CreateWalletCommand(
        walletId: 'wif', walletName: 'w', wif: dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST).toWIF()));
    await expectLater(
      wallet.commandHandler(RecordDelegatedAddressesCommand(walletId: 'wif', derivationIndices: [1])),
      throwsA(isA<StateError>()),
    );
  });

  test('an event journaled before the delegated chain existed reads its chain from what it carried', () {
    final discovered = AddressDiscoveredEvent.fromMap({
      'walletId': 'w',
      'address': 'a',
      'derivationIndex': 4,
      'isChange': true,
      'transactionCount': 1,
    });
    expect(discovered.chain, AddressChain.change);
    final generated = AddressGeneratedEvent.fromMap({
      'walletId': 'w',
      'address': 'b',
      'derivationIndex': 4,
      'purpose': 'change',
    });
    expect(generated.chain, AddressChain.change);
    expect(AddressGeneratedEvent.fromMap({'walletId': 'w', 'address': 'c', 'derivationIndex': 1}).chain,
        AddressChain.receive);

    // What it writes now still carries isChange, for a release that reads
    // nothing else.
    final written = AddressDiscoveredEvent(
      walletId: 'w',
      address: 'd',
      derivationIndex: 2,
      chain: AddressChain.delegated,
      transactionCount: 0,
    ).getWalletEventData();
    expect(written['chain'], 2);
    expect(written['isChange'], isFalse);
  });
}
