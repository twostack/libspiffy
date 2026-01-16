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

  /// Whether to use SSL/TLS for connections.
  final bool enableSsl;

  /// Maximum number of connections in the pool.
  final int maxConnections;

  /// Maximum time to wait for a connection from the pool.
  final Duration connectionTimeout;

  /// Maximum time a connection can be idle before being closed.
  final Duration idleTimeout;

  /// Maximum lifetime of a connection before it's recycled.
  final Duration maxConnectionAge;

  /// Schema name to use (default: 'public').
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
  /// - [enableSsl]: Use SSL (default: false)
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
    this.enableSsl = false,
    this.maxConnections = 10,
    this.connectionTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(minutes: 10),
    this.maxConnectionAge = const Duration(hours: 1),
    this.schema = 'public',
    this.applicationName = 'libspiffy',
  });

  /// Creates a configuration from a PostgreSQL connection string.
  ///
  /// Supported formats:
  /// - `postgresql://user:password@host:port/database`
  /// - `postgres://user:password@host:port/database`
  /// - `postgresql://user:password@host:port/database?sslmode=require`
  ///
  /// Query parameters:
  /// - `sslmode`: 'require' or 'disable' (default: disable)
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
    final sslMode = queryParams['sslmode'] ?? 'disable';
    final enableSsl = sslMode == 'require' || sslMode == 'verify-full';

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
      enableSsl: enableSsl,
      maxConnections: maxConnections,
      connectionTimeout: connectionTimeout,
      idleTimeout: idleTimeout,
      maxConnectionAge: maxConnectionAge,
      schema: queryParams['schema'] ?? 'public',
      applicationName: queryParams['application_name'] ?? 'libspiffy',
    );
  }

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
    return Pool.withEndpoints(
      [toEndpoint()],
      settings: PoolSettings(
        maxConnectionCount: maxConnections,
        maxConnectionAge: maxConnectionAge,
        sslMode: enableSsl ? SslMode.require : SslMode.disable,
        applicationName: applicationName,
        connectTimeout: connectionTimeout,
      ),
    );
  }

  /// Creates a single database connection.
  ///
  /// Use [createPool] for production workloads. This method is useful
  /// for migrations or administrative tasks that need a dedicated connection.
  Future<Connection> createConnection() async {
    return Connection.open(
      toEndpoint(),
      settings: ConnectionSettings(
        sslMode: enableSsl ? SslMode.require : SslMode.disable,
        applicationName: applicationName,
        connectTimeout: connectionTimeout,
      ),
    );
  }

  /// Returns a connection string representation of this configuration.
  ///
  /// Note: The password is included in the string, so be careful
  /// when logging or displaying this value.
  String toConnectionString() {
    final buffer = StringBuffer('postgresql://');

    if (username != null) {
      buffer.write(Uri.encodeComponent(username!));
      if (password != null) {
        buffer.write(':${Uri.encodeComponent(password!)}');
      }
      buffer.write('@');
    }

    buffer.write('$host:$port/$database');

    final params = <String>[];
    if (enableSsl) {
      params.add('sslmode=require');
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
        'ssl: $enableSsl, '
        'maxConnections: $maxConnections'
        ')';
  }

  /// Creates a copy of this configuration with the specified changes.
  PostgresConfig copyWith({
    String? host,
    int? port,
    String? database,
    String? username,
    String? password,
    bool? enableSsl,
    int? maxConnections,
    Duration? connectionTimeout,
    Duration? idleTimeout,
    Duration? maxConnectionAge,
    String? schema,
    String? applicationName,
  }) {
    return PostgresConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      database: database ?? this.database,
      username: username ?? this.username,
      password: password ?? this.password,
      enableSsl: enableSsl ?? this.enableSsl,
      maxConnections: maxConnections ?? this.maxConnections,
      connectionTimeout: connectionTimeout ?? this.connectionTimeout,
      idleTimeout: idleTimeout ?? this.idleTimeout,
      maxConnectionAge: maxConnectionAge ?? this.maxConnectionAge,
      schema: schema ?? this.schema,
      applicationName: applicationName ?? this.applicationName,
    );
  }
}
