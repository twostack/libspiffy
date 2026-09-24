# CDN Block Header Sync Guide

Fast initial block header synchronization via pre-built binary files hosted on a CDN, replacing the slow Bitcoin P2P `getheaders` protocol for first-time wallet setup.

## Overview

A fresh wallet needs all block headers for SPV validation. Via P2P, this means ~860 sequential round-trips at 2,000 headers each -- easily 30+ minutes on testnet. CDN sync downloads the same headers as compact binary files in parallel, completing in under 2 minutes.

**How it works:**

1. A one-time export tool converts block headers to chunked 80-byte binary files
2. These files are hosted on any static file server or CDN
3. On first wallet setup, LibSpiffy downloads the chunks, validates them, and bulk-imports
4. P2P sync then handles only the small delta of recent blocks

## Generating CDN Data

### Prerequisites

- A block header source: either a `block_headers.json` backup file (OverNode format) or an existing Isar/PostgreSQL database with synced headers
- Dart SDK installed

### Step 1: Export headers to binary chunks

From the `libspiffy` directory:

```bash
dart run tool/export_headers_to_cdn.dart \
  --source /path/to/block_headers.json \
  --output /path/to/cdn/testnet \
  --network testnet \
  --chunk-size 50000
```

**Options:**

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--source` | Yes | -- | Path to `block_headers.json` backup file |
| `--output` | Yes | -- | Output directory for CDN files |
| `--network` | No | `testnet` | Network name (`testnet` or `mainnet`) |
| `--chunk-size` | No | `50000` | Number of headers per binary chunk file |

**Input format** -- The source JSON is an array of header objects:

```json
[
  {
    "height": 1,
    "hash": "00000000b873e79784...",
    "prevBlockHash": "000000000933ea01ad...",
    "merkleRoot": "f0315ffc38709d70ad...",
    "timestamp": 1296688928,
    "version": 1,
    "bits": 486604799,
    "nonce": 1924588547,
    "isOrphaned": false,
    "storedAt": "2026-01-05T01:59:06.149754"
  }
]
```

Orphaned headers (`"isOrphaned": true`) are automatically skipped.

### Step 2: Verify the output

The tool produces:

```
testnet/
  manifest.json                        # Chunk index with SHA-256 hashes + checkpoints
  headers_0000001_0050000.bin          # 50,000 headers * 80 bytes = 4 MB
  headers_0050001_0100000.bin
  ...
  headers_1700001_1719437.bin          # Final partial chunk
```

Each `.bin` file contains raw 80-byte Bitcoin block headers concatenated sequentially:

```
[version:4][prevBlock:32][merkleRoot:32][timestamp:4][bits:4][nonce:4] = 80 bytes
```

The `manifest.json` contains:

```json
{
  "version": 1,
  "network": "testnet",
  "generatedAt": "2026-02-18T03:07:36.224805Z",
  "totalHeaders": 1719437,
  "chunkSize": 50000,
  "headerSizeBytes": 80,
  "chunks": [
    {
      "filename": "headers_0000001_0050000.bin",
      "startHeight": 1,
      "endHeight": 50000,
      "headerCount": 50000,
      "sha256": "fd20ca4ceb4a58cc9544918cfa99e888c0ae0e737742bb5a4e4ce38b5127a415",
      "sizeBytes": 4000000
    }
  ],
  "checkpoints": {
    "100000": "00000000009e2958c15ff9290d571bf9459e93b19765c6801ddeccadbb160a1e",
    "200000": "0000000000287bffd321963ef05feab753ebe274e1d78b2fd4e2bfe9ad3aa6f2"
  }
}
```

Checkpoints are automatically generated every 100,000 blocks using the block hash from the source data.

### Step 3: Host the files

Upload the output directory to any static file server. The files are served as-is with no server-side logic required.

**Examples:**

```bash
# Local testing with Python
cd /path/to/cdn && python3 -m http.server 8080

# AWS S3 + CloudFront
aws s3 sync /path/to/cdn/testnet s3://your-bucket/testnet

# Nginx
# Point root to the CDN directory, enable gzip for .json files
```

The expected URL structure is:

```
https://your-cdn.com/testnet/manifest.json
https://your-cdn.com/testnet/headers_0000001_0050000.bin
https://your-cdn.com/testnet/headers_0050001_0100000.bin
...
```

## Consuming CDN Data in LibSpiffy

### Basic usage

```dart
await libspiffy.initialize(
  cdnBaseUrl: 'https://your-cdn.com',
  networkType: 'test',
  enableP2P: true,
  onHeaderSyncProgress: (current, total, phase) {
    print('CDN sync: $phase - $current/$total headers');
  },
);
```

CDN sync runs automatically during `initialize()`:
1. Fetches `manifest.json` from `{cdnBaseUrl}/{network}/`
2. Determines which chunks are needed (skips already-synced ranges)
3. Downloads chunks with 4 concurrent HTTP connections
4. Validates SHA-256 integrity, chain continuity, and checkpoints
5. Bulk-inserts into storage (Isar or PostgreSQL)
6. P2P sync then picks up any remaining blocks

If the CDN is unavailable or validation fails, initialization continues normally and P2P handles the full sync.

### Configuration options

Pass a `CdnHeaderSyncConfig` for fine-grained control:

```dart
final cdnConfig = CdnHeaderSyncConfig(
  baseUrl: 'https://your-cdn.com',
  network: 'testnet',
  concurrentDownloads: 4,         // Parallel chunk downloads (default: 4)
  downloadTimeout: Duration(seconds: 30),
  validateProofOfWork: false,     // PoW check per header (default: false, slow)
  verifyCheckpoints: true,        // Verify manifest checkpoints (default: true)
  onProgress: (current, total, phase) { ... },
);
```

### Progress phases

The `onProgress` callback reports these phases:

| Phase | Description |
|-------|-------------|
| `fetchingManifest` | Downloading `manifest.json` |
| `downloadingChunks` | Downloading binary chunk files in parallel |
| `validatingChunks` | Verifying SHA-256 hashes and chain continuity |
| `importingHeaders` | Bulk-inserting into storage |
| `complete` | CDN sync finished successfully |
| `fallbackToP2P` | CDN sync failed, P2P will handle it |

## Updating CDN Data

When new blocks are mined, the CDN data becomes stale. To update:

1. Get a fresh `block_headers.json` backup from a fully-synced node
2. Re-run the export tool with the new source file
3. Upload the new files to the CDN (overwrite existing)

The wallet handles the gap between CDN data and the current chain tip via normal P2P sync. A CDN that's a few days behind is fine -- P2P fills the small delta quickly.

## Validation & Security

CDN-served headers go through multiple validation layers:

1. **SHA-256 chunk integrity** -- each downloaded chunk's hash must match the manifest
2. **Chain continuity** -- every header's `prevBlock` must equal the previous header's hash
3. **Checkpoint verification** -- block hashes at known heights must match the manifest's checkpoint values
4. **Proof-of-work** (optional) -- each header meets its stated difficulty target

This means a malicious CDN cannot serve fabricated headers unless they also solve proof-of-work for every block -- the same security guarantee as P2P sync.

## Size Estimates

| Network | Headers | Binary size | Chunks (50K each) |
|---------|---------|-------------|-------------------|
| BSV Testnet | ~1.7M | ~136 MB | 35 |
| BSV Mainnet | ~880K | ~70 MB | 18 |

Binary format is ~4-5x smaller than JSON. CDN edge servers can further compress with gzip/brotli on the wire.
