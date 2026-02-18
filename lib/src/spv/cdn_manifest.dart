/// Describes a single chunk of binary block headers on the CDN.
class CdnChunkInfo {
  final String filename;
  final int startHeight;
  final int endHeight;
  final int headerCount;
  final String sha256;
  final int sizeBytes;

  const CdnChunkInfo({
    required this.filename,
    required this.startHeight,
    required this.endHeight,
    required this.headerCount,
    required this.sha256,
    required this.sizeBytes,
  });

  factory CdnChunkInfo.fromJson(Map<String, dynamic> json) {
    return CdnChunkInfo(
      filename: json['filename'] as String,
      startHeight: json['startHeight'] as int,
      endHeight: json['endHeight'] as int,
      headerCount: json['headerCount'] as int,
      sha256: json['sha256'] as String,
      sizeBytes: json['sizeBytes'] as int,
    );
  }

  Map<String, dynamic> toJson() => {
    'filename': filename,
    'startHeight': startHeight,
    'endHeight': endHeight,
    'headerCount': headerCount,
    'sha256': sha256,
    'sizeBytes': sizeBytes,
  };
}

/// CDN manifest describing all available header chunks for a network.
class CdnManifest {
  final int version;
  final String network;
  final DateTime generatedAt;
  final int totalHeaders;
  final int chunkSize;
  final int headerSizeBytes;
  final List<CdnChunkInfo> chunks;

  /// Hardcoded checkpoint hashes: height -> expected block hash.
  final Map<int, String> checkpoints;

  const CdnManifest({
    required this.version,
    required this.network,
    required this.generatedAt,
    required this.totalHeaders,
    required this.chunkSize,
    this.headerSizeBytes = 80,
    required this.chunks,
    required this.checkpoints,
  });

  factory CdnManifest.fromJson(Map<String, dynamic> json) {
    final chunksJson = json['chunks'] as List<dynamic>;
    final checkpointsJson = json['checkpoints'] as Map<String, dynamic>? ?? {};

    return CdnManifest(
      version: json['version'] as int,
      network: json['network'] as String,
      generatedAt: DateTime.parse(json['generatedAt'] as String),
      totalHeaders: json['totalHeaders'] as int,
      chunkSize: json['chunkSize'] as int,
      headerSizeBytes: json['headerSizeBytes'] as int? ?? 80,
      chunks: chunksJson
          .map((c) => CdnChunkInfo.fromJson(c as Map<String, dynamic>))
          .toList(),
      checkpoints: checkpointsJson.map(
        (k, v) => MapEntry(int.parse(k), v as String),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'network': network,
    'generatedAt': generatedAt.toIso8601String(),
    'totalHeaders': totalHeaders,
    'chunkSize': chunkSize,
    'headerSizeBytes': headerSizeBytes,
    'chunks': chunks.map((c) => c.toJson()).toList(),
    'checkpoints': checkpoints.map((k, v) => MapEntry(k.toString(), v)),
  };
}

/// Result of a CDN header sync operation.
class CdnSyncResult {
  final bool success;
  final int headersImported;
  final int finalHeight;
  final Duration elapsed;
  final String? error;

  const CdnSyncResult({
    required this.success,
    required this.headersImported,
    required this.finalHeight,
    required this.elapsed,
    this.error,
  });
}
