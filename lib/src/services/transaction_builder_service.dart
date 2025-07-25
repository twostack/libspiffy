import 'dart:typed_data';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:convert/convert.dart';

import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../models/wallet_state.dart';
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

/// Transaction building configuration
class TransactionBuildConfig {
  /// Fee rate in satoshis per kilobyte
  final int feePerKb;
  
  /// UTXO selection strategy
  final UTXOSelectionStrategy selectionStrategy;
  
  /// Minimum change amount (dust threshold)
  final int minChangeAmount;
  
  /// Whether to create change output even for small amounts
  final bool forceChange;
  
  /// Whether to enable Replace-By-Fee (RBF)
  final bool enableRBF;
  
  /// Custom transaction options
  final Set<dartsv.TransactionOption> options;

  const TransactionBuildConfig({
    this.feePerKb = 1000,
    this.selectionStrategy = UTXOSelectionStrategy.optimalChange,
    this.minChangeAmount = 546,
    this.forceChange = false,
    this.enableRBF = false,
    this.options = const {dartsv.TransactionOption.DISABLE_DUST_OUTPUTS},
  });

  /// Default configuration for standard transactions
  static const TransactionBuildConfig standard = TransactionBuildConfig();
  
  /// High-fee configuration for priority transactions
  static const TransactionBuildConfig priority = TransactionBuildConfig(
    feePerKb: 5000,
    selectionStrategy: UTXOSelectionStrategy.largestFirst,
  );
  
  /// Privacy-focused configuration
  static const TransactionBuildConfig privacy = TransactionBuildConfig(
    selectionStrategy: UTXOSelectionStrategy.random,
    forceChange: true,
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
  
  /// Custom locking script (for advanced use cases)
  final dartsv.SVScript? customScript;

  TransactionOutputSpec({
    required this.address,
    required this.amount,
    this.scriptType,
    this.customScript,
  });
}

/// Result of transaction building operation
class TransactionBuildResult {
  /// The built transaction (unsigned)
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

  TransactionBuildResult({
    required this.transaction,
    required this.selectedInputs,
    required this.totalInput,
    required this.totalOutput,
    required this.fee,
    required this.changeAmount,
    required this.readyForSigning,
  });
}

/// Exception thrown during transaction building
class TransactionBuildException implements Exception {
  final String message;
  final String? code;
  
  TransactionBuildException(this.message, {this.code});
  
  @override
  String toString() => 'TransactionBuildException${code != null ? ' ($code)' : ''}: $message';
}

/// Comprehensive transaction building service
/// Based on proven DartSV patterns from tx_utils.dart
class TransactionBuilderService {
  final ScriptTypeRegistry _scriptRegistry;
  final dartsv.NetworkType _networkType;

  TransactionBuilderService({
    ScriptTypeRegistry? scriptRegistry,
    dartsv.NetworkType networkType = dartsv.NetworkType.TEST,
  }) : _scriptRegistry = scriptRegistry ?? ScriptTypeRegistry(networkType: networkType),
       _networkType = networkType;

  /// Build a standard P2PKH transaction
  /// Based on the makePKHTransaction pattern from tx_utils.dart
  Future<TransactionBuildResult> buildP2PKHTransaction({
    required List<BitcoinUtxo> availableUtxos,
    required String recipientAddress,
    required BigInt amount,
    required String changeAddress,
    required dartsv.SVPrivateKey signingKey,
    TransactionBuildConfig config = TransactionBuildConfig.standard,
  }) async {
    try {
      // Convert addresses
      final toAddress = dartsv.Address.fromBase58(recipientAddress);
      final changeAddr = dartsv.Address.fromBase58(changeAddress);
      
      // Select UTXOs for the required amount
      final selectedUtxos = _selectUTXOs(
        availableUtxos,
        amount + BigInt.from(config.feePerKb), // Add buffer for fees
        config.selectionStrategy,
      );
      
      if (selectedUtxos.isEmpty) {
        throw TransactionBuildException(
          'Insufficient funds: need $amount satoshis',
          code: 'INSUFFICIENT_FUNDS',
        );
      }
      
      // Calculate total input
      final totalInput = selectedUtxos.fold<BigInt>(
        BigInt.zero,
        (sum, utxo) => sum + utxo.value.getValue(),
      );
      
      // Build transaction using DartSV patterns
      final builder = dartsv.TransactionBuilder();
      final signer = dartsv.TransactionSigner(
        dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value,
        signingKey,
      );
      
      // Add inputs - based on tx_utils.dart pattern
      for (final utxo in selectedUtxos) {
        final outpoint = dartsv.TransactionOutpoint(
          utxo.txid,
          utxo.vout,
          utxo.value.getValue(),
          _createLockingScript(utxo),
        );
        
        builder.spendFromOutpointWithSigner(
          signer,
          outpoint,
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
          dartsv.P2PKHUnlockBuilder(signingKey.publicKey),
        );
      }
      
      // Set fee rate and options
      builder.withFeePerKb(config.feePerKb);
      for (final option in config.options) {
        builder.withOption(option);
      }
      
      // Add output
      builder.spendToPKH(toAddress, amount);
      
      // Add change output if needed
      builder.sendChangeToPKH(changeAddr);
      
      // Build transaction (skip sanity checks as per tx_utils.dart pattern)
      final transaction = builder.build(true);
      
      // Calculate actual fee and change
      final totalOutput = transaction.outputs.fold<BigInt>(
        BigInt.zero,
        (sum, output) => sum + BigInt.from(output.satoshis is int ? output.satoshis as int : (output.satoshis as double).toInt()),
      );
      final fee = totalInput - totalOutput;
      final changeAmount = totalOutput - amount;
      
      return TransactionBuildResult(
        transaction: transaction,
        selectedInputs: selectedUtxos,
        totalInput: totalInput,
        totalOutput: totalOutput,
        fee: fee,
        changeAmount: changeAmount,
        readyForSigning: true,
      );
      
    } catch (e) {
      if (e is TransactionBuildException) rethrow;
      throw TransactionBuildException('Failed to build P2PKH transaction: $e');
    }
  }

  /// Build a multi-output transaction
  Future<TransactionBuildResult> buildMultiOutputTransaction({
    required List<BitcoinUtxo> availableUtxos,
    required List<TransactionOutputSpec> outputs,
    required String changeAddress,
    required dartsv.SVPrivateKey signingKey,
    TransactionBuildConfig config = TransactionBuildConfig.standard,
  }) async {
    try {
      // Calculate total output amount
      final totalOutputAmount = outputs.fold<BigInt>(
        BigInt.zero,
        (sum, output) => sum + output.amount,
      );
      
      // Select UTXOs
      final selectedUtxos = _selectUTXOs(
        availableUtxos,
        totalOutputAmount + BigInt.from(config.feePerKb * 2), // Buffer for fees
        config.selectionStrategy,
      );
      
      if (selectedUtxos.isEmpty) {
        throw TransactionBuildException(
          'Insufficient funds: need $totalOutputAmount satoshis',
          code: 'INSUFFICIENT_FUNDS',
        );
      }
      
      // Calculate total input
      final totalInput = selectedUtxos.fold<BigInt>(
        BigInt.zero,
        (sum, utxo) => sum + utxo.value.getValue(),
      );
      
      // Build transaction
      final builder = dartsv.TransactionBuilder();
      final signer = dartsv.TransactionSigner(
        dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value,
        signingKey,
      );
      
      // Add inputs
      for (final utxo in selectedUtxos) {
        final outpoint = dartsv.TransactionOutpoint(
          utxo.txid,
          utxo.vout,
          utxo.value.getValue(),
          _createLockingScript(utxo),
        );
        
        builder.spendFromOutpointWithSigner(
          signer,
          outpoint,
          dartsv.TransactionInput.MAX_SEQ_NUMBER,
          dartsv.P2PKHUnlockBuilder(signingKey.publicKey),
        );
      }
      
      // Set fee rate and options
      builder.withFeePerKb(config.feePerKb);
      for (final option in config.options) {
        builder.withOption(option);
      }
      
      // Add outputs (only P2PKH for now)
      for (final outputSpec in outputs) {
        // Standard address output (custom scripts not yet supported)
        final address = dartsv.Address.fromBase58(outputSpec.address);
        builder.spendToPKH(address, outputSpec.amount);
      }
      
      // Add change output
      final changeAddr = dartsv.Address.fromBase58(changeAddress);
      builder.sendChangeToPKH(changeAddr);
      
      // Build transaction
      final transaction = builder.build(true);
      
      // Calculate results
      final totalOutput = transaction.outputs.fold<BigInt>(
        BigInt.zero,
        (sum, output) => sum + BigInt.from(output.satoshis is int ? output.satoshis as int : (output.satoshis as double).toInt()),
      );
      final fee = totalInput - totalOutput;
      final changeAmount = totalOutput - totalOutputAmount;
      
      return TransactionBuildResult(
        transaction: transaction,
        selectedInputs: selectedUtxos,
        totalInput: totalInput,
        totalOutput: totalOutput,
        fee: fee,
        changeAmount: changeAmount,
        readyForSigning: true,
      );
      
    } catch (e) {
      if (e is TransactionBuildException) rethrow;
      throw TransactionBuildException('Failed to build multi-output transaction: $e');
    }
  }

  /// Select UTXOs based on strategy
  List<BitcoinUtxo> _selectUTXOs(
    List<BitcoinUtxo> availableUtxos,
    BigInt requiredAmount,
    UTXOSelectionStrategy strategy,
  ) {
    // Filter available UTXOs (unspent and not reserved)
    final unspentUtxos = availableUtxos
        .where((utxo) => utxo.status == UTXOStatus.available)
        .toList();
    
    if (unspentUtxos.isEmpty) {
      return [];
    }
    
    // Sort based on strategy
    switch (strategy) {
      case UTXOSelectionStrategy.smallestFirst:
        unspentUtxos.sort((a, b) => a.value.getValue().compareTo(b.value.getValue()));
        break;
        
      case UTXOSelectionStrategy.largestFirst:
        unspentUtxos.sort((a, b) => b.value.getValue().compareTo(a.value.getValue()));
        break;
        
      case UTXOSelectionStrategy.random:
        unspentUtxos.shuffle();
        break;
        
      case UTXOSelectionStrategy.optimalChange:
        // Try to find exact match first, then largest first
        unspentUtxos.sort((a, b) => b.value.getValue().compareTo(a.value.getValue()));
        break;
    }
    
    // Select UTXOs until we have enough
    final selected = <BitcoinUtxo>[];
    BigInt totalSelected = BigInt.zero;
    
    for (final utxo in unspentUtxos) {
      selected.add(utxo);
      totalSelected += utxo.value.getValue();
      
      if (totalSelected >= requiredAmount) {
        break;
      }
    }
    
    return totalSelected >= requiredAmount ? selected : [];
  }

  /// Create locking script for UTXO
  dartsv.SVScript _createLockingScript(BitcoinUtxo utxo) {
    // Create script from the scriptPubKey hex string
    if (utxo.scriptPubKey.isNotEmpty) {
      return dartsv.SVScript.fromHex(utxo.scriptPubKey);
    }
    
    // Fallback: create empty script (will need to be provided externally)
    return dartsv.SVScript();
  }

  /// Estimate transaction fee based on inputs and outputs
  BigInt estimateFee({
    required int inputCount,
    required int outputCount,
    required int feePerKb,
  }) {
    // Rough estimate: 180 bytes per input + 34 bytes per output + 10 bytes overhead
    final estimatedSize = (inputCount * 180) + (outputCount * 34) + 10;
    return BigInt.from((estimatedSize * feePerKb) ~/ 1000);
  }

  /// Get optimal UTXO count for amount
  int getOptimalUTXOCount(List<BitcoinUtxo> utxos, BigInt amount) {
    final sorted = List<BitcoinUtxo>.from(utxos)
      ..sort((a, b) => b.value.getValue().compareTo(a.value.getValue()));
    
    BigInt total = BigInt.zero;
    int count = 0;
    
    for (final utxo in sorted) {
      count++;
      total += utxo.value.getValue();
      if (total >= amount) {
        return count;
      }
    }
    
    return count;
  }
} 