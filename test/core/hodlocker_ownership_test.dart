/// Bead spiffyvault-mnz.1: a HODLocker output (a coin time-locked to a key
/// until a block height) to one of the wallet's keys is the wallet's, and is
/// recorded with its lock: plugin-managed, so it is never selected and is in
/// no balance but the locked one, on the aggregate and the read model alike.
///
/// Every path dropped such an output before: dartsv names the script
/// `hodlocker`, and no switch had a case for it.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:hex/hex.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/hodlocker_lock.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_balances.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

import '../actors/in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _walletId = 'wallet-hodlocker';
const _lockHeight = 1700000;
final _network = dartsv.NetworkType.TEST;

String _txid(String c) => List.filled(64, c).join();

dartsv.SVScript _lockTo(String address, {int height = _lockHeight}) => dartsv.HODLockerLockingScriptBuilder(
      HEX.decode(dartsv.Address.fromBase58(address).pubkeyHash160),
      BigInt.from(height),
    ).getScriptPubkey();

dartsv.SVScript _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey();

void main() {
  late InMemoryEventStore store;
  late BitcoinWalletAggregate wallet;
  late String address;
  late String foreignAddress;

  setUp(() async {
    store = InMemoryEventStore();
    wallet = BitcoinWalletAggregate(
      aggregateId: _walletId,
      aggregateType: 'Wallet',
      eventStore: store,
      cryptoService: DartSVCryptoService(),
      secureStorage: InMemorySecureStorage(),
    );
    await wallet.preStart();
    await wallet.commandHandler(CreateWalletCommand(walletId: _walletId, walletName: 'Locks', mnemonic: _mnemonic));
    await wallet.commandHandler(GenerateAddressCommand(walletId: _walletId, label: 'lock'));
    address = store.allEvents.whereType<AddressGeneratedEvent>().last.address;
    foreignAddress = dartsv.SVPrivateKey.fromHex('5c' * 32, _network).publicKey.toAddress(_network).toBase58();
  });

  Future<InMemoryWalletStorage> project() async {
    final storage = InMemoryWalletStorage();
    final projection = WalletProjection(projectionId: 'hodlocker-test', eventStore: store, storage: storage);
    for (final event in store.allEvents) {
      await projection.handle(event);
    }
    return storage;
  }

  Future<void> receive(String txid, dartsv.SVScript script, String attributedTo) =>
      wallet.commandHandler(ReceiveUTXOCommand(
        walletId: _walletId,
        txid: txid,
        vout: 0,
        satoshis: BigInt.from(90000),
        scriptPubKey: script.toHex(),
        address: attributedTo,
        initialStatus: UTXOStatus.available,
        blockHeight: 1690000,
      ));

  group('received', () {
    test('a lock to a wallet key is taken on with its lock, whatever the sender named', () async {
      await receive(_txid('a'), _lockTo(address), address);

      final utxo = wallet.currentState.utxos['${_txid('a')}:0']!;
      expect(utxo.pluginMetadata, {
        'pluginId': 'hodlocker',
        'scriptType': 'hodlocker',
        'lockHeight': _lockHeight,
        'ownerAddress': address,
      });
      expect(utxo.isPluginManaged, isTrue);
      expect(WalletBalances.isSpendable(wallet.currentState, utxo), isFalse,
          reason: 'a locked coin is never selected for a payment');
    });

    test('on the read model it is locked balance and nothing else', () async {
      await receive(_txid('a'), _lockTo(address), address);
      await wallet.commandHandler(ReceiveUTXOCommand(
        walletId: _walletId,
        txid: _txid('b'),
        vout: 0,
        satoshis: BigInt.from(5000),
        scriptPubKey: _p2pkh(address).toHex(),
        address: address,
        initialStatus: UTXOStatus.available,
        blockHeight: 1690000,
      ));

      final storage = await project();
      final rows = await storage.getUTXOs(_walletId, includeSpent: true);
      expect(HodlockerLock.lockedSatoshis(rows), BigInt.from(90000));
      expect((await storage.getPaymentUTXOs(_walletId)).map((u) => u.key), ['${_txid('b')}:0']);
      expect(await storage.getBalance(_walletId), BigInt.from(5000));
      final lockRow = rows.singleWhere((u) => u.key == '${_txid('a')}:0');
      expect(lockRow.pluginMetadata?['lockHeight'], _lockHeight);
    });

    test('a lock to a key the wallet does not hold is refused, however it is attributed', () async {
      await expectLater(
        receive(_txid('c'), _lockTo(foreignAddress), address),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('HODLocker'))),
      );
      expect(wallet.currentState.utxos, isEmpty);
    });
  });

  group('the wallet\'s own transaction', () {
    RecordOutgoingTransactionCommand record(dartsv.Transaction tx) => RecordOutgoingTransactionCommand(
          walletId: _walletId,
          txid: tx.id,
          rawHex: tx.serialize(),
          totalInputSats: 100200,
          totalOutputSats: 100000,
          fee: 200,
          numInputs: tx.inputs.length,
          numOutputs: tx.outputs.length,
          txVersion: 1,
          txLockTime: 0,
          spentUtxoKeys: const [],
          recipientAddresses: [address],
          paymentAmount: BigInt.from(90000),
          deferSpend: true,
        );

    dartsv.Transaction txWith(List<(int, dartsv.SVScript)> outputs) {
      final tx = dartsv.Transaction()
        ..version = 1
        ..nLockTime = 0;
      tx.inputs.add(dartsv.TransactionInput(_txid('e'), 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
      for (final (sats, script) in outputs) {
        tx.outputs.add(dartsv.TransactionOutput(BigInt.from(sats), script));
      }
      return tx;
    }

    test('a lock it made to its own key is recorded as a locked coin, beside its change', () async {
      final tx = txWith([(90000, _lockTo(address)), (10000, _p2pkh(address))]);
      await wallet.commandHandler(record(tx));

      final lock = wallet.currentState.utxos['${tx.id}:0'];
      expect(lock?.pluginMetadata?['pluginId'], 'hodlocker');
      expect(lock?.pluginMetadata?['lockHeight'], _lockHeight);
      expect(wallet.currentState.utxos['${tx.id}:1']?.isPluginManaged, isFalse);
    });

    test('a lock to someone else\'s key is not the wallet\'s', () async {
      final tx = txWith([(90000, _lockTo(foreignAddress)), (10000, _p2pkh(address))]);
      await wallet.commandHandler(record(tx));

      expect(wallet.currentState.utxos.containsKey('${tx.id}:0'), isFalse);
      expect(wallet.currentState.utxos.containsKey('${tx.id}:1'), isTrue);
    });
  });
}
