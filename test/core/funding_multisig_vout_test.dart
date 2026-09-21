/// Audit 2026-09-14 SPV-13 (libspiffy-bfh), funding-transaction part:
/// BitcoinWalletAggregate located the 2-of-2 multisig output of a channel
/// funding transaction by amount. When the change output carries the same
/// amount as the funding output, the lookup reported the change output's
/// index as the funding outpoint, so the refund and every payment transaction
/// would spend the client's change instead of the channel. dartsv's
/// TransactionBuilder puts the change output first, where the last-match
/// amount lookup found the multisig output by accident but lost the change
/// output (changeOutputIndex null); with the other order it reported the
/// change output as the funding outpoint.
library;

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';
import 'package:libspiffy/src/models/fee_rate.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';
const _walletId = 'wallet-funding-vout';
const _fundingAmount = 30000;

void main() {
  late TestActorSystem system;
  var spawned = 0;
  final clientKey = dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST);
  final serverKey = dartsv.SVPrivateKey(networkType: dartsv.NetworkType.TEST);

  setUp(() => system = TestActorSystem());
  tearDown(() => system.shutdown());

  /// A wallet holding one confirmed UTXO of [utxoSats] builds a funding
  /// transaction for [_fundingAmount]; returns the reply.
  Future<FundingTransactionBuiltResponse> buildFunding(int utxoSats) async {
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
    await setup.commandHandler(CreateWalletCommand(
        walletId: _walletId, walletName: 'vout', mnemonic: _mnemonic));
    await setup.commandHandler(
        GenerateAddressCommand(walletId: _walletId, label: 'funding'));
    final address = setup.currentState.addresses.keys.last;
    await setup.commandHandler(ReceiveUTXOCommand(
      walletId: _walletId,
      txid: 'a' * 64,
      vout: 0,
      satoshis: BigInt.from(utxoSats),
      scriptPubKey: dartsv.P2PKHLockBuilder.fromAddress(
              dartsv.Address.fromBase58(address))
          .getScriptPubkey()
          .toHex(),
      address: address,
      initialStatus: UTXOStatus.available,
      blockHeight: 800000,
      confirmations: 6,
    ));

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
      BuildFundingTransactionCommand(feeRate: const FeeRate(satoshis: 100, bytes: 1000),
        walletId: _walletId,
        correlationId: 'corr-$spawned',
        channelId: 'channel-vout',
        clientPubKeyHex: clientKey.publicKey.toHex(),
        serverPubKeyHex: serverKey.publicKey.toHex(),
        fundingAmountSats: _fundingAmount,
        changeAddressBase58: address,
      ),
      sender: probe.ref,
    );
    final response = await probe.expectMsgType<FundingTransactionBuiltResponse>(
        timeout: const Duration(seconds: 10));
    expect(response.success, isTrue, reason: response.error);
    return response;
  }

  test('the multisig vout is found by script when change equals the funding '
      'amount', () async {
    final multisigScriptHex = dartsv.P2MSLockBuilder(
      [clientKey.publicKey, serverKey.publicKey],
      2,
      sorting: true,
    ).getScriptPubkey().toHex();

    // Scout the fee the builder charges for a one-input, two-output funding
    // transaction, then size the UTXO so the change equals the funding
    // amount. The fee can move by a satoshi with the signature length, so
    // try the neighbours too.
    final scout = await buildFunding(100000);
    final scoutTx = dartsv.Transaction.fromHex(scout.fundingTxHex);
    final scoutOutputs =
        scoutTx.outputs.fold<int>(0, (sum, o) => sum + o.satoshis.toInt());
    final fee = 100000 - scoutOutputs;

    FundingTransactionBuiltResponse? equalChange;
    for (final delta in const [0, -1, 1, -2, 2]) {
      final response = await buildFunding(2 * _fundingAmount + fee + delta);
      final tx = dartsv.Transaction.fromHex(response.fundingTxHex);
      if (tx.outputs.length == 2 &&
          tx.outputs.every((o) => o.satoshis.toInt() == _fundingAmount)) {
        equalChange = response;
        break;
      }
    }
    expect(equalChange, isNotNull,
        reason: 'test precondition: a funding transaction whose change '
            'equals the funding amount');

    final tx = dartsv.Transaction.fromHex(equalChange!.fundingTxHex);
    expect(tx.outputs[equalChange.fundingOutputIndex].script.toHex(),
        multisigScriptHex,
        reason: 'fundingOutputIndex must point at the 2-of-2 multisig output, '
            'not at the equal-valued change output');
    expect(equalChange.changeOutputIndex, isNotNull,
        reason: 'the change output must be reported (the amount lookup '
            'lost it when both outputs matched)');
    expect(equalChange.changeOutputIndex,
        isNot(equalChange.fundingOutputIndex));
    expect(tx.outputs[equalChange.changeOutputIndex!].script.toHex(),
        isNot(multisigScriptHex));
  });
}
