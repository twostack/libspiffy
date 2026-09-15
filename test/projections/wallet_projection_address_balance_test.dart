/// Bead libspiffy-hccp item 5: the wallet row's balances were not
/// recomputed when the wallet derived a new key (AddressGeneratedEvent).
///
/// A bare multisig UTXO the wallet cannot spend alone counts in no balance
/// (bead libspiffy-0k8); whether the wallet can spend it depends on the keys
/// it holds, so it becomes spendable when the wallet derives the missing
/// key. The aggregate's available balance, `getBalance` and `BalanceResponse`
/// follow at once; the wallet row caught up only at the next UTXO event.
/// The projection now recomputes on a new address, but only for a wallet
/// whose row counts such a UTXO (`notSpendableAloneUtxoCount`): other
/// wallets' address events load no UTXO rows.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import '../actors/in_memory_event_store.dart';

const _walletId = 'address-balance';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

String _txid(int n) => n.toRadixString(16).padLeft(64, '0');

String _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();

/// In-memory storage that counts UTXO loads, and can hide a wallet row
/// metadata key (a row written before the key existed).
class _CountingStorage extends InMemoryWalletStorage {
  int utxoLoads = 0;
  String? hiddenKey;

  @override
  Future<List<BitcoinUtxo>> getUTXOs(String walletId, {bool includeSpent = false}) {
    utxoLoads++;
    return super.getUTXOs(walletId, includeSpent: includeSpent);
  }

  @override
  Future<Map<String, dynamic>?> getWallet(String walletId) async {
    final row = await super.getWallet(walletId);
    final key = hiddenKey;
    if (row == null || key == null) return row;
    return {
      ...row,
      'metadata': {...(row['metadata'] as Map<String, dynamic>)}..remove(key),
    };
  }
}

void main() {
  late InMemoryEventStore store;
  late InMemorySecureStorage secureStorage;
  late BitcoinWalletAggregate wallet;
  late _CountingStorage storage;
  late WalletProjection projection;
  var projected = 0;

  BitcoinWalletAggregate newAggregate(InMemoryEventStore eventStore) => BitcoinWalletAggregate(
        aggregateId: _walletId,
        aggregateType: 'BitcoinWallet',
        eventStore: eventStore,
        cryptoService: DartSVCryptoService(),
        secureStorage: secureStorage,
      );

  /// Applies the journal's events not yet projected.
  Future<void> project() async {
    final events = store.allEvents;
    for (; projected < events.length; projected++) {
      await projection.handle(events[projected]);
    }
  }

  Future<Map<String, dynamic>> walletRow() async =>
      (await storage.getWallet(_walletId))!['metadata'] as Map<String, dynamic>;

  /// The public keys of the wallet's first [count] generated addresses, from
  /// a scratch wallet with the same mnemonic.
  Future<List<dartsv.SVPublicKey>> firstKeys(int count) async {
    final scratchStore = InMemoryEventStore();
    final scratch = BitcoinWalletAggregate(
      aggregateId: _walletId,
      aggregateType: 'BitcoinWallet',
      eventStore: scratchStore,
      cryptoService: DartSVCryptoService(),
      secureStorage: InMemorySecureStorage(),
    );
    await scratch.preStart();
    await scratch.commandHandler(CreateWalletCommand(walletId: _walletId, walletName: 'scratch', mnemonic: _mnemonic));
    for (var i = 0; i < count; i++) {
      await scratch.commandHandler(GenerateAddressCommand(walletId: _walletId, includePublicKey: true));
    }
    return [
      for (final e in scratchStore.allEvents.whereType<AddressGeneratedEvent>().take(count))
        dartsv.SVPublicKey.fromHex(e.publicKeyHex!),
    ];
  }

  setUp(() async {
    store = InMemoryEventStore();
    secureStorage = InMemorySecureStorage();
    storage = _CountingStorage();
    projection = WalletProjection(projectionId: 'address-balance', eventStore: store, storage: storage);
    projected = 0;
    wallet = newAggregate(store);
    await wallet.preStart();
    await wallet.commandHandler(CreateWalletCommand(walletId: _walletId, walletName: 'W', mnemonic: _mnemonic));
    await wallet.commandHandler(GenerateAddressCommand(walletId: _walletId, includePublicKey: true));
    final root = wallet.currentState.rootAddress!;
    await wallet.commandHandler(ReceiveUTXOCommand(
      walletId: _walletId,
      txid: _txid(1),
      vout: 0,
      satoshis: BigInt.from(40000),
      scriptPubKey: _p2pkh(root),
      address: root,
      blockHeight: 900,
      confirmations: 6,
      initialStatus: UTXOStatus.available,
    ));
  });

  test('a multisig UTXO that becomes spendable when the wallet derives its key is in the wallet row at once',
      () async {
    final keys = await firstKeys(2);
    final generatedSoFar = store.allEvents.whereType<AddressGeneratedEvent>().map((e) => e.publicKeyHex).toList();
    expect(generatedSoFar, [keys[0].toHex()], reason: 'the second key is not derived yet');

    // A journal written before bead viy: a 2-of-2 of the wallet's first and
    // second keys, recorded while the wallet held only the first.
    final escrow = dartsv.P2MSLockBuilder([keys[0], keys[1]], 2, sorting: false).getScriptPubkey().toHex();
    await store.persistEvents(store.journal.keys.single, [
      UTXOReceivedEvent(
        walletId: _walletId,
        txid: _txid(7),
        vout: 0,
        satoshis: 100000,
        scriptPubKey: escrow,
        address: 'p2ms:2-of-2',
        confirmations: 6,
        blockHeight: 900,
        initialStatus: UTXOStatus.available,
        version: wallet.currentState.version + 1,
        timestamp: DateTime.utc(2026, 9, 1),
      ),
    ], 0);
    await project();
    expect((await walletRow())['totalBalance'], '40000');
    expect(await storage.getBalance(_walletId), BigInt.from(40000));

    // The wallet derives the second key.
    wallet = newAggregate(store);
    await wallet.preStart();
    expect(wallet.currentState.availableBalance, BigInt.from(40000));
    await wallet.commandHandler(GenerateAddressCommand(walletId: _walletId, includePublicKey: true));
    expect(store.allEvents.last, isA<AddressGeneratedEvent>());
    expect(wallet.currentState.availableBalance, BigInt.from(140000), reason: 'the aggregate follows the keys');
    await project();

    expect(await storage.getBalance(_walletId), BigInt.from(140000));
    final row = await walletRow();
    expect(row['totalBalance'], '140000', reason: 'the wallet row follows the new key without a UTXO event');
    expect(row['confirmedBalance'], '140000');
    expect(row['availableUtxoCount'], 2);
    expect(row['notSpendableAloneUtxoCount'], 0);

    // Nothing left that a key could make spendable: the next address loads
    // no UTXO rows.
    storage.utxoLoads = 0;
    await wallet.commandHandler(GenerateAddressCommand(walletId: _walletId));
    await project();
    expect(storage.utxoLoads, 0);
    expect((await walletRow())['totalBalance'], '140000');
  });

  test('an address of a wallet without such a UTXO loads no UTXO rows; a row from before the count recomputes once',
      () async {
    await project();
    expect((await walletRow())['notSpendableAloneUtxoCount'], 0);

    storage.utxoLoads = 0;
    for (var i = 0; i < 3; i++) {
      await wallet.commandHandler(GenerateAddressCommand(walletId: _walletId));
    }
    await project();
    expect(storage.utxoLoads, 0, reason: 'no recomputation per address');

    // A wallet row written before the count was stored: the first address
    // recomputes (and stores the count), the next does not.
    storage.hiddenKey = 'notSpendableAloneUtxoCount';
    await wallet.commandHandler(GenerateAddressCommand(walletId: _walletId));
    await project();
    expect(storage.utxoLoads, 1);
    storage.hiddenKey = null;
    await wallet.commandHandler(GenerateAddressCommand(walletId: _walletId));
    await project();
    expect(storage.utxoLoads, 1);
    expect((await walletRow())['totalBalance'], '40000');
  });
}
