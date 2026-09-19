/// Balances agree across layers (spv-understanding.md, "Balances"): the
/// wallet aggregate's spendable amount (`WalletState.availableBalance`, the
/// UTXOs its coin selection may pick) and the read side's
/// (`ReadModelStorage.getBalance`, the wallet row's balance fields written by
/// `WalletProjection`) leave out the same UTXOs.
///
/// * libspiffy-vsap: `getBalance` and the wallet row counted watch-only UTXOs
///   (at a watch address the wallet holds no key for), which the aggregate
///   and `BalanceResponse` leave out.
/// * libspiffy-ecy8: the aggregate treated any plugin metadata as
///   plugin-managed, the read side only metadata naming a `pluginId`; and the
///   projection dropped the metadata a UTXO was received with, so an earmark
///   (`pluginId: funding-earmark`) was spendable on the read side.
/// * libspiffy-0k8: a journal written before bead viy can hold a bare
///   multisig UTXO the wallet cannot spend alone; replay counted it as
///   spendable on both layers. It is kept (state and row) but not spendable.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/plugin/plugin_registry.dart';
import 'package:libspiffy/src/plugin/plugin_types.dart';
import 'package:libspiffy/src/plugin/script_plugin.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import '../actors/in_memory_event_store.dart';

const _walletId = 'balance-agreement';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

String _txid(int n) => n.toRadixString(16).padLeft(64, '0');
String _key(int n) => '${_txid(n)}:0';

String _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();

/// A script no standard template matches, claimed by [_LabelPlugin].
const _pluginScript = '0a6c6162656c2d746f6b656e7575';

/// A plugin whose metadata does not name the plugin.
class _LabelPlugin extends ScriptPlugin {
  @override
  String get pluginId => 'label-token';
  @override
  String get displayName => 'Label token';
  @override
  List<String> get scriptTypes => const ['label'];
  @override
  String? identifyScript(dartsv.SVScript script) => script.toHex() == _pluginScript ? 'label' : null;
  @override
  Map<String, dynamic>? extractMetadata(dartsv.SVScript script) =>
      identifyScript(script) == null ? null : {'tokenId': 'abc'};
  @override
  dartsv.LockingScriptBuilder? createLockBuilder(PluginOutputSpec spec) => null;
  @override
  dartsv.UnlockingScriptBuilder? createUnlockBuilder(PluginUnlockSpec spec) => null;
}

final _serverKey = dartsv.SVPrivateKey.fromHex('11' * 32, dartsv.NetworkType.TEST).publicKey;
final _watchAddress =
    dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST).publicKey.toAddress(dartsv.NetworkType.TEST).toBase58();

void main() {
  late InMemoryEventStore store;
  late InMemorySecureStorage secureStorage;
  late BitcoinWalletAggregate wallet;
  late String root;
  late dartsv.SVPublicKey walletKey;

  BitcoinWalletAggregate newAggregate() => BitcoinWalletAggregate(
        aggregateId: _walletId,
        aggregateType: 'BitcoinWallet',
        eventStore: store,
        cryptoService: DartSVCryptoService(),
        secureStorage: secureStorage,
      );

  setUp(() async {
    store = InMemoryEventStore();
    secureStorage = InMemorySecureStorage();
    wallet = newAggregate();
    await wallet.preStart();
    await wallet.commandHandler(CreateWalletCommand(walletId: _walletId, walletName: 'agreement', mnemonic: _mnemonic));
    await wallet.commandHandler(GenerateAddressCommand(walletId: _walletId, includePublicKey: true));
    root = wallet.currentState.rootAddress!;
    walletKey = dartsv.SVPublicKey.fromHex(store.allEvents.whereType<AddressGeneratedEvent>().last.publicKeyHex!);
  });

  Future<void> receive(int n, int sats, {String? address, String? script, Map<String, dynamic>? pluginMetadata}) =>
      wallet.commandHandler(ReceiveUTXOCommand(
        walletId: _walletId,
        txid: _txid(n),
        vout: 0,
        satoshis: BigInt.from(sats),
        scriptPubKey: script ?? _p2pkh(address ?? root),
        address: address ?? root,
        blockHeight: 900,
        confirmations: 6,
        initialStatus: UTXOStatus.available,
        pluginMetadata: pluginMetadata,
      ));

  /// Journals a receive WITHOUT the command path's rules, the way a journal
  /// written before those rules exists (bead libspiffy-abwk, V-97). The
  /// event goes into the store as well as into the aggregate, so a replay
  /// and the read model see exactly what a real journal would hand them.
  Future<void> receiveByReplay(int n, int sats, {required String script}) async {
    final event = UTXOReceivedEvent(
      walletId: _walletId,
      txid: _txid(n),
      vout: 0,
      satoshis: sats,
      scriptPubKey: script,
      address: root,
      blockHeight: 900,
      confirmations: 6,
      initialStatus: UTXOStatus.available,
      version: wallet.currentState.version + 1,
    );
    await store.persistEvents('BitcoinWallet_$_walletId', [event], 0);
    wallet.eventHandler(event);
  }

  /// The whole journal applied to a fresh read model.
  Future<InMemoryWalletStorage> project() async {
    final storage = InMemoryWalletStorage();
    final projection = WalletProjection(projectionId: 'agreement', eventStore: store, storage: storage);
    for (final event in store.allEvents) {
      await projection.handle(event);
    }
    return storage;
  }

  Future<Map<String, dynamic>> walletRow(InMemoryWalletStorage storage) async =>
      (await storage.getWallet(_walletId))!['metadata'] as Map<String, dynamic>;

  test('vsap: watch-only UTXOs are out of getBalance and the wallet row balances, and reported apart', () async {
    await wallet.commandHandler(AddWatchAddressCommand(walletId: _walletId, address: _watchAddress, scriptType: 'p2pkh'));
    await receive(1, 40000);
    await receive(2, 90000, address: _watchAddress);

    expect(wallet.currentState.availableBalance, BigInt.from(40000));

    final storage = await project();
    expect((await storage.getUTXOs(_walletId)).map((u) => u.key).toSet(), {_key(1), _key(2)},
        reason: 'the watch-only UTXO row is kept');
    expect(await storage.getBalance(_walletId), BigInt.from(40000));
    final row = await walletRow(storage);
    expect(row['confirmedBalance'], '40000');
    expect(row['unconfirmedBalance'], '0');
    expect(row['totalBalance'], '40000');
    expect(row['watchOnlyBalance'], '90000');
    expect(await storage.getWatchOnlyBalance(_walletId), BigInt.from(90000));
  });

  test('ecy8: plugin metadata without a pluginId leaves a UTXO spendable on both layers; one naming a pluginId '
      'takes it out of both', () async {
    await receive(1, 40000);
    await receive(2, 3000, pluginMetadata: {'purpose': 'label only'});
    await receive(3, 5000, pluginMetadata: {'pluginId': 'funding-earmark', 'purpose': 'mint'});

    final storage = await project();
    final aggregateSpendable = wallet.getAvailableUTXOs(wallet.currentState).map((u) => u.key).toSet();
    final readSpendable = (await storage.getPaymentUTXOs(_walletId)).map((u) => u.key).toSet();
    expect(aggregateSpendable, {_key(1), _key(2)});
    expect(readSpendable, aggregateSpendable);
    expect(wallet.currentState.availableBalance, BigInt.from(43000));
    expect(await storage.getBalance(_walletId), BigInt.from(43000));
    expect((await walletRow(storage))['totalBalance'], '43000');
    expect((await storage.getUTXOsByPlugin(_walletId, 'funding-earmark')).map((u) => u.key), [_key(3)]);
    expect(wallet.currentState.utxos[_key(3)]!.isPluginManaged, isTrue);
    expect(wallet.currentState.utxos[_key(2)]!.isPluginManaged, isFalse);
  });

  group('ecy8: a script a registered plugin claims', () {
    setUp(() => PluginRegistry().register(_LabelPlugin()));
    tearDown(() => PluginRegistry().unregister('label-token'));

    test('is plugin-managed on both layers, whatever metadata it was received with, after replay and a snapshot',
        () async {
      await receive(1, 40000);
      await receive(2, 3000, script: _pluginScript, pluginMetadata: {'tokenId': 'abc'}); // names no plugin
      await receive(3, 5000, script: _pluginScript); // no metadata

      for (final state in [
        wallet.currentState,
        await () async {
          final replayed = newAggregate();
          await replayed.preStart();
          return replayed.currentState;
        }(),
      ]) {
        expect(state.utxos[_key(2)]!.pluginMetadata, {'tokenId': 'abc', 'pluginId': 'label-token'});
        expect(state.utxos[_key(3)]!.pluginMetadata, {'pluginId': 'label-token'});
        expect(state.availableBalance, BigInt.from(40000));
      }
      final restored = await newAggregate().restoreStateFromMap(
          {...wallet.currentState.toMap(), 'utxos': {
            for (final e in wallet.currentState.toMap()['utxos'].entries)
              e.key: {...e.value as Map, 'pluginMetadata': null},
          }},
          1);
      expect(restored.utxos[_key(3)]!.isPluginManaged, isTrue, reason: 'a snapshot written before the rule');
      expect(restored.availableBalance, BigInt.from(40000));

      final storage = await project();
      expect((await storage.getPaymentUTXOs(_walletId)).map((u) => u.key), [_key(1)]);
      expect(await storage.getBalance(_walletId), BigInt.from(40000));
      expect((await walletRow(storage))['totalBalance'], '40000');
    });
  });

  test('0k8: a journaled bare multisig UTXO the wallet cannot spend alone is kept but spendable on neither layer',
      () async {
    await receive(1, 40000);
    // A journal written before beads viy / n0p: an escrow holding one wallet
    // key, recorded as a wallet UTXO under a pseudo-address.
    final escrow = dartsv.P2MSLockBuilder([walletKey, _serverKey], 2, sorting: false).getScriptPubkey().toHex();
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

    final replayed = newAggregate();
    await replayed.preStart();
    final state = replayed.currentState;
    expect(state.utxos[_key(7)]?.status, UTXOStatus.available, reason: 'the UTXO is kept as journaled');
    expect(state.availableBalance, BigInt.from(40000));
    expect(replayed.getAvailableUTXOs(state).map((u) => u.key), [_key(1)]);
    expect(() => replayed.selectUTXOsForAmount(state, BigInt.from(40001)), throwsA(isA<StateError>()));
    expect(state.balance, BigInt.from(140000), reason: 'the buckets count everything the wallet holds');
    expect(WalletState.fromMap(state.toMap()).availableBalance, BigInt.from(40000), reason: 'a snapshot');

    final storage = await project();
    expect((await storage.getUTXOs(_walletId)).map((u) => u.key).toSet(), {_key(1), _key(7)},
        reason: 'the row is kept');
    expect(await storage.getBalance(_walletId), BigInt.from(40000));
    expect((await walletRow(storage))['totalBalance'], '40000');
  });

  // Bead libspiffy-kfvv. `ReceiveUTXOCommand` checked a bare multisig
  // script's threshold against the wallet's keys but never a P2PK script's
  // key, and `applyReceived` checks neither, so an output locked to someone
  // else's public key could be attributed to a wallet address. Channel
  // funding refused to spend it (bead libspiffy-8egy, V-83) while both
  // balances counted it, the two layers disagreeing about the same output.
  // `unlocksAlone` is now the one predicate: `WalletBalances.cannotSpendAlone`
  // on the write side and `splitBalanceUtxos` on the read side both call it.
  //
  // Since bead libspiffy-abwk (V-97) the COMMAND path refuses such an output,
  // so the only way one reaches a wallet is a journal written before that —
  // which is why this receives it by replay. The rule here is what keeps
  // those rows honest, and it does not become unnecessary because new ones
  // are refused: the old ones are permanent.
  test('kfvv: a P2PK UTXO locked to a key the wallet does not hold is kept but spendable on neither layer', () async {
    await receive(1, 40000);
    final foreignP2pk = dartsv.P2PKLockBuilder(_serverKey).getScriptPubkey().toHex();
    await receiveByReplay(7, 100000, script: foreignP2pk);
    // A P2PK output to the wallet's own key stays spendable: the exclusion
    // is the foreign key, not the script type (bead libspiffy-8egy).
    await receive(8, 7000, script: dartsv.P2PKLockBuilder(walletKey).getScriptPubkey().toHex());

    expect(wallet.currentState.utxos[_key(7)]?.status, UTXOStatus.available, reason: 'the UTXO is kept as received');
    expect(wallet.getAvailableUTXOs(wallet.currentState).map((u) => u.key), [_key(1), _key(8)]);
    expect(wallet.currentState.availableBalance, BigInt.from(47000));
    expect(wallet.currentState.balance, BigInt.from(147000), reason: 'the buckets count everything the wallet holds');

    final replayed = newAggregate();
    await replayed.preStart();
    expect(replayed.currentState.availableBalance, BigInt.from(47000), reason: 'replay');
    expect(WalletState.fromMap(replayed.currentState.toMap()).availableBalance, BigInt.from(47000),
        reason: 'a snapshot');

    final storage = await project();
    expect((await storage.getUTXOs(_walletId)).map((u) => u.key).toSet(), {_key(1), _key(7), _key(8)},
        reason: 'the row is kept');
    expect(await storage.getBalance(_walletId), BigInt.from(47000));
    expect(await storage.getWatchOnlyBalance(_walletId), BigInt.zero,
        reason: 'no watch address is involved: it is not watch-only funds');
    expect((await walletRow(storage))['totalBalance'], '47000');
  });
}
