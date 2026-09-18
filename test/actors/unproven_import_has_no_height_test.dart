/// Bead libspiffy-nys0: a transaction imported without a merkle proof was
/// recorded at block height 0 — the genesis block — because
/// `TransactionImportedEvent.blockHeight` could not hold an absence.
///
/// SPVActor built the transaction data with `blockHeight ?? 0` and
/// WalletManagerActor read it back with `?? 0`, so an unproven receive
/// journaled a height nothing had proven. Where evidence is missing the
/// honest record is an absence (spv-understanding.md, "What this library is
/// for"), which is the rule bead libspiffy-jc3h/V-79 settled one level down
/// for UTXOs: a height means a proof puts it in a block we hold.
///
/// The aggregate and read-model halves are in
/// test/core/imported_transaction_height_test.dart.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';

import '../spv/testnet_proof_fixture.dart';
import 'in_memory_event_store.dart';
import 'wallet_ownership_stub.dart';

const _xpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

void main() {
  group('SPVActor', () {
    final key = dartsv.HDPrivateKey.fromXpriv(_xpriv).deriveChildNumber(0).deriveChildNumber(0).privateKey;
    final address = key.publicKey.toAddress(dartsv.NetworkType.TEST);
    final lock = dartsv.P2PKHLockBuilder.fromAddress(address);

    Uint8List bytes(String txHex) => Uint8List.fromList(hex.decode(txHex));

    late LocalActorSystem system;
    late InMemoryWalletStorage storage;
    late ActorRef spv;
    late dartsv.Transaction g;

    setUp(() async {
      g = dartsv.Transaction.fromHex(kFixtureTxHex);
      storage = InMemoryWalletStorage();
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      system = LocalActorSystem(ActorSystemConfig());
      final sink = await system.spawn('sink', () => _Sink());
      spv = await system.spawn(
          'spv', () => SPVActor(walletManager: sink, invoiceCoordinator: sink, storage: storage));
    });

    tearDown(() => system.shutdown());

    Future<SPVValidationResult> receive(String txid, BEEF beef) async {
      final done = Completer<SPVValidationResult>();
      final receiver = await system.spawn(
          'receiver-${DateTime.now().microsecondsSinceEpoch}', () => _Receiver(done));
      spv.tell(
        ReceiveTransactionMessage(
            transactionId: txid, beef: beef, fromCounterparty: 'alice', targetWalletId: 'w'),
        sender: receiver,
      );
      return done.future.timeout(const Duration(seconds: 10));
    }

    /// An unproven payment spending the proven fixture transaction: the BEEF
    /// carries a BUMP for the parent and none for the payment itself.
    dartsv.Transaction unprovenPayment() {
      final builder = dartsv.TransactionBuilder();
      final out = g.outputs[1];
      builder.spendFromOutpointWithSigner(
        dartsv.DefaultTransactionSigner(
            dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, key),
        dartsv.TransactionOutpoint(g.id, 1, out.satoshis, out.script),
        dartsv.TransactionInput.MAX_SEQ_NUMBER,
        dartsv.P2PKHUnlockBuilder(key.publicKey),
      );
      builder.spendToLockBuilder(lock, BigInt.from(399000000));
      builder.withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);
      return builder.build(false);
    }

    test('an unproven transaction is built with no block height, not height 0', () async {
      final pay = unprovenPayment();
      final beef = BEEF.create(
        bumps: [fixtureBump()],
        txs: [bytes(kFixtureTxHex), bytes(pay.serialize())],
        hasMerkle: [true, false],
        bumpIndex: [0],
      );

      final result = await receive(pay.id, beef);
      expect(result.isValid, isTrue, reason: result.validationError);
      expect(result.transactionData!['bumpProof'], isEmpty, reason: 'no proof came with it');
      expect(result.transactionData!['blockHeight'], isNull,
          reason: 'nothing proves which block it is in, so it is in none we know of');
    });

    test('a proven transaction still carries the height its BUMP proves', () async {
      final beef = BEEF.create(
        bumps: [fixtureBump()],
        txs: [bytes(kFixtureTxHex)],
        hasMerkle: [true],
        bumpIndex: [0],
      );

      final result = await receive(kFixtureTxid, beef);
      expect(result.isValid, isTrue, reason: result.validationError);
      expect(result.transactionData!['blockHeight'], kFixtureHeight);
    });
  });

  group('WalletManagerActor', () {
    late TestActorSystem actorSystem;
    late InMemoryEventStore eventStore;
    late ActorRef walletManager;

    setUp(() async {
      actorSystem = TestActorSystem();
      eventStore = InMemoryEventStore();
      walletManager = await actorSystem.spawn(
        'wallet-manager',
        () => WalletManagerActor(
          eventStore: eventStore,
          cryptoService: DartSVCryptoService(),
          secureStorage: InMemorySecureStorage(),
        ),
      );
    });

    tearDown(() async => actorSystem.shutdown());

    List<Event> journal(String walletId) => eventStore.journal['BitcoinWallet_$walletId'] ?? const [];

    Future<TransactionImportedEvent> imported(String walletId, String txid) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (true) {
        final found =
            journal(walletId).whereType<TransactionImportedEvent>().where((e) => e.txid == txid);
        if (found.isNotEmpty) return found.first;
        if (DateTime.now().isAfter(deadline)) fail('$walletId never recorded $txid');
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }

    SPVValidationResult result(String txid, String address, {int? blockHeight, String bumpProof = ''}) =>
        SPVValidationResult(
          txid: txid,
          isValid: true,
          targetWalletId: 'w',
          spendableUTXOs: [
            {
              'txid': txid,
              'vout': 0,
              'satoshis': 5000,
              'script': '76a914000000000000000000000000000000000000000088ac',
              'address': address,
            },
          ],
          transactionData: {
            'rawHex': '00',
            'blockHeight': blockHeight,
            'bumpProof': bumpProof,
            'totalOutputSats': 5000,
            'numInputs': 1,
            'numOutputs': 1,
            'txVersion': 1,
            'txLockTime': 0,
            'walletReceivingAddresses': [address],
            'walletReceivedSats': 5000,
            'totalInputSats': 6000,
            'sendingAddresses': <String>[],
          },
        );

    test('an unproven receive journals no block height, and a proven one journals its own', () async {
      final created = await walletManager.ask<WalletCreatedMessage>(
        CreateWalletMessage('w', 'W', mnemonic: _mnemonic),
        const Duration(seconds: 10),
      );
      expect(created.success, isTrue, reason: created.error);

      final unproven = 'aa' * 32;
      walletManager.tell(result(unproven, created.rootAddress));
      expect((await imported('w', unproven)).blockHeight, isNull,
          reason: 'an import with no proof recorded a height nothing proved');

      final proven = 'bb' * 32;
      walletManager.tell(result(proven, created.rootAddress,
          blockHeight: kFixtureHeight, bumpProof: fixtureBumpHex()));
      expect((await imported('w', proven)).blockHeight, kFixtureHeight);
    });
  });
}

/// Wallet manager and invoice coordinator stand-in; answers SPVActor's
/// ownership query (every wallet exists and owns nothing).
class _Sink extends WalletOwnershipStub {}

class _Receiver extends Actor {
  final Completer<SPVValidationResult> done;
  _Receiver(this.done);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is SPVValidationResult && !done.isCompleted) done.complete(message);
  }
}
