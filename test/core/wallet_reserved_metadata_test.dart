/// Bead libspiffy-hfai: host-supplied wallet metadata cannot overwrite the
/// records the wallet keeps in `WalletState.metadata`.
///
/// The wallet aggregate keeps its own records in the same map as the host's
/// wallet metadata: derivation indices and chains (signing key lookup), the
/// outgoing and imported transaction records, and the deferred payments with
/// the inputs they hold. The wallet projection keeps its derived values
/// (balances, counts) in the wallet row's metadata, which the same event
/// feeds. `UpdateWalletConfigurationCommand.newMetadata` was merged over all
/// of it and journaled, and `CreateWalletCommand.walletMetadata` seeded it.
/// Now a command naming a reserved key is rejected before anything is
/// written, and a journaled event from before the fix that names one applies
/// only its other keys (the event itself stays in the journal).
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet/state_records.dart';
import 'package:libspiffy/src/core/wallet/wallet_keys.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/models/address_chain.dart';

import '../actors/in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _w = 'hfai-wallet';
const _pid = 'BitcoinWallet_$_w';
const _foreign = 'muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg';

final _crypto = DartSVCryptoService();

String _txid(int n) => n.toRadixString(16).padLeft(64, '0');

String _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();

/// A transaction spending [inputs] to a foreign address.
String _paymentHex(List<String> inputs) {
  final tx = dartsv.Transaction();
  for (final key in inputs) {
    final parts = key.split(':');
    tx.addInput(dartsv.TransactionInput(parts[0], int.parse(parts[1]), dartsv.TransactionInput.MAX_SEQ_NUMBER));
  }
  tx.addOutput(dartsv.TransactionOutput(BigInt.from(1000), dartsv.SVScript.fromHex(_p2pkh(_foreign))));
  return tx.serialize();
}

/// A wallet aggregate over an in-memory journal, with its secrets.
class _Wallet {
  final InMemoryEventStore store;
  final InMemorySecureStorage secrets;
  late final BitcoinWalletAggregate aggregate;

  _Wallet({InMemoryEventStore? store, InMemorySecureStorage? secrets})
      : store = store ?? InMemoryEventStore(),
        secrets = secrets ?? InMemorySecureStorage() {
    aggregate = BitcoinWalletAggregate(
      aggregateId: _w,
      aggregateType: 'BitcoinWallet',
      eventStore: this.store,
      cryptoService: _crypto,
      secureStorage: this.secrets,
    );
  }

  WalletState get state => aggregate.currentState;
  List<Event> get journal => store.journal[_pid] ?? const [];

  Future<void> handle(WalletCommand command) => aggregate.commandHandler(command);

  /// This wallet's journal recovered by a fresh aggregate.
  Future<_Wallet> recovered() async {
    final fresh = _Wallet(store: store, secrets: secrets);
    await fresh.aggregate.preStart();
    return fresh;
  }

  /// Whether signing resolves [address] to the key that derives it.
  Future<bool> signsFor(String address) async {
    final key = await WalletKeys(cryptoService: _crypto, secureStorage: secrets)
        .privateKeyForAddress(address, _w, state);
    return key.publicKey.toAddress(dartsv.NetworkType.TEST).toBase58() == address;
  }
}

/// A testnet HD wallet with a history that fills every record: a generated
/// receive address (index 1) and change address, UTXOs on them, an imported
/// transaction and an outgoing payment whose inputs are held as a deferred
/// payment.
class _History {
  final _Wallet wallet;
  final String receiveAddress;
  final String changeAddress;
  final String heldInput;
  final String paymentTxid;

  _History(this.wallet, this.receiveAddress, this.changeAddress, this.heldInput, this.paymentTxid);

  static Future<_History> build() async {
    final wallet = _Wallet();
    await wallet.aggregate.preStart();
    await wallet.handle(CreateWalletCommand(
        walletId: _w, walletName: 'hfai', mnemonic: _mnemonic, walletMetadata: {'network': 'testnet', 'theme': 'light'}));
    await wallet.handle(GenerateAddressCommand(walletId: _w));
    await wallet.handle(GenerateAddressCommand(walletId: _w));
    await wallet.handle(GenerateAddressCommand(walletId: _w, purpose: 'change'));
    final addresses = wallet.state.addresses.keys.where((a) => a != wallet.state.rootAddress).toList();
    // Index 2 on the receive chain: a lookup that loses the index (0) or the
    // chain resolves another key.
    final receive = addresses.firstWhere((a) => wallet.state.metadata['address_indices'][a] == 2 &&
        wallet.state.metadata['address_chains'][a] == AddressChain.receive.index);
    final change =
        addresses.firstWhere((a) => wallet.state.metadata['address_chains'][a] == AddressChain.change.index);

    for (final (n, address) in [(1, receive), (2, change), (3, wallet.state.rootAddress!)]) {
      await wallet.handle(ReceiveUTXOCommand(
        walletId: _w,
        txid: _txid(n),
        vout: 0,
        satoshis: BigInt.from(10000 * n),
        scriptPubKey: _p2pkh(address),
        address: address,
        blockHeight: 100,
        confirmations: 6,
        initialStatus: UTXOStatus.available,
      ));
    }
    await wallet.handle(RecordImportedTransactionCommand(
      walletId: _w,
      txid: _txid(1),
      rawHex: '',
      blockHeight: 100,
      bumpProofHex: '',
      totalOutputSats: 10000,
      numInputs: 1,
      numOutputs: 1,
      txVersion: 1,
      txLockTime: 0,
      walletReceivingAddresses: [receive],
      walletReceivedSats: 10000,
      totalInputSats: 10100,
      sendingAddresses: const [],
    ));

    final held = '${_txid(3)}:0';
    final rawHex = _paymentHex([held]);
    final txid = dartsv.Transaction.fromHex(rawHex).id;
    await wallet.handle(RecordOutgoingTransactionCommand(
      walletId: _w,
      txid: txid,
      rawHex: rawHex,
      totalInputSats: 30000,
      totalOutputSats: 1000,
      fee: 100,
      numInputs: 1,
      numOutputs: 1,
      txVersion: 1,
      txLockTime: 0,
      spentUtxoKeys: [held],
      recipientAddresses: const [_foreign],
      paymentAmount: BigInt.from(1000),
      deferSpend: true,
      purpose: 'invoice-payment',
    ));

    final history = _History(wallet, receive, change, held, txid);
    await history.expectIntact(wallet);
    return history;
  }

  /// The internal records of [other] are the ones this history built.
  Future<void> expectIntact(_Wallet other) async {
    expect(await other.signsFor(receiveAddress), isTrue, reason: 'signing resolves the receive address key');
    expect(await other.signsFor(changeAddress), isTrue, reason: 'signing resolves the change address key');
    expect(other.state.utxos[heldInput]!.reservedByTxId, paymentTxid, reason: 'the deferred payment holds its input');
    final metadata = other.state.metadata;
    expect((metadata['address_indices'] as Map)[receiveAddress], 2);
    expect((metadata['address_chains'] as Map)[changeAddress], AddressChain.change.index);
    expect((metadata['outgoingTransactions'] as Map).keys, [paymentTxid]);
    expect((metadata['importedTransactions'] as Map).keys, [_txid(1)]);
    expect((metadata['deferredSpends'] as Map)[paymentTxid]['state'], 'outstanding');
    expect((metadata['deferredHolds'] as Map)[heldInput], paymentTxid);
    expect(metadata['network'], 'testnet');
  }
}

void main() {
  group('UpdateWalletConfigurationCommand naming a reserved key', () {
    const reserved = <String, Object?>{
      'outgoingTransactions': <String, dynamic>{},
      'address_indices': <String, dynamic>{},
      'deferredHolds': <String, dynamic>{},
      'deferredSpends': 'overwritten',
      'address_chains': <String, dynamic>{},
      'importedTransactions': <String, dynamic>{},
      'network': 'mainnet',
      'confirmedBalance': '999999',
    };

    for (final entry in reserved.entries) {
      test("'${entry.key}' is rejected: no event, state intact, signing still works", () async {
        final history = await _History.build();
        final wallet = history.wallet;
        final before = wallet.state;
        final journalLength = wallet.journal.length;

        await expectLater(
          wallet.handle(UpdateWalletConfigurationCommand(
            walletId: _w,
            newName: 'renamed',
            newMetadata: {entry.key: entry.value, 'theme': 'dark'},
          )),
          throwsA(isA<ArgumentError>().having((e) => e.message.toString(), 'message', contains(entry.key))),
        );

        expect(wallet.journal, hasLength(journalLength), reason: 'nothing journaled');
        expect(identical(wallet.state, before), isTrue, reason: 'state unchanged');
        expect(wallet.state.name, 'hfai');
        expect(wallet.state.metadata['theme'], 'light', reason: 'the rejected command applied none of its keys');
        await history.expectIntact(wallet);
        await history.expectIntact(await wallet.recovered());
      });
    }

    test('ordinary user keys still merge, and the update is journaled', () async {
      final history = await _History.build();
      final wallet = history.wallet;
      final journalLength = wallet.journal.length;

      await wallet.handle(UpdateWalletConfigurationCommand(
          walletId: _w, newMetadata: {'theme': 'dark', 'profile': {'owner': 'alice'}}));
      await wallet.handle(UpdateWalletConfigurationCommand(walletId: _w, newName: 'renamed'));

      expect(wallet.journal, hasLength(journalLength + 2));
      for (final w in [wallet, await wallet.recovered()]) {
        expect(w.state.name, 'renamed');
        expect(w.state.metadata['theme'], 'dark');
        expect(w.state.metadata['profile'], {'owner': 'alice'});
        await history.expectIntact(w);
      }
    });
  });

  group('replay of a journal written before the fix', () {
    test('a WalletConfigurationUpdatedEvent naming reserved keys applies only its other keys', () async {
      final history = await _History.build();
      final wallet = history.wallet;
      final version = wallet.state.version;
      // What the unfixed aggregate journaled for such a command.
      wallet.store.journal[_pid]!.add(WalletConfigurationUpdatedEvent(
        walletId: _w,
        newName: 'renamed',
        newMetadata: {
          'address_indices': <String, dynamic>{},
          'address_chains': 'garbage',
          'outgoingTransactions': <String, dynamic>{},
          'deferredSpends': <String, dynamic>{},
          'deferredHolds': <String, dynamic>{},
          'network': 'mainnet',
          'theme': 'dark',
        },
        version: version + 1,
        timestamp: DateTime.utc(2026, 9, 1),
      ));

      final replayed = await wallet.recovered();

      expect(replayed.journal.whereType<WalletConfigurationUpdatedEvent>(), hasLength(1),
          reason: 'the event stays in the journal');
      expect(replayed.state.version, version + 1);
      expect(replayed.state.name, 'renamed');
      expect(replayed.state.metadata['theme'], 'dark');
      await history.expectIntact(replayed);
    });

    test('a WalletCreatedEvent whose metadata names reserved keys seeds no internal record', () async {
      final store = InMemoryEventStore();
      final held = '${_txid(7)}:0';
      final root = (await _crypto.derivePrivateKey(
              await _crypto.mnemonicToHDPrivateKey(_mnemonic, network: dartsv.NetworkType.TEST), 0))
          .publicKey
          .toAddress(dartsv.NetworkType.TEST)
          .toBase58();
      store.journal[_pid] = [
        WalletCreatedEvent(
          walletId: _w,
          walletName: 'seeded',
          rootAddress: root,
          walletType: WalletType.hd,
          walletMetadata: {
            'network': 'testnet',
            'theme': 'light',
            'deferredHolds': {held: 'not-a-payment'},
            'outgoingTransactions': {'not-a-payment': {'txid': 'not-a-payment', 'spentUtxoKeys': [held]}},
          },
          version: 1,
          timestamp: DateTime.utc(2026, 9, 1),
        ),
        UTXOReceivedEvent(
          walletId: _w,
          txid: _txid(7),
          vout: 0,
          satoshis: 5000,
          scriptPubKey: _p2pkh(root),
          address: root,
          initialStatus: UTXOStatus.available,
          version: 2,
          timestamp: DateTime.utc(2026, 9, 1),
        ),
      ];

      final wallet = await _Wallet(store: store).recovered();

      expect(wallet.state.metadata['network'], 'testnet');
      expect(wallet.state.networkType, 'testnet');
      expect(wallet.state.metadata['theme'], 'light');
      expect(wallet.state.metadata['deferredHolds'], anyOf(isNull, isEmpty));
      expect(wallet.state.metadata['outgoingTransactions'], anyOf(isNull, isEmpty));
      // An input no payment holds can be reserved.
      await wallet.handle(ReserveUTXOCommand(walletId: _w, utxoKey: held, reservedByTxId: 'payment'));
      expect(wallet.state.utxos[held]!.reservedByTxId, 'payment');
    });
  });

  group('CreateWalletCommand naming a reserved key', () {
    test('is rejected before key material is written; network stays the creation input', () async {
      final wallet = _Wallet();
      await wallet.aggregate.preStart();

      await expectLater(
        wallet.handle(CreateWalletCommand(
          walletId: _w,
          walletName: 'seeded',
          mnemonic: _mnemonic,
          walletMetadata: {
            'network': 'testnet',
            'deferredHolds': {'${_txid(7)}:0': 'not-a-payment'},
          },
        )),
        throwsA(isA<ArgumentError>().having((e) => e.message.toString(), 'message', contains('deferredHolds'))),
      );
      expect(wallet.journal, isEmpty);
      expect(wallet.state.isCreated, isFalse);
      expect(await wallet.secrets.getMnemonic(_w), isNull, reason: 'no key material for a rejected creation');

      await wallet.handle(CreateWalletCommand(
          walletId: _w, walletName: 'ok', mnemonic: _mnemonic, walletMetadata: {'network': 'testnet', 'theme': 'x'}));
      expect(wallet.state.isCreated, isTrue);
      expect(wallet.state.networkType, 'testnet');
      expect(wallet.state.metadata['theme'], 'x');
    });
  });

  group('the reserved-key set', () {
    test('holds every key the aggregate writes into WalletState.metadata', () async {
      final history = await _History.build();
      final internal = history.wallet.state.metadata.keys.where((k) => k != 'theme').toSet();
      expect(internal, containsAll(['address_indices', 'address_chains', 'outgoingTransactions',
          'importedTransactions', 'deferredSpends', 'deferredHolds', 'network']));
      expect(WalletMetadataKeys.reserved, containsAll(internal));
    });

    test('holds every key the projection writes into the wallet row metadata', () async {
      final storage = InMemoryWalletStorage();
      final projection = WalletProjection(projectionId: 'hfai', eventStore: InMemoryEventStore(), storage: storage);
      final history = await _History.build();
      for (final event in history.wallet.journal) {
        await projection.handle(event);
      }
      final keys = ((await storage.getWallet(_w))!['metadata'] as Map).keys.where((k) => k != 'theme').toSet();
      expect(keys, containsAll(['confirmedBalance', 'utxoCount', 'walletType', 'lastUpdated']));
      expect(WalletMetadataKeys.reserved, containsAll(keys));
    });

    test('host keys pass; a creation may name its network', () {
      expect(WalletMetadataKeys.reservedIn({'theme': 1, 'network': 'testnet'}), ['network']);
      expect(WalletMetadataKeys.reservedIn({'theme': 1, 'network': 'testnet'}, creation: true), isEmpty);
      final host = {'theme': 1};
      expect(identical(WalletMetadataKeys.hostEntries(host), host), isTrue);
      expect(WalletMetadataKeys.hostEntries({'theme': 1, 'deferredHolds': {}}), {'theme': 1});
    });
  });

  group('WalletProjection', () {
    test('replaying a creation naming reserved keys writes only its host keys and network', () async {
      final storage = InMemoryWalletStorage();
      final projection = WalletProjection(projectionId: 'hfai', eventStore: InMemoryEventStore(), storage: storage);
      await projection.handle(WalletCreatedEvent(
        walletId: _w,
        walletName: 'hfai',
        rootAddress: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
        walletType: WalletType.hd,
        walletMetadata: {
          'network': 'testnet',
          'theme': 'light',
          'derivationIndex': 'x',
          'outgoingTransactions': <String, dynamic>{},
        },
        version: 1,
        timestamp: DateTime.utc(2026, 9, 1),
      ));

      final metadata = (await storage.getWallet(_w))!['metadata'] as Map<String, dynamic>;
      expect(metadata['theme'], 'light');
      expect(metadata['network'], 'testnet');
      expect(metadata.keys, isNot(contains('derivationIndex')));
      expect(metadata.keys, isNot(contains('outgoingTransactions')));
    });

    test('replaying a configuration update naming read-model keys keeps the derived values', () async {
      final storage = InMemoryWalletStorage();
      final projection = WalletProjection(projectionId: 'hfai', eventStore: InMemoryEventStore(), storage: storage);
      const root = 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt';
      await projection.handle(WalletCreatedEvent(
        walletId: _w,
        walletName: 'hfai',
        rootAddress: root,
        walletType: WalletType.hd,
        walletMetadata: {'network': 'testnet'},
        version: 1,
        timestamp: DateTime.utc(2026, 9, 1),
      ));
      await projection.handle(UTXOReceivedEvent(
        walletId: _w,
        txid: _txid(1),
        vout: 0,
        satoshis: 5000,
        scriptPubKey: _p2pkh(root),
        address: root,
        initialStatus: UTXOStatus.available,
        confirmations: 6,
        blockHeight: 100,
        version: 2,
        timestamp: DateTime.utc(2026, 9, 1),
      ));
      final before = Map<String, dynamic>.of((await storage.getWallet(_w))!['metadata'] as Map<String, dynamic>);
      expect(before['utxoCount'], 1);

      await projection.handle(WalletConfigurationUpdatedEvent(
        walletId: _w,
        newMetadata: {'confirmedBalance': '999999', 'utxoCount': 42, 'walletType': 'xpub', 'theme': 'dark'},
        version: 3,
        timestamp: DateTime.utc(2026, 9, 2),
      ));

      final after = (await storage.getWallet(_w))!['metadata'] as Map<String, dynamic>;
      expect(after['theme'], 'dark');
      for (final key in ['confirmedBalance', 'utxoCount', 'walletType']) {
        expect(after[key], before[key], reason: key);
      }
    });
  });
}
