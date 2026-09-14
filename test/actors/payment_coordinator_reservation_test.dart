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
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

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

    paymentCoordinator = await actorSystem.spawn(
      'payment-coordinator',
      () => PaymentCoordinatorActor(
        walletManager: walletManager,
        walletProjection: projection,
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

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('ReadModelStorage.${invocation.memberName} not expected');
}
