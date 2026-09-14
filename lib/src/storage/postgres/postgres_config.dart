/// PostgreSQL configuration for libspiffy server-side deployments.
///
/// Provides connection configuration and pool management for PostgreSQL.
library;

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
  }) : sslMode = sslMode ??
            (enableSsl == false ? SslMode.disable : SslMode.require);

  /// Whether connections use TLS at all.
  bool get enableSsl => sslMode != SslMode.disable;

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
  ///   `verify-full` ([SslMode.verifyFull]). Default: `require`. Any other
  ///   value throws [ArgumentError].
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
    );
  }

  static SslMode _parseSslMode(String? value) {
    switch (value) {
      case null:
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
        applicationName: applicationName,
        connectTimeout: connectionTimeout,
        onOpen: _onOpen,
      );

  /// The connection settings [createConnection] uses.
  ConnectionSettings toConnectionSettings() => ConnectionSettings(
        sslMode: sslMode,
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
        'maxConnections: $maxConnections'
        ')';
  }

  /// Creates a copy of this configuration with the specified changes.
  ///
  /// [sslMode] wins over [enableSsl]; `enableSsl: true` on a config that
  /// already uses TLS keeps its mode (so [SslMode.verifyFull] is not
  /// downgraded).
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
  }) {
    final SslMode mode;
    if (sslMode != null) {
      mode = sslMode;
    } else if (enableSsl == null) {
      mode = this.sslMode;
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
    );
  }
}
