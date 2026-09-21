/// Regression test for PaymentCoordinatorActor's UTXO reservation wait
/// (audit finding A-H4, coordinator side).
///
/// The coordinator used to treat "no error reply within 2 s" as a successful
/// reservation, so a wallet manager that never answered (or answered slowly)
/// let the payment proceed on unreserved coins. Silence must now be a
/// failure: the payment is rejected and the reservation released.
import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/payment_coordinator_actor.dart';
import 'package:libspiffy/src/actors/payment_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';
import '../mocks/policy_rate_arc.dart';

void main() {
  late ActorSystem actorSystem;
  late _SilentWalletManager walletManagerProbe;
  late ActorRef paymentCoordinator;

  const walletId = 'wallet-1';

  setUp(() async {
    actorSystem = LocalActorSystem();
    walletManagerProbe = _SilentWalletManager();
    final walletManager = await actorSystem.spawn('wallet-manager', () => walletManagerProbe);
    final projection = await actorSystem.spawn('projection', () => _SilentWalletManager());

    final now = DateTime.now();
    final storage = _UtxoOnlyStorage({
      walletId: [
        BitcoinUtxo(
          txid: 'aa' * 32,
          vout: 0,
          value: dartsv.Coin.ofSat(BigInt.from(100000)),
          address: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
          scriptPubKey: '76a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac',
          status: UTXOStatus.available,
          createdAt: now,
          updatedAt: now,
        ),
      ],
    });

    final arc = await actorSystem.spawn('arc', () => PolicyRateArc());
    paymentCoordinator = await actorSystem.spawn(
      'payment-coordinator',
      () => PaymentCoordinatorActor(
        walletManager: walletManager,
        walletProjection: projection,
        arcActor: arc,
        storage: storage,
        secureStorage: InMemorySecureStorage(),
        reservationReplyTimeout: const Duration(milliseconds: 300),
      ),
    );
  });

  tearDown(() async {
    await actorSystem.shutdown();
  });

  test('no reply to ReserveUTXOCommand fails the payment and releases the reservation', () async {
    final replies = _Collector();
    final replyTo = await actorSystem.spawn('reply-to', () => replies);

    paymentCoordinator.tell(
      PayInvoiceMessage(
        walletId: walletId,
        invoiceId: 'inv-1',
        addresses: ['mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt'],
        amount: BigInt.from(10000),
      ),
      sender: replyTo,
    );

    final response = await replies
        .firstOfType<BEEFPaymentResponse>()
        .timeout(const Duration(seconds: 5));

    expect(response.invoiceId, equals('inv-1'));
    expect(response.success, isFalse);
    expect(response.error, contains('Failed to reserve UTXOs'),
        reason: 'silence from the wallet must be reported as a reservation failure');

    // The coordinator asked for the reservation exactly once ...
    final commands = walletManagerProbe.received
        .whereType<WalletCommandMessage>()
        .map((m) => m.command)
        .toList();
    final reserves = commands.whereType<ReserveUTXOCommand>().toList();
    expect(reserves, hasLength(1));
    expect(reserves.single.utxoKey, equals('${'aa' * 32}:0'));

    // ... and, having heard nothing back, released it rather than spending.
    final releases = commands.whereType<ReleaseUTXOsCommand>().toList();
    expect(releases, hasLength(1),
        reason: 'an unanswered reservation must be released');
    expect(releases.single.reservationId, equals(reserves.single.reservedByTxId));
  });

  group('A-M7: a failure after the reservation releases it', () {
    const fundingTxid = 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101';
    const address = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';

    BitcoinUtxo fundingUtxo() {
      final now = DateTime.now();
      return BitcoinUtxo(
        txid: fundingTxid,
        vout: 1,
        value: dartsv.Coin.ofSat(BigInt.from(100000)),
        address: address,
        scriptPubKey: '76a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac',
        status: UTXOStatus.available,
        createdAt: now,
        updatedAt: now,
      );
    }

    Future<({BEEFPaymentResponse response, List<WalletCommand> commands})> payWith({
      required _ScriptedWalletManager walletManager,
      required ReadModelStorage storage,
    }) async {
      final system = LocalActorSystem();
      try {
        final walletManagerRef = await system.spawn('wallet-manager', () => walletManager);
        final projection = await system.spawn('projection', () => _SilentWalletManager());
        final secureStorage = InMemorySecureStorage();
        // Key material the pre-fix coordinator read for itself; the fixed
        // coordinator never touches it.
        await secureStorage.setWIF(walletId, 'cStLVGeWx7fVYKKDXYWVeEbEcPZEC4TD73DjQpHCks2Y8EAjVDSS');
        final arc = await system.spawn('arc', () => PolicyRateArc());
        final coordinator = await system.spawn(
          'payment-coordinator',
          () => PaymentCoordinatorActor(
            walletManager: walletManagerRef,
            walletProjection: projection,
            arcActor: arc,
            storage: storage,
            secureStorage: secureStorage,
            reservationReplyTimeout: const Duration(seconds: 2),
          ),
        );
        final replies = _Collector();
        final replyTo = await system.spawn('reply-to', () => replies);
        coordinator.tell(
          PayInvoiceMessage(
            walletId: walletId,
            invoiceId: 'inv-leak',
            addresses: ['mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt'],
            amount: BigInt.from(10000),
          ),
          sender: replyTo,
        );
        final response = await replies
            .firstOfType<BEEFPaymentResponse>()
            .timeout(const Duration(seconds: 10));
        // The release is fire-and-forget; let it reach the wallet manager.
        await walletManager.waitFor<ReleaseUTXOsCommand>(const Duration(seconds: 2));
        return (response: response, commands: walletManager.commands);
      } finally {
        await system.shutdown();
      }
    }

    void expectReleased(List<WalletCommand> commands) {
      final reserves = commands.whereType<ReserveUTXOCommand>().toList();
      expect(reserves, hasLength(1));
      final releases = commands.whereType<ReleaseUTXOsCommand>().toList();
      expect(releases, hasLength(1),
          reason: 'the reserved UTXOs must be released when the payment fails');
      expect(releases.single.reservationId, equals(reserves.single.reservedByTxId));
    }

    test('an exception from the read model after reserving releases the reservation', () async {
      final result = await payWith(
        walletManager: _ScriptedWalletManager(),
        storage: _ScriptedStorage(
          utxos: [fundingUtxo()],
          bestHeight: () => throw StateError('read model offline'),
        ),
      );

      expect(result.response.success, isFalse);
      expect(result.response.error, contains('read model offline'));
      expectReleased(result.commands);
    });

    test('a malformed signing reply releases the reservation', () async {
      final result = await payWith(
        walletManager: _ScriptedWalletManager(signedHex: 'not-a-transaction'),
        storage: _ScriptedStorage(
          utxos: [fundingUtxo()],
          bestHeight: () => 1239645,
          address: AddressMetadata(
            address: address,
            scriptType: 'p2pkh',
            derivationIndex: 0,
            isChange: false,
            purpose: 'receive',
            usageCount: 1,
            balance: BigInt.from(100000),
            createdAt: DateTime.now(),
            isWatched: true,
          ),
        ),
      );

      expect(result.response.success, isFalse);
      expect(result.commands.whereType<SignTransactionCommand>(), hasLength(1),
          reason: 'the failure must come from the signing step');
      expectReleased(result.commands);
    });
  });
}

/// Wallet manager stand-in that confirms every reservation and answers
/// signing requests with [signedHex].
class _ScriptedWalletManager extends Actor {
  final String signedHex;
  final List<WalletCommand> commands = [];
  final StreamController<WalletCommand> _stream = StreamController.broadcast();

  _ScriptedWalletManager({this.signedHex = ''});

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

/// Read model with one spendable UTXO whose parent carries a merkle proof.
class _ScriptedStorage implements ReadModelStorage {
  final List<BitcoinUtxo> utxos;
  final int Function() bestHeight;
  final AddressMetadata? address;

  _ScriptedStorage({required this.utxos, required this.bestHeight, this.address});

  @override
  Future<List<BitcoinUtxo>> getPaymentUTXOs(String walletId) async => List.of(utxos);

  @override
  Future<int> getBestHeight() async => bestHeight();

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
  Future<AddressMetadata?> getAddressMetadata(String walletId, String addr) async =>
      address?.address == addr ? address : null;

  @override
  Future<Map<String, dynamic>?> getWallet(String walletId) async =>
      {'walletId': walletId, 'walletType': 'wif', 'network': 'testnet'};

  /// No watch addresses: the payment coordinator leaves watch-only UTXOs
  /// out (bead libspiffy-87a2).
  @override
  Future<List<AddressMetadata>> getAddressesByPurpose(String walletId, String purpose) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('ReadModelStorage.${invocation.memberName} not expected');
}

/// Wallet manager stand-in that records what it is told and never replies.
class _SilentWalletManager extends Actor {
  final List<dynamic> received = [];

  @override
  Future<void> onMessage(dynamic message) async {
    received.add(message);
  }
}

class _Collector extends Actor {
  final List<dynamic> received = [];
  final StreamController<dynamic> _stream = StreamController.broadcast();

  Future<T> firstOfType<T>() async {
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

/// Read model exposing only spendable UTXOs; the payment must fail at the
/// reservation step, so nothing else may be consulted.
class _UtxoOnlyStorage implements ReadModelStorage {
  final Map<String, List<BitcoinUtxo>> _utxos;
  _UtxoOnlyStorage(this._utxos);

  @override
  Future<List<BitcoinUtxo>> getPaymentUTXOs(String walletId) async =>
      List.of(_utxos[walletId] ?? const []);

  /// No watch addresses: the payment coordinator leaves watch-only UTXOs
  /// out (bead libspiffy-87a2).
  @override
  Future<List<AddressMetadata>> getAddressesByPurpose(String walletId, String purpose) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('ReadModelStorage.${invocation.memberName} not expected');
}
