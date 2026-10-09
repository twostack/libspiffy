# CDN Block Header Sync Guide

Fast initial block header synchronization via pre-built binary files hosted on a CDN, replacing the slow Bitcoin P2P `getheaders` protocol for first-time wallet setup.

## Overview

A fresh wallet needs all block headers for SPV validation. Via P2P, this means ~860 sequential round-trips at 2,000 headers each -- easily 30+ minutes on testnet. CDN sync downloads the same headers as compact binary files, completing in under 2 minutes.

**How it works:**

1. A one-time export tool converts block headers to chunked 80-byte binary files
2. These files are hosted on any static file server or CDN
3. On first wallet setup, LibSpiffy downloads the chunks, validates them, and bulk-imports
4. P2P sync then handles only the small delta of recent blocks

## Generating CDN Data

### Prerequisites

- A block header source: a `block_headers.json` backup file (OverNode format), or WhatsOnChain (see [Building from WhatsOnChain](#building-from-whatsonchain))
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

### Building from WhatsOnChain

Without a backup file, `tool/fetch_woc_headers_to_cdn.dart` builds the same layout from the raw header files WhatsOnChain publishes:

```bash
dart run tool/fetch_woc_headers_to_cdn.dart \
  --network mainnet \
  --output /path/to/cdn/mainnet \
  [--cache /path/to/cache] [--chunk-size 50000] [--reorg-margin 100]
```

`--network` is `mainnet` or `testnet`. Before writing anything it checks that block 0 is the network's genesis block, that every header links to the one before it, and that every header meets its own difficulty target. It leaves out the newest `--reorg-margin` blocks (default 100), so a tip that is later reorganised away never reaches the CDN. Downloads are cached in `--cache` (default `<output>/.woc-cache`), so a rerun fetches only new files.

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
# Local testing with Python (plain http: only CdnHeaderSyncService with allowInsecureHttp: true accepts it)
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
1. Fetches `manifest.json` from `{cdnBaseUrl}/{network}/`, where `{network}` is `mainnet`, `testnet` or `regtest`, from `networkType`
2. Determines which chunks are needed (skips already-synced ranges)
3. Processes one chunk at a time: downloads it (cached on disk in `dataDirectory`, when given, until imported), validates it, and imports it before downloading the next
4. Validates SHA-256 integrity, the link to the stored tip (or the genesis block), chain continuity, proof of work, and checkpoints
5. Bulk-inserts into storage (Isar or PostgreSQL)
6. P2P sync then picks up any remaining blocks

`cdnBaseUrl` must be an `https` URL. A failed pass is retried from where it stopped, up to three passes. If the CDN is still unavailable or validation fails, initialization continues normally, the headers already imported stay, and P2P handles the rest. Pass `onHeaderSyncResult` to learn how the sync ended (a `CdnSyncResult` with `success`, `headersImported`, `finalHeight` and `error`).

### Configuration options

`initialize()` builds its `CdnHeaderSyncConfig` from its own parameters. To run a sync yourself, pass a `CdnHeaderSyncConfig` to `CdnHeaderSyncService`:

```dart
final cdnConfig = CdnHeaderSyncConfig(
  baseUrl: 'https://your-cdn.com',
  network: 'testnet',
  downloadTimeout: Duration(seconds: 30),
  validateProofOfWork: true,      // PoW check per header (default: true)
  verifyCheckpoints: true,        // Verify manifest checkpoints (default: true)
  allowInsecureHttp: false,       // Permit an http baseUrl, for a local test CDN (default: false)
  cacheDirectory: '/path/to/cache', // Keep downloaded chunks on disk until imported (default: memory only)
  maxRetries: 3,                  // Download attempts per chunk (default: 3)
  onProgress: (current, total, phase) { ... },
);

final result = await CdnHeaderSyncService(
  config: cdnConfig,
  headerChain: libspiffy.headerChain,
).synchronize();
```

### Progress phases

The `onProgress` callback reports these phases:

| Phase | Description |
|-------|-------------|
| `fetchingManifest` | Downloading `manifest.json` |
| `downloadingChunks` | Downloading a binary chunk file |
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

1. **SHA-256 chunk integrity** -- each downloaded chunk's hash must match the manifest (a transport check only: the manifest comes from the same CDN)
2. **Anchoring** -- the first new header must link to the stored tip, or be the network's genesis block built into the code
3. **Chain continuity** -- every header's `prevBlock` must equal the previous header's hash
4. **Proof-of-work** (on by default) -- each header's hash is at or below its own target, and that target is no easier than the network's proof-of-work limit
5. **Checkpoint verification** -- block hashes at known heights must match the manifest's checkpoint values. These are advisory: a mismatch rejects the chunk, a match proves nothing on its own

This means a malicious CDN cannot serve fabricated headers unless they also solve proof-of-work for every block -- the same security guarantee as P2P sync. A CDN URL must be `https`, so a network attacker cannot choose which headers the wallet sees.

## Size Estimates

| Network | Headers | Binary size | Chunks (50K each) |
|---------|---------|-------------|-------------------|
| BSV Testnet | ~1.7M | ~136 MB | 35 |
| BSV Mainnet | ~880K | ~70 MB | 18 |

Binary format is ~4-5x smaller than JSON. CDN edge servers can further compress with gzip/brotli on the wire.
