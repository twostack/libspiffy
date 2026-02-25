import 'package:dartsv/dartsv.dart' as dartsv;

/// Analyzes transactions to identify wallet outputs and spending patterns
class TransactionAnalyzer {
  /// Sort transactions by dependency order (parents before children)
  /// Essential for correct UTXO tracking
  static List<dartsv.Transaction> sortByDependency(
    List<dartsv.Transaction> transactions,
  ) {
    final txMap = <String, dartsv.Transaction>{};
    final dependsOn = <String, Set<String>>{};
    final result = <dartsv.Transaction>[];
    final processed = <String>{};
    
    // Build dependency graph
    for (final tx in transactions) {
      txMap[tx.id] = tx;
      dependsOn[tx.id] = {};
      
      for (final input in tx.inputs) {
        final prevTxid = input.prevTxnId;
        if (txMap.containsKey(prevTxid)) {
          dependsOn[tx.id]!.add(prevTxid);
        }
      }
    }
    
    // Topological sort
    void processTx(String txid) {
      if (processed.contains(txid)) return;
      
      // Process dependencies first
      for (final depTxid in dependsOn[txid] ?? {}) {
        if (!processed.contains(depTxid)) {
          processTx(depTxid);
        }
      }
      
      if (txMap.containsKey(txid)) {
        result.add(txMap[txid]!);
        processed.add(txid);
      }
    }
    
    for (final tx in transactions) {
      processTx(tx.id);
    }
    
    return result;
  }
  
  /// Two-phase algorithm: Identify wallet outputs and track spending
  static HarvestResult harvestUTXOs({
    required List<dartsv.Transaction> transactions,
    required List<String> walletAddresses,
    required Map<String, int> transactionHeights,
    required Map<String, DateTime> transactionTimestamps,
    dartsv.NetworkType networkType = dartsv.NetworkType.TEST,
  }) {
    // Phase 1: Identify ALL wallet outputs
    final utxos = <String, Map<int, _OutputInfo>>{}; // txid -> {vout -> outputInfo}
    
    for (final tx in transactions) {
      for (int i = 0; i < tx.outputs.length; i++) {
        final output = tx.outputs[i];
        
        // Check if output belongs to wallet (P2PKH address check)
        final outputInfo = _analyzeOutput(output, walletAddresses, networkType: networkType);
        if (outputInfo != null) {
          utxos[tx.id] ??= {};
          utxos[tx.id]![i] = outputInfo;
        }
      }
    }
    
    // Phase 2: Track which outputs are spent
    final spentOutputs = <String, Set<int>>{}; // txid -> {spent vout indexes}
    
    for (final tx in transactions) {
      for (final input in tx.inputs) {
        final prevTxid = input.prevTxnId;
        final prevIndex = input.prevTxnOutputIndex;
        
        if (prevTxid.isEmpty) continue; // Skip coinbase
        
        if (utxos.containsKey(prevTxid) && 
            utxos[prevTxid]!.containsKey(prevIndex)) {
          spentOutputs[prevTxid] ??= {};
          spentOutputs[prevTxid]!.add(prevIndex);
        }
      }
    }
    
    // Result: Create UTXO models for unspent outputs only
    final harvestedUtxos = <HarvestedUTXO>[];
    
    for (final txid in utxos.keys) {
      final outputs = utxos[txid]!;
      final spent = spentOutputs[txid] ?? {};
      
      for (final entry in outputs.entries) {
        final vout = entry.key;
        final outputInfo = entry.value;
        
        if (!spent.contains(vout)) {
          // This is an unspent output
          harvestedUtxos.add(HarvestedUTXO(
            txid: txid,
            vout: vout,
            satoshis: outputInfo.satoshis,
            scriptPubKey: outputInfo.scriptPubKey,
            address: outputInfo.address,
            blockHeight: transactionHeights[txid] ?? 0,
            timestamp: transactionTimestamps[txid] ?? DateTime.now(),
          ));
        }
      }
    }
    
    return HarvestResult(
      utxos: harvestedUtxos,
      totalAmount: harvestedUtxos.fold(
        BigInt.zero,
        (sum, utxo) => sum + utxo.satoshis,
      ),
    );
  }
  
  /// Analyze an output to see if it belongs to the wallet
  /// Returns OutputInfo if it's a wallet output, null otherwise
  static _OutputInfo? _analyzeOutput(
    dartsv.TransactionOutput output,
    List<String> walletAddresses, {
    dartsv.NetworkType networkType = dartsv.NetworkType.TEST,
  }) {
    try {
      // Parse P2PKH script to get address
      final locker = dartsv.P2PKHLockBuilder.fromScript(
        output.script,
        networkType: networkType,
      );
      final address = locker.address?.toBase58();
      
      if (address != null && walletAddresses.contains(address)) {
        return _OutputInfo(
          satoshis: output.satoshis,
          scriptPubKey: output.script.toHex(),
          address: address,
        );
      }
      
      return null;
    } catch (e) {
      // Not a P2PKH output or parsing error
      return null;
    }
  }
}

/// Internal helper class for tracking output information during harvesting
class _OutputInfo {
  final BigInt satoshis;
  final String scriptPubKey;
  final String address;
  
  _OutputInfo({
    required this.satoshis,
    required this.scriptPubKey,
    required this.address,
  });
}

class HarvestResult {
  final List<HarvestedUTXO> utxos;
  final BigInt totalAmount;
  
  HarvestResult({
    required this.utxos,
    required this.totalAmount,
  });
}

class HarvestedUTXO {
  final String txid;
  final int vout;
  final BigInt satoshis;
  final String scriptPubKey;
  final String address;
  final int blockHeight;
  final DateTime timestamp;
  
  HarvestedUTXO({
    required this.txid,
    required this.vout,
    required this.satoshis,
    required this.scriptPubKey,
    required this.address,
    required this.blockHeight,
    required this.timestamp,
  });
}

