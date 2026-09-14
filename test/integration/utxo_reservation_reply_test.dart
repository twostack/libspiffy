/// Regression test for the wallet aggregate's ReserveUTXOCommand reply
/// (audit finding A-H4, aggregate side).
///
/// The aggregate used to answer ReserveUTXOCommand only on failure (and then
/// with a generic error map). Callers had to treat silence as success, which
/// is what the payment coordinators did. Every reservation request now gets a
/// UTXOReservedResponse, success or failure, through the wallet manager.
import 'dart:async';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:test/test.dart';

import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';

import 'isar_test_helper.dart';

void main() {
  late LibSpiffyActorSystem libspiffy;
  late LocalActorSystem actorSystem;
  late Isar isar;
  late Directory testDir;
  late String walletId;

  const fundingTxid = 'a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a2101';

  setUpAll(() async {
    await ensureIsarInitialized();
  });

  setUp(() async {
    testDir = await Directory.systemTemp.createTemp('utxo_reservation_reply_');
    isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: testDir.path,
      name: 'test_${DateTime.now().microsecondsSinceEpoch}',
    );
    actorSystem = LocalActorSystem(ActorSystemConfig());
    libspiffy = LibSpiffyActorSystem();
    await libspiffy.initialize(
      actorSystem: actorSystem,
      isar: isar,
      dataDirectory: testDir.path,
      enableP2P: false,
      secureStorage: InMemorySecureStorage(),
    );

    // Create a wallet and give it one available UTXO.
    walletId = 'wallet-${DateTime.now().microsecondsSinceEpoch}';
    final mnemonic = await DartSVCryptoService().generateMnemonic();

    final created = await _tellAndAwait<WalletCreatedMessage>(
      actorSystem,
      libspiffy.walletManager,
      CreateWalletMessage(walletId, 'Reservation Test', mnemonic: mnemonic),
    );
    expect(created.success, isTrue, reason: created.error);

    final received = await _tellAndAwait<UTXOReceivedResponse>(
      actorSystem,
      libspiffy.walletManager,
      WalletCommandMessage(
        walletId,
        ReceiveUTXOCommand(
          walletId: walletId,
          txid: fundingTxid,
          vout: 1,
          satoshis: BigInt.from(200000),
          scriptPubKey: '76a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac',
          address: created.rootAddress,
          blockHeight: 1239645,
          confirmations: 10,
          initialStatus: UTXOStatus.available,
        ),
      ),
    );
    expect(received.success, isTrue, reason: received.error);
  });

  tearDown(() async {
    await libspiffy.shutdown();
    if (await testDir.exists()) {
      await testDir.delete(recursive: true);
    }
  });

  test('a successful reservation is answered with UTXOReservedResponse(success: true)', () async {
    final response = await _tellAndAwait<UTXOReservedResponse>(
      actorSystem,
      libspiffy.walletManager,
      WalletCommandMessage(
        walletId,
        ReserveUTXOCommand(
          walletId: walletId,
          utxoKey: '$fundingTxid:1',
          reservedByTxId: 'payment-1',
          reservationReason: 'payment',
          reservationDuration: const Duration(minutes: 2),
        ),
      ),
    );

    expect(response.success, isTrue, reason: response.error);
    expect(response.walletId, equals(walletId));
    expect(response.utxoKey, equals('$fundingTxid:1'));
    expect(response.reservedByTxId, equals('payment-1'));
  });

  test('a rejected reservation is answered with UTXOReservedResponse(success: false)', () async {
    final response = await _tellAndAwait<UTXOReservedResponse>(
      actorSystem,
      libspiffy.walletManager,
      WalletCommandMessage(
        walletId,
        ReserveUTXOCommand(
          walletId: walletId,
          utxoKey: '${'ff' * 32}:0', // not in the wallet
          reservedByTxId: 'payment-2',
        ),
      ),
    );

    expect(response.success, isFalse);
    expect(response.utxoKey, equals('${'ff' * 32}:0'));
    expect(response.reservedByTxId, equals('payment-2'));
    expect(response.error, isNotNull);
  });
}

/// Sends [message] to [target] from a throwaway receiver and returns the
/// first reply of type [T]. Any other reply is ignored, so on the old code
/// (no reply on success; a bare error map on failure) this times out.
Future<T> _tellAndAwait<T>(ActorSystem system, ActorRef target, Message message) async {
  final completer = Completer<T>();
  final receiver = await system.spawn(
    'receiver-${T.toString()}-${DateTime.now().microsecondsSinceEpoch}',
    () => _TypedReceiver<T>(completer),
  );
  try {
    target.tell(message, sender: receiver);
    return await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('No $T reply within 5 s'),
    );
  } finally {
    await system.stop(receiver);
  }
}

class _TypedReceiver<T> extends Actor {
  final Completer<T> completer;
  _TypedReceiver(this.completer);

  @override
  Future<void> onMessage(dynamic message) async {
    final payload = message is LocalMessage ? message.payload : message;
    if (payload is T && !completer.isCompleted) {
      completer.complete(payload);
    }
  }
}
