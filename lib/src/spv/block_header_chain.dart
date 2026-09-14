import 'dart:async';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' show sha256;
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart';

import '../storage/read_model_storage.dart';
import '../utils/hex_utils.dart' as hex_utils;
import 'difficulty_rules.dart';
import 'network_params.dart';

/// The header a [BlockHeaderChain] is anchored to: normally the network
/// genesis at height 0, optionally a hard-coded checkpoint further up.
class BlockHeaderAnchor {
  final BlockHeader header;
  final int height;

  const BlockHeaderAnchor(this.header, this.height);

  String get hash => header.blockHash().toString();
}

/// Why a header was not accepted.
enum HeaderRejectReason {
  /// The chain is empty and the header is neither the anchor nor a child
  /// of it.
  notAnchor,

  /// The header's `prevBlock` is not a known header on any branch.
  unknownParent,

  /// The caller's height does not match the parent's height + 1.
  heightMismatch,

  /// `bits` do not decode to a target between 1 and the pow limit.
  invalidTarget,

  /// The block hash is above the header's own target.
  insufficientWork,

  /// `bits` violate the network's difficulty rule.
  difficulty,

  /// Timestamp at or below the median of the previous 11 headers.
  timestampTooOld,

  /// Timestamp more than two hours in the future.
  timestampTooFar,

  /// The storage layer failed.
  storage,
}

/// Result of [BlockHeaderChain.acceptHeader].
class HeaderAcceptResult {
  final bool accepted;

  /// Height the header sits at (derived from its parent), when known.
  final int? height;

  /// Whether the header is already known (on the active chain or a side
  /// branch); such headers are accepted without being stored again.
  final bool alreadyKnown;

  /// Whether the header is now the active chain tip.
  final bool isNewTip;

  /// Whether accepting it moved the tip to a different branch.
  final bool reorganized;

  /// Height of the common ancestor when [reorganized].
  final int? forkHeight;

  /// Headers that left the active chain when [reorganized], oldest first.
  final List<BlockHeader> orphaned;

  final HeaderRejectReason? reason;
  final String? detail;

  const HeaderAcceptResult._({
    required this.accepted,
    this.height,
    this.alreadyKnown = false,
    this.isNewTip = false,
    this.reorganized = false,
    this.forkHeight,
    this.orphaned = const [],
  })  : reason = null,
        detail = null;

  const HeaderAcceptResult.rejected(this.reason, this.detail, {this.height})
      : accepted = false,
        alreadyKnown = false,
        isNewTip = false,
        reorganized = false,
        forkHeight = null,
        orphaned = const [];

  @override
  String toString() => accepted
      ? 'HeaderAcceptResult(accepted at $height'
          '${alreadyKnown ? ', already known' : ''}'
          '${isNewTip ? ', new tip' : ''}'
          '${reorganized ? ', reorg from $forkHeight orphaning ${orphaned.length}' : ''})'
      : 'HeaderAcceptResult(rejected: $reason, $detail)';
}

/// A header that is stored in memory but not on the active chain.
class _SideHeader {
  final BlockHeader header;
  final int height;
  final String hash;
  final String parentHash;

  /// Height of the active-chain header this branch forks from.
  final int forkHeight;

  /// Cumulative work of this branch above [forkHeight], including this
  /// header.
  final BigInt workAboveFork;

  _SideHeader({
    required this.header,
    required this.height,
    required this.hash,
    required this.parentHash,
    required this.forkHeight,
    required this.workAboveFork,
  });
}

/// Manages the block header chain for SPV validation.
///
/// Anchoring: the chain is anchored to [anchor] (the network genesis by
/// default). `initialize()` seeds the anchor into an empty store and refuses
/// a store whose anchor height holds a different header, or that starts one
/// above the anchor without linking to it. A store written by the previous,
/// unanchored code (heights from 1, no genesis) is accepted when its height-1
/// header links to the genesis, and the genesis is back-filled at height 0.
///
/// Validation: every header must name a known parent (its height is derived
/// from the parent, never from the caller), decode `bits` to a target in
/// (0, powLimit], hash at or below that target, satisfy the network
/// difficulty rule ([DifficultyRules]), carry a timestamp above the median
/// of the previous eleven and at most two hours ahead of [clock].
///
/// Fork choice: the tip is the branch with the most cumulative work above
/// the common ancestor (work = 2^256 / (target + 1)). Competing branches are
/// held in memory; when one overtakes the active chain, the active headers
/// above the fork are marked orphaned in storage, the branch is stored, and
/// the tip moves. Equal work keeps the current tip. Chainwork is recomputed
/// from `bits` over the fork window, so nothing extra is persisted.
class BlockHeaderChain {
  final ReadModelStorage _storage;
  final Logger _logger;
  final bool _skipProofOfWorkValidation;
  final NetworkParams params;
  final BlockHeaderAnchor anchor;
  final DateTime Function() _clock;

  // In-memory cache of recent active-chain headers.
  final Map<String, BlockHeader> _headerCache = {};
  final Map<int, String> _heightToHash = {};
  final Map<String, int> _hashToHeight = {};

  // Headers off the active chain, keyed by hash.
  final Map<String, _SideHeader> _sideHeaders = {};

  // Chain state
  BlockHeader? _chainTip;
  int _bestHeight = 0;

  // Memoised work of the active chain above a fork height; cleared when
  // the tip changes.
  final Map<int, BigInt> _activeWorkAboveFork = {};

  static const int _maxCacheSize = 2016;
  static const int _maxSideHeaders = 200000;
  static const Duration _maxFutureDrift = Duration(hours: 2);
  static const int _medianTimeSpan = 11;

  BlockHeaderChain(
    this._storage, {
    Logger? logger,
    bool skipProofOfWorkValidation = false,
    NetworkParams? params,
    BlockHeaderAnchor? anchor,
    DateTime Function()? clock,
  })  : _logger = logger ?? Logger('BlockHeaderChain'),
        _skipProofOfWorkValidation = skipProofOfWorkValidation,
        params = params ?? NetworkParams.forNetwork(null),
        anchor = anchor ??
            BlockHeaderAnchor((params ?? NetworkParams.forNetwork(null)).genesisHeader, 0),
        _clock = clock ?? DateTime.now;

  /// Current chain tip header
  BlockHeader? get chainTip => _chainTip;

  /// Best known block height
  int get bestHeight => _bestHeight;

  /// Number of headers in cache
  int get cacheSize => _headerCache.length;

  /// Number of headers held off the active chain.
  int get sideHeaderCount => _sideHeaders.length;

  /// Whether the chain holds any header at all.
  bool get isEmpty => _chainTip == null;

  /// Initialize the header chain by loading the current tip from storage.
  ///
  /// Throws [StateError] when the store holds headers that are not anchored
  /// to [anchor] (wrong network, or a chain installed by an untrusted peer
  /// before anchoring existed). Such a store must be cleared.
  Future<void> initialize() async {
    try {
      _chainTip = await _storage.getChainTip();
      _bestHeight = await _storage.getBestHeight();

      if (_chainTip == null) {
        if (!_skipProofOfWorkValidation) {
          await _storeActive(anchor.header, anchor.height);
          _logger.info('Seeded ${params.name} anchor at height ${anchor.height}: ${anchor.hash}');
        }
      } else if (!_skipProofOfWorkValidation) {
        await _verifyStoredAnchor();
      }

      _logger.info('Initialized header chain: tip at height $_bestHeight');

      if (_chainTip != null) {
        await _loadRecentHeadersIntoCache();
      }
    } catch (e) {
      _logger.severe('Failed to initialize header chain: $e');
      rethrow;
    }
  }

  /// Checks that an existing store is anchored; back-fills the anchor for
  /// a store written by the pre-anchoring code (headers from height 1).
  Future<void> _verifyStoredAnchor() async {
    final atAnchor = await _storage.getBlockHeaderByHeight(anchor.height);
    if (atAnchor != null) {
      final hash = atAnchor.blockHash().toString();
      if (hash != anchor.hash) {
        throw StateError('Header store is not anchored to ${params.name}: height ${anchor.height} '
            'holds $hash, expected ${anchor.hash}. Clear the header database.');
      }
      return;
    }
    final next = await _storage.getBlockHeaderByHeight(anchor.height + 1);
    if (next == null || next.prevBlock.toString() != anchor.hash) {
      throw StateError('Header store is not anchored to ${params.name}: no header at height '
          '${anchor.height} and height ${anchor.height + 1} does not link to ${anchor.hash}. '
          'Clear the header database.');
    }
    await _storage.storeBlockHeader(anchor.header, anchor.height);
    _logger.warning('Back-filled ${params.name} anchor at height ${anchor.height} into a header '
        'store written before anchoring existed');
  }

  /// Validate and store a header at [height].
  ///
  /// The height is derived from the header's parent; this method rejects
  /// the header when [height] disagrees. Prefer [acceptHeader].
  Future<bool> validateAndStoreHeader(BlockHeader header, int height) async {
    final result = await acceptHeader(header, expectedHeight: height);
    return result.accepted;
  }

  /// Validate [header], place it on the branch its parent belongs to, and
  /// move the tip if that branch now carries the most work.
  Future<HeaderAcceptResult> acceptHeader(BlockHeader header, {int? expectedHeight}) async {
    try {
      final hash = header.blockHash().toString();

      // Already active?
      final knownHeight = await _activeHeightOf(hash);
      if (knownHeight != null) {
        if (expectedHeight != null && expectedHeight != knownHeight) {
          return HeaderAcceptResult.rejected(HeaderRejectReason.heightMismatch,
              'header $hash is at height $knownHeight, caller said $expectedHeight',
              height: knownHeight);
        }
        return HeaderAcceptResult._(accepted: true, height: knownHeight, alreadyKnown: true,
            isNewTip: hash == _chainTip?.blockHash().toString());
      }
      final knownSide = _sideHeaders[hash];
      if (knownSide != null) {
        return HeaderAcceptResult._(accepted: true, height: knownSide.height, alreadyKnown: true);
      }

      // Empty chain: only the anchor, or a direct child of it, can start it.
      if (_chainTip == null) {
        return _acceptFirstHeader(header, hash, expectedHeight);
      }

      final parentHash = header.prevBlock.toString();
      final parentActiveHeight = await _activeHeightOf(parentHash);
      final parentSide = parentActiveHeight == null ? _sideHeaders[parentHash] : null;
      if (parentActiveHeight == null && parentSide == null) {
        return HeaderAcceptResult.rejected(
            HeaderRejectReason.unknownParent, 'parent $parentHash of $hash is not known');
      }
      final height = (parentActiveHeight ?? parentSide!.height) + 1;
      if (expectedHeight != null && expectedHeight != height) {
        return HeaderAcceptResult.rejected(HeaderRejectReason.heightMismatch,
            'parent of $hash is at height ${height - 1}, caller said $expectedHeight',
            height: height);
      }

      final ancestry = await _ancestryFor(parentHash, parentActiveHeight, parentSide);
      final prev = (await ancestry.headerAt(height - 1))!;
      final rejection = await _validate(header, hash, height, prev, ancestry);
      if (rejection != null) return rejection;

      // Extends the tip: the common case.
      if (parentActiveHeight != null && parentActiveHeight == _bestHeight) {
        await _storeActive(header, height);
        _logger.fine('Stored header at height $height: ${hash.substring(0, 16)}...');
        return HeaderAcceptResult._(accepted: true, height: height, isNewTip: true);
      }

      // Side branch.
      final forkHeight = parentSide?.forkHeight ?? parentActiveHeight!;
      final work = (parentSide?.workAboveFork ?? BigInt.zero) + DifficultyRules.blockWork(header.bits);
      final side = _SideHeader(
        header: header,
        height: height,
        hash: hash,
        parentHash: parentHash,
        forkHeight: forkHeight,
        workAboveFork: work,
      );
      _sideHeaders[hash] = side;
      _boundSideHeaders();

      final activeWork = await _activeWorkAbove(forkHeight);
      if (work <= activeWork) {
        _logger.info('Header $hash at height $height stored on a side branch forking at '
            '$forkHeight (work $work vs active $activeWork)');
        return HeaderAcceptResult._(accepted: true, height: height);
      }

      final orphaned = await _reorganizeTo(side);
      return HeaderAcceptResult._(
        accepted: true,
        height: height,
        isNewTip: true,
        reorganized: true,
        forkHeight: forkHeight,
        orphaned: orphaned,
      );
    } catch (e, st) {
      _logger.warning('Failed to validate/store header: $e\n$st');
      return HeaderAcceptResult.rejected(HeaderRejectReason.storage, '$e');
    }
  }

  Future<HeaderAcceptResult> _acceptFirstHeader(
      BlockHeader header, String hash, int? expectedHeight) async {
    if (_skipProofOfWorkValidation) {
      // Test mode: whatever comes first is the anchor.
      final height = expectedHeight ?? 0;
      await _storeActive(header, height);
      return HeaderAcceptResult._(accepted: true, height: height, isNewTip: true);
    }
    if (hash == anchor.hash) {
      if (expectedHeight != null && expectedHeight != anchor.height) {
        return HeaderAcceptResult.rejected(HeaderRejectReason.heightMismatch,
            'anchor belongs at height ${anchor.height}, caller said $expectedHeight',
            height: anchor.height);
      }
      final rejection = await _validate(header, hash, anchor.height, null, _EmptyAncestry());
      if (rejection != null) return rejection;
      await _storeActive(header, anchor.height);
      return HeaderAcceptResult._(accepted: true, height: anchor.height, isNewTip: true);
    }
    if (header.prevBlock.toString() == anchor.hash) {
      // Seed the anchor, then accept the child through the normal path.
      await _storeActive(anchor.header, anchor.height);
      return acceptHeader(header, expectedHeight: expectedHeight);
    }
    return HeaderAcceptResult.rejected(HeaderRejectReason.notAnchor,
        'chain is empty and $hash is not the ${params.name} anchor ${anchor.hash} nor its child');
  }

  /// Consensus checks other than linkage. [prev] is null only for the anchor.
  Future<HeaderAcceptResult?> _validate(BlockHeader header, String hash, int height,
      BlockHeader? prev, HeaderAncestry ancestry) async {
    if (_skipProofOfWorkValidation) return null;

    final target = NetworkParams.bitsToTarget(header.bits);
    if (target <= BigInt.zero || target > params.powLimit) {
      return HeaderAcceptResult.rejected(HeaderRejectReason.invalidTarget,
          'bits 0x${header.bits.toRadixString(16)} at height $height decode to a target outside '
          '(0, powLimit]',
          height: height);
    }
    if (prev != null) {
      final verdict = await DifficultyRules.check(params, height, header, prev, ancestry);
      if (!verdict.ok) {
        return HeaderAcceptResult.rejected(HeaderRejectReason.difficulty,
            'bits 0x${header.bits.toRadixString(16)} at height $height violate ${verdict.rule}'
            '${verdict.expectedBits == null ? '' : ' (expected 0x${verdict.expectedBits!.toRadixString(16)})'}',
            height: height);
      }
    }

    if (NetworkParams.hashToBigInt(hash) > target) {
      return HeaderAcceptResult.rejected(HeaderRejectReason.insufficientWork,
          'hash $hash at height $height is above its target', height: height);
    }

    final now = _clock();
    if (header.timestamp.isAfter(now.add(_maxFutureDrift))) {
      return HeaderAcceptResult.rejected(HeaderRejectReason.timestampTooFar,
          'timestamp ${header.timestamp.toUtc()} at height $height is more than 2h ahead of '
          '${now.toUtc()}',
          height: height);
    }

    if (prev == null) return null;

    final mtp = await _medianTimePast(height - 1, ancestry);
    if (!header.timestamp.isAfter(mtp)) {
      return HeaderAcceptResult.rejected(HeaderRejectReason.timestampTooOld,
          'timestamp ${header.timestamp.toUtc()} at height $height is not after the median time '
          'past ${mtp.toUtc()}',
          height: height);
    }
    return null;
  }

  /// Median timestamp of the up-to-eleven headers ending at [height].
  Future<DateTime> _medianTimePast(int height, HeaderAncestry ancestry) async {
    final times = <DateTime>[];
    for (var h = height; h > height - _medianTimeSpan && h >= 0; h--) {
      final a = await ancestry.headerAt(h);
      if (a == null) break;
      times.add(a.timestamp);
    }
    times.sort();
    return times[times.length ~/ 2];
  }

  /// Ancestry accessor for the branch ending at the given parent.
  Future<HeaderAncestry> _ancestryFor(
      String parentHash, int? parentActiveHeight, _SideHeader? parentSide) async {
    if (parentSide == null) return _ActiveAncestry(this);
    // Collect the side-branch path down to the fork point.
    final path = <int, BlockHeader>{};
    var cursor = parentSide;
    while (true) {
      path[cursor.height] = cursor.header;
      final up = _sideHeaders[cursor.parentHash];
      if (up == null) break;
      cursor = up;
    }
    return _SideAncestry(this, path);
  }

  /// Height of [hash] on the active chain, or null.
  Future<int?> _activeHeightOf(String hash) async {
    final cached = _hashToHeight[hash];
    if (cached != null) return cached;
    try {
      return await _storage.getHeightByBlockHash(hash);
    } catch (e) {
      _logger.warning('Failed to get height by hash $hash: $e');
      return null;
    }
  }

  /// Header at [height] on the active chain (cache, then storage).
  Future<BlockHeader?> _activeHeaderAt(int height) async {
    final hash = _heightToHash[height];
    if (hash != null) {
      final cached = _headerCache[hash];
      if (cached != null) return cached;
    }
    try {
      final header = await _storage.getBlockHeaderByHeight(height);
      if (header != null) _cacheActive(header, height);
      return header;
    } catch (e) {
      _logger.warning('Failed to get header by height $height: $e');
      return null;
    }
  }

  /// Work of the active chain strictly above [forkHeight].
  Future<BigInt> _activeWorkAbove(int forkHeight) async {
    final memo = _activeWorkAboveFork[forkHeight];
    if (memo != null) return memo;
    var work = BigInt.zero;
    const chunk = 2000;
    for (var from = forkHeight + 1; from <= _bestHeight; from += chunk) {
      final to = (from + chunk - 1).clamp(from, _bestHeight);
      final headers = await _storage.getBlockHeaderRange(from, to);
      for (final h in headers) {
        work += DifficultyRules.blockWork(h.bits);
      }
    }
    _activeWorkAboveFork[forkHeight] = work;
    return work;
  }

  /// Make the branch ending at [tip] the active chain. Returns the headers
  /// that left the active chain, oldest first.
  Future<List<BlockHeader>> _reorganizeTo(_SideHeader tip) async {
    // Collect the new branch, oldest first.
    final branch = <_SideHeader>[];
    var cursor = tip;
    while (true) {
      branch.add(cursor);
      final up = _sideHeaders[cursor.parentHash];
      if (up == null) break;
      cursor = up;
    }
    final newBranch = branch.reversed.toList();
    final forkHeight = tip.forkHeight;

    _logger.warning('Reorganizing: fork at height $forkHeight, replacing '
        '${_bestHeight - forkHeight} header(s) with ${newBranch.length} '
        '(new tip ${tip.hash} at height ${tip.height})');

    // Old branch, oldest first.
    final orphaned = <BlockHeader>[];
    for (var h = forkHeight + 1; h <= _bestHeight; h++) {
      final old = await _activeHeaderAt(h);
      if (old != null) orphaned.add(old);
    }

    // Retire the old branch first: a backend keyed by height (the in-memory
    // store) can hold only one header per height, so the replacement must
    // not be written while the old header still occupies its height.
    for (var i = 0; i < orphaned.length; i++) {
      final old = orphaned[i];
      final oldHash = old.blockHash().toString();
      final oldHeight = forkHeight + 1 + i;
      await _storage.markHeaderAsOrphaned(oldHash);
      _uncacheActive(oldHash, oldHeight);
    }

    // Store the new branch. storeBlockHeader is an upsert on every backend:
    // a header orphaned by an earlier reorg (a reorg back onto a previous
    // branch) is re-activated with its orphan flag cleared (libspiffy-0v3).
    for (final s in newBranch) {
      try {
        await _storage.storeBlockHeader(s.header, s.height);
      } catch (e) {
        _logger.severe('Could not store reorganized header ${s.hash} at height ${s.height}: '
            '$e. The active tip is correct in memory but storage will not reflect it '
            'after a restart.');
      }
    }
    // Keep the old branch reachable in memory so it can be compared
    // against (and, if it regains the lead, re-activated).
    var oldWork = BigInt.zero;
    for (var i = 0; i < orphaned.length; i++) {
      final old = orphaned[i];
      final oldHash = old.blockHash().toString();
      oldWork += DifficultyRules.blockWork(old.bits);
      _sideHeaders[oldHash] = _SideHeader(
        header: old,
        height: forkHeight + 1 + i,
        hash: oldHash,
        parentHash: old.prevBlock.toString(),
        forkHeight: forkHeight,
        workAboveFork: oldWork,
      );
    }

    // Activate the new branch.
    for (final s in newBranch) {
      _sideHeaders.remove(s.hash);
      _cacheActive(s.header, s.height);
    }
    _chainTip = tip.header;
    _bestHeight = tip.height;
    _activeWorkAboveFork.clear();
    _maintainCacheSize();

    _logger.info('Reorganization complete: new tip at height $_bestHeight');
    return orphaned;
  }

  /// Store [header] as the active tip at [height].
  Future<void> _storeActive(BlockHeader header, int height) async {
    await _storage.storeBlockHeader(header, height);
    _cacheActive(header, height);
    if (_chainTip == null || height >= _bestHeight) {
      _bestHeight = height;
      _chainTip = header;
      _activeWorkAboveFork.clear();
    }
    _maintainCacheSize();
  }

  /// Get header by hash (active chain only)
  Future<BlockHeader?> getHeaderByHash(String hash) async {
    if (_headerCache.containsKey(hash)) {
      return _headerCache[hash];
    }
    try {
      final header = await _storage.getBlockHeaderByHash(hash);
      if (header != null) {
        _headerCache[hash] = header;
      }
      return header;
    } catch (e) {
      _logger.warning('Failed to get header by hash $hash: $e');
      return null;
    }
  }

  /// Get header by height (active chain only)
  Future<BlockHeader?> getHeaderByHeight(int height) => _activeHeaderAt(height);

  /// Get height for a given block hash (active chain only)
  Future<int?> getHeightByHash(String hash) => _activeHeightOf(hash);

  /// Whether [hash] is known on the active chain or a side branch.
  Future<bool> hasHeader(String hash) async =>
      _sideHeaders.containsKey(hash) || await _activeHeightOf(hash) != null;

  /// Block locator for `getheaders`: the last ten active headers, then
  /// exponentially sparser ones down to the anchor. A peer on another
  /// branch answers from the first hash it recognises, so the reply starts
  /// at (or below) the fork point.
  Future<List<Hash>> buildBlockLocator() async {
    final locator = <Hash>[];
    if (_chainTip == null) {
      locator.add(anchor.header.blockHash());
      return locator;
    }
    var step = 1;
    var height = _bestHeight;
    while (height > anchor.height) {
      final header = await _activeHeaderAt(height);
      if (header != null) locator.add(header.blockHash());
      if (locator.length >= 10) step *= 2;
      height -= step;
    }
    final base = await _activeHeaderAt(anchor.height);
    locator.add((base ?? anchor.header).blockHash());
    return locator;
  }

  /// Validate merkle proof against the header chain
  Future<bool> validateMerkleProof(MerkleProof proof) async {
    try {
      final header = await getHeaderByHash(proof.blockHash);
      if (header == null) {
        _logger.warning('Block header not found for merkle proof: ${proof.blockHash}');
        return false;
      }

      final computedRoot = _computeMerkleRoot(
        proof.txid,
        proof.merkleProof,
        proof.position,
      );

      final headerMerkleRoot = header.merkleRoot.toString();
      final isValid = computedRoot == headerMerkleRoot;

      if (isValid) {
        _logger.fine('✅ Merkle proof validated for tx ${proof.txid}');
      } else {
        _logger.warning('❌ Invalid merkle proof for tx ${proof.txid}');
        _logger.fine('  Computed root: $computedRoot');
        _logger.fine('  Header root:   $headerMerkleRoot');
      }

      return isValid;
    } catch (e) {
      _logger.warning('Merkle proof validation failed: $e');
      return false;
    }
  }

  /// Feed the headers of a competing branch. The chain decides itself which
  /// headers are orphaned (by cumulative work); [orphanedHeaders] is only
  /// logged. Returns the last accept result, or null when [newHeaders] is
  /// empty.
  Future<HeaderAcceptResult?> handleReorganization(
    List<BlockHeader> orphanedHeaders,
    List<BlockHeader> newHeaders,
  ) async {
    _logger.info('Handling blockchain reorganization: '
        '${orphanedHeaders.length} reported orphaned, ${newHeaders.length} new');
    HeaderAcceptResult? last;
    for (final header in newHeaders) {
      last = await acceptHeader(header);
      if (!last.accepted) {
        _logger.warning('Reorganization header rejected: $last');
        break;
      }
    }
    _logger.info('Reorganization processed: tip at height $_bestHeight');
    return last;
  }

  /// Bulk import pre-validated headers from CDN sync.
  ///
  /// These headers have already been validated for chain continuity,
  /// checkpoint verification, and chunk integrity by CdnHeaderSyncService.
  /// This method skips individual validation and writes directly in bulk.
  /// The anchor, if it is the first header and already stored, is skipped.
  ///
  /// Parameters:
  /// - [headers]: Pre-validated block headers in order
  /// - [startHeight]: Height of the first header in the list
  Future<void> bulkImportHeaders(List<BlockHeader> headers, int startHeight) async {
    if (headers.isEmpty) return;

    if (startHeight == anchor.height &&
        headers.first.blockHash().toString() == anchor.hash &&
        await _activeHeightOf(anchor.hash) == anchor.height) {
      headers = headers.sublist(1);
      startHeight += 1;
      if (headers.isEmpty) return;
    }

    _logger.info('Bulk importing ${headers.length} headers starting at height $startHeight');

    const batchSize = 1000;
    for (var i = 0; i < headers.length; i += batchSize) {
      final end = (i + batchSize).clamp(0, headers.length);
      final batch = <(BlockHeader, int)>[];
      for (var j = i; j < end; j++) {
        batch.add((headers[j], startHeight + j));
      }
      await _storage.storeBlockHeadersBulk(batch);
    }

    final lastHeight = startHeight + headers.length - 1;
    if (_chainTip == null || lastHeight >= _bestHeight) {
      _bestHeight = lastHeight;
      _chainTip = headers.last;
    }
    _activeWorkAboveFork.clear();

    _headerCache.clear();
    _heightToHash.clear();
    _hashToHeight.clear();
    await _loadRecentHeadersIntoCache();

    _logger.info('Bulk import complete: ${headers.length} headers, tip at height $_bestHeight');
  }

  /// Get recent headers for caching/display
  Future<List<BlockHeader>> getRecentHeaders(int count) async {
    try {
      return await _storage.getRecentHeaders(count);
    } catch (e) {
      _logger.warning('Failed to get recent headers: $e');
      return [];
    }
  }

  /// Compute merkle root from transaction ID and proof
  String _computeMerkleRoot(String txid, List<String> merkleProof, int position) {
    var current = txid;
    var currentPos = position;

    for (final proof in merkleProof) {
      String left, right;
      if (currentPos % 2 == 0) {
        left = current;
        right = proof;
      } else {
        left = proof;
        right = current;
      }
      current = _hashPair(left, right);
      currentPos = currentPos ~/ 2;
    }

    return current;
  }

  /// Hash a pair of hashes (double SHA256)
  String _hashPair(String left, String right) {
    final leftBytes = hex_utils.hexToBytes(left);
    final rightBytes = hex_utils.hexToBytes(right);
    final combined = Uint8List.fromList([...leftBytes, ...rightBytes]);
    final firstHash = sha256.convert(combined);
    final secondHash = sha256.convert(firstHash.bytes);
    return secondHash.toString();
  }

  /// Load recent active headers into the cache, with their heights.
  ///
  /// `getRecentHeaders` returns newest first; heights are assigned from the
  /// tip downwards as long as each header links to the next, so a gap in
  /// storage cannot mis-height the cache.
  Future<void> _loadRecentHeadersIntoCache() async {
    final cacheCount = _maxCacheSize ~/ 2;
    final recentHeaders = await _storage.getRecentHeaders(cacheCount);

    var height = _bestHeight;
    String? expectedHash = _chainTip?.blockHash().toString();
    for (final header in recentHeaders) {
      final hash = header.blockHash().toString();
      if (expectedHash != null && hash != expectedHash) break;
      _cacheActive(header, height);
      expectedHash = header.prevBlock.toString();
      height--;
    }

    _logger.fine('Loaded ${_headerCache.length} recent headers into cache');
  }

  /// Keep the active-header cache bounded (evicts the lowest heights).
  void _maintainCacheSize() {
    if (_headerCache.length <= _maxCacheSize) return;
    final heights = _heightToHash.keys.toList()..sort();
    final excess = _headerCache.length - _maxCacheSize;
    for (final h in heights.take(excess)) {
      final hash = _heightToHash[h];
      if (hash != null) _uncacheActive(hash, h);
    }
    // Cached headers without a height mapping (loaded by hash) go too.
    if (_headerCache.length > _maxCacheSize) {
      _headerCache.removeWhere((hash, _) => !_hashToHeight.containsKey(hash));
    }
  }

  void _cacheActive(BlockHeader header, int height) {
    final hash = header.blockHash().toString();
    _headerCache[hash] = header;
    _heightToHash[height] = hash;
    _hashToHeight[hash] = height;
  }

  void _uncacheActive(String hash, int height) {
    _headerCache.remove(hash);
    _hashToHeight.remove(hash);
    if (_heightToHash[height] == hash) _heightToHash.remove(height);
  }

  /// Keep side branches bounded. When over the limit, drop every branch
  /// except the one with the most work; if that alone is over the limit,
  /// drop everything (recovery then needs the headers to be re-sent).
  void _boundSideHeaders() {
    if (_sideHeaders.length <= _maxSideHeaders) return;
    _SideHeader? best;
    for (final s in _sideHeaders.values) {
      if (best == null || s.workAboveFork > best.workAboveFork) best = s;
    }
    final keep = <String>{};
    var cursor = best;
    while (cursor != null) {
      keep.add(cursor.hash);
      cursor = _sideHeaders[cursor.parentHash];
    }
    _sideHeaders.removeWhere((hash, _) => !keep.contains(hash));
    if (_sideHeaders.length > _maxSideHeaders) {
      _logger.severe('Side branch exceeds $_maxSideHeaders headers without overtaking the '
          'active chain; discarding it');
      _sideHeaders.clear();
    } else {
      _logger.warning('Discarded side branches to stay within $_maxSideHeaders headers');
    }
  }
}

/// Ancestry on the active chain.
class _ActiveAncestry implements HeaderAncestry {
  final BlockHeaderChain _chain;
  _ActiveAncestry(this._chain);

  @override
  Future<BlockHeader?> headerAt(int height) => _chain._activeHeaderAt(height);
}

/// Ancestry on a side branch: the branch's own headers above the fork, the
/// active chain below it.
class _SideAncestry implements HeaderAncestry {
  final BlockHeaderChain _chain;
  final Map<int, BlockHeader> _path;
  _SideAncestry(this._chain, this._path);

  @override
  Future<BlockHeader?> headerAt(int height) async =>
      _path[height] ?? await _chain._activeHeaderAt(height);
}

class _EmptyAncestry implements HeaderAncestry {
  @override
  Future<BlockHeader?> headerAt(int height) async => null;
}
