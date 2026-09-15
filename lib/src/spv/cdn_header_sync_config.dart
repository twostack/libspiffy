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
///
/// The CDN is an untrusted transport (audit finding SPV-04). Nothing it
/// serves is believed on its own: the first header must be the in-code
/// genesis block of [network] (see `NetworkParams`), every header must link
/// to the one before it and carry valid proof of work at or below the
/// network's `powLimit`, and the connection must be https unless
/// [allowInsecureHttp] is set for local testing.
class CdnHeaderSyncConfig {
  /// Base URL for CDN (e.g., "https://headers.spiffywallet.com").
  ///
  /// Must use the `https` scheme unless [allowInsecureHttp] is true; see
  /// [checkBaseUrl].
  final String baseUrl;

  /// Network subdirectory ("testnet", "mainnet" or "regtest"). Also selects
  /// the consensus constants (genesis block, proof-of-work limit) the
  /// downloaded headers are checked against.
  final String network;

  /// Unused: chunks are downloaded one at a time.
  ///
  /// `CdnHeaderSyncService` validates and imports each chunk before it
  /// fetches the next, because every chunk must link to the one before it
  /// and the service holds one chunk (~8 MB) in memory at a time. Parallel
  /// downloads would multiply that peak without speeding up validation, so
  /// this value has never been read (audit SPV-16).
  @Deprecated('Unused: CDN chunks are downloaded sequentially. Will be removed.')
  final int concurrentDownloads;

  /// Timeout per chunk download
  final Duration downloadTimeout;

  /// Whether to validate proof-of-work for CDN-sourced headers.
  ///
  /// Defaults to true: each header's hash must be at or below its own
  /// target, and that target must be no easier than the network's
  /// `powLimit`. Turning this off means any header the CDN serves that
  /// merely links to the previous one is accepted; only do that for
  /// synthetic test data.
  final bool validateProofOfWork;

  /// Whether to compare block hashes against the checkpoints listed in the
  /// CDN manifest.
  ///
  /// Manifest checkpoints come from the same origin as the headers, so they
  /// are advisory only: a mismatch rejects the chunk, but a match proves
  /// nothing on its own and can never replace the in-code genesis anchor or
  /// proof-of-work validation.
  final bool verifyCheckpoints;

  /// Permit a plaintext `http` [baseUrl].
  ///
  /// Defaults to false. Intended only for a CDN mock on localhost during
  /// development and tests; a plaintext CDN lets a network attacker choose
  /// which headers the wallet sees.
  final bool allowInsecureHttp;

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
    this.validateProofOfWork = true,
    this.verifyCheckpoints = true,
    this.allowInsecureHttp = false,
    this.onProgress,
    this.cacheDirectory,
    this.maxRetries = 3,
  });

  /// Throws an [ArgumentError] unless [baseUrl] is an absolute `https` URL,
  /// or an `http` URL and [allowInsecureHttp] is set.
  ///
  /// `CdnHeaderSyncService` calls this in its constructor, so a plaintext
  /// CDN is refused before any request is made.
  void checkBaseUrl() {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ArgumentError.value(
          baseUrl, 'baseUrl', 'must be an absolute https URL');
    }
    if (uri.scheme == 'https') return;
    if (uri.scheme == 'http' && allowInsecureHttp) return;
    throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'CDN header sync requires https; set allowInsecureHttp: true only '
            'for a local test CDN');
  }
}
