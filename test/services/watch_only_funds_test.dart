/// Bead libspiffy-wdch, item 4: `splitWatchOnlyUtxos` listed a bare multisig
/// UTXO the wallet cannot spend alone (a journal written before bead viy can
/// hold one: a channel's 2-of-2 funding output, an escrow) as signable, so a
/// selection outside the wallet aggregate picked it and the payment failed
/// at signing. It now applies the read side's rule (`splitBalanceUtxos`,
/// spv-understanding.md "Balances"): spendable, watch-only, cannot spend
/// alone.
library;

// The wallet manager stand-in passes replies on through dactor's @internal
// `Actor.context`.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/payment_coordinator_actor.dart';
import 'package:libspiffy/src/actors/payment_messages.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/services/watch_only_funds.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import 'package:libspiffy/src/utils/crypto_utils.dart';
import 'package:spiffynode/spiffy_node.dart' show BlockHeader, Hash;

import '../actors/in_memory_event_store.dart';

const _walletId = 'watch-only-funds';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _externalAddress = 'n4VQ5YdHf7hLQ2gWQYYrcxoE5B7nWuDFNF'; // testnet, not ours

String _txid(int n) => n.toRadixString(16).padLeft(64, '0');
String _key(int n) => '${_txid(n)}:0';

final _otherKey = dartsv.SVPrivateKey.fromHex('11' * 32, dartsv.NetworkType.TEST).publicKey;
final _watchKey = dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST).publicKey;
final _watchAddress = _watchKey.toAddress(dartsv.NetworkType.TEST).toBase58();

String _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();

void main() {
  late InMemoryEventStore store;
  late InMemorySecureStorage secureStorage;
  late BitcoinWalletAggregate wallet;
  late String root;
  late dartsv.SVPublicKey walletKey;

  setUp(() async {
    store = InMemoryEventStore();
    secureStorage = InMemorySecureStorage();
    wallet = BitcoinWalletAggregate(
      aggregateId: _walletId,
      aggregateType: 'BitcoinWallet',
      eventStore: store,
      cryptoService: DartSVCryptoService(),
      secureStorage: secureStorage,
    );
    await wallet.preStart();
    await wallet.commandHandler(CreateWalletCommand(walletId: _walletId, walletName: 'funds', mnemonic: _mnemonic));
    await wallet.commandHandler(GenerateAddressCommand(walletId: _walletId, includePublicKey: true));
    root = wallet.currentState.rootAddress!;
    walletKey = dartsv.SVPublicKey.fromHex(store.allEvents.whereType<AddressGeneratedEvent>().last.publicKeyHex!);
  });

  Future<void> receive(int n, int sats, {String? address, String? script, String? txid, int vout = 0}) async {
    await wallet.commandHandler(ReceiveUTXOCommand(
      walletId: _walletId,
      txid: txid ?? _txid(n),
      vout: vout,
      satoshis: BigInt.from(sats),
      scriptPubKey: script ?? _p2pkh(address ?? root),
      address: address ?? root,
      blockHeight: 900,
      confirmations: 6,
      initialStatus: UTXOStatus.available,
    ));
  }

  /// A journal written before beads viy / n0p: an escrow needing a wallet
  /// key and another party's, recorded as a wallet UTXO.
  String escrowScript() => dartsv.P2MSLockBuilder([walletKey, _otherKey], 2, sorting: false).getScriptPubkey().toHex();

  Future<void> journalLegacyEscrow(int n, int sats, {String? txid, int vout = 0}) async {
    await store.persistEvents(store.journal.keys.single, [
      UTXOReceivedEvent(
        walletId: _walletId,
        txid: txid ?? _txid(n),
        vout: vout,
        satoshis: sats,
        scriptPubKey: escrowScript(),
        address: 'p2ms:2-of-2',
        confirmations: 6,
        blockHeight: 900,
        initialStatus: UTXOStatus.available,
        version: wallet.currentState.version + 1,
        timestamp: DateTime.utc(2026, 9, 1),
      ),
    ], 0);
  }

  /// The whole journal applied to a fresh read model.
  Future<InMemoryWalletStorage> project() async {
    final storage = InMemoryWalletStorage();
    final projection = WalletProjection(projectionId: 'funds', eventStore: store, storage: storage);
    for (final event in store.allEvents) {
      await projection.handle(event);
    }
    return storage;
  }

  test('a bare multisig UTXO the wallet cannot spend alone is not signable', () async {
    await wallet.commandHandler(AddWatchAddressCommand(walletId: _walletId, address: _watchAddress, scriptType: 'p2pkh'));
    await receive(1, 40000);
    await receive(2, 30000, address: _watchAddress);
    // 1-of-2 over a wallet key: the wallet signs it alone.
    await receive(3, 20000, script: dartsv.P2MSLockBuilder([walletKey, _otherKey], 1, sorting: false).getScriptPubkey().toHex());
    await journalLegacyEscrow(4, 100000);
    final storage = await project();

    final split = await splitWatchOnlyUtxos(storage, _walletId, await storage.getPaymentUTXOs(_walletId));

    // Old code: the escrow (_key(4)) was listed as signable.
    expect(split.signable.map((u) => u.key).toSet(), {_key(1), _key(3)});
    expect(split.watchOnly.map((u) => u.key), [_key(2)]);
    expect(split.notSpendableAlone.map((u) => u.key), [_key(4)]);
    expect(split.watchOnlyNote, contains('30000 satoshis'));
    expect(split.excludedNote, allOf(contains('30000 satoshis'), contains('100000 satoshis')));
  });

  test('a payment is funded from a UTXO the wallet can spend, not a larger escrow it cannot spend alone', () async {
    // One proven parent pays the wallet 40 000 sat (P2PKH, vout 0) and the
    // escrow 100 000 sat (vout 1).
    final parent = dartsv.Transaction()
      ..version = 2
      ..nLockTime = 0;
    parent.inputs.add(dartsv.TransactionInput(_txid(99), 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    parent.outputs.add(dartsv.TransactionOutput(BigInt.from(40000), dartsv.SVScript.fromHex(_p2pkh(root))));
    parent.outputs.add(dartsv.TransactionOutput(BigInt.from(100000), dartsv.SVScript.fromHex(escrowScript())));
    final p2pkhKey = '${parent.id}:0';
    final escrowKey = '${parent.id}:1';
    await receive(0, 40000, txid: parent.id, vout: 0);
    await journalLegacyEscrow(0, 100000, txid: parent.id, vout: 1);
    final storage = await project();
    expect((await storage.getPaymentUTXOs(_walletId)).map((u) => u.key).toSet(), {p2pkhKey, escrowKey},
        reason: 'the escrow row is kept');
    final bump = CryptoUtils.createBumpFromTscProof({
      'index': 0,
      'txOrId': parent.id,
      'target': '00' * 32,
      'nodes': ['ab' * 32],
    }, 900);
    await storage.storeBlockHeader(
        BlockHeader(
          version: 536870912,
          prevBlock: Hash.fromHex('00' * 32),
          merkleRoot: Hash.fromBytes(bump.computeMerkleRoot(Uint8List.fromList(hex.decode(parent.id).reversed.toList()))),
          timestamp: DateTime.utc(2026, 9, 1),
          bits: 0x1d00ffff,
          nonce: 1,
        ),
        900);
    await storage.storeTransaction(
        _walletId,
        BitcoinTransaction.fromDartSvTransaction(
          walletId: _walletId,
          transaction: parent,
          status: TransactionStatus.confirmed,
          receivingAddresses: [root],
          sendingAddresses: const [],
          netAmount: BigInt.from(40000),
          blockHeight: 900,
          inputValue: BigInt.from(141000),
        ));
    await storage.storeMerkleProof(
        parent.id,
        MerkleProof(
          blockHash: '00' * 32,
          txid: parent.id,
          merkleProof: [hex.encode(bump.serialize())],
          position: 0,
          blockHeight: 900,
          status: MerkleProofStatus.verified,
        ));

    final system = LocalActorSystem(ActorSystemConfig());
    addTearDown(system.shutdown);
    final walletManager = await system.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: store,
        cryptoService: DartSVCryptoService(),
        secureStorage: secureStorage,
        aggregateIdleTimeout: null,
        readModelStorage: storage,
      ),
    );
    final observed = _ObservingWalletManager(walletManager);
    final observedRef = await system.spawn('observed-wallet-manager', () => observed);
    final projection = await system.spawn('projection', () => _AppliedProjection());
    final coordinator = await system.spawn(
      'payment-coordinator',
      () => PaymentCoordinatorActor(walletManager: observedRef, walletProjection: projection, storage: storage),
    );

    final response = await coordinator.ask<BEEFPaymentResponse>(
      PayInvoiceMessage(
        walletId: _walletId,
        invoiceId: 'inv-escrow',
        addresses: [_externalAddress],
        amount: BigInt.from(10000),
      ),
      const Duration(seconds: 30),
    );

    final reserved = [for (final c in observed.commands.whereType<ReserveUTXOCommand>()) c.utxoKey];
    // Old code: the largest UTXO, the escrow, was reserved and the payment
    // failed when the wallet could not sign it alone.
    expect(reserved, [p2pkhKey], reason: 'reserved $reserved; payment error: ${response.error}');
    expect(response.success, isTrue, reason: response.error);
  });
}

/// Passes every message on to [wallet], with its sender, and keeps the
/// wallet commands.
class _ObservingWalletManager extends Actor {
  final ActorRef wallet;
  _ObservingWalletManager(this.wallet);
  final List<WalletCommand> commands = [];

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletCommandMessage) commands.add(message.command);
    wallet.tell(message, sender: context.sender);
  }
}

/// Wallet projection stand-in: answers every wait for an applied event as
/// applied.
class _AppliedProjection extends Actor {
  @override
  Future<void> onMessage(dynamic message) async => context.sender?.tell(LocalMessage(payload: true));
}
