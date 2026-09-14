/// Pure tests for [PostgresConfig] (audit S-14). No database needed: they
/// inspect the ConnectionSettings / PoolSettings the config hands to
/// package:postgres, and run the settings' onOpen callback against a
/// recording fake connection.
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/storage/postgres/postgres_config.dart';

/// Records every statement onOpen issues; everything else is unsupported.
class _RecordingConnection implements Connection {
  final statements = <String>[];

  @override
  Future<Result> execute(
    Object query, {
    Object? parameters,
    bool ignoreRows = false,
    QueryMode? queryMode,
    Duration? timeout,
  }) async {
    statements.add(query is Sql ? query.toString() : query as String);
    return Result(rows: const [], affectedRows: 0, schema: ResultSchema(const []));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

Future<List<String>> _onOpenStatements(ConnectionSettings settings) async {
  final conn = _RecordingConnection();
  await settings.onOpen?.call(conn);
  return conn.statements;
}

void main() {
  group('PostgresConfig SSL (audit S-14)', () {
    test('sslmode=verify-full maps to SslMode.verifyFull, not require', () {
      final config = PostgresConfig.fromConnectionString(
          'postgresql://u:p@db.example.com:5432/app?sslmode=verify-full');
      expect(config.toPoolSettings().sslMode, SslMode.verifyFull);
      expect(config.toConnectionSettings().sslMode, SslMode.verifyFull);
    });

    test('the constructor defaults to SslMode.require', () {
      const config = PostgresConfig(host: 'db.example.com', database: 'app');
      expect(config.toPoolSettings().sslMode, SslMode.require);
      expect(config.toConnectionSettings().sslMode, SslMode.require);
      expect(config.enableSsl, isTrue);
    });

    test('a connection string without sslmode defaults to SslMode.require', () {
      final config = PostgresConfig.fromConnectionString(
          'postgresql://u:p@db.example.com/app');
      expect(config.toPoolSettings().sslMode, SslMode.require);
    });

    test('SSL can still be disabled explicitly', () {
      const byFlag = PostgresConfig(
          host: 'localhost', database: 'app', enableSsl: false);
      expect(byFlag.toPoolSettings().sslMode, SslMode.disable);
      expect(byFlag.toConnectionSettings().sslMode, SslMode.disable);

      final byString = PostgresConfig.fromConnectionString(
          'postgresql://u:p@localhost/app?sslmode=disable');
      expect(byString.toPoolSettings().sslMode, SslMode.disable);
      expect(byString.enableSsl, isFalse);
    });

    test('an unknown sslmode is rejected instead of silently disabling SSL', () {
      expect(
        () => PostgresConfig.fromConnectionString(
            'postgresql://u:p@localhost/app?sslmode=verify-fulll'),
        throwsArgumentError,
      );
    });

    test('copyWith keeps and overrides the SSL mode', () {
      final config = PostgresConfig.fromConnectionString(
          'postgresql://u:p@db.example.com/app?sslmode=verify-full');
      expect(config.copyWith(maxConnections: 3).toPoolSettings().sslMode,
          SslMode.verifyFull);
      expect(config.copyWith(enableSsl: false).toPoolSettings().sslMode,
          SslMode.disable);
      expect(config.copyWith(enableSsl: true).toPoolSettings().sslMode,
          SslMode.verifyFull,
          reason: 'enableSsl: true must not downgrade verify-full');
    });
  });

  group('PostgresConfig schema and idleTimeout (audit S-14)', () {
    test('a non-public schema is applied as search_path on every connection',
        () async {
      const config = PostgresConfig(
          host: 'localhost', database: 'app', schema: 'tenant_a');
      expect(await _onOpenStatements(config.toPoolSettings()),
          contains('SET search_path TO "tenant_a"'));
      expect(await _onOpenStatements(config.toConnectionSettings()),
          contains('SET search_path TO "tenant_a"'));
    });

    test('the schema identifier is quoted', () async {
      const config = PostgresConfig(
          host: 'localhost', database: 'app', schema: 'we"ird');
      expect(await _onOpenStatements(config.toPoolSettings()),
          contains('SET search_path TO "we""ird"'));
    });

    test('idleTimeout is applied as the server idle_session_timeout', () async {
      const config = PostgresConfig(
          host: 'localhost',
          database: 'app',
          idleTimeout: Duration(seconds: 90));
      expect(await _onOpenStatements(config.toPoolSettings()),
          contains("SET idle_session_timeout = '90000ms'"));
    });

    test('a zero idleTimeout leaves idle connections open', () async {
      const config = PostgresConfig(
          host: 'localhost', database: 'app', idleTimeout: Duration.zero);
      final statements = await _onOpenStatements(config.toPoolSettings());
      expect(statements.where((s) => s.contains('idle_session_timeout')),
          isEmpty);
    });

    test('pool settings carry the configured limits', () {
      const config = PostgresConfig(
        host: 'localhost',
        database: 'app',
        maxConnections: 7,
        connectionTimeout: Duration(seconds: 3),
        maxConnectionAge: Duration(minutes: 5),
        applicationName: 'lane1',
      );
      final settings = config.toPoolSettings();
      expect(settings.maxConnectionCount, 7);
      expect(settings.connectTimeout, const Duration(seconds: 3));
      expect(settings.maxConnectionAge, const Duration(minutes: 5));
      expect(settings.applicationName, 'lane1');
    });
  });

  group('PostgresConfig.toConnectionString (audit S-14)', () {
    test('does not embed the password by default', () {
      final config = PostgresConfig.fromConnectionString(
          'postgresql://alice:s3cr3t@db.example.com:5433/app');
      final s = config.toConnectionString();
      expect(s, isNot(contains('s3cr3t')));
      expect(s, startsWith('postgresql://alice@db.example.com:5433/app'));
    });

    test('includes the password only when asked', () {
      final config = PostgresConfig.fromConnectionString(
          'postgresql://alice:s3cr3t@db.example.com:5433/app');
      expect(config.toConnectionString(includePassword: true),
          'postgresql://alice:s3cr3t@db.example.com:5433/app');
    });

    test('round-trips the SSL mode, schema and application name', () {
      for (final mode in SslMode.values) {
        final config = PostgresConfig(
          host: 'db.example.com',
          database: 'app',
          username: 'alice',
          password: 'pw',
          sslMode: mode,
          schema: 'tenant_a',
          applicationName: 'svc',
        );
        final parsed = PostgresConfig.fromConnectionString(
            config.toConnectionString(includePassword: true));
        expect(parsed.sslMode, mode);
        expect(parsed.schema, 'tenant_a');
        expect(parsed.applicationName, 'svc');
        expect(parsed.password, 'pw');
      }
    });
  });
}
