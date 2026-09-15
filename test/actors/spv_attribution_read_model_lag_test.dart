/// libspiffy-29t: SPVActor decided which outputs of a received transaction
/// are the target wallet's through the read model (`isWalletAddress`,
/// `getUTXOs`). The read model is written by the wallet projection, which
/// lags the wallet aggregate's journal. A BEEF paying a freshly created
/// wallet, or a receive address generated moments earlier, validated with
/// no spendable outputs: WalletManagerActor then told the wallet nothing and
/// the payment was silently not credited (the payer believes it paid).
///
/// Now SPVActor asks the wallet (through WalletManagerActor, answered by the
/// aggregate from its event-sourced state, in its mailbox after any address
/// generation it has acknowledged) which candidate addresses and outpoints
/// are its own. A wallet that cannot answer fails the result loudly instead
/// of validating it with nothing credited.
///
/// These tests run with no wallet projection at all: the read model never
/// learns the wallet's addresses or UTXOs, the limit of a lagging
/// projection, so the outcome does not depend on scheduling.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';
import 'in_memory_event_store.dart';

/// The key the fixture transaction's output 1 pays (its m/0/0 address is
/// mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12).
const _payerXpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';
const _payerRootAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';
const _recipientMnemonic = 'legal winner thank year wave sausage worth useful '
    'legal winner thank yellow';

void main() {
  final payerKey = dartsv.HDPrivateKey.fromXpriv(_payerXpriv)
      .deriveChildNumber(0)
      .deriveChildNumber(0)
      .privateKey;
  final foreignKey = dartsv.SVPrivateKey.fromHex('11' * 32, dartsv.NetworkType.TEST).publicKey;
  final g = dartsv.Transaction.fromHex(kFixtureTxHex);

  /// Spends the fixture transaction's output 1 (2 BSV) to [outputs].
  dartsv.Transaction spendFixture(List<(dartsv.LockingScriptBuilder, int)> outputs) {
    final out = g.outputs[1];
    final builder = dartsv.TransactionBuilder()
      ..spendFromOutpointWithSigner(
        dartsv.DefaultTransactionSigner(
            dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, payerKey),
        dartsv.TransactionOutpoint(g.id, 1, out.satoshis, out.script),
        dartsv.TransactionInput.MAX_SEQ_NUMBER,
        dartsv.P2PKHUnlockBuilder(payerKey.publicKey),
      );
    for (final (lock, sats) in outputs) {
      builder.spendToLockBuilder(lock, BigInt.from(sats));
    }
    builder.withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);
    return builder.build(false);
  }

  Uint8List bytes(String txHex) => Uint8List.fromList(hex.decode(txHex));

  /// The fixture transaction alone, with its proof.
  BEEF fixtureBeef() => BEEF.create(
        bumps: [fixtureBump()],
        txs: [bytes(kFixtureTxHex)],
        hasMerkle: [true],
        bumpIndex: [0],
      );

  /// An unproven [payment] of the fixture's output 1, with the fixture as
  /// its proven ancestor.
  BEEF paymentBeef(dartsv.Transaction payment) => BEEF.create(
        bumps: [fixtureBump()],
        txs: [bytes(kFixtureTxHex), bytes(payment.serialize())],
        hasMerkle: [true, false],
        bumpIndex: [0],
      );

  late LocalActorSystem system;
  late InMemoryEventStore eventStore;
  late ActorRef walletManager;
  late ActorRef spv;
  late InMemoryWalletStorage readModel;

  setUp(() async {
    system = LocalActorSystem(ActorSystemConfig());
    eventStore = InMemoryEventStore();
    // The read model: block headers only. No projection writes to it, so it
    // never knows any wallet's addresses or UTXOs.
    readModel = InMemoryWalletStorage();
    await readModel.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    walletManager = await system.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: eventStore,
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
        aggregateIdleTimeout: null,
      ),
    );
    final invoices = await system.spawn('invoices', () => _Sink());
    spv = await system.spawn(
      'spv',
      () => SPVActor(walletManager: walletManager, invoiceCoordinator: invoices, storage: readModel),
    );
  });

  tearDown(() => system.shutdown());

  List<Event> journal(String walletId) => eventStore.journal['BitcoinWallet_$walletId'] ?? const [];

  Future<String> createWallet(String walletId, {String? mnemonic, String? xpriv}) async {
    final created = await walletManager.ask<WalletCreatedMessage>(
      CreateWalletMessage(walletId, walletId, mnemonic: mnemonic, xpriv: xpriv),
      const Duration(seconds: 10),
    );
    expect(created.success, isTrue, reason: created.error);
    return created.rootAddress;
  }

  Future<AddressGeneratedResponse> generateAddress(String walletId) async {
    final generated = await walletManager.ask<AddressGeneratedResponse>(
      WalletCommandMessage(walletId, GenerateAddressCommand(walletId: walletId, includePublicKey: true)),
      const Duration(seconds: 10),
    );
    expect(generated.success, isTrue, reason: generated.error);
    return generated;
  }

  var receiverCount = 0;
  Future<SPVValidationResult> receive(String walletId, String txid, BEEF beef) async {
    final done = Completer<SPVValidationResult>();
    final receiver = await system.spawn('receiver-${receiverCount++}', () => _Receiver(done));
    spv.tell(
      ReceiveTransactionMessage(transactionId: txid, beef: beef, fromCounterparty: 'payer', targetWalletId: walletId),
      sender: receiver,
    );
    return done.future.timeout(const Duration(seconds: 20));
  }

  /// Waits until the wallet has journaled the import of [txid]. The wallet
  /// manager tells the wallet its received UTXOs and spends before the
  /// import, and the aggregate's mailbox is FIFO, so by then every command
  /// the SPV result produced has been handled.
  Future<TransactionImportedEvent> settled(String walletId, String txid) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      final imported = journal(walletId).whereType<TransactionImportedEvent>().where((e) => e.txid == txid);
      if (imported.isNotEmpty) return imported.single;
      if (DateTime.now().isAfter(deadline)) fail('wallet $walletId never recorded $txid');
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  Iterable<UTXOReceivedEvent> received(String walletId, String txid) =>
      journal(walletId).whereType<UTXOReceivedEvent>().where((e) => e.txid == txid);

  test('a payment to a freshly generated receive address is credited before the read model knows the address',
      () async {
    await createWallet('recipient', mnemonic: _recipientMnemonic);
    final address = (await generateAddress('recipient')).address;

    final payment = spendFixture([
      (dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(address)), 150000000),
      (dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(_payerRootAddress)), 49990000),
    ]);

    final result = await receive('recipient', payment.id, paymentBeef(payment));
    expect(result.isValid, isTrue, reason: result.validationError);
    expect([for (final u in result.spendableUTXOs) (u['vout'], u['address'])], [(0, address)],
        reason: 'the output paying the wallet\'s generated address is the wallet\'s');

    final imported = await settled('recipient', payment.id);
    expect([for (final e in received('recipient', payment.id)) (e.vout, e.address, e.satoshis)],
        [(0, address, 150000000)],
        reason: 'the payment must be credited to the wallet');
    expect(imported.walletReceivingAddresses, [address]);
    expect(imported.walletReceivedSats, 150000000);
    expect(imported.rawHex, payment.serialize(), reason: 'the transaction is recorded whole');
  });

  test('a multisig output locked to a freshly generated wallet key is attributed from the wallet\'s own keys',
      () async {
    await createWallet('escrow', mnemonic: _recipientMnemonic);
    final generated = await generateAddress('escrow');
    final walletKey = dartsv.SVPublicKey.fromHex(generated.publicKeyHex!);

    final payment = spendFixture([
      // Spendable by the wallet alone: a wallet UTXO.
      (dartsv.P2MSLockBuilder([walletKey, foreignKey], 1, sorting: false), 100000000),
      // Needs the foreign key's signature too: not a wallet UTXO (bead viy).
      (dartsv.P2MSLockBuilder([walletKey, foreignKey], 2, sorting: false), 99990000),
    ]);

    final result = await receive('escrow', payment.id, paymentBeef(payment));
    expect(result.isValid, isTrue, reason: result.validationError);

    final imported = await settled('escrow', payment.id);
    expect([for (final e in received('escrow', payment.id)) (e.vout, e.address)], [(0, generated.address)],
        reason: 'the 1-of-2 output holding the wallet\'s generated key is the wallet\'s; the 2-of-2 is not');
    expect(imported.walletReceivedSats, 100000000);
  });

  test('a freshly created wallet is credited, and its spend of that output is attributed, before the read model catches up',
      () async {
    final root = await createWallet('fresh', xpriv: _payerXpriv);
    expect(root, _payerRootAddress);

    final first = await receive('fresh', kFixtureTxid, fixtureBeef());
    expect(first.isValid, isTrue, reason: first.validationError);
    await settled('fresh', kFixtureTxid);
    expect([for (final e in received('fresh', kFixtureTxid)) (e.vout, e.address)], [(1, _payerRootAddress)],
        reason: 'the fixture pays the new wallet\'s root address');

    // The wallet's own spend of that UTXO arrives (e.g. from another device).
    final foreign = dartsv.P2PKHLockBuilder.fromAddress(foreignKey.toAddress(dartsv.NetworkType.TEST));
    final spend = spendFixture([(foreign, 199990000)]);
    final second = await receive('fresh', spend.id, paymentBeef(spend));
    expect(second.isValid, isTrue, reason: second.validationError);
    expect([for (final s in second.spentUTXOs) '${s['txid']}:${s['vout']}'], ['$kFixtureTxid:1'],
        reason: 'the input spends a UTXO the wallet holds');

    await settled('fresh', spend.id);
    expect(
      journal('fresh').whereType<UTXOSpentEvent>().where((e) => e.txid == kFixtureTxid && e.vout == 1),
      [isA<UTXOSpentEvent>().having((e) => e.spentInTxId, 'spentInTxId', spend.id)],
    );
  });

  test('a watch address, which only the read model records, is still credited', () async {
    await createWallet('watcher', mnemonic: _recipientMnemonic);
    final watchAddress = foreignKey.toAddress(dartsv.NetworkType.TEST).toBase58();
    // What RegisterWatchAddressCommand writes: a read-model row, no event.
    await readModel.upsertAddress('watcher', AddressMetadata(
      address: watchAddress,
      scriptType: 'p2pkh',
      isChange: false,
      purpose: 'watch',
      usageCount: 0,
      balance: BigInt.zero,
      createdAt: DateTime.now(),
      isWatched: true,
    ));

    final payment = spendFixture([(dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(watchAddress)), 199990000)]);
    final result = await receive('watcher', payment.id, paymentBeef(payment));
    expect(result.isValid, isTrue, reason: result.validationError);
    await settled('watcher', payment.id);
    expect([for (final e in received('watcher', payment.id)) e.address], [watchAddress]);
  });

  test('a payment for a wallet nobody knows fails loudly instead of validating with nothing credited', () async {
    final result = await receive('no-such-wallet', kFixtureTxid, fixtureBeef());
    expect(result.isValid, isFalse,
        reason: 'the outputs cannot be attributed, so the result must not claim the payment was received');
    expect(result.validationError, contains('no-such-wallet'));
  });
}

class _Sink extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

class _Receiver extends Actor {
  final Completer<SPVValidationResult> done;
  _Receiver(this.done);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is SPVValidationResult && !done.isCompleted) done.complete(message);
  }
}
