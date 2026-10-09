import '../models/fee_rate.dart';

/// Configuration for the ARC service
class ArcServiceConfig {
  /// Base URL for the ARC API
  final String baseUrl;
  
  /// API key for authentication (optional)
  final String? apiKey;
  
  /// Default callback URL for transaction status updates (optional)
  final String? defaultCallbackUrl;

  /// Upper bound on any single HTTP request to ARC. A hung connection used
  /// to block the calling actor indefinitely.
  final Duration requestTimeout;

  /// The lowest rate the wallet pays, set by the app; null for none.
  ///
  /// Every transaction pays this ARC's published policy rate, or this floor
  /// when the policy is lower. An ARC can publish a rate no miner mines at
  /// (GorillaPool's testnet ARC publishes 0 sat/kB); libspiffy assumes no
  /// rate of its own, so the app that knows its network sets the floor.
  final FeeRate? minimumFeeRate;

  /// Create a new ARC service configuration
  const ArcServiceConfig({
    required this.baseUrl,
    this.apiKey,
    this.defaultCallbackUrl,
    this.requestTimeout = const Duration(seconds: 30),
    this.minimumFeeRate,
  });

  /// Configuration for the TAAL testnet ARC service
  static ArcServiceConfig taalTestnet({String? apiKey, FeeRate? minimumFeeRate}) =>
      ArcServiceConfig(
        baseUrl: 'https://arc-test.taal.com/v1',
        apiKey: apiKey,
        minimumFeeRate: minimumFeeRate,
      );

  /// Configuration for the TAAL mainnet ARC service
  static ArcServiceConfig taalMainnet({String? apiKey, FeeRate? minimumFeeRate}) =>
      ArcServiceConfig(
        baseUrl: 'https://arc.taal.com/v1',
        apiKey: apiKey,
        minimumFeeRate: minimumFeeRate,
      );

  /// Configuration for the GorillaPool mainnet ARC service (no API key).
  static ArcServiceConfig gorillaPoolMainnet({String? apiKey, FeeRate? minimumFeeRate}) =>
      ArcServiceConfig(
        baseUrl: 'https://arc.gorillapool.io/v1',
        apiKey: apiKey,
        minimumFeeRate: minimumFeeRate,
      );

  /// Configuration for the GorillaPool testnet ARC service (no API key).
  static ArcServiceConfig gorillaPoolTestnet({String? apiKey, FeeRate? minimumFeeRate}) =>
      ArcServiceConfig(
        baseUrl: 'https://testnet.arc.gorillapool.io/v1',
        apiKey: apiKey,
        minimumFeeRate: minimumFeeRate,
      );

  /// Configuration for the BSV Association's testnet Arcade (no API key).
  ///
  /// Arcade is the Teranode-era successor to ARC. It serves the ARC API at
  /// its root, so the base URL has no `/v1`.
  static ArcServiceConfig bsvaArcadeTestnet({String? apiKey, FeeRate? minimumFeeRate}) =>
      ArcServiceConfig(
        baseUrl: 'https://arcade-v2-testnet-us-1.bsvblockchain.tech',
        apiKey: apiKey,
        minimumFeeRate: minimumFeeRate,
      );

  /// Create a custom configuration
  static ArcServiceConfig custom({
    required String baseUrl,
    String? apiKey,
    String? defaultCallbackUrl,
    FeeRate? minimumFeeRate,
  }) {
    return ArcServiceConfig(
      baseUrl: baseUrl,
      apiKey: apiKey,
      defaultCallbackUrl: defaultCallbackUrl,
      minimumFeeRate: minimumFeeRate,
    );
  }
} 