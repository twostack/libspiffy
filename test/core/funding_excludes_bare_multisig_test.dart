/// nlp (libspiffy-nlp), channel funding part: BuildFundingTransactionCommand
/// signs every funding input as P2PKH for the UTXO's address. A bare
/// multisig output the wallet can spend alone is a wallet UTXO (beads viy,
/// n0p), attributed to the first wallet key's address; selected for a
/// channel funding it got a P2PKH signature over a P2PKH subscript, an input
/// no node accepts, and the funding transaction was handed out regardless.
/// Channel funding now selects only UTXOs it can sign; the same holds for a
/// P2PK UTXO (`<key> OP_CHECKSIG`).
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

void main() {
  late TestActorSystem system;
  var spawned = 0;
  final clientKey = dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST);
  final serverKey = dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST);
  final otherKey = dartsv.SVPrivateKey.fromHex('11' * 32, dartsv.NetworkType.TEST).publicKey;

  setUp(() => system = TestActorSystem());
  tearDown(() => system.shutdown());

  /// A wallet holding a UTXO worth [multisigSats] locked by a 1-of-2
  /// multisig script over a wallet key (or, with [p2pk], a P2PK script to
  /// that key) and, when [p2pkhSats] is given, a P2PKH UTXO; builds a
  /// 30 000 sat funding transaction. Returns the reply and the funded scripts
  /// by outpoint.
  Future<(FundingTransactionBuiltResponse, Map<String, (String, int)>)> buildFunding(
      {required int multisigSats, int? p2pkhSats, bool p2pk = false}) async {
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

    // Over the generated address's key: the wallet can spend it alone.
    await receive(
        'b' * 64,
        p2pk
            ? '21${walletKey.toHex()}ac'
            : dartsv.P2MSLockBuilder([walletKey, otherKey], 1, sorting: false).getScriptPubkey().toHex(),
        second,
        multisigSats);
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

  for (final p2pk in [false, true]) {
    test(
        'nlp: channel funding spends the P2PKH UTXO, not a larger ${p2pk ? 'P2PK' : 'multisig'} one, '
        'and every input verifies', () async {
      final (response, funded) = await buildFunding(multisigSats: 90000, p2pkhSats: 50000, p2pk: p2pk);

      expect(response.success, isTrue, reason: response.error);
      final tx = dartsv.Transaction.fromHex(response.fundingTxHex);
      expect(tx.inputs.map((i) => '${i.prevTxnId}:${i.prevTxnOutputIndex}'), ['${'c' * 64}:0']);
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
    });
  }

  test('nlp: channel funding from a wallet whose only UTXO is multisig is refused with the reason', () async {
    final (response, _) = await buildFunding(multisigSats: 90000);

    expect(response.success, isFalse);
    expect(response.error, contains('multisig'));
  });
}
