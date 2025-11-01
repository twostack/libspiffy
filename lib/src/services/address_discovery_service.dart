import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';

import '../models/blockchain_data_models.dart';
import 'blockchain_data_source.dart';

/// Service for discovering used addresses in an HD wallet
///
/// Implements BIP44 address discovery using the "gap limit" algorithm:
/// 1. Derive addresses sequentially from an HD public key
/// 2. Check each address for transaction history
/// 3. Stop when finding N consecutive unused addresses (gap limit)
///
/// This ensures we discover all used addresses without scanning infinitely.
///
/// Example:
/// ```dart
/// final discoveryService = AddressDiscoveryService(dataSource);
/// final result = await discoveryService.discoverAddresses(
///   hdPublicKey: hdPubKey,
///   gapLimit: 20,
/// );
/// print('Found ${result.usedAddresses.length} used addresses');
/// ```
class AddressDiscoveryService {
  final Logger _logger = Logger('AddressDiscoveryService');
  final BlockchainDataSource _dataSource;

  AddressDiscoveryService(this._dataSource);

  /// Discover all used addresses in an HD wallet
  ///
  /// Parameters:
  /// - [hdPublicKey]: The HD public key to derive addresses from (m/44'/0'/0')
  /// - [networkType]: Network type ('main' or 'test')
  /// - [gapLimit]: Number of consecutive unused addresses before stopping (default: 20)
  /// - [onProgress]: Optional callback for progress updates
  ///
  /// Returns [AddressDiscoveryResult] with all discovered addresses.
  ///
  /// The process checks both receiving addresses (m/44'/0'/0'/0/x) and
  /// change addresses (m/44'/0'/0'/1/x) according to BIP44.
  Future<AddressDiscoveryResult> discoverAddresses({
    required dartsv.HDPublicKey hdPublicKey,
    required String networkType,
    int gapLimit = 20,
    void Function(int scannedCount, int usedCount)? onProgress,
  }) async {
    _logger.info(
      '🔍 Starting address discovery with gap limit $gapLimit on network: $networkType',
    );
    _logger.info('   HD Public Key (xpub): ${hdPublicKey.xpubkey}');

    final usedAddresses = <DiscoveredAddress>[];
    int totalTransactions = 0;

    // Determine network type
    final network = networkType == 'main'
        ? dartsv.NetworkType.MAIN
        : dartsv.NetworkType.TEST;
    
    _logger.info('   Network type resolved to: ${network == dartsv.NetworkType.MAIN ? "MAINNET" : "TESTNET"}');

    // Scan receiving addresses (m/44'/236'/0'/0/x for BSV)
    _logger.fine('Scanning receiving addresses...');
    final receivingResults = await _scanAddressChain(
      hdPublicKey: hdPublicKey,
      isChange: false,
      network: network,
      gapLimit: gapLimit,
      onProgress: onProgress,
    );
    usedAddresses.addAll(receivingResults);
    totalTransactions += receivingResults.fold<int>(
      0,
      (sum, addr) => sum + addr.transactionCount,
    );

    // Scan change addresses (m/44'/236'/0'/1/x for BSV)
    _logger.fine('Scanning change addresses...');
    final changeResults = await _scanAddressChain(
      hdPublicKey: hdPublicKey,
      isChange: true,
      network: network,
      gapLimit: gapLimit,
      onProgress: onProgress,
    );
    usedAddresses.addAll(changeResults);
    totalTransactions += changeResults.fold<int>(
      0,
      (sum, addr) => sum + addr.transactionCount,
    );

    final lastCheckedIndex = usedAddresses.isEmpty
        ? 0
        : usedAddresses
            .map((addr) => addr.derivationIndex)
            .reduce((a, b) => a > b ? a : b);

    _logger.info(
      'Discovery complete: ${usedAddresses.length} addresses, '
      '$totalTransactions transactions',
    );

    return AddressDiscoveryResult(
      usedAddresses: usedAddresses,
      lastCheckedIndex: lastCheckedIndex,
      totalTransactions: totalTransactions,
    );
  }

  /// Scan a single chain (receiving or change) for used addresses
  Future<List<DiscoveredAddress>> _scanAddressChain({
    required dartsv.HDPublicKey hdPublicKey,
    required bool isChange,
    required dartsv.NetworkType network,
    required int gapLimit,
    void Function(int scannedCount, int usedCount)? onProgress,
  }) async {
    final usedAddresses = <DiscoveredAddress>[];
    int consecutiveUnused = 0;
    int index = 0;
    int scannedCount = 0;

    // Derive the change or receiving chain key
    final chainKey = hdPublicKey.deriveChildNumber(isChange ? 1 : 0);
    _logger.info('   → Scanning ${isChange ? "change" : "receiving"} address chain...');

    while (consecutiveUnused < gapLimit) {
      // Derive address at current index
      final addressKey = chainKey.deriveChildNumber(index);
      final address = addressKey.publicKey.toAddress(network).toString();

      scannedCount++;
      
      if (index < 3 || usedAddresses.isNotEmpty) {
        // Log first 3 addresses always, and any address when we've found used ones
        _logger.info(
          '      Checking ${isChange ? "change" : "receiving"} address m/44\'/236\'/0\'/${isChange ? "1" : "0"}/$index: $address',
        );
      }

      // Check if address has transaction history
      try {
        final history = await _dataSource.getTransactionHistory(
          address,
          // No limit - fetch all transactions (data source handles pagination)
        );

        if (history.isNotEmpty) {
          // Address has been used
          _logger.info(
            '      ✅ Found used address at index $index with ${history.length} transactions',
          );

          usedAddresses.add(DiscoveredAddress(
            address: address,
            derivationIndex: index,
            isChange: isChange,
            transactionCount: history.length,
            txids: history.map((tx) => tx.txid).toList(),
          ));

          consecutiveUnused = 0; // Reset gap counter
        } else {
          // Address is unused
          consecutiveUnused++;
          if (index < 3) {
            _logger.info('      ⚪ Address unused, gap count: $consecutiveUnused/$gapLimit');
          }
        }
      } catch (e) {
        _logger.warning('      ❌ Error checking address $address: $e');
        // Continue scanning even if one address fails
        consecutiveUnused++;
      }

      index++;

      // Report progress
      if (onProgress != null) {
        onProgress(scannedCount, usedAddresses.length);
      }
    }

    _logger.fine(
      'Finished scanning ${isChange ? 'change' : 'receiving'} chain: '
      '${usedAddresses.length} used addresses found',
    );

    return usedAddresses;
  }

  /// Discover addresses for a specific index range
  ///
  /// Useful for resuming discovery or scanning specific ranges.
  ///
  /// Parameters:
  /// - [hdPublicKey]: The HD public key to derive addresses from
  /// - [networkType]: Network type ('main' or 'test')
  /// - [isChange]: Whether to scan change addresses (true) or receiving addresses (false)
  /// - [startIndex]: Starting derivation index (default: 0)
  /// - [endIndex]: Ending derivation index (exclusive)
  ///
  /// Returns list of [DiscoveredAddress] for used addresses in the range.
  Future<List<DiscoveredAddress>> discoverAddressRange({
    required dartsv.HDPublicKey hdPublicKey,
    required String networkType,
    required bool isChange,
    required int startIndex,
    required int endIndex,
  }) async {
    if (startIndex < 0 || endIndex <= startIndex) {
      throw ArgumentError('Invalid index range: $startIndex to $endIndex');
    }

    final network = networkType == 'main'
        ? dartsv.NetworkType.MAIN
        : dartsv.NetworkType.TEST;

    final usedAddresses = <DiscoveredAddress>[];
    final chainKey = hdPublicKey.deriveChildNumber(isChange ? 1 : 0);

    for (int index = startIndex; index < endIndex; index++) {
      final addressKey = chainKey.deriveChildNumber(index);
      final address = addressKey.publicKey.toAddress(network).toString();

      try {
        final history = await _dataSource.getTransactionHistory(
          address,
          // No limit - fetch all transactions (data source handles pagination)
        );

        if (history.isNotEmpty) {
          usedAddresses.add(DiscoveredAddress(
            address: address,
            derivationIndex: index,
            isChange: isChange,
            transactionCount: history.length,
            txids: history.map((tx) => tx.txid).toList(),
          ));
        }
      } catch (e) {
        _logger.warning('Error checking address $address: $e');
      }
    }

    return usedAddresses;
  }

  /// Get transaction history for a single address
  ///
  /// Helper method for retrieving complete transaction history.
  Future<List<TransactionInfo>> getAddressHistory(String address) async {
    return _dataSource.getTransactionHistory(address);
  }
}

