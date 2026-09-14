import 'dart:io';

import 'package:dactor/dactor.dart';
import 'package:isar/isar.dart';
import 'package:logging/logging.dart' as logging;
import 'package:test/test.dart';

import 'package:libspiffy/libspiffy.dart';

import '../integration/isar_test_helper.dart';

/// Audit finding KM-1 (mitigated): a persistent backend with no
/// [SecureStorage] silently fell back to [InMemorySecureStorage], so after a
/// restart every wallet still existed but none could sign. The system now
/// logs SEVERE when that combination is configured.
void main() {
  setUpAll(() async {
    await ensureIsarInitialized();
  });

  group('LibSpiffyActorSystem secure storage default (KM-1)', () {
    late Directory tempDir;
    late List<logging.LogRecord> records;
    late logging.Level previousLevel;
    late void Function() cancel;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('libspiffy_km1_');
      records = <logging.LogRecord>[];
      previousLevel = logging.Logger.root.level;
      logging.Logger.root.level = logging.Level.ALL;
      final sub = logging.Logger.root.onRecord.listen(records.add);
      cancel = () => sub.cancel();
    });

    tearDown(() async {
      cancel();
      logging.Logger.root.level = previousLevel;
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    Iterable<logging.LogRecord> secureStorageWarnings() => records.where((r) =>
        r.level == logging.Level.SEVERE &&
        r.message.contains('InMemorySecureStorage'));

    test('logs SEVERE when the Isar backend is initialised without a secureStorage',
        () async {
      final isar = await Isar.open(
        LibSpiffySchemas.allSchemas,
        directory: tempDir.path,
        name: 'km1_${DateTime.now().microsecondsSinceEpoch}',
      );
      final actorSystem = LocalActorSystem(ActorSystemConfig());
      final libspiffy = LibSpiffyActorSystem();
      try {
        await libspiffy.initialize(
          actorSystem: actorSystem,
          isar: isar,
          dataDirectory: tempDir.path,
          storageBackend: StorageBackend.isar,
          enableP2P: false,
        );

        expect(libspiffy.secureStorage, isA<InMemorySecureStorage>());
        final warnings = secureStorageWarnings().toList();
        expect(warnings, hasLength(1),
            reason: 'expected one SEVERE record about the in-memory '
                'secure storage fallback, got: '
                '${records.where((r) => r.level >= logging.Level.WARNING).map((r) => '${r.level.name}: ${r.message}').toList()}');
        expect(warnings.single.loggerName, equals('LibSpiffyActorSystem'));
        expect(warnings.single.message, contains('isar backend'));
        expect(warnings.single.message, contains('lost on restart'));
      } finally {
        await libspiffy.shutdown();
        await actorSystem.shutdown();
        await isar.close();
      }
    });

    test('does not log SEVERE when the Isar backend is given a secureStorage',
        () async {
      final isar = await Isar.open(
        LibSpiffySchemas.allSchemas,
        directory: tempDir.path,
        name: 'km1_${DateTime.now().microsecondsSinceEpoch}',
      );
      final actorSystem = LocalActorSystem(ActorSystemConfig());
      final libspiffy = LibSpiffyActorSystem();
      final supplied = InMemorySecureStorage();
      try {
        await libspiffy.initialize(
          actorSystem: actorSystem,
          isar: isar,
          dataDirectory: tempDir.path,
          storageBackend: StorageBackend.isar,
          secureStorage: supplied,
          enableP2P: false,
        );

        expect(identical(libspiffy.secureStorage, supplied), isTrue);
        expect(secureStorageWarnings(), isEmpty);
      } finally {
        await libspiffy.shutdown();
        await actorSystem.shutdown();
        await isar.close();
      }
    });

    test('does not log SEVERE for the inMemory backend without a secureStorage',
        () async {
      final actorSystem = LocalActorSystem(ActorSystemConfig());
      final libspiffy = LibSpiffyActorSystem();
      try {
        await libspiffy.initialize(
          actorSystem: actorSystem,
          dataDirectory: tempDir.path,
          storageBackend: StorageBackend.inMemory,
          enableP2P: false,
        );

        expect(libspiffy.secureStorage, isA<InMemorySecureStorage>());
        expect(secureStorageWarnings(), isEmpty);
      } finally {
        await libspiffy.shutdown();
        await actorSystem.shutdown();
      }
    });
  });
}
