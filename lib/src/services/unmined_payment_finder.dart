import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';

import '../storage/read_model_storage.dart';
import '../utils/beef.dart';
import '../utils/tx_finality.dart';
import 'blockchain_data_source.dart';
import 'transaction_import_service.dart';

/// A payment to one of a wallet's addresses that is still in the mempool,
/// as a BEEF the wallet checks like any payment handed to it.
class UnminedPayment {
  final String txid;
  final String beefHex;

  const UnminedPayment({required this.txid, required this.beefHex});
}

/// Finds payments to named addresses that are not mined yet
/// (spiffyvault-bld). An address scan read mined history only, so a payment
/// showed some ten minutes after it was made, once a block held it.
///
/// The data source lists each address's unspent outputs, the unconfirmed
/// ones included. For each transaction the wallet does not hold, the BEEF
/// is built: the transaction, and its ancestors back to mined ones with
/// their merkle proofs. The caller hands it to the wallet's BEEF check
/// (`ValidateBEEFCommand`), the path every received payment takes: SPV
/// against the stored headers, the outputs recorded as on the way, and the
/// network status followed from there. Nothing here is trusted: the data
/// source only says where to look.
///
/// A transaction whose lock time is still to come is left out: the network
/// refuses it until then, and it can be replaced. So is one whose unmined
/// ancestry is deeper than [maxUnminedAncestors], or that the data source
/// cannot deliver whole; a later scan, or the block, brings it.
class UnminedPaymentFinder {
  static final _log = Logger('UnminedPaymentFinder');

  final BlockchainDataSource _dataSource;
  final TransactionImportService _importService;
  final ReadModelStorage _storage;
  final DateTime Function() _clock;

  /// How many unmined transactions one payment's BEEF may carry besides the
  /// payment itself.
  final int maxUnminedAncestors;

  UnminedPaymentFinder({
    required BlockchainDataSource dataSource,
    required TransactionImportService importService,
    required ReadModelStorage storage,
    this.maxUnminedAncestors = 25,
    DateTime Function()? clock,
  })  : _dataSource = dataSource,
        _importService = importService,
        _storage = storage,
        _clock = clock ?? DateTime.now;

  /// The unmined payments to [addresses] that [walletId] does not hold yet.
  /// An address the data source cannot answer for is passed over.
  Future<List<UnminedPayment>> find(String walletId, List<String> addresses) async {
    final txids = <String>[];
    for (final address in addresses) {
      try {
        for (final utxo in await _dataSource.getUtxos(address)) {
          if (utxo.height != null && utxo.height! > 0) continue;
          if (!txids.contains(utxo.txid)) txids.add(utxo.txid);
        }
      } catch (e) {
        _log.info('Unspent outputs of $address not available: $e');
      }
    }
    if (txids.isEmpty) return const [];

    final bestHeight = await _bestHeightOrNull();
    final found = <UnminedPayment>[];
    for (final txid in txids) {
      if (await _storage.getTransaction(txid, walletId: walletId) != null) continue;
      try {
        final beefHex = await _beefFor(txid, bestHeight);
        if (beefHex != null) found.add(UnminedPayment(txid: txid, beefHex: beefHex));
      } catch (e) {
        _log.info('Unmined payment $txid to wallet $walletId left for a later scan: $e');
      }
    }
    _log.info('${found.length} unmined payment(s) to ${addresses.length} address(es) of $walletId');
    return found;
  }

  /// The BEEF of [txid]: proven ancestors with their BUMPs, then the
  /// unmined ones parents first, then [txid]. Null when it is not final.
  Future<String?> _beefFor(String txid, int? bestHeight) async {
    final raw = await _rawTransaction(txid);
    if (!isFinalTransaction(dartsv.Transaction.fromHex(raw), bestHeight: bestHeight, now: _clock())) {
      _log.info('$txid is not final yet (lock time to come); not taken as a payment');
      return null;
    }

    final unmined = <String, String>{txid: raw}; // txid -> raw, discovery order
    final proven = <String, ImportedTransaction>{};
    final queue = <String>[txid];
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      for (final input in dartsv.Transaction.fromHex(unmined[current]!).inputs) {
        final parent = input.prevTxnId.toString();
        if (unmined.containsKey(parent) || proven.containsKey(parent)) continue;
        final mined = await _minedOrNull(parent);
        if (mined != null) {
          proven[parent] = mined;
          continue;
        }
        if (unmined.length > maxUnminedAncestors) {
          throw StateError('more than $maxUnminedAncestors unmined ancestors');
        }
        unmined[parent] = await _rawTransaction(parent);
        queue.add(parent);
      }
    }

    final bumps = BeefBumps.of({for (final p in proven.values) p.txid: p.bump});
    final txs = <Uint8List>[];
    final hasMerkle = <bool>[];
    final bumpIndex = <int>[];
    for (final p in proven.values) {
      txs.add(Uint8List.fromList(hex.decode(p.rawHex)));
      final index = bumps.indexFor(p.txid);
      hasMerkle.add(index != null);
      if (index != null) bumpIndex.add(index);
    }
    for (final id in _parentsFirst(unmined)) {
      txs.add(Uint8List.fromList(hex.decode(unmined[id]!)));
      hasMerkle.add(false);
    }
    final beef = BEEF.create(bumps: bumps.bumps, txs: txs, hasMerkle: hasMerkle, bumpIndex: bumpIndex);
    return hex.encode(beef.serialize());
  }

  /// [txid] with its merkle proof when it is mined; null when the data
  /// source has no proof for it (not mined). A proof that does not check
  /// out is an error, not a reason to take the transaction for unmined.
  Future<ImportedTransaction?> _minedOrNull(String txid) async {
    try {
      return await _importService.importTransaction(txid);
    } on TransactionImportException catch (e) {
      if (e.originalError is DataSourceException) return null;
      rethrow;
    }
  }

  /// The raw transaction [txid], checked to hash to it.
  Future<String> _rawTransaction(String txid) async {
    final raw = await _dataSource.getRawTransaction(txid);
    final actual = dartsv.Transaction.fromHex(raw).id;
    if (actual != txid) throw StateError('the data source sent $actual for $txid');
    return raw;
  }

  /// The txids of [unmined] ordered so each comes after the unmined parents
  /// it spends.
  static List<String> _parentsFirst(Map<String, String> unmined) {
    final parents = <String, List<String>>{
      for (final e in unmined.entries)
        e.key: [
          for (final input in dartsv.Transaction.fromHex(e.value).inputs)
            if (unmined.containsKey(input.prevTxnId.toString())) input.prevTxnId.toString(),
        ],
    };
    final ordered = <String>[];
    final placed = <String>{};
    void place(String id) {
      if (!placed.add(id)) return;
      for (final p in parents[id]!) {
        place(p);
      }
      ordered.add(id);
    }

    for (final id in unmined.keys.toList().reversed) {
      place(id);
    }
    return ordered;
  }

  Future<int?> _bestHeightOrNull() async {
    try {
      final height = await _storage.getBestHeight();
      return height > 0 ? height : null;
    } catch (_) {
      return null;
    }
  }
}
