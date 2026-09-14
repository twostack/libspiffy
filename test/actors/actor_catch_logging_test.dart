/// Failures caught by the actors are logged (A-L5, libspiffy-753,
/// doc/audit-2026-09-14.md).
///
/// PaymentCoordinatorActor, PaymentChannelManagerActor, WalletManagerActor
/// and LibSpiffyActorSystem's wallet preload caught exceptions and dropped
/// them: the caller got (at best) an error reply, and the log had nothing,
/// no error and no stack trace. Every such catch now logs a WARNING carrying
/// the error and its stack trace. One representative catch per file is
/// exercised here.
import 'dart:async';
import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:isar/isar.dart';
import 'package:logging/logging.dart' as logging;
import 'package:test/test.dart';

import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/payment_channel_manager_actor.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';

import '../integration/isar_test_helper.dart';
import 'in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

void main() {
  late List<logging.LogRecord> records;
  late StreamSubscription<logging.LogRecord> logSub;
  late logging.Level previousLevel;

  setUp(() {
    records = [];
    previousLevel = logging.Logger.root.level;
    logging.Logger.root.level = logging.Level.ALL;
    logSub = logging.Logger.root.onRecord.listen(records.add);
  });

  tearDown(() async {
    await logSub.cancel();
    logging.Logger.root.level = previousLevel;
  });

  /// The WARNING records from [loggerName] that carry an error and a stack
  /// trace.
  List<logging.LogRecord> warningsFrom(String loggerName) => records
      .where((r) =>
          r.loggerName == loggerName &&
          r.level == logging.Level.WARNING &&
          r.error != null &&
          r.stackTrace != null)
      .toList();

  Future<T> waitFor<T>(List<dynamic> received) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (received.whereType<T>().isEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('no $T received');
      await Future.delayed(const Duration(milliseconds: 10));
    }
    return received.whereType<T>().first;
  }

  group('actors', () {
    late ActorSystem actorSystem;

    setUp(() {
      actorSystem = LocalActorSystem();
    });

    tearDown(() async {
      await actorSystem.shutdown();
    });

    test('PaymentCoordinatorActor: an exception escaping the payment handler '
        'is replied to and logged with its stack trace', () async {
      final probe = await actorSystem.spawn('probe', () => _Collector());
      final replies = _Collector();
      final replyTo = await actorSystem.spawn('reply-to', () => replies);
      final coordinator = await actorSystem.spawn(
        'payment-coordinator',
        () => PaymentCoordinatorActor(
          walletManager: probe,
          walletProjection: probe,
          // Throws StorageException('Wallet not found') for any wallet. (The
          // in-memory backend itself returns empty for unknown wallets since
          // audit S-15, so the failure is injected.)
          storage: _WalletNotFoundStorage(),
        ),
      );

      coordinator.tell(
        PayInvoiceMessage(
          walletId: 'ghost',
          invoiceId: 'inv-1',
          addresses: ['mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt'],
          amount: BigInt.from(1000),
        ),
        sender: replyTo,
      );

      final reply = await waitFor<BEEFPaymentResponse>(replies.received);
      expect(reply.success, isFalse);
      expect(reply.error, contains('Wallet not found'));
      expect(warningsFrom('PaymentCoordinatorActor'), isNotEmpty,
          reason: 'the failure was not logged with error and stack trace');
    });

    test('PaymentChannelManagerActor: a failed request is replied to and '
        'logged with its stack trace', () async {
      final probe = await actorSystem.spawn('probe', () => _Collector());
      final replies = _Collector();
      final replyTo = await actorSystem.spawn('reply-to', () => replies);
      final manager = await actorSystem.spawn(
        'payment-channel-manager',
        () => PaymentChannelManagerActor(
          walletManager: probe,
          eventStore: InMemoryEventStore(),
          cryptoService: DartSVCryptoService(),
        ),
      );

      manager.tell(QueryChannelStateMessage(channelId: 'ghost-channel'),
          sender: replyTo);

      final reply = await waitFor<ChannelStateResponse>(replies.received);
      expect(reply.success, isFalse);
      expect(
        warningsFrom('PaymentChannelManagerActor')
            .where((r) => r.message.contains('ghost-channel')),
        isNotEmpty,
        reason: 'the failure was not logged with error and stack trace',
      );
    });
  });

  test('WalletManagerActor: a failed wallet creation is replied to and '
      'logged with its stack trace', () async {
    final actorSystem = TestActorSystem();
    addTearDown(actorSystem.shutdown);
    final walletManager = await actorSystem.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: InMemoryEventStore(),
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
      ),
    );
    // Occupy the aggregate's actor id so spawning it throws.
    await actorSystem.spawn('wallet-w2', () => _Collector());

    final reply = await walletManager.ask<WalletCreatedMessage>(
      CreateWalletMessage('w2', 'Wallet 2', mnemonic: _mnemonic),
      const Duration(seconds: 10),
    );
    expect(reply.success, isFalse);
    expect(warningsFrom('WalletManagerActor'), isNotEmpty,
        reason: 'the failure was not logged with error and stack trace');
  });

  test('LibSpiffyActorSystem: a failed wallet preload is logged with its '
      'stack trace', () async {
    await ensureIsarInitialized();
    final tempDir = await Directory.systemTemp.createTemp('libspiffy_al5_');
    final isar = await Isar.open(
      LibSpiffySchemas.allSchemas,
      directory: tempDir.path,
      name: 'al5_${DateTime.now().microsecondsSinceEpoch}',
    );
    final libspiffy = LibSpiffyActorSystem();
    try {
      await libspiffy.initialize(
        isar: isar,
        dataDirectory: tempDir.path,
        readModelStorage: _ListWalletsFails(),
        secureStorage: InMemorySecureStorage(),
        enableP2P: false,
      );

      expect(
        warningsFrom('LibSpiffyActorSystem')
            .where((r) => r.message.contains('preload')),
        isNotEmpty,
        reason: 'the preload failure was not logged with error and stack '
            'trace',
      );
    } finally {
      await libspiffy.shutdown();
      if (isar.isOpen) await isar.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });
}

class _ListWalletsFails extends InMemoryWalletStorage {
  @override
  Future<List<String>> listWallets() async =>
      throw StateError('read model unavailable');
}

class _Collector extends Actor {
  final List<dynamic> received = [];

  @override
  Future<void> onMessage(dynamic message) async {
    received.add(message);
  }
}

/// Read model whose payment-UTXO lookup fails, to drive the coordinator's
/// catch path.
class _WalletNotFoundStorage extends InMemoryWalletStorage {
  @override
  Future<List<BitcoinUtxo>> getPaymentUTXOs(String walletId) async =>
      throw StorageException('Wallet not found: $walletId');
}
