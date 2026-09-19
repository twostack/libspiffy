/// Pure tests for [PostgresConfig] (audit S-14). No database needed: they
/// inspect the ConnectionSettings / PoolSettings the config hands to
/// package:postgres, and run the settings' onOpen callback against a
/// recording fake connection.
library;

import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/storage/postgres/postgres_config.dart';

/// A self-signed certificate authority, generated for these tests alone. It
/// signs nothing and is never trusted by anything else; it exists so a test
/// can prove the bytes reach a real [SecurityContext], which parses them.
const _caPem = '''
-----BEGIN CERTIFICATE-----
MIIDGTCCAgGgAwIBAgIUTnImdJaoldw6zpusIATCJCWlHh4wDQYJKoZIhvcNAQEL
BQAwHDEaMBgGA1UEAwwRbGlic3BpZmZ5IHRlc3QgQ0EwHhcNMjYwOTE5MDY1ODE3
WhcNMzYwOTE2MDY1ODE3WjAcMRowGAYDVQQDDBFsaWJzcGlmZnkgdGVzdCBDQTCC
ASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJsJfC7dy68ZXcJ9g2vz79n6
vsh9qfziu/3JPD2OCrXJXCPvrUnrjuVLEGl2Qnl/ByNHg/f89WLS30uRTn9ad7Ia
S13ukoOlSqjaNrFGF7fj54COqwUMsGkaMfpl1zZj/AMQqymQBwP08fZdZgiY0wf4
nri2lAySbXm3QjoxFHyKwFdkmK8VMRqun0ekb0QDA26/52e+eK5NMjHFcRfxUIP5
g1yWZE08uSXEJNJoZixCldgklLNP5Y8o/Hp/akeOkctBdJiaDJG7XMOaXY3tfFcH
7ANDX5+gJCYq2iLc/mHFNmZIS6/qcUk8zy5c3wcv4CdrpbtE/884Mp2PS98gSHEC
AwEAAaNTMFEwHQYDVR0OBBYEFBXKBCcH8oReH6YD4Ns75pscB/LdMB8GA1UdIwQY
MBaAFBXKBCcH8oReH6YD4Ns75pscB/LdMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZI
hvcNAQELBQADggEBABSyHfRnUOGam3Zc9VNwASlpaTNRAW+xFmLV4nnlNgJiRbz3
z59sRYyDe6NL0Saa/3YCo4IA91zHPUAX4MnzINk58c7iC5gX20oUSmS1lKqpl7nx
LIOQ9t1J5wqL0UsOoIMQatmGQI/a4yCdOCk3erUnBBcO6aO8jgbrQlzauqaJbOdJ
f9MxXiELTfi9uVUEUdLgueY7UjjjFgHYSy4q//YrMsHjFXYvkgRPDabub8M9uSQQ
mtel7NhPj7vb3tnn7O5fwz0PZv5i/3TA4vOLFIVAXn1ZidVXcSPbxsVuOply1G6C
O1VdCBYiRv+E6FY2H62D8kcRZnJerKLMxAxviIo=
-----END CERTIFICATE-----
''';

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

  group('PostgresConfig private CA (libspiffy-tpv)', () {
    late Directory dir;
    late String caPath;

    setUpAll(() {
      dir = Directory.systemTemp.createTempSync('libspiffy_ca');
      caPath = '${dir.path}/ca.pem';
      File(caPath).writeAsStringSync(_caPem);
    });

    tearDownAll(() => dir.deleteSync(recursive: true));

    test('a config with no certificate hands the driver no SecurityContext',
        () {
      const config = PostgresConfig(host: 'db.example.com', database: 'app');
      expect(config.resolveSecurityContext(), isNull);
      expect(config.toPoolSettings().securityContext, isNull);
      expect(config.toConnectionSettings().securityContext, isNull);
      expect(config.sslMode, SslMode.require,
          reason: 'the default is unchanged');
    });

    test('a CA file reaches the SecurityContext the driver is handed', () {
      final config = PostgresConfig(
        host: 'db.example.com',
        database: 'app',
        sslRootCertPath: caPath,
      );
      final context = config.resolveSecurityContext();
      expect(context, isNotNull);
      expect(config.toPoolSettings().securityContext, same(context));
      expect(config.toConnectionSettings().securityContext, same(context));
      expect(config.sslMode, SslMode.verifyFull,
          reason: 'a CA nothing verifies against would be decorative');
    });

    test('a CA supplied as bytes reaches it too', () {
      final config = PostgresConfig(
        host: 'db.example.com',
        database: 'app',
        sslRootCertBytes: utf8.encode(_caPem),
      );
      expect(config.resolveSecurityContext(), isNotNull);
      expect(config.toPoolSettings().securityContext,
          same(config.resolveSecurityContext()));
      expect(config.sslMode, SslMode.verifyFull);
    });

    test('a certificate that cannot be read or parsed is an ArgumentError, '
        'not an empty trust store', () {
      final missing = PostgresConfig(
        host: 'db.example.com',
        database: 'app',
        sslRootCertPath: '${dir.path}/absent.pem',
      );
      expect(missing.resolveSecurityContext, throwsArgumentError);
      expect(() => missing.toPoolSettings(), throwsArgumentError);

      final garbage = PostgresConfig(
        host: 'db.example.com',
        database: 'app',
        sslRootCertBytes: utf8.encode('not a certificate'),
      );
      expect(garbage.resolveSecurityContext, throwsArgumentError);
    });

    test('an explicit SecurityContext is handed over as it stands', () {
      final context = SecurityContext(withTrustedRoots: true);
      final config = PostgresConfig(
        host: 'db.example.com',
        database: 'app',
        securityContext: context,
      );
      expect(config.resolveSecurityContext(), same(context));
      expect(config.toConnectionSettings().securityContext, same(context));
      expect(config.sslMode, SslMode.verifyFull);
    });

    test('an explicit SSL mode still wins over the certificate', () {
      final required = PostgresConfig(
        host: 'db.example.com',
        database: 'app',
        sslMode: SslMode.require,
        sslRootCertPath: caPath,
      );
      expect(required.sslMode, SslMode.require);
      expect(required.toPoolSettings().securityContext, isNotNull);

      final off = PostgresConfig(
        host: 'db.example.com',
        database: 'app',
        enableSsl: false,
        sslRootCertPath: caPath,
      );
      expect(off.sslMode, SslMode.disable,
          reason: 'enableSsl: false keeps working unchanged');
    });

    test('sslrootcert in a connection string selects verify-full and '
        'round-trips', () {
      final config = PostgresConfig.fromConnectionString(
          'postgresql://u:p@db.example.com/app?sslrootcert=$caPath');
      expect(config.sslRootCertPath, caPath);
      expect(config.sslMode, SslMode.verifyFull);
      expect(config.resolveSecurityContext(), isNotNull);

      final reparsed =
          PostgresConfig.fromConnectionString(config.toConnectionString());
      expect(reparsed.sslRootCertPath, caPath);
      expect(reparsed.sslMode, SslMode.verifyFull);
    });

    test('a connection string without sslrootcert still configures no context',
        () {
      final config = PostgresConfig.fromConnectionString(
          'postgresql://u:p@db.example.com/app');
      expect(config.sslRootCertPath, isNull);
      expect(config.resolveSecurityContext(), isNull);
      expect(config.sslMode, SslMode.require);
    });

    test('copyWith carries the certificate and raises require to verify-full',
        () {
      const plain = PostgresConfig(host: 'db.example.com', database: 'app');
      final withCa = plain.copyWith(sslRootCertPath: caPath);
      expect(withCa.sslRootCertPath, caPath);
      expect(withCa.sslMode, SslMode.verifyFull);
      expect(withCa.toPoolSettings().securityContext, isNotNull);

      expect(withCa.copyWith(maxConnections: 3).sslRootCertPath, caPath);
      expect(withCa.copyWith(maxConnections: 3).sslMode, SslMode.verifyFull);
      expect(withCa.copyWith(enableSsl: false).sslMode, SslMode.disable);
      expect(plain.copyWith(maxConnections: 3).sslMode, SslMode.require,
          reason: 'a config with no CA is unaffected');
    });

    test('toString names the certificate without leaking the password', () {
      final config = PostgresConfig(
        host: 'db.example.com',
        database: 'app',
        password: 's3cr3t',
        sslRootCertPath: caPath,
      );
      expect(config.toString(), contains(caPath));
      expect(config.toString(), isNot(contains('s3cr3t')));
    });
  });
}
