/// Bead libspiffy-7p2: a payment recorded with a deferred spend holds its
/// inputs until it is settled or cancelled, so releasing the coordinator's
/// payment reservation no longer frees them. A payment that fails after its
/// transaction was recorded, before it was handed to anyone, must cancel the
/// recorded deferred payment, or its inputs would stay held for good.
import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart' show AwaitEventApplied, AwaitFailed;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/payment_coordinator_actor.dart';
import 'package:libspiffy/src/actors/payment_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

import '../spv/testnet_proof_fixture.dart';

const _walletId = 'wallet-1';
const _fundingTxid = 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101';
const _address = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';

void main() {
  test('recorded, then the read model fails: the deferred payment is cancelled, then the reservation released',
      () async {
    final system = LocalActorSystem();
    addTearDown(system.shutdown);
    final walletManager = _ScriptedWalletManager(signedHex: kFixture2TxHex);
    final walletManagerRef = await system.spawn('wallet-manager', () => walletManager);
    final projection = await system.spawn('projection', () => _FailingProjection());
    final coordinator = await system.spawn(
      'payment-coordinator',
      () => PaymentCoordinatorActor(
        walletManager: walletManagerRef,
        walletProjection: projection,
        storage: _ScriptedStorage(),
        reservationReplyTimeout: const Duration(seconds: 2),
      ),
    );
    final replies = _Collector();
    final replyTo = await system.spawn('reply-to', () => replies);

    coordinator.tell(
      PayInvoiceMessage(
        walletId: _walletId,
        invoiceId: 'inv-undelivered',
        addresses: const ['mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt'],
        amount: BigInt.from(10000),
      ),
      sender: replyTo,
    );
    final response = await replies.first<BEEFPaymentResponse>().timeout(const Duration(seconds: 10));
    await walletManager.waitFor<ReleaseUTXOsCommand>(const Duration(seconds: 2));

    expect(response.success, isFalse);
    final commands = walletManager.commands;
    final recorded = commands.whereType<RecordOutgoingTransactionCommand>().single;
    expect(recorded.deferSpend, isTrue);
    expect(recorded.invoiceId, 'inv-undelivered');
    expect(recorded.purpose, 'invoice-payment');

    final cancels = commands.whereType<CancelDeferredSpendCommand>().toList();
    expect(cancels.map((c) => c.txid), [recorded.txid],
        reason: 'the undelivered payment\'s hold must be cancelled');
    final release = commands.whereType<ReleaseUTXOsCommand>().single;
    expect(commands.indexOf(cancels.single), lessThan(commands.indexOf(release)));
  });
}

/// Confirms every reservation and answers signing with [signedHex].
class _ScriptedWalletManager extends Actor {
  final String signedHex;
  final List<WalletCommand> commands = [];
  final StreamController<WalletCommand> _stream = StreamController.broadcast();

  _ScriptedWalletManager({required this.signedHex});

  Future<void> waitFor<T>(Duration timeout) async {
    if (commands.any((c) => c is T)) return;
    await _stream.stream.firstWhere((c) => c is T).timeout(timeout, onTimeout: () => commands.first);
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! WalletCommandMessage) return;
    final command = message.command;
    commands.add(command);
    _stream.add(command);
    if (command is ReserveUTXOCommand) {
      context.sender?.tell(UTXOReservedResponse(
        walletId: command.walletId,
        utxoKey: command.utxoKey,
        reservedByTxId: command.reservedByTxId,
        success: true,
      ));
    } else if (command is SignTransactionCommand) {
      context.sender?.tell(TransactionSignedResponse(
        walletId: command.walletId,
        txid: command.transactionId,
        signedHex: signedHex,
        success: true,
      ));
    }
  }
}

/// A wallet projection that cannot apply anything.
class _FailingProjection extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is AwaitEventApplied) {
      context.sender?.tell(AwaitFailed(reason: 'read model offline'));
    }
  }
}

class _Collector extends Actor {
  final List<dynamic> received = [];
  final StreamController<dynamic> _stream = StreamController.broadcast();

  Future<T> first<T>() async {
    for (final m in received) {
      if (m is T) return m;
    }
    return (await _stream.stream.firstWhere((m) => m is T)) as T;
  }

  @override
  Future<void> onMessage(dynamic message) async {
    received.add(message);
    _stream.add(message);
  }
}

/// One spendable UTXO whose parent carries a merkle proof.
class _ScriptedStorage implements ReadModelStorage {
  @override
  Future<List<BitcoinUtxo>> getPaymentUTXOs(String walletId) async {
    final now = DateTime.now();
    return [
      BitcoinUtxo(
        txid: _fundingTxid,
        vout: 1,
        value: dartsv.Coin.ofSat(BigInt.from(100000)),
        address: _address,
        scriptPubKey: '76a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac',
        status: UTXOStatus.available,
        createdAt: now,
        updatedAt: now,
      ),
    ];
  }

  @override
  Future<int> getBestHeight() async => 1239645;

  @override
  Future<Map<String, BitcoinTransaction>> getTransactionsBatch(List<String> txids) async => {
        for (final txid in txids)
          txid: BitcoinTransaction(
            txid: txid,
            rawHex: '00',
            status: TransactionStatus.confirmed,
            inputValue: BigInt.zero,
            outputValue: BigInt.zero,
            fee: BigInt.zero,
            receivingAddresses: const [],
            sendingAddresses: const [],
            netAmount: BigInt.zero,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            lockTime: 0,
            version: 2,
          ),
      };

  @override
  Future<Map<String, MerkleProof>> getMerkleProofsBatch(List<String> txids) async => {
        for (final txid in txids)
          txid: MerkleProof(
            blockHash: '00' * 32,
            txid: txid,
            merkleProof: const [],
            position: 0,
            blockHeight: 1239645,
          ),
      };

  @override
  Future<AddressMetadata?> getAddressMetadata(String walletId, String addr) async => addr == _address
      ? AddressMetadata(
          address: _address,
          scriptType: 'p2pkh',
          derivationIndex: 0,
          isChange: false,
          purpose: 'receive',
          usageCount: 1,
          balance: BigInt.from(100000),
          createdAt: DateTime.now(),
          isWatched: true,
        )
      : null;

  @override
  Future<Map<String, dynamic>?> getWallet(String walletId) async =>
      {'walletId': walletId, 'walletType': 'wif', 'network': 'testnet'};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('ReadModelStorage.${invocation.memberName} not expected');
}
