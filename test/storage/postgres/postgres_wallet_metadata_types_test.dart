/// Bead libspiffy-k7na on PostgreSQL: the wallet metadata type contract
/// shared with the in-memory and Isar backends.
@Tags(['postgres', 'integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'package:libspiffy/src/storage/postgres/postgres_config.dart';
import 'package:libspiffy/src/storage/postgres/postgres_migrations.dart';
import 'package:libspiffy/src/storage/postgres/postgres_wallet_storage.dart';

import '../wallet_metadata_types_contract.dart';

void main() {
  final config = PostgresConfig(
    host: Platform.environment['POSTGRES_HOST'] ?? 'localhost',
    port: int.tryParse(Platform.environment['POSTGRES_PORT'] ?? '5432') ?? 5432,
    database: Platform.environment['POSTGRES_DATABASE'] ?? 'libspiffy_test',
    username: Platform.environment['POSTGRES_USER'] ?? 'postgres',
    password: Platform.environment['POSTGRES_PASSWORD'] ?? 'postgres',
    maxConnections: 2,
    enableSsl: false, // the local test server has no TLS
  );
  final run = DateTime.now().microsecondsSinceEpoch;

  group('PostgresWalletStorage', () {
    late PostgresWalletStorage storage;
    var counter = 0;

    setUpAll(() async {
      await PostgresMigrations(config).migrate();
    });

    setUp(() async {
      storage = PostgresWalletStorage(config);
      await storage.initialize();
    });

    tearDown(() async {
      await storage.close();
    });

    defineWalletMetadataTypesContract(() => storage, unique: () => 'pw$run-${counter++}');
  });
}
