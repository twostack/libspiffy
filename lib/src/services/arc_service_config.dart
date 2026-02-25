/// Configuration for the ARC service
class ArcServiceConfig {
  /// Base URL for the ARC API
  final String baseUrl;
  
  /// API key for authentication (optional)
  final String? apiKey;
  
  /// Default callback URL for transaction status updates (optional)
  final String? defaultCallbackUrl;

  /// Create a new ARC service configuration
  const ArcServiceConfig({
    required this.baseUrl,
    this.apiKey,
    this.defaultCallbackUrl,
  });

  /// Configuration for the TAAL testnet ARC service
  /// Requires an API key to be provided at runtime
  static ArcServiceConfig taalTestnet({required String apiKey}) =>
      ArcServiceConfig(
        baseUrl: 'https://arc-test.taal.com/v1',
        apiKey: apiKey,
      );

  /// Configuration for the TAAL mainnet ARC service
  static const ArcServiceConfig taalMainnet = ArcServiceConfig(
    baseUrl: 'https://arc.taal.com/v1',
  );

  /// Create a custom configuration
  static ArcServiceConfig custom({
    required String baseUrl,
    String? apiKey,
    String? defaultCallbackUrl,
  }) {
    return ArcServiceConfig(
      baseUrl: baseUrl,
      apiKey: apiKey,
      defaultCallbackUrl: defaultCallbackUrl,
    );
  }
} 