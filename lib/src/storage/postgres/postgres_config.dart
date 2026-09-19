/// PostgreSQL configuration for libspiffy server-side deployments.
///
/// Provides connection configuration and pool management for PostgreSQL.
library;

import 'dart:io' show SecurityContext;

import 'package:postgres/postgres.dart';

/// Configuration for PostgreSQL database connections.
///
/// This class holds all the parameters needed to connect to a PostgreSQL
/// database and configure connection pooling for server-side deployments.
class PostgresConfig {
  /// The hostname or IP address of the PostgreSQL server.
  final String host;

  /// The port number of the PostgreSQL server (default: 5432).
  final int port;

  /// The name of the database to connect to.
  final String database;

  /// The username for authentication.
  final String? username;

  /// The password for authentication.
  final String? password;

  /// How connections use TLS.
  ///
  /// [SslMode.require] (the default) encrypts but accepts any certificate;
  /// [SslMode.verifyFull] also verifies the certificate chain and host name;
  /// [SslMode.disable] sends everything, including the password, in clear.
  final SslMode sslMode;

  /// Path to a PEM file holding the certificate authority that signed the
  /// server's certificate.
  ///
  /// A server whose certificate is signed by a private CA cannot be verified
  /// against the operating system's root store, so [SslMode.verifyFull] is
  /// unusable without the CA. Give it here and it reaches the driver as the
  /// [SecurityContext] the TLS handshake verifies against
  /// ([resolveSecurityContext]).
  ///
  /// Supplying a CA and no [sslMode] selects [SslMode.verifyFull]: a CA that
  /// nothing verifies against is decorative, and [SslMode.require] accepts
  /// any certificate at all.
  final String? sslRootCertPath;

  /// The PEM bytes of that certificate authority, for deployments that get
  /// the certificate from a secret store rather than a file.
  ///
  /// Behaves exactly like [sslRootCertPath]; if both are given, both
  /// authorities are trusted.
  final List<int>? sslRootCertBytes;

  /// A [SecurityContext] to hand the driver as it stands.
  ///
  /// Wins over [sslRootCertPath] and [sslRootCertBytes]. Use it for a
  /// handshake those cannot describe — a client certificate and key for
  /// mutual TLS, for instance.
  final SecurityContext? securityContext;

  /// Maximum number of connections in the pool.
  final int maxConnections;

  /// Maximum time to wait for a connection from the pool.
  final Duration connectionTimeout;

  /// Maximum time a connection can be idle before being closed.
  ///
  /// package:postgres' pool has no idle eviction of its own, so this is
  /// applied as the server's `idle_session_timeout` on every connection
  /// (PostgreSQL 14+; ignored by older servers): the server closes a session
  /// idle for this long and the pool opens a fresh one when needed.
  /// [Duration.zero] disables it.
  final Duration idleTimeout;

  /// Maximum lifetime of a connection before it's recycled.
  final Duration maxConnectionAge;

  /// Schema name to use (default: 'public').
  ///
  /// A schema other than `public` is applied as the `search_path` of every
  /// connection, so unqualified tables (including the migrations') live
  /// there. The schema must already exist.
  final String schema;

  /// Application name to use for connections (helps with monitoring).
  final String applicationName;

  /// Creates a new PostgreSQL configuration.
  ///
  /// Required parameters:
  /// - [host]: The PostgreSQL server hostname
  /// - [database]: The database name
  ///
  /// Optional parameters with defaults:
  /// - [port]: Server port (default: 5432)
  /// - [username]: Authentication username
  /// - [password]: Authentication password
  /// - [sslMode]: TLS mode (default: [SslMode.require])
  /// - [enableSsl]: Shorthand for [sslMode]: `false` means
  ///   [SslMode.disable], `true` [SslMode.require]. Ignored when [sslMode] is
  ///   given. Pass `enableSsl: false` for a local server without TLS.
  /// - [maxConnections]: Pool size (default: 10)
  /// - [connectionTimeout]: Wait time for connection (default: 30s)
  /// - [idleTimeout]: Idle connection timeout (default: 10min)
  /// - [maxConnectionAge]: Max connection lifetime (default: 1h)
  /// - [schema]: Database schema (default: 'public')
  /// - [applicationName]: App name for monitoring (default: 'libspiffy')
  /// - [sslRootCertPath] / [sslRootCertBytes] / [securityContext]: the
  ///   certificate authority (or context) TLS verifies the server against.
  ///   Default: none, i.e. exactly today's behaviour. Supplying one without
  ///   an [sslMode] or `enableSsl: false` selects [SslMode.verifyFull]
  ///   rather than [SslMode.require], since a CA nothing verifies against
  ///   would be decorative; an explicit [sslMode] is always obeyed.
  const PostgresConfig({
    required this.host,
    required this.database,
    this.port = 5432,
    this.username,
    this.password,
    bool? enableSsl,
    SslMode? sslMode,
    this.maxConnections = 10,
    this.connectionTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(minutes: 10),
    this.maxConnectionAge = const Duration(hours: 1),
    this.schema = 'public',
    this.applicationName = 'libspiffy',
    this.sslRootCertPath,
    this.sslRootCertBytes,
    this.securityContext,
  }) : sslMode = sslMode ??
            (enableSsl == false
                ? SslMode.disable
                : (sslRootCertPath != null ||
                        sslRootCertBytes != null ||
                        securityContext != null)
                    ? SslMode.verifyFull
                    : SslMode.require);

  /// Whether connections use TLS at all.
  bool get enableSsl => sslMode != SslMode.disable;

  /// Built contexts, keyed by the config that describes them, so a config
  /// used for several pools reads its CA file once and hands the driver the
  /// same context every time (package:postgres compares contexts by
  /// identity when deciding whether a pooled connection may be reused).
  static final Expando<SecurityContext> _resolvedContexts =
      Expando<SecurityContext>('PostgresConfig.securityContext');

  /// The [SecurityContext] this config hands the driver, or `null` when it
  /// configures none (the default, which leaves the driver's own behaviour
  /// exactly as it was).
  ///
  /// [securityContext] is returned as given. Otherwise, when a CA is
  /// configured, a context trusting **only** that CA is built — not the
  /// operating system's root store, which is the point of a private CA: a
  /// certificate from any other issuer, public or not, fails the handshake.
  /// Pass [securityContext] directly to trust more than that.
  ///
  /// A CA is only actually *checked* under [SslMode.verifyFull];
  /// [SslMode.require] accepts every certificate and [SslMode.disable] uses
  /// no TLS at all. The context is still handed over under those modes, and
  /// the constructor picks [SslMode.verifyFull] when a CA is given and no
  /// mode is, so this only bites a caller who asked for both a CA and a
  /// weaker mode explicitly.
  ///
  /// Throws [ArgumentError] if the certificate cannot be read or parsed —
  /// rather than connecting with a trust store that silently holds nothing.
  SecurityContext? resolveSecurityContext() {
    if (securityContext != null) return securityContext;
    if (sslRootCertPath == null && sslRootCertBytes == null) return null;
    final cached = _resolvedContexts[this];
    if (cached != null) return cached;

    final context = SecurityContext();
    final path = sslRootCertPath;
    if (path != null) {
      try {
        context.setTrustedCertificates(path);
      } catch (e) {
        throw ArgumentError.value(
          path,
          'sslRootCertPath',
          'Failed to load the PostgreSQL root certificate: $e',
        );
      }
    }
    final bytes = sslRootCertBytes;
    if (bytes != null) {
      try {
        context.setTrustedCertificatesBytes(bytes);
      } catch (e) {
        throw ArgumentError.value(
          '${bytes.length} bytes',
          'sslRootCertBytes',
          'Failed to load the PostgreSQL root certificate: $e',
        );
      }
    }
    _resolvedContexts[this] = context;
    return context;
  }

  /// Creates a configuration from a PostgreSQL connection string.
  ///
  /// Supported formats:
  /// - `postgresql://user:password@host:port/database`
  /// - `postgres://user:password@host:port/database`
  /// - `postgresql://user:password@host:port/database?sslmode=verify-full`
  ///
  /// Query parameters:
  /// - `sslmode`: `disable`; `allow`, `prefer` or `require` (all mapped to
  ///   [SslMode.require], never silently to plain text); `verify-ca` or
  ///   `verify-full` ([SslMode.verifyFull]). Default: `require`, or
  ///   `verify-full` when `sslrootcert` is given. Any other value throws
  ///   [ArgumentError].
  /// - `sslrootcert`: path to the PEM certificate authority that signed the
  ///   server's certificate ([sslRootCertPath])
  /// - `application_name`: Application name for monitoring
  /// - `schema`: Schema name (default: public)
  factory PostgresConfig.fromConnectionString(
    String connectionString, {
    int maxConnections = 10,
    Duration connectionTimeout = const Duration(seconds: 30),
    Duration idleTimeout = const Duration(minutes: 10),
    Duration maxConnectionAge = const Duration(hours: 1),
  }) {
    final uri = Uri.parse(connectionString);

    if (!['postgresql', 'postgres'].contains(uri.scheme)) {
      throw ArgumentError(
        'Invalid connection string scheme: ${uri.scheme}. '
        'Expected "postgresql" or "postgres".',
      );
    }

    final queryParams = uri.queryParameters;
    final sslMode = _parseSslMode(queryParams['sslmode']);

    // Extract username and password from userInfo
    String? username;
    String? password;
    if (uri.userInfo.isNotEmpty) {
      final parts = uri.userInfo.split(':');
      username = Uri.decodeComponent(parts[0]);
      if (parts.length > 1) {
        password = Uri.decodeComponent(parts.sublist(1).join(':'));
      }
    }

    // Extract database name from path (remove leading slash)
    final database = uri.path.startsWith('/')
        ? uri.path.substring(1)
        : uri.path;

    if (database.isEmpty) {
      throw ArgumentError('Database name is required in connection string');
    }

    return PostgresConfig(
      host: uri.host,
      port: uri.port != 0 ? uri.port : 5432,
      database: database,
      username: username,
      password: password,
      sslMode: sslMode,
      maxConnections: maxConnections,
      connectionTimeout: connectionTimeout,
      idleTimeout: idleTimeout,
      maxConnectionAge: maxConnectionAge,
      schema: queryParams['schema'] ?? 'public',
      applicationName: queryParams['application_name'] ?? 'libspiffy',
      sslRootCertPath: queryParams['sslrootcert'],
    );
  }

  /// The mode for an `sslmode` parameter, or `null` when there is none, so
  /// the constructor derives it (`require`, or `verify-full` when a root
  /// certificate is given).
  static SslMode? _parseSslMode(String? value) {
    switch (value) {
      case null:
        return null;
      case 'allow':
      case 'prefer':
      case 'require':
        return SslMode.require;
      case 'verify-ca':
      case 'verify-full':
        return SslMode.verifyFull;
      case 'disable':
        return SslMode.disable;
      default:
        throw ArgumentError.value(
          value,
          'sslmode',
          'Unsupported sslmode (expected disable, allow, prefer, require, '
              'verify-ca or verify-full)',
        );
    }
  }

  static String _sslModeParameter(SslMode mode) => switch (mode) {
        SslMode.disable => 'disable',
        SslMode.require => 'require',
        SslMode.verifyFull => 'verify-full',
      };

  /// Creates an [Endpoint] for the postgres package.
  Endpoint toEndpoint() {
    return Endpoint(
      host: host,
      port: port,
      database: database,
      username: username,
      password: password,
    );
  }

  /// Creates a connection pool with the configured settings.
  ///
  /// The pool manages connections automatically, reusing connections
  /// across queries and handling connection lifecycle.
  Future<Pool> createPool() async {
    return Pool.withEndpoints([toEndpoint()], settings: toPoolSettings());
  }

  /// The pool settings [createPool] uses.
  ///
  /// Build this once per pool: the pool only reuses a connection whose
  /// settings (including the [ConnectionSettings.onOpen] callback identity)
  /// match.
  PoolSettings toPoolSettings() => PoolSettings(
        maxConnectionCount: maxConnections,
        maxConnectionAge: maxConnectionAge,
        sslMode: sslMode,
        securityContext: resolveSecurityContext(),
        applicationName: applicationName,
        connectTimeout: connectionTimeout,
        onOpen: _onOpen,
      );

  /// The connection settings [createConnection] uses.
  ConnectionSettings toConnectionSettings() => ConnectionSettings(
        sslMode: sslMode,
        securityContext: resolveSecurityContext(),
        applicationName: applicationName,
        connectTimeout: connectionTimeout,
        onOpen: _onOpen,
      );

  /// Applies the per-session options (schema, idle timeout) to a newly
  /// opened connection.
  Future<void> _onOpen(Connection connection) async {
    if (schema != 'public') {
      await connection.execute(
        'SET search_path TO "${schema.replaceAll('"', '""')}"',
      );
    }
    if (idleTimeout > Duration.zero) {
      try {
        await connection.execute(
          "SET idle_session_timeout = '${idleTimeout.inMilliseconds}ms'",
        );
      } on ServerException catch (e) {
        // 42704 undefined_object: the server predates PostgreSQL 14 and has
        // no idle_session_timeout. Connections then simply stay open.
        if (e.code != '42704') rethrow;
      }
    }
  }

  /// Creates a single database connection.
  ///
  /// Use [createPool] for production workloads. This method is useful
  /// for migrations or administrative tasks that need a dedicated connection.
  Future<Connection> createConnection() async {
    return Connection.open(toEndpoint(), settings: toConnectionSettings());
  }

  /// Returns a connection string representation of this configuration.
  ///
  /// The password is left out unless [includePassword] is true, so the
  /// default result is safe to log. A string without the password parses
  /// back into a config with no password.
  ///
  /// [sslRootCertPath] round-trips as `sslrootcert`. [sslRootCertBytes] and
  /// [securityContext] have no connection-string spelling, so a config
  /// carrying either does not round-trip through this string: the resulting
  /// config trusts nothing beyond the system roots. It stays a summary for
  /// logs, as it already is for [maxConnections] and the timeouts.
  String toConnectionString({bool includePassword = false}) {
    final buffer = StringBuffer('postgresql://');

    if (username != null) {
      buffer.write(Uri.encodeComponent(username!));
      if (includePassword && password != null) {
        buffer.write(':${Uri.encodeComponent(password!)}');
      }
      buffer.write('@');
    }

    buffer.write('$host:$port/$database');

    final params = <String>[];
    if (sslMode != SslMode.require) {
      params.add('sslmode=${_sslModeParameter(sslMode)}');
    }
    if (sslRootCertPath != null) {
      params.add('sslrootcert=${Uri.encodeComponent(sslRootCertPath!)}');
    }
    if (schema != 'public') {
      params.add('schema=${Uri.encodeComponent(schema)}');
    }
    if (applicationName != 'libspiffy') {
      params.add('application_name=${Uri.encodeComponent(applicationName)}');
    }

    if (params.isNotEmpty) {
      buffer.write('?${params.join('&')}');
    }

    return buffer.toString();
  }

  /// Returns a sanitized string representation (without password).
  @override
  String toString() {
    return 'PostgresConfig('
        'host: $host, '
        'port: $port, '
        'database: $database, '
        'username: $username, '
        'sslMode: ${sslMode.name}, '
        '${_sslRootCertDescription()}'
        'maxConnections: $maxConnections'
        ')';
  }

  String _sslRootCertDescription() {
    if (securityContext != null) return 'securityContext: supplied, ';
    if (sslRootCertPath != null) return 'sslRootCert: $sslRootCertPath, ';
    if (sslRootCertBytes != null) {
      return 'sslRootCert: ${sslRootCertBytes!.length} bytes, ';
    }
    return '';
  }

  /// Creates a copy of this configuration with the specified changes.
  ///
  /// [sslMode] wins over [enableSsl]; `enableSsl: true` on a config that
  /// already uses TLS keeps its mode (so [SslMode.verifyFull] is not
  /// downgraded).
  ///
  /// Adding a root certificate to a config left at the default
  /// [SslMode.require], and naming neither [sslMode] nor [enableSsl], gets
  /// [SslMode.verifyFull], exactly as the constructor does: the copy would
  /// otherwise carry a CA it never checks.
  PostgresConfig copyWith({
    String? host,
    int? port,
    String? database,
    String? username,
    String? password,
    bool? enableSsl,
    SslMode? sslMode,
    int? maxConnections,
    Duration? connectionTimeout,
    Duration? idleTimeout,
    Duration? maxConnectionAge,
    String? schema,
    String? applicationName,
    String? sslRootCertPath,
    List<int>? sslRootCertBytes,
    SecurityContext? securityContext,
  }) {
    // `null` leaves the mode to the constructor, which derives it from
    // whether the copy carries a root certificate.
    final SslMode? mode;
    if (sslMode != null) {
      mode = sslMode;
    } else if (enableSsl == null) {
      mode = this.sslMode == SslMode.require ? null : this.sslMode;
    } else if (!enableSsl) {
      mode = SslMode.disable;
    } else {
      mode = this.enableSsl ? this.sslMode : SslMode.require;
    }
    return PostgresConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      database: database ?? this.database,
      username: username ?? this.username,
      password: password ?? this.password,
      sslMode: mode,
      maxConnections: maxConnections ?? this.maxConnections,
      connectionTimeout: connectionTimeout ?? this.connectionTimeout,
      idleTimeout: idleTimeout ?? this.idleTimeout,
      maxConnectionAge: maxConnectionAge ?? this.maxConnectionAge,
      schema: schema ?? this.schema,
      applicationName: applicationName ?? this.applicationName,
      sslRootCertPath: sslRootCertPath ?? this.sslRootCertPath,
      sslRootCertBytes: sslRootCertBytes ?? this.sslRootCertBytes,
      securityContext: securityContext ?? this.securityContext,
    );
  }
}
