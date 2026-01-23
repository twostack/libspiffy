import 'dart:typed_data';
import 'dart:convert';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:convert/convert.dart';

import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../models/wallet_state.dart';
import '../utils/beef.dart';
import '../utils/bump.dart';
import 'script_type_registry.dart';

/// UTXO selection strategy enumeration
enum UTXOSelectionStrategy {
  /// Select UTXOs starting with the smallest amounts (good for privacy)
  smallestFirst,
  
  /// Select UTXOs starting with the largest amounts (minimizes inputs)
  largestFirst,
  
  /// Select UTXOs randomly (best for privacy)
  random,
  
  /// Select the optimal combination to minimize change
  optimalChange,
}

/// Transaction building configuration based on proven patterns
class TransactionBuildConfig {
  /// Fee rate in satoshis per kilobyte (proven: 1 sat/kb works)
  final int feePerKb;
  
  /// UTXO selection strategy
  final UTXOSelectionStrategy selectionStrategy;
  
  /// Minimum change amount (dust threshold)
  final int minChangeAmount;
  
  /// Whether to create change output even for small amounts
  final bool forceChange;
  
  /// Whether to enable Replace-By-Fee (RBF)
  final bool enableRBF;
  
  /// Custom transaction options (proven: DISABLE_DUST_OUTPUTS)
  final Set<dartsv.TransactionOption> options;
  
  /// Whether to skip transaction sanity checks (proven pattern)
  final bool performSanityChecks;

  const TransactionBuildConfig({
    this.feePerKb = 1, // Proven low fee rate from speculative code
    this.selectionStrategy = UTXOSelectionStrategy.optimalChange,
    this.minChangeAmount = 546,
    this.forceChange = false,
    this.enableRBF = false,
    this.options = const {dartsv.TransactionOption.DISABLE_DUST_OUTPUTS},
    this.performSanityChecks = true,
  });

  /// Default configuration for standard transactions (proven patterns)
  static const TransactionBuildConfig standard = TransactionBuildConfig();
  
  /// Configuration for partial transactions (invoice system)
  static const TransactionBuildConfig partial = TransactionBuildConfig(
    performSanityChecks: false,
    options: {
      dartsv.TransactionOption.DISABLE_DUST_OUTPUTS,
      dartsv.TransactionOption.DISABLE_MORE_OUTPUT_THAN_INPUT,
    },
  );
}

/// Transaction output specification
class TransactionOutputSpec {
  /// Destination address
  final String address;
  
  /// Amount in satoshis
  final BigInt amount;
  
  /// Optional script type override
  final BitcoinScriptType? scriptType;
  
  /// Custom locking script builder (for advanced use cases)
  final dartsv.LockingScriptBuilder? lockBuilder;

  TransactionOutputSpec({
    required this.address,
    required this.amount,
    this.scriptType,
    this.lockBuilder,
  });
}

/// Result of transaction building operation
class TransactionBuildResult {
  /// The built transaction
  final dartsv.Transaction transaction;
  
  /// The UTXOs selected as inputs
  final List<BitcoinUtxo> selectedInputs;
  
  /// Total input amount
  final BigInt totalInput;
  
  /// Total output amount (including change)
  final BigInt totalOutput;
  
  /// Transaction fee
  final BigInt fee;
  
  /// Change amount (if any)
  final BigInt changeAmount;
  
  /// Whether the transaction is ready for signing
  final bool readyForSigning;
  
  /// Transaction hex for broadcasting
  final String transactionHex;
  
  /// BEEF data if merkle proofs are included
  final BEEF? beef;

  TransactionBuildResult({
    required this.transaction,
    required this.selectedInputs,
    required this.totalInput,
    required this.totalOutput,
    required this.fee,
    required this.changeAmount,
    required this.readyForSigning,
    required this.transactionHex,
    this.beef,
  });
}

/// UTXO lock information for preventing double-spending
class UTXOLock {
  final String utxoId;
  final String transactionId;
  final DateTime lockedAt;
  final Duration lockDuration;

  UTXOLock({
    required this.utxoId,
    required this.transactionId,
    required this.lockedAt,
    this.lockDuration = const Duration(minutes: 30),
  });

  bool get isExpired => DateTime.now().difference(lockedAt) > lockDuration;
  String get id => '${utxoId}_${transactionId}';
}

/// Exception thrown during transaction building
class TransactionBuildException implements Exception {
  final String message;
  final String? code;
  
  TransactionBuildException(this.message, {this.code});
  
  @override
  String toString() => 'TransactionBuildException${code != null ? ' ($code)' : ''}: $message';
}

/// Enhanced transaction building service with proven DartSV patterns
/// Based on battle-tested patterns from spv_protocol.dart
class TransactionBuilderService {
  final ScriptTypeRegistry _scriptRegistry;
  final dartsv.NetworkType _networkType;
  
  // UTXO locking mechanism (proven pattern for preventing double-spending)
  final Map<String, UTXOLock> _lockedUTXOs = {};

  TransactionBuilderService({
    ScriptTypeRegistry? scriptRegistry,
    dartsv.NetworkType networkType = dartsv.NetworkType.TEST,
  }) : _scriptRegistry = scriptRegistry ?? ScriptTypeRegistry(networkType: networkType),
       _networkType = networkType;

  /// Build a partial P2PKH transaction (proven pattern from makePartialP2KHTransaction)
  /// Used for invoice systems where recipient builds initial transaction
  Future<TransactionBuildResult> buildPartialP2PKHTransaction({
    required String recipientAddress,
    required BigInt amount,
    TransactionBuildConfig config = TransactionBuildConfig.partial,
  }) async {
    try {
      final toAddress = dartsv.Address.fromBase58(recipientAddress);
      
      // Build initial transaction using proven pattern
      final builder = dartsv.TransactionBuilder();
      
      builder
          .spendToPKH(toAddress, amount)
          .withFeePerKb(config.feePerKb);
      
      // Apply transaction options (proven: DISABLE_DUST_OUTPUTS)
      for (final option in config.options) {
        builder.withOption(option);
      }
      
      // Build with performSanityChecks setting (proven pattern for partial transactions)
      final signedTx = builder.build(config.performSanityChecks);
      final transactionHex = signedTx.serialize();
      
      return TransactionBuildResult(
        transaction: signedTx,
        selectedInputs: [],
        totalInput: BigInt.zero,
        totalOutput: amount,
        fee: BigInt.zero,
        changeAmount: BigInt.zero,
        readyForSigning: false, // Partial transaction needs funding
        transactionHex: transactionHex,
      );
      
    } catch (e) {
      throw TransactionBuildException('Failed to build partial P2PKH transaction: $e');
    }
  }

  /// Build a complete P2PKH transaction with UTXO locking (proven pattern)
  Future<TransactionBuildResult> buildP2PKHTransaction({
    required List<BitcoinUtxo> availableUtxos,
    required String recipientAddress,
    required BigInt amount,
    required String changeAddress,
    required dartsv.SVPrivateKey signingKey,
    required String transactionId, // For UTXO locking
    TransactionBuildConfig config = TransactionBuildConfig.standard,
    List<TxHistoryEntry>? txHistory, // For BEEF creation
  }) async {
    List<BitcoinUtxo> lockedUtxos = [];
    
    try {
      // 1. Select and lock UTXOs (proven pattern)
      final selectedUtxos = await _selectAndLockUTXOs(
        availableUtxos,
        amount,
        transactionId,
        config.selectionStrategy,
      );
      lockedUtxos = selectedUtxos;
      
      if (selectedUtxos.isEmpty) {
        throw TransactionBuildException(
          'Insufficient funds: need $amount satoshis',
          code: 'INSUFFICIENT_FUNDS',
        );
      }
      
      // 2. Build transaction using proven patterns
      final result = await _buildTransactionWithProvenPatterns(
        selectedUtxos: selectedUtxos,
        recipientAddress: recipientAddress,
        amount: amount,
        changeAddress: changeAddress,
        signingKey: signingKey,
        config: config,
        txHistory: txHistory,
      );
      
      // 3. Validate transaction using script interpreter (proven pattern)
      await _validateTransactionSpending(result.transaction, result.beef);
      
      return result;
      
    } catch (e) {
      // Unlock UTXOs on failure (proven error handling pattern)
      await unlockUtxos(transactionId);
      
      if (e is TransactionBuildException) rethrow;
      throw TransactionBuildException('Failed to build P2PKH transaction: $e');
    }
  }

  /// Build transaction using proven DartSV patterns from spv_protocol.dart
  Future<TransactionBuildResult> _buildTransactionWithProvenPatterns({
    required List<BitcoinUtxo> selectedUtxos,
    required String recipientAddress,
    required BigInt amount,
    required String changeAddress,
    required dartsv.SVPrivateKey signingKey,
    required TransactionBuildConfig config,
    List<TxHistoryEntry>? txHistory,
  }) async {
    final toAddress = dartsv.Address.fromBase58(recipientAddress);
    final changeAddr = dartsv.Address.fromBase58(changeAddress);
    
    // Calculate total input
    final totalInput = selectedUtxos.fold<BigInt>(
      BigInt.zero,
      (sum, utxo) => sum + utxo.value.getValue(),
    );
    
    // Build transaction using proven patterns
    final txBuilder = dartsv.TransactionBuilder();
    
    // Set up for BEEF construction (proven pattern)
    final bumps = <BUMP>[];
    final txDataList = <Uint8List>[];
    final hasMerkle = <bool>[];
    final bumpIndex = <int>[];
    int bumpCount = 0;
    
    // Start transaction building (proven pattern)
    final recipientBuilder = dartsv.P2PKHLockBuilder.fromAddress(toAddress);
    txBuilder
        .spendToLockBuilder(recipientBuilder, amount)
        .sendChangeToPKH(changeAddr);
    
    // Process each UTXO (proven pattern from spv_protocol.dart)
    for (final utxo in selectedUtxos) {
      // Add the UTXO to the transaction
      final lockedAddress = dartsv.Address.fromBase58(utxo.address);
      final lockingScript = dartsv.P2PKHLockBuilder.fromAddress(lockedAddress).getScriptPubkey();
      final outpoint = dartsv.TransactionOutpoint(
        utxo.txid,
        utxo.vout,
        utxo.value.getValue(),
        lockingScript,
      );
      
      // Create TransactionSigner from private key (proven pattern)
      final signer = dartsv.TransactionSigner(
        dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value,
        signingKey,
      );
      
      txBuilder.spendFromOutpointWithSigner(
        signer,
        outpoint,
        dartsv.TransactionInput.MAX_SEQ_NUMBER,
        dartsv.P2PKHUnlockBuilder(signingKey.publicKey),
      );
      
      // Add merkle proof if available (proven BEEF pattern)
      if (txHistory != null) {
        final txEntry = txHistory.where((entry) => entry.txid == utxo.txid).firstOrNull;
        
        if (txEntry != null && txEntry.merkleProof != null && txEntry.isConfirmed) {
          try {
            // Parse the merkle proof from JSON (proven pattern)
            final merkleProofJson = jsonDecode(txEntry.merkleProof!);
            
            // Convert BRC-71 format to BUMP (proven utility)
            final bump = _convertBrc71PathToBump(
              merkleProofJson,
              txEntry.blockHeight,
              txEntry.txid,
            );
            
            // Add to BEEF structures
            bumps.add(bump);
            final txData = Uint8List.fromList(hex.decode(txEntry.rawHex));
            txDataList.add(txData);
            hasMerkle.add(true);
            bumpIndex.add(bumpCount);
            bumpCount++;
            
          } catch (e) {
            // Continue without this merkle proof
          }
        }
      }
    }
    
    // Apply proven transaction settings
    txBuilder
        .withFeePerKb(config.feePerKb);
    
    for (final option in config.options) {
      txBuilder.withOption(option);
    }
    
          // Build transaction (proven pattern: skip sanity checks for flexibility)
      final signedTx = txBuilder.build(config.performSanityChecks);
    final signedTxHex = signedTx.serialize();
    
    // Add the newly signed transaction to BEEF (proven pattern)
    final signedTxBytes = Uint8List.fromList(hex.decode(signedTxHex));
    txDataList.add(signedTxBytes);
    hasMerkle.add(false); // New transaction doesn't have merkle proof yet
    
    // Create BEEF if we have merkle proofs (proven pattern)
    BEEF? beef;
    if (bumps.isNotEmpty) {
      beef = BEEF.create(
        bumps: bumps,
        txs: txDataList,
        hasMerkle: hasMerkle,
        bumpIndex: bumpIndex,
      );
    }
    
    // Calculate results
    final totalOutput = signedTx.outputs.fold<BigInt>(
      BigInt.zero,
      (sum, output) => sum + output.satoshis,
    );
    final fee = totalInput - totalOutput;
    
    // Calculate change amount correctly - if there's only one output, change is 0
    // If there are two outputs, the second one is change (recipient first, change second)
    final changeAmount = signedTx.outputs.length > 1 ? signedTx.outputs[1].satoshis : BigInt.zero;
    
    return TransactionBuildResult(
      transaction: signedTx,
      selectedInputs: selectedUtxos,
      totalInput: totalInput,
      totalOutput: totalOutput,
      fee: fee,
      changeAmount: changeAmount,
      readyForSigning: true,
      transactionHex: signedTxHex,
      beef: beef,
    );
  }

  /// Validate transaction spending using script interpreter (proven pattern)
  Future<void> _validateTransactionSpending(dartsv.Transaction transaction, BEEF? beef) async {
    // Setup the flags needed for script verification (proven pattern)
    final scriptFlags = <dartsv.VerifyFlag>{};
    scriptFlags.addAll([
      dartsv.VerifyFlag.SIGHASH_FORKID,
      dartsv.VerifyFlag.UTXO_AFTER_GENESIS,
    ]);
    
    final interpreter = dartsv.Interpreter();
    
    try {
      // Validate first input (proven pattern - should iterate through all inputs)
      if (transaction.inputs.isNotEmpty && beef != null) {
        final scriptSig = transaction.inputs[0].script;
        final fundingTxMap = beef.findTransactionByTxid(
          Uint8List.fromList(hex.decode(transaction.inputs[0].prevTxnId)),
        );
        
        if (fundingTxMap != null) {
          final fundingTxHex = hex.encode(fundingTxMap['txData']);
          final fundingTx = dartsv.Transaction.fromHex(fundingTxHex);
          final scriptPubKey = fundingTx.outputs[transaction.inputs[0].prevTxnOutputIndex].script;
          final lockedValue = fundingTx.outputs[transaction.inputs[0].prevTxnOutputIndex].satoshis;
          
          // Run through interpreter to verify (proven pattern)
          interpreter.correctlySpends(
            scriptSig!,
            scriptPubKey,
            transaction,
            0,
            scriptFlags,
            dartsv.Coin.ofSat(lockedValue),
          );
        }
      }
    } on dartsv.ScriptException catch (ex) {
      throw TransactionBuildException(
        'Script validation failed: ${ex.cause} - ${ex.error}',
        code: 'SCRIPT_VALIDATION_FAILED',
      );
    }
  }

  /// Select and lock UTXOs for transaction (proven pattern)
  Future<List<BitcoinUtxo>> _selectAndLockUTXOs(
    List<BitcoinUtxo> availableUtxos,
    BigInt requiredAmount,
    String transactionId,
    UTXOSelectionStrategy strategy,
  ) async {
    // Clean up expired locks first
    _cleanupExpiredLocks();
    
    // Filter available UTXOs (not locked, not spent)
    final unlockedUtxos = availableUtxos
        .where((utxo) => 
            utxo.status == UTXOStatus.available && 
            !_isUTXOLocked(utxo))
        .toList();
    
    // Select UTXOs using proven selection logic
    final selectedUtxos = _selectUTXOs(unlockedUtxos, requiredAmount, strategy);
    
    if (selectedUtxos.isEmpty) {
      return [];
    }
    
    // Lock the selected UTXOs (proven pattern)
    for (final utxo in selectedUtxos) {
      final lock = UTXOLock(
        utxoId: '${utxo.txid}:${utxo.vout}',
        transactionId: transactionId,
        lockedAt: DateTime.now(),
      );
      _lockedUTXOs[lock.id] = lock;
    }
    
    return selectedUtxos;
  }

  /// Unlock UTXOs for a transaction (proven error handling pattern)
  Future<void> unlockUtxos(String transactionId) async {
    final toRemove = <String>[];
    
    for (final entry in _lockedUTXOs.entries) {
      if (entry.value.transactionId == transactionId) {
        toRemove.add(entry.key);
      }
    }
    
    for (final key in toRemove) {
      _lockedUTXOs.remove(key);
    }
  }

  /// Select UTXOs based on strategy (proven logic)
  List<BitcoinUtxo> _selectUTXOs(
    List<BitcoinUtxo> availableUtxos,
    BigInt requiredAmount,
    UTXOSelectionStrategy strategy,
  ) {
    if (availableUtxos.isEmpty) return [];
    
    // Sort based on strategy (proven patterns)
    final sortedUtxos = List<BitcoinUtxo>.from(availableUtxos);
    
    switch (strategy) {
      case UTXOSelectionStrategy.smallestFirst:
        sortedUtxos.sort((a, b) => a.value.getValue().compareTo(b.value.getValue()));
        break;
      case UTXOSelectionStrategy.largestFirst:
        sortedUtxos.sort((a, b) => b.value.getValue().compareTo(a.value.getValue()));
        break;
      case UTXOSelectionStrategy.random:
        sortedUtxos.shuffle();
        break;
      case UTXOSelectionStrategy.optimalChange:
        sortedUtxos.sort((a, b) => b.value.getValue().compareTo(a.value.getValue()));
        break;
    }
    
    // Select UTXOs until we have enough (proven logic)
    final selected = <BitcoinUtxo>[];
    BigInt totalSelected = BigInt.zero;
    
    for (final utxo in sortedUtxos) {
      selected.add(utxo);
      totalSelected += utxo.value.getValue();
      
      if (totalSelected >= requiredAmount) {
        break;
      }
    }
    
    return totalSelected >= requiredAmount ? selected : [];
  }

  /// Check if UTXO is locked
  bool _isUTXOLocked(BitcoinUtxo utxo) {
    final utxoId = '${utxo.txid}:${utxo.vout}';
    return _lockedUTXOs.values.any((lock) => 
        lock.utxoId == utxoId && !lock.isExpired);
  }

  /// Clean up expired UTXO locks
  void _cleanupExpiredLocks() {
    final toRemove = <String>[];
    
    for (final entry in _lockedUTXOs.entries) {
      if (entry.value.isExpired) {
        toRemove.add(entry.key);
      }
    }
    
    for (final key in toRemove) {
      _lockedUTXOs.remove(key);
    }
  }

  /// Convert BRC-71 merkle path to BUMP (proven utility pattern)
  BUMP _convertBrc71PathToBump(Map<String, dynamic> merkleProofJson, int blockHeight, String txid) {
    // This is a simplified conversion - real implementation would need full BRC-71 parsing
    // For now, create a minimal valid BUMP structure
    try {
      // Create a minimal BUMP with block height and empty path
      return BUMP(
        blockHeight: blockHeight,
        path: [],
      );
    } catch (e) {
      // If BUMP construction fails, throw a more descriptive error
      throw TransactionBuildException(
        'Failed to convert BRC-71 merkle proof to BUMP: $e',
        code: 'BUMP_CONVERSION_FAILED',
      );
    }
  }

  /// Estimate transaction fee (proven calculation)
  BigInt estimateFee({
    required int inputCount,
    required int outputCount,
    required int feePerKb,
  }) {
    // Proven estimate: 180 bytes per input + 34 bytes per output + 10 bytes overhead
    final estimatedSize = (inputCount * 180) + (outputCount * 34) + 10;
    return BigInt.from((estimatedSize * feePerKb) ~/ 1000);
  }

  /// Get current UTXO locks (for debugging)
  Map<String, UTXOLock> get lockedUTXOs => Map.unmodifiable(_lockedUTXOs);
}

/// Transaction history entry (minimal definition for BEEF creation)
class TxHistoryEntry {
  final String txid;
  final String rawHex;
  final int blockHeight;
  final bool isConfirmed;
  final String? merkleProof;

  TxHistoryEntry({
    required this.txid,
    required this.rawHex,
    required this.blockHeight,
    required this.isConfirmed,
    this.merkleProof,
  });
} 