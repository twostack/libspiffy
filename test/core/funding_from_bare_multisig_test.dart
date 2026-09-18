/// 8egy (libspiffy-8egy), channel funding part: a bare multisig output the
/// wallet can spend alone, and a P2PK output locked to a wallet key, are the
/// wallet's own money (beads viy, n0p). `BuildFundingTransactionCommand` used
/// to sign every funding input as P2PKH, so under bead libspiffy-nlp it
/// selected them out altogether and the money could not fund a channel at
/// all. It now spends them with their own unlocking scripts
/// (`WalletTransactionSigner.unlockFor`): `OP_0 <sig>...` for bare multisig,
/// `<sig>` for P2PK.
///
/// What is still refused is an output the wallet cannot unlock on its own —
/// a channel's own 2-of-2 funding output, whose second signature belongs to
/// the counterparty.
///
/// The fee estimate follows: a bare multisig or P2PK input is not 148 bytes.
library;

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _walletId = 'wallet-funding-multisig';

/// The fee policy channel funding estimates with (satoshis per 1000 bytes).
const _feePerKb = 100;

void main() {
  late TestActorSystem system;
  var spawned = 0;
  final clientKey = dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST);
  final serverKey = dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST);
  final otherKey = dartsv.SVPrivateKey.fromHex('11' * 32, dartsv.NetworkType.TEST).publicKey;

  setUp(() => system = TestActorSystem());
  tearDown(() => system.shutdown());

  /// A wallet holding a UTXO worth [multisigSats] locked by a
  /// [threshold]-of-2 multisig script over a wallet key and [otherKey] (or,
  /// with [p2pk], a P2PK script to the wallet key) and, when [p2pkhSats] is
  /// given, a P2PKH UTXO; builds a 30 000 sat funding transaction. Returns
  /// the reply and the funded scripts by outpoint.
  Future<(FundingTransactionBuiltResponse, Map<String, (String, int)>)> buildFunding(
      {required int multisigSats, int? p2pkhSats, bool p2pk = false, int threshold = 1}) async {
    final store = InMemoryEventStore();
    final secureStorage = InMemorySecureStorage();
    final cryptoService = DartSVCryptoService();
    final setup = BitcoinWalletAggregate(
      aggregateId: _walletId,
      aggregateType: 'BitcoinWallet',
      eventStore: store,
      cryptoService: cryptoService,
      secureStorage: secureStorage,
    );
    await setup.preStart();
    await setup
        .commandHandler(CreateWalletCommand(walletId: _walletId, walletName: 'multisig funding', mnemonic: _mnemonic));
    await setup.commandHandler(GenerateAddressCommand(walletId: _walletId, includePublicKey: true));
    final root = setup.currentState.rootAddress!;
    final generated = store.allEvents.whereType<AddressGeneratedEvent>().last;
    final second = generated.address;
    expect(second, isNot(root));
    final walletKey = dartsv.SVPublicKey.fromHex(generated.publicKeyHex!);

    final funded = <String, (String, int)>{};
    /// Journals the UTXO without going through [ReceiveUTXOCommand], which
    /// refuses a bare multisig output the wallet cannot spend alone (beads
    /// viy, n0p). A journal written before that rule holds such rows, and
    /// replay keeps them.
    Future<void> receiveLegacy(String txid, String scriptHex, String address, int sats) async {
      await store.persistEvent(
        'BitcoinWallet_$_walletId',
        UTXOReceivedEvent(
          walletId: _walletId,
          txid: txid,
          vout: 0,
          satoshis: sats,
          scriptPubKey: scriptHex,
          address: address,
          initialStatus: UTXOStatus.available,
          blockHeight: 800000,
          confirmations: 6,
          version: setup.currentState.version + 1,
          timestamp: DateTime.now(),
        ),
        setup.currentState.version,
      );
      funded['$txid:0'] = (scriptHex, sats);
    }

    Future<void> receive(String txid, String scriptHex, String address, int sats) async {
      await setup.commandHandler(ReceiveUTXOCommand(
        walletId: _walletId,
        txid: txid,
        vout: 0,
        satoshis: BigInt.from(sats),
        scriptPubKey: scriptHex,
        address: address,
        initialStatus: UTXOStatus.available,
        blockHeight: 800000,
        confirmations: 6,
      ));
      funded['$txid:0'] = (scriptHex, sats);
    }

    // Over the generated address's key: at threshold 1 the wallet can spend
    // it alone; at threshold 2 it also needs [otherKey]'s signature.
    final scriptHex = p2pk
        ? '21${walletKey.toHex()}ac'
        : dartsv.P2MSLockBuilder([walletKey, otherKey], threshold, sorting: false).getScriptPubkey().toHex();
    await (threshold > 1 ? receiveLegacy : receive)('b' * 64, scriptHex, second, multisigSats);
    if (p2pkhSats != null) {
      await receive(
          'c' * 64,
          dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(root)).getScriptPubkey().toHex(),
          root,
          p2pkhSats);
    }

    final ActorRef walletRef = await system.spawn(
      'wallet-${spawned++}',
      () => BitcoinWalletAggregate(
        aggregateId: _walletId,
        aggregateType: 'BitcoinWallet',
        eventStore: store,
        cryptoService: cryptoService,
        secureStorage: secureStorage,
      ),
    );
    final probe = await system.createProbe();
    walletRef.tell(
      BuildFundingTransactionCommand(
        walletId: _walletId,
        correlationId: 'corr-$spawned',
        channelId: 'channel-multisig',
        clientPubKeyHex: clientKey.publicKey.toHex(),
        serverPubKeyHex: serverKey.publicKey.toHex(),
        fundingAmountSats: 30000,
        changeAddressBase58: root,
      ),
      sender: probe.ref,
    );
    final response = await probe.expectMsgType<FundingTransactionBuiltResponse>(timeout: const Duration(seconds: 10));
    return (response, funded);
  }

  /// Runs every input of [tx] through the script interpreter against the
  /// locking script it actually spends.
  void expectInputsVerify(dartsv.Transaction tx, Map<String, (String, int)> funded) {
    for (var i = 0; i < tx.inputs.length; i++) {
      final (scriptHex, sats) = funded['${tx.inputs[i].prevTxnId}:${tx.inputs[i].prevTxnOutputIndex}']!;
      dartsv.Interpreter().correctlySpends(
        tx.inputs[i].script!,
        dartsv.SVScript.fromHex(scriptHex),
        tx,
        i,
        {dartsv.VerifyFlag.SIGHASH_FORKID, dartsv.VerifyFlag.UTXO_AFTER_GENESIS},
        dartsv.Coin.ofSat(BigInt.from(sats)),
      );
    }
  }

  for (final p2pk in [false, true]) {
    final kind = p2pk ? 'P2PK' : 'bare multisig';

    test('8egy: channel funding spends a $kind wallet UTXO and its input verifies', () async {
      final (response, funded) = await buildFunding(multisigSats: 90000, p2pk: p2pk);

      expect(response.success, isTrue, reason: response.error);
      final tx = dartsv.Transaction.fromHex(response.fundingTxHex);
      expect(tx.inputs.map((i) => '${i.prevTxnId}:${i.prevTxnOutputIndex}'), ['${'b' * 64}:0']);
      expectInputsVerify(tx, funded);
    });

    test('8egy: a $kind UTXO is selected ahead of a smaller P2PKH one, and both kinds verify', () async {
      // Largest first: the non-P2PKH UTXO now competes on amount like any
      // other. 30 000 + fee fits in it alone, so it is the only input.
      final (response, funded) = await buildFunding(multisigSats: 90000, p2pkhSats: 50000, p2pk: p2pk);

      expect(response.success, isTrue, reason: response.error);
      final tx = dartsv.Transaction.fromHex(response.fundingTxHex);
      expect(tx.inputs.map((i) => '${i.prevTxnId}:${i.prevTxnOutputIndex}'), ['${'b' * 64}:0']);
      expectInputsVerify(tx, funded);
    });

    test('8egy: a $kind funding transaction reports its real fee and pays the policy rate', () async {
      final (response, _) = await buildFunding(multisigSats: 90000, p2pk: p2pk);

      expect(response.success, isTrue, reason: response.error);
      final tx = dartsv.Transaction.fromHex(response.fundingTxHex);
      final outputTotal = tx.outputs.fold<int>(0, (sum, o) => sum + o.satoshis.toInt());

      // The reported fee is the transaction's own: inputs minus outputs.
      expect(response.fee, response.totalInputSats - outputTotal);
      expect(response.totalOutputSats, outputTotal);
      expect(response.changeAmount, tx.outputs[response.changeOutputIndex!].satoshis.toInt());

      // And it covers the standard policy fee for the size actually broadcast:
      // a fee estimate built on 148-byte P2PKH inputs does not describe this
      // transaction. (BSV has no fee auction; the policy rate is the whole
      // requirement.)
      final sizeBytes = response.fundingTxHex.length ~/ 2;
      expect(response.fee, greaterThanOrEqualTo(sizeBytes * _feePerKb ~/ 1000));
    });
  }

  test('8egy: a 2-of-2 output the counterparty must co-sign still cannot fund a channel', () async {
    final (response, _) = await buildFunding(multisigSats: 90000, threshold: 2);

    expect(response.success, isFalse);
    expect(response.error, contains('cannot unlock on its own'));
  });
}
