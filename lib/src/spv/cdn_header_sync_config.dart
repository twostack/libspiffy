/// Phase of CDN block header synchronization.
enum CdnSyncPhase {
  fetchingManifest,
  downloadingChunks,
  validatingChunks,
  importingHeaders,
  complete,
  fallbackToP2P,
}

/// Callback type for CDN sync progress reporting.
typedef CdnSyncProgressCallback = void Function(
  int current,
  int total,
  CdnSyncPhase phase,
);

/// Configuration for CDN-based fast initial block header sync.
class CdnHeaderSyncConfig {
  /// Base URL for CDN (e.g., "https://headers.spiffywallet.com")
  final String baseUrl;

  /// Network subdirectory ("testnet" or "mainnet")
  final String network;

  /// Number of concurrent chunk downloads (default: 4)
  final int concurrentDownloads;

  /// Timeout per chunk download
  final Duration downloadTimeout;

  /// Whether to validate proof-of-work for CDN-sourced headers
  final bool validateProofOfWork;

  /// Whether to verify checkpoints from manifest
  final bool verifyCheckpoints;

  /// Progress callback: (downloadedHeaders, totalHeaders, phase)
  final CdnSyncProgressCallback? onProgress;

  /// Optional directory for caching downloaded chunks to disk.
  /// Enables crash-resilient sync — cached chunks survive app restarts.
  /// When null, chunks are held in memory only.
  final String? cacheDirectory;

  /// Max retry attempts per chunk download (default: 3)
  final int maxRetries;

  const CdnHeaderSyncConfig({
    required this.baseUrl,
    required this.network,
    this.concurrentDownloads = 4,
    this.downloadTimeout = const Duration(seconds: 30),
    this.validateProofOfWork = false,
    this.verifyCheckpoints = true,
    this.onProgress,
    this.cacheDirectory,
    this.maxRetries = 3,
  });
}
