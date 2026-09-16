/// libspiffy-5ry: `ReceiveUTXOCommand` took a block height and a confirmation
/// count while leaving `initialStatus` at its `pending` default, so a caller
/// who handed the wallet everything a mined UTXO has ended up with a wallet
/// that reports nothing spendable and says nothing about why (it cost the
/// payment_api and transaction_history fixtures real debugging time).
///
/// The SPV model settles which way the trap is closed: a block height is
/// evidence only when a merkle proof produced it, so the command may not
/// derive `available` from a caller-supplied height — that would let a caller
/// conjure spendable funds with no proof at all. What it can do is refuse the
/// contradiction: a height with `pending` is rejected at construction, where
/// the error reaches the caller (the senders of this command `tell()` it
/// without a sender, so an error raised inside the aggregate is dropped).
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';

const _w = '5ry-wallet';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

String _txid(int n) => n.toRadixString(16).padLeft(64, '0');

String _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();

/// A wallet aggregate driven without an actor system.
class _Wallet {
  final BitcoinWalletAggregate aggregate = BitcoinWalletAggregate(
    aggregateId: _w,
    aggregateType: 'BitcoinWallet',
    eventStore: InMemoryEventStore(),
    cryptoService: DartSVCryptoService(),
    secureStorage: InMemorySecureStorage(),
  );

  late String root;

  WalletState get state => aggregate.state ?? aggregate.createInitialState();

  static Future<_Wallet> create() async {
    final wallet = _Wallet();
    await wallet.handle(CreateWalletCommand(walletId: _w, walletName: '5ry', mnemonic: _mnemonic));
    wallet.root = wallet.state.rootAddress!;
    return wallet;
  }

  Future<List<Event>> handle(WalletCommand command) async {
    final events = await aggregate.handleCommand(state, command);
    for (final e in events) {
      aggregate.eventHandler(e);
    }
    return events;
  }
}

void main() {
  late _Wallet wallet;

  setUp(() async {
    wallet = await _Wallet.create();
  });

  /// The command a fixture writes when it hands the wallet a mined UTXO: the
  /// height and the confirmation count it has, and no `initialStatus`.
  ReceiveUTXOCommand fixtureReceive() => ReceiveUTXOCommand(
        walletId: _w,
        txid: _txid(1),
        vout: 0,
        satoshis: BigInt.from(100000),
        scriptPubKey: _p2pkh(wallet.root),
        address: wallet.root,
        blockHeight: 800000,
        confirmations: 6,
      );

  group('libspiffy-5ry: a block height and a pending status are contradictory', () {
    test('a receive carrying a block height with the default status is rejected, naming the fix', () {
      expect(
        fixtureReceive,
        throwsA(isA<ArgumentError>().having((e) => e.message.toString(), 'message',
            allOf(contains('blockHeight'), contains('initialStatus'), contains('UTXOStatus.available')))),
      );
    });

    test('the API never leaves a caller with mined funds that are not spendable', () async {
      // Either the command is refused, or the wallet can spend what it took.
      ReceiveUTXOCommand? command;
      try {
        command = fixtureReceive();
      } on ArgumentError {
        command = null;
      }
      if (command == null) return;

      await wallet.handle(command);
      expect(wallet.state.availableBalance, BigInt.from(100000),
          reason: 'the command was accepted with a block height and 6 confirmations, '
              'so the funds it recorded must be spendable');
    });

    test('a receive with an explicit status keeps its height and is spendable', () async {
      await wallet.handle(ReceiveUTXOCommand(
        walletId: _w,
        txid: _txid(2),
        vout: 0,
        satoshis: BigInt.from(70000),
        scriptPubKey: _p2pkh(wallet.root),
        address: wallet.root,
        blockHeight: 800000,
        confirmations: 6,
        initialStatus: UTXOStatus.available,
      ));

      final utxo = wallet.state.utxos['${_txid(2)}:0'];
      expect(utxo!.status, UTXOStatus.available);
      expect(utxo.blockHeight, 800000);
      expect(wallet.state.availableBalance, BigInt.from(70000));
    });

    test('an unproven receive (no height) still defaults to pending', () async {
      await wallet.handle(ReceiveUTXOCommand(
        walletId: _w,
        txid: _txid(3),
        vout: 0,
        satoshis: BigInt.from(50000),
        scriptPubKey: _p2pkh(wallet.root),
        address: wallet.root,
        confirmations: 0,
      ));

      final utxo = wallet.state.utxos['${_txid(3)}:0'];
      expect(utxo!.status, UTXOStatus.pending);
      expect(utxo.blockHeight, isNull);
      expect(wallet.state.availableBalance, BigInt.zero);
    });
  });
}
