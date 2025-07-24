# LibSpiffy Implementation Roadmap

**Actor-Based SPV Bitcoin Wallet Library**

Version: 1.0.0  
Last Updated: December 2024

---

## 🎯 **Project Vision**

LibSpiffy is an event-sourced, actor-based Bitcoin SPV wallet library built on the Dactor/Eventador/DuraQ stack with SpiffyNode integration for robust peer-to-peer functionality and chain tracking.

### **Core Architectural Principles**
- ✅ **Event Sourcing**: All wallet state changes captured as immutable events
- ✅ **Aggregate Root Per Wallet**: Each wallet is an independent aggregate with UTXO scope isolation
- ✅ **Flexible Storage Abstraction**: Interface-based storage with in-memory default, Isar-compatible design
- ✅ **P2P Library Agnostic**: Abstract P2P integration, deferring CryptoPeer decisions
- ✅ **DartSV Foundation**: Pure BSV transaction library without Lightning/Segwit cruft

---

## 📋 **Implementation Phases**

# **PHASE 1: FOUNDATION & CORE ARCHITECTURE** 🚧 **IN PROGRESS**
*Timeline: 3-4 weeks* | **Status: Phase 1A & 1B Complete ✅ | Phase 1C & 1D In Progress**

## **🎉 PHASE 1 PROGRESS SUMMARY**

### **✅ COMPLETED (Phases 1A & 1B)**
- **Core Models**: `WalletEvent`, `BitcoinUtxo`, `WalletState`, `BitcoinTransaction` with full DartSV integration
- **Storage Interfaces**: `WalletStorage` and `SecureStorage` with platform-agnostic design
- **In-Memory Implementations**: Thread-safe storage with caching, statistics, and debugging tools
- **Infrastructure**: Project structure, dependencies, exports, and DartSV API integration
- **Key Integration**: Successfully resolved `Coin.getValue()` and `TransactionOutput.satoshis` usage

### **📋 NEXT UP (Phases 1C & 1D)**
- **Phase 1C**: Wallet Aggregate Root with event sourcing business logic
- **Phase 1D**: Basic Services (Crypto, ARC, BEEF/BUMP, Transaction Building)

## **Phase 1A: Project Foundation (Week 1)** ✅ **COMPLETED**
*Goal: Set up basic infrastructure and project structure*

### **🔧 Infrastructure Setup** ✅ **COMPLETED**
- [x] **Update pubspec.yaml dependencies** ✅ **COMPLETED**
  - [x] Add spiffynode dependency path
  - [x] Verify eventador, dactor, dartsv integration
  - [x] Add additional required packages (uuid, logging, etc.)
- [x] **Create core project structure** ✅ **COMPLETED**
  ```
  lib/src/
  ├── core/           # Aggregate roots, events, commands
  ├── models/         # Domain models ✅ IMPLEMENTED
  ├── services/       # Business services
  ├── storage/        # Storage abstraction ✅ IMPLEMENTED
  │   ├── wallet_storage.dart      # Wallet data storage interface ✅
  │   ├── secure_storage.dart      # Secure storage interface ✅
  │   ├── in_memory_wallet_storage.dart   # In-memory implementations ✅
  │   ├── in_memory_secure_storage.dart   # In-memory implementations ✅
  │   └── isar_storage.dart        # Future: Isar implementations
  ├── actors/         # Actor implementations
  ├── spv/           # SPV validation and BEEF/BUMP utilities
  │   ├── beef.dart          # Background Evaluation Extended Format
  │   ├── bump.dart          # BSV Universal Merkle Path  
  │   ├── spv_validator.dart # SPV validation service
  │   └── merkle_utils.dart  # Merkle tree utilities
  └── utils/          # Utility functions
  ```
- [x] **Set up main libspiffy.dart export file** ✅ **COMPLETED**
- [ ] **Create basic logging configuration**
- [ ] **Set up example directory structure**

### **📊 Core Domain Models** ✅ **COMPLETED**
- [x] **Port BitcoinUtxo from speculative code** ⭐ **IMPLEMENTED** ✅
  - [x] UTXO identification (txid, vout, scriptPubKey)
  - [x] Value handling using DartSV's `Coin` class with `getValue()` method
  - [x] Spent/unspent status tracking with UTXOStatus enum
  - [x] Block confirmation tracking
  - [x] Reservation system for transaction building
  - [x] Complete CRUD operations with copyWith pattern
- [x] **Port BitcoinTransaction from speculative code** ⭐ **IMPLEMENTED** ✅
  - [x] Transaction data structure (inputs, outputs, locktime)
  - [x] Fee calculation and validation
  - [x] Transaction status tracking with TransactionStatus enum
  - [x] Integration with DartSV's Transaction class (with input value parameter)
  - [x] Net amount calculation for wallet perspective
  - [x] Convenience methods (isIncoming, isOutgoing, isConfirmed)
- [x] **WalletEvent base class** ⭐ **IMPLEMENTED** ✅
  - [x] Event sourcing foundation with UUID generation
  - [x] Version tracking and timestamp management
  - [x] Serialization/deserialization support
  - [x] Abstract base for all wallet events
- [x] **WalletState for snapshots** ⭐ **IMPLEMENTED** ✅
  - [x] Immutable wallet state representation
  - [x] UTXO collection with reservation tracking
  - [x] Address generation tracking with derivation index
  - [x] Balance calculations using DartSV's Coin class
  - [x] Serialization support for persistence
- [x] **Use DartSV's Coin class for money values** ⭐ **IMPLEMENTED** ✅
  ```dart
  import 'package:dartsv/dartsv.dart' as dartsv;
  
  // Successfully integrated DartSV's Coin with getValue() method
  class WalletBalance {
    final dartsv.Coin confirmed;     // DartSV's satoshi-native money type
    final dartsv.Coin unconfirmed;   // Handles Bitcoin-specific precision
    final dartsv.Coin total;         // Built-in arithmetic operations
    
    dartsv.Coin get availableBalance => confirmed + unconfirmed;
    BigInt get satoshis => availableBalance.getValue();
  }
  ```
- [ ] **Port AddressInfo from speculative code** ⭐ **PENDING**
  - [ ] Address metadata (derivation index, used status)
  - [ ] Address type detection and validation
  - [ ] Integration with HD wallet derivation paths
- [x] **Create supporting value objects** ⭐ **IMPLEMENTED** ✅
  - [x] `TransactionStatus` enum (created, signed, broadcast, pending, confirmed, failed)
  - [x] `UTXOStatus` enum (available, reserved, spent)
  - [ ] `NetworkType` enum (mainnet, testnet) - integrate with DartSV's NetworkType
  - [ ] `AddressPurpose` enum (receiving, change, etc.)

### **🎭 Event Sourcing Foundation**
- [ ] **Define wallet events**
  ```dart
  // Wallet lifecycle
  - WalletCreatedEvent
  - WalletConfigurationUpdatedEvent
  
  // Address management
  - AddressGeneratedEvent  
  - AddressLabelUpdatedEvent
  
  // UTXO lifecycle
  - UTXOReceivedEvent
  - UTXOSpentEvent
  - UTXOConfirmationUpdatedEvent
  
  // Transaction management
  - TransactionCreatedEvent
  - TransactionSignedEvent
  - TransactionBroadcastEvent
  
  // UTXO reservations
  - UTXOReservationPlacedEvent
  - UTXOReservationReleasedEvent
  - UTXOReservationExpiredEvent
  
  // Balance tracking
  - BalanceUpdatedEvent
  ```
- [ ] **Define wallet commands**
  ```dart
  - CreateWalletCommand
  - GenerateAddressCommand
  - ReceiveUTXOCommand
  - SpendUTXOCommand
  - CreateTransactionCommand
  - SignTransactionCommand
  - BroadcastTransactionCommand
  - ReserveUTXOCommand
  - ReleaseUTXOCommand
  ```
- [ ] **Create wallet state model**
  - [ ] Immutable wallet state representation
  - [ ] Event application methods
  - [ ] Balance calculation logic
  - [ ] UTXO availability checking

---

## **Phase 1B: Storage Abstraction (Week 2)** ✅ **COMPLETED**
*Goal: Flexible, testable storage layer*

### **💾 Storage Interface Design** ✅ **COMPLETED**
- [x] **Create abstract WalletStorage interface** ⭐ **IMPLEMENTED** ✅
  ```dart
  abstract class WalletStorage {
    // Event store operations ✅ IMPLEMENTED
    Future<void> saveEvents(String walletId, List<WalletEvent> events);
    Future<List<WalletEvent>> loadEvents(String walletId, {int? fromVersion});
    
    // UTXO queries (read model) ✅ IMPLEMENTED
    Future<List<BitcoinUtxo>> getUTXOs(String walletId, {bool includeSpent});
    Future<List<BitcoinUtxo>> getAvailableUTXOs(String walletId);
    Future<BigInt> getBalance(String walletId);
    
    // Wallet management ✅ IMPLEMENTED
    Future<List<String>> getWalletIds();
    Future<bool> walletExists(String walletId);
    Future<void> deleteWallet(String walletId);
  }
  ```

### **🔐 Secure Storage Interface Design** ✅ **COMPLETED**
- [x] **Create platform-agnostic SecureStorage interface** ⭐ **IMPLEMENTED** ✅
  ```dart
  abstract class SecureStorage {
    // Basic secure storage operations ✅ IMPLEMENTED
    Future<String?> getString(String key);
    Future<void> setString(String key, String value);
    Future<bool> containsKey(String key);
    Future<void> delete(String key);
    Future<void> deleteAll();
    Future<Map<String, String>> getAll();
    
    // Wallet-specific operations ✅ IMPLEMENTED
    Future<String?> getPrivateKey(String walletId);
    Future<void> setPrivateKey(String walletId, String privateKey);
    Future<String?> getMnemonic(String walletId);
    Future<void> setMnemonic(String walletId, String mnemonic);
    
    // Identity operations ✅ IMPLEMENTED  
    Future<String?> getIdentityKey(String identityId);
    Future<void> setIdentityKey(String identityId, String privateKey);
    Future<List<String>> getIdentityIds();
    
    // Account metadata ✅ IMPLEMENTED
    Future<void> setAccountMetadata(String accountId, Map<String, String> metadata);
    Future<Map<String, String>> getAccountMetadata(String accountId);
    Future<void> deleteAccountMetadata(String accountId);
  }
  ```
- [x] **Reference existing implementation for feature completeness** ✅ **COMPLETED**
  - [x] Use speculative_code/services/secure_storage_service.dart as feature reference ⭐
  - [x] Extract all required operations from FlutterSecureStorage implementation
  - [x] Maintain API compatibility for easy platform implementation

### **🧠 In-Memory Implementation** ✅ **COMPLETED**  
- [x] **Create InMemoryWalletStorage** ⭐ **IMPLEMENTED** ✅
  - [x] Event storage with Map<String, List<WalletEvent>>
  - [x] UTXO indexing for efficient queries with Map<String, Map<String, BitcoinUtxo>>
  - [x] Thread-safe operations with proper locking using Completer-based locks
  - [x] Balance caching with automatic invalidation
  - [x] Wallet isolation and cleanup operations
  - [x] Additional UTXO management methods (addOrUpdateUtxo, removeUtxo, updateUtxoStatus)
- [x] **Create InMemorySecureStorage** ⭐ **IMPLEMENTED** ✅
  - [x] Basic key-value storage with Map<String, String>
  - [x] Wallet private key and mnemonic storage
  - [x] Identity key management
  - [x] Account metadata storage with prefix-based organization
  - [x] **WARNING**: Properly documented as development/testing only
  - [x] Debug utilities (debugInfo, statistics, integrity validation)
- [x] **Implement query optimizations** ✅ **COMPLETED**
  - [x] Index UTXOs by wallet ID with efficient Map-based storage
  - [x] Balance caching with invalidation on state changes
  - [x] Wallet-specific locking for thread safety
- [x] **Add storage statistics and monitoring** ✅ **COMPLETED**
  - [x] Memory usage tracking (total events, UTXOs, wallets)
  - [x] Storage statistics (events, UTXOs, balance cache)
  - [x] Debug information for troubleshooting

### **🔮 Future Storage Preparations**
- [ ] **Design Isar-compatible data models**
  - [ ] Ensure all models can be serialized to Isar
  - [ ] Plan index strategies for efficient queries
  - [ ] Design migration strategies
- [ ] **Create storage factory pattern**
  - [ ] Abstract factory for storage implementations
  - [ ] Configuration-driven storage selection
  - [ ] Environment-specific storage strategies
- [ ] **Platform-specific secure storage implementations**  
  - [ ] Flutter implementation using FlutterSecureStorage
  - [ ] Desktop implementation using OS keychain/credential manager
  - [ ] Web implementation using secure IndexedDB with encryption
  - [ ] Server implementation using encrypted configuration files
  - [ ] Hardware security module (HSM) integration for enterprise

---

## **Phase 1C: Wallet Aggregate Root (Week 3)**
*Goal: Event-sourced wallet with business logic*

### **🏛️ Aggregate Root Implementation**
- [ ] **Create BitcoinWalletAggregate**
  ```dart
  class BitcoinWalletAggregate extends AggregateRoot {
    final String walletId;
    WalletState _state;
    
    // Command processing
    Future<List<WalletEvent>> processCommand(WalletCommand command);
    
    // Event application
    void applyEvent(WalletEvent event);
    
    // Business rule validation
    bool _canSpendUTXO(String utxoKey);
    bool _canReserveUTXO(String utxoKey);
  }
  ```
- [ ] **Implement command handlers**
  - [ ] `_handleCreateWallet` - Initialize new wallet
  - [ ] `_handleGenerateAddress` - Create new addresses
  - [ ] `_handleReceiveUTXO` - Track incoming UTXOs
  - [ ] `_handleSpendUTXO` - Process UTXO spending
  - [ ] `_handleReserveUTXO` - Reserve UTXOs for transactions
  - [ ] `_handleReleaseUTXO` - Release UTXO reservations
- [ ] **Implement event application**
  - [ ] State transitions for each event type
  - [ ] Immutable state updates
  - [ ] Consistency validation

### **🔐 Business Rules & Validation**
- [ ] **UTXO management rules**  
  - [ ] Prevent double-spending
  - [ ] Validate UTXO ownership
  - [ ] Check reservation conflicts
  - [ ] Handle expiration logic
- [ ] **Transaction validation**
  - [ ] Input/output validation
  - [ ] Fee calculation verification
  - [ ] Signature requirements
- [ ] **Wallet constraints**
  - [ ] Maximum address generation limits
  - [ ] Balance consistency checks
  - [ ] State invariant validation

### **⚡ In-Flight Transaction Tracking**
- [ ] **Implement spent-but-unconfirmed logic**
  - [ ] Track pending outgoing transactions
  - [ ] Handle transaction confirmation updates
  - [ ] Manage conflicting transactions
  - [ ] Automatic cleanup of expired transactions
- [ ] **UTXO reservation system**
  - [ ] Time-based reservations
  - [ ] Automatic expiration handling
  - [ ] Reservation conflict resolution
  - [ ] Integration with transaction building

---

## **Phase 1D: Basic Services (Week 4)**
*Goal: Core wallet services and utilities*

### **🔑 Cryptographic Services**
- [ ] **Port crypto utilities from speculative code**
  - [ ] Mnemonic generation and validation
  - [ ] HD key derivation (BIP32/BIP44)
  - [ ] Address generation for different script types
  - [ ] Private key management and signing
- [ ] **Create CryptoService interface**
  ```dart
  abstract class CryptoService {
    Future<String> generateMnemonic();
    Future<bool> validateMnemonic(String mnemonic);
    Future<String> generateAddress(String derivationPath);
    Future<List<int>> signTransaction(Transaction tx, PrivateKey key);
  }
  ```
- [ ] **Implement DartSV-based crypto service**
  - [ ] Integration with DartSV for all cryptographic operations
  - [ ] Support for BSV-specific features
  - [ ] Secure key storage abstractions

### **🌐 ARC Service Integration (Production-Ready Reference Available)**
- [ ] **Port production-ready ARC service from speculative code** ⭐ **EXISTING IMPLEMENTATION**
  - [ ] HTTP client for ARC API communication ✅ **COMPLETE**
  - [ ] Transaction submission with proper error handling ✅ **COMPLETE**
  - [ ] Status checking with all ARC transaction states ✅ **COMPLETE**
  - [ ] Batch transaction operations ✅ **COMPLETE**
  - [ ] Policy and health endpoint integration ✅ **COMPLETE**
  - [ ] Adapt for BEEF format merkle proof retrieval (extend existing)
- [ ] **Adapt existing ArcService interface for BEEF integration**
  ```dart
  // Based on existing production-ready implementation
  class ArcService {
    // ✅ EXISTING: Transaction operations
    Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl});
    Future<ArcTransactionResponse> getTransaction(String txid);
    Future<String> getRawTransaction(String txid);
    Future<List<ArcSubmitResponse>> submitBatchTransactions(List<String> rawTxs);
    
    // 🔄 EXTEND: Add BEEF format support
    Future<BEEF?> getTransactionProofBEEF(String txid);
    Future<BEEF?> getBatchTransactionProofs(List<String> txids);
  }
  ```
- [ ] **Leverage existing configuration management** ✅ **COMPLETE**
  - [ ] Multiple ARC node support (baseUrl configuration)
  - [ ] API key authentication handling
  - [ ] Proper HTTP client lifecycle management
  - [ ] Error handling and exception management

### **🥩 BEEF/BUMP Integration (Critical for BSV SPV)**
- [ ] **Port BEEF (Background Evaluation Extended Format) from speculative code** ⭐ **EXISTING IMPLEMENTATION**
  - [ ] BEEF parsing and serialization (0100BEEF magic bytes) ✅ **COMPLETE**
  - [ ] Transaction packaging with merkle proofs ✅ **COMPLETE**
  - [ ] Multi-transaction BEEF support ✅ **COMPLETE**
  - [ ] BEEF validation against block headers ✅ **COMPLETE**
  - [ ] Integration with BlockHeaderService ✅ **COMPLETE**
- [ ] **Port BUMP (BSV Universal Merkle Path) from speculative code** ⭐ **EXISTING IMPLEMENTATION**
  - [ ] BUMP parsing and serialization ✅ **COMPLETE**
  - [ ] Merkle path validation algorithms ✅ **COMPLETE**
  - [ ] Merkle root computation for SPV verification ✅ **COMPLETE**
  - [ ] Block height tracking and validation ✅ **COMPLETE**
  - [ ] Tree traversal and sibling hash resolution ✅ **COMPLETE**
- [ ] **Create SPV validation services using proven patterns** ⭐ **REFERENCE PATTERNS AVAILABLE**
  ```dart
  // Based on BEEF validation patterns from spv_protocol.dart
  class SPVValidator {
    final ArcService arcService;
    final BlockHeaderService blockHeaderService;
    
    Future<bool> validateBEEF(BEEF beef) async {
      // Basic BEEF structure validation
      if (!beef.validate()) return false;
      
      // Get transactions with merkle proofs
      final verifiedTxs = beef.getVerifiedTransactions();
      
      // Validate each transaction with merkle proof against block headers
      for (final tx in verifiedTxs) {
        final txid = tx['txid'] as Uint8List;
        final isValid = await beef.validateTransactionWithBlockHeaderService(
          txid, blockHeaderService
        );
        if (!isValid) return false;
      }
      
      return true;
    }
    
    Future<bool> validateTransactionWithScript(dartsv.Transaction tx, BEEF beef) async {
      // Script validation using DartSV interpreter
      var scriptFlags = <dartsv.VerifyFlag>{}..addAll([
        dartsv.VerifyFlag.SIGHASH_FORKID, 
        dartsv.VerifyFlag.UTXO_AFTER_GENESIS
      ]);
      
      var interpreter = dartsv.Interpreter();
      
      for (int i = 0; i < tx.inputs.length; i++) {
        final input = tx.inputs[i];
        final scriptSig = input.script;
        
        // Find funding transaction in BEEF
        final fundingTxMap = beef.findTransactionByTxid(
          Uint8List.fromList(hex.decode(input.prevTxnId))
        );
        
        if (fundingTxMap != null) {
          final fundingTxHex = hex.encode(fundingTxMap['txData']);
          final fundingTx = dartsv.Transaction.fromHex(fundingTxHex);
          final scriptPubKey = fundingTx.outputs[input.prevTxnOutputIndex].script;
          final lockedValue = fundingTx.outputs[input.prevTxnOutputIndex].satoshis;
          
          try {
            interpreter.correctlySpends(
              scriptSig!, scriptPubKey, tx, i, scriptFlags, 
              dartsv.Coin.ofSat(lockedValue)
            );
          } on dartsv.ScriptException catch (ex) {
            print('Script validation failed: ${ex.cause} - ${ex.error}');
            return false;
          }
        }
      }
      
      return true;
    }
  }
  ```
- [ ] **BEEF creation patterns for transaction building** ⭐ **REFERENCE PATTERNS AVAILABLE**
  ```dart
  // Based on BEEF creation patterns from spv_protocol.dart
  class BEEFBuilder {
    Future<BEEF> createBEEFForTransaction(
      dartsv.Transaction signedTx,
      List<BitcoinUtxo> utxos,
      TransactionHistoryService txHistoryService
    ) async {
      final bumps = <BUMP>[];
      final txDataList = <Uint8List>[];
      final hasMerkle = <bool>[];
      final bumpIndex = <int>[];
      int bumpCount = 0;
      
      // Process each UTXO to build merkle proofs
      for (var utxo in utxos) {
        final txEntry = await txHistoryService.getTransaction(utxo.txid);
        
        if (txEntry?.merkleProof != null && txEntry!.isConfirmed) {
          // Parse merkle proof from JSON (BRC-71 format)
          final merkleProofJson = jsonDecode(txEntry.merkleProof!);
          
          // Convert BRC-71 format to BUMP
          final bump = CryptoUtils.convertBrc71PathToBump(
            merkleProofJson, txEntry.blockHeight, txEntry.txid
          );
          
          bumps.add(bump);
          txDataList.add(Uint8List.fromList(hex.decode(txEntry.rawHex)));
          hasMerkle.add(true);
          bumpIndex.add(bumpCount);
          bumpCount++;
        }
      }
      
      // Add the new signed transaction (without merkle proof)
      final signedTxBytes = Uint8List.fromList(hex.decode(signedTx.serialize()));
      txDataList.add(signedTxBytes);
      hasMerkle.add(false);
      
      // Create and validate BEEF
      final beef = BEEF.create(
        bumps: bumps,
        txs: txDataList,
        hasMerkle: hasMerkle,
        bumpIndex: bumpIndex,
      );
      
      return beef;
    }
  }
  ```
- [ ] **BEEF/BUMP utility functions** ✅ **EXISTING IMPLEMENTATIONS**
  - [ ] Transaction ID calculation (double SHA-256) ✅ **COMPLETE**
  - [ ] Merkle tree navigation algorithms ✅ **COMPLETE**
  - [ ] Byte order handling (little-endian vs big-endian) ✅ **COMPLETE**
  - [ ] Hash pair computation for merkle trees ✅ **COMPLETE**
  - [ ] Block header format compatibility ✅ **COMPLETE**
  - [ ] BRC-71 to BUMP conversion utilities ✅ **COMPLETE**

### **🛠️ Transaction Building**
- [ ] **Port transaction builder from speculative code** ⭐ **REFERENCE PATTERNS AVAILABLE**
  - [ ] Use speculative_code/protocol/spv_protocol.dart as reference for DartSV patterns
  - [ ] UTXO selection algorithms with amount-based selection
  - [ ] Fee estimation with `withFeePerKb()`
  - [ ] Change output handling with `sendChangeToPKH()`
  - [ ] Multi-input transactions with `spendFromOutpointWithSigner()`
- [ ] **Create TransactionBuilder service using proven DartSV patterns**
  ```dart
  class TransactionBuilder {
    // Based on patterns from spv_protocol.dart
    Future<Transaction> buildTransaction({
      required List<BitcoinUtxo> inputs,
      required List<TransactionOutput> outputs,
      BigInt? feeRate,
    }) async {
      var txBuilder = dartsv.TransactionBuilder();
      
      // Add outputs first
      for (final output in outputs) {
        txBuilder.spendToPKH(output.address, output.amount);
      }
      
      // Add change handling
      txBuilder.sendChangeToPKH(changeAddress);
      
      // Add inputs with proper unlocking
      for (final utxo in inputs) {
        var outpoint = dartsv.TransactionOutpoint(
          utxo.txid, utxo.vout, BigInt.parse(utxo.satoshis), lockingScript
        );
        txBuilder.spendFromOutpointWithSigner(
          signer, outpoint, dartsv.TransactionInput.MAX_SEQ_NUMBER,
          dartsv.P2PKHUnlockBuilder(publicKey)
        );
      }
      
      return txBuilder
        .withFeePerKb(feeRate ?? 1)
        .withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS)
        .build(true); // Don't skip sanity checks
    }
  }
  ```
- [ ] **Implement UTXO selection strategies with locking patterns**
  ```dart
  // Based on spv_protocol.dart UTXO management patterns
  class UTXOManager {
    Future<List<BitcoinUtxo>> selectUTXOsForAmount(BigInt amount) async {
      return await bitcoinWalletService.getUtxosForAmount(amount);
    }
    
    Future<List<BitcoinUtxo>> lockUTXOsForTransaction(
      List<BitcoinUtxo> utxos, String transactionId
    ) async {
      return await bitcoinWalletService.lockUtxosForTransaction(utxos, transactionId);
    }
    
    Future<void> unlockUTXOs(String transactionId) async {
      await bitcoinWalletService.unlockUtxos(transactionId);
    }
  }
  ```
- [ ] **Script validation using DartSV interpreter patterns**
  ```dart
  // Based on script validation from spv_protocol.dart
  class ScriptValidator {
    Future<bool> validateTransactionSpending(
      dartsv.Transaction tx, List<dartsv.Transaction> fundingTxs
    ) async {
      var scriptFlags = <dartsv.VerifyFlag>{}..addAll([
        dartsv.VerifyFlag.SIGHASH_FORKID, 
        dartsv.VerifyFlag.UTXO_AFTER_GENESIS
      ]);
      
      var interpreter = dartsv.Interpreter();
      
      for (int i = 0; i < tx.inputs.length; i++) {
        final input = tx.inputs[i];
        final fundingTx = fundingTxs[i];
        final scriptSig = input.script;
        final scriptPubKey = fundingTx.outputs[input.prevTxnOutputIndex].script;
        final lockedValue = fundingTx.outputs[input.prevTxnOutputIndex].satoshis;
        
        try {
          interpreter.correctlySpends(
            scriptSig!, scriptPubKey, tx, i, scriptFlags, 
            dartsv.Coin.ofSat(lockedValue)
          );
        } on dartsv.ScriptException catch (ex) {
          print('Script validation failed: ${ex.cause} - ${ex.error}');
          return false;
        }
      }
      return true;
    }
  }
  ```

---

# **PHASE 2: SPV INTEGRATION & NETWORKING**
*Timeline: 2-3 weeks*

## **Phase 2A: SpiffyNode Integration (Week 5)**
*Goal: Chain tracking and SPV validation with BEEF/BUMP*

### **📡 Chain Tip Integration**
- [ ] **Integrate ChainTipTracker from SpiffyNode**
  - [ ] Import spiffynode as dependency
  - [ ] Set up chain tip monitoring
  - [ ] Handle chain reorganizations
  - [ ] Network height tracking
- [ ] **Create enhanced SPVService with BEEF/BUMP support**
  ```dart
  class SPVService {
    final ChainTipTracker chainTipTracker;
    final SPVValidator beefValidator;
    
    int get networkHeight;
    Future<bool> validateBEEF(BEEF beef);
    Future<bool> validateTransaction(String txid, BUMP merkleProof);
    Stream<int> trackConfirmations(String txid);
    Future<bool> verifyTransactionInclusion(String txid, int blockHeight);
  }
  ```
- [ ] **Implement confirmation tracking with BEEF integration**
  - [ ] Real-time confirmation updates using BEEF proofs
  - [ ] Reorganization handling with merkle proof re-validation
  - [ ] Deep confirmation validation against block headers

### **🔗 Block Header Management with BEEF/BUMP Validation** 
- [ ] **Integrate SpiffyNode header tracking with BEEF validation**
  - [ ] Header synchronization for merkle root verification
  - [ ] Header validation for BEEF proof checking
  - [ ] Merkle root verification against BUMP computations
- [ ] **Implement enhanced SPV validation**
  - [ ] BEEF format merkle proof verification against headers
  - [ ] BUMP merkle path validation with block headers
  - [ ] Transaction inclusion verification using computed merkle roots
  - [ ] Block height validation for BEEF transactions
  - [ ] Fork handling for BEEF proofs across chain reorganizations

### **⚖️ Enhanced Balance & Confirmation Logic**
- [ ] **BEEF-based balance calculations**
  - [ ] Confirmation-based balance tiers using BEEF proofs
  - [ ] Pending transaction tracking with merkle proof validation
  - [ ] Reorganization impact assessment with BEEF re-validation
- [ ] **UTXO confirmation tracking with BEEF integration**
  - [ ] Real-time confirmation updates using ARC BEEF responses
  - [ ] Confirmation threshold configuration with merkle proof depth
  - [ ] Reorganization impact on UTXOs with BEEF proof re-validation

---

## **Phase 2B: Actor Architecture (Week 6)**
*Goal: Scalable multi-wallet actor system*

### **🎭 Wallet Manager Actor**
- [ ] **Create WalletManagerActor**
  ```dart
  class WalletManagerActor extends Actor {
    Map<String, BitcoinWalletAggregate> wallets;
    
    Future<void> handleCreateWallet(CreateWalletMessage msg);
    Future<void> handleExecuteCommand(ExecuteWalletCommandMessage msg);
    Future<void> handleWalletQuery(WalletQueryMessage msg);
  }
  ```
- [ ] **Implement wallet lifecycle management**
  - [ ] Wallet creation and initialization
  - [ ] Wallet loading and persistence
  - [ ] Wallet deletion and cleanup
  - [ ] Multi-wallet coordination

### **🌐 SPV Actor**
- [ ] **Create SPVActor for chain operations**
  - [ ] Chain tip monitoring
  - [ ] Block header synchronization
  - [ ] Transaction validation requests
  - [ ] Confirmation tracking
- [ ] **Implement SPV message handling**
  - [ ] Chain update notifications
  - [ ] Validation request processing
  - [ ] Confirmation status updates

### **📡 ARC Actor**
- [ ] **Create ARCActor for network communication**
  - [ ] Transaction broadcasting
  - [ ] Status monitoring
  - [ ] Merkle proof retrieval
  - [ ] Multi-node failover
- [ ] **Implement ARC message handling**
  - [ ] Broadcast request processing
  - [ ] Status polling management
  - [ ] Proof retrieval requests

---

## **Phase 2C: Advanced UTXO Management (Week 7)**  
*Goal: Production-ready UTXO handling*

### **🔒 UTXO Reservation System**
- [ ] **Enhanced reservation logic**
  - [ ] Time-based reservations with auto-expiry
  - [ ] Hierarchical reservation priority
  - [ ] Conflict resolution strategies
  - [ ] Reservation renewal mechanisms
- [ ] **Reservation persistence**
  - [ ] Event-sourced reservation tracking
  - [ ] Reservation recovery after restart
  - [ ] Cross-wallet reservation coordination

### **💰 Advanced Balance Calculations**
- [ ] **Multi-tier balance system**
  ```dart
  class WalletBalance {
    BigInt confirmed;           // >= 6 confirmations
    BigInt unconfirmed;         // 1-5 confirmations  
    BigInt pending;             // 0 confirmations
    BigInt reserved;            // Reserved for pending transactions
    BigInt available;           // Available for spending
  }
  ```
- [ ] **Real-time balance updates**
  - [ ] Event-driven balance recalculation
  - [ ] Efficient incremental updates
  - [ ] Balance change notifications

### **🔄 Transaction Status Management**
- [ ] **Comprehensive transaction tracking**
  - [ ] Transaction lifecycle states
  - [ ] Confirmation progression
  - [ ] Reorganization handling
  - [ ] Failed transaction cleanup
- [ ] **Automated status updates**
  - [ ] Background status polling
  - [ ] Event-driven status changes
  - [ ] User notification system

---

# **PHASE 3: PRODUCTION FEATURES**
*Timeline: 2-3 weeks*

## **Phase 3A: Multi-Wallet Support (Week 8)**
*Goal: Enterprise-grade wallet management*

### **🏢 Wallet Management System**
- [ ] **Wallet discovery and enumeration**
  - [ ] Wallet registry maintenance
  - [ ] Wallet metadata management
  - [ ] Wallet search and filtering
- [ ] **Wallet isolation and security**
  - [ ] Per-wallet security contexts
  - [ ] Isolated event streams
  - [ ] Cross-wallet operation prevention

### **📊 Wallet Analytics**
- [ ] **Transaction history analysis**
  - [ ] Spending pattern analysis
  - [ ] Fee optimization recommendations
  - [ ] Privacy score calculation
- [ ] **Performance metrics**
  - [ ] Wallet synchronization status
  - [ ] Transaction success rates
  - [ ] Network performance metrics

---

## **Phase 3B: Advanced Transaction Features (Week 9)**
*Goal: Sophisticated transaction handling*

### **🏗️ Complex Transaction Support**
- [ ] **Multi-input/multi-output transactions**
  - [ ] Batched transaction support
  - [ ] Complex script handling
  - [ ] Custom transaction templates
- [ ] **Transaction optimization**
  - [ ] Fee optimization algorithms
  - [ ] UTXO consolidation strategies
  - [ ] Privacy-preserving transactions

### **⏰ Scheduled and Delayed Transactions**
- [ ] **Transaction scheduling system**
  - [ ] Time-based transaction execution
  - [ ] Conditional transaction triggers
  - [ ] Recurring transaction support
- [ ] **Transaction templates**
  - [ ] Saved transaction patterns
  - [ ] Template parameterization
  - [ ] Template sharing and import

---

## **Phase 3C: Monitoring & Observability (Week 10)**
*Goal: Production monitoring and debugging*

### **📈 Metrics and Monitoring**
- [ ] **Wallet metrics collection**
  - [ ] Balance change tracking
  - [ ] Transaction volume metrics
  - [ ] Error rate monitoring
  - [ ] Performance metrics
- [ ] **Actor system monitoring**
  - [ ] Message processing rates
  - [ ] Actor lifecycle events
  - [ ] Memory usage tracking
  - [ ] Error rate analysis

### **🔍 Debugging and Diagnostics**
- [ ] **Comprehensive logging system**
  - [ ] Structured event logging
  - [ ] Performance timing logs
  - [ ] Error context capture
  - [ ] Debug information collection
- [ ] **Diagnostic tools**
  - [ ] Wallet state inspection
  - [ ] Event replay capabilities
  - [ ] Transaction trace analysis
  - [ ] Actor communication debugging

---

# **PHASE 4: POLISH & OPTIMIZATION**
*Timeline: 1-2 weeks*

## **Phase 4A: Performance Optimization (Week 11)**
*Goal: Production-ready performance*

### **⚡ Performance Tuning**
- [ ] **Memory optimization**
  - [ ] Event stream optimization
  - [ ] State caching strategies
  - [ ] Garbage collection tuning
- [ ] **Query optimization**
  - [ ] Index strategy optimization
  - [ ] Query result caching
  - [ ] Batch operation support
- [ ] **Actor system optimization**
  - [ ] Message batching
  - [ ] Actor pool management
  - [ ] Resource allocation optimization

### **📱 Resource Management**
- [ ] **Memory management**
  - [ ] Event history pruning
  - [ ] State snapshot strategies
  - [ ] Memory leak prevention
- [ ] **Network resource optimization**
  - [ ] Connection pooling
  - [ ] Request batching
  - [ ] Adaptive retry strategies

---

## **Phase 4B: Testing & Documentation (Week 12)**
*Goal: Production readiness*

### **🧪 Comprehensive Testing**
- [ ] **Unit test coverage**
  - [ ] Event sourcing logic tests
  - [ ] UTXO management tests
  - [ ] Transaction building tests
  - [ ] Actor behavior tests
- [ ] **Integration tests**
  - [ ] End-to-end wallet operations
  - [ ] SPV validation tests
  - [ ] Multi-wallet interaction tests
  - [ ] Network failure recovery tests
- [ ] **Performance tests**
  - [ ] Load testing with multiple wallets
  - [ ] Memory usage benchmarks
  - [ ] Transaction throughput tests
  - [ ] Actor system stress tests

### **📚 Documentation**
- [ ] **API documentation**
  - [ ] Complete API reference
  - [ ] Usage examples
  - [ ] Best practices guide
  - [ ] Migration guides
- [ ] **Architecture documentation**
  - [ ] System architecture overview
  - [ ] Event sourcing patterns
  - [ ] Actor system design
  - [ ] Integration guidelines

---

# **🔗 INTEGRATION POINTS**

## **Spiffynode Integration**
- `ChainTipTracker` - Real-time chain state monitoring for SPV validation
- `PeerManager` - Multi-peer P2P connections for network resilience

## **DartSV Integration** ⭐ **PRODUCTION-READY PATTERNS**
- **Money Handling**: `Coin` class for all money values and satoshi arithmetic
- **HD Wallets**: `HDPrivateKey`/`HDPublicKey` for BIP32 key derivation (reference: xpriv_account.dart)
- **Transactions**: `Transaction` class for transaction building and validation
- **Signing**: `TransactionSigner` for Bitcoin SV transaction signing with SIGHASH_FORKID
- **Networks**: `NetworkType` enum for mainnet/testnet distinction
- **Addresses**: `Address` class for address generation and validation
- **Mnemonics**: `Mnemonic` class for BIP39 seed phrase validation

## **Actor System Integration**
- `Dactor` - Concurrent, fault-tolerant wallet operations with supervision
- Event-driven architecture with proper error boundaries

## **Event Store Integration**
- `Eventador` - Event sourcing persistence with projections and snapshots

---

# **📊 SUCCESS METRICS**

## **Technical Metrics**
- [ ] **Performance benchmarks**
  - [ ] < 100ms transaction creation time
  - [ ] < 50ms balance calculation time  
  - [ ] > 1000 transactions/second processing
  - [ ] < 10MB memory per wallet
- [ ] **Reliability metrics**
  - [ ] 99.9% uptime target
  - [ ] < 0.1% transaction failure rate
  - [ ] 100% event sourcing consistency
  - [ ] Zero data loss guarantee

## **Feature Completeness**
- [ ] **Core wallet features**
  - [ ] Address generation and management
  - [ ] UTXO tracking and management
  - [ ] Transaction creation and signing
  - [ ] Balance calculation and reporting
- [ ] **SPV capabilities**
  - [ ] Chain tip tracking
  - [ ] Transaction validation
  - [ ] Merkle proof verification
  - [ ] Confirmation tracking
- [ ] **Production features**
  - [ ] Multi-wallet support
  - [ ] Actor-based scalability
  - [ ] Comprehensive monitoring
  - [ ] Error handling and recovery

---

# **🚨 RISK MITIGATION**

## **Technical Risks**
- [ ] **SpiffyNode integration complexity**
  - [ ] Risk: Complex P2P networking integration
  - [ ] Mitigation: Abstract P2P layer, incremental integration
- [ ] **Event sourcing complexity**
  - [ ] Risk: Complex state management and consistency
  - [ ] Mitigation: Comprehensive testing, simple event design
- [ ] **Actor system complexity**
  - [ ] Risk: Complex concurrent programming
  - [ ] Mitigation: Well-defined actor boundaries, supervision strategies

## **Performance Risks**
- [ ] **Memory usage scaling**
  - [ ] Risk: Memory growth with wallet count
  - [ ] Mitigation: Event history pruning, efficient data structures
- [ ] **Network latency impact**
  - [ ] Risk: Slow ARC/P2P network operations
  - [ ] Mitigation: Async operations, timeout handling, retries

---

# **📝 NOTES**

## **Architecture Decisions**
- **Event Sourcing**: Full audit trail, enables complex business logic replay
- **One Aggregate Per Wallet**: Clear boundaries, isolated failure domains
- **Storage Abstraction**: Testability, deployment flexibility
- **P2P Agnostic**: Future-proofing for different P2P libraries
- **DartSV Foundation**: BSV-specific transaction handling without cruft
- **BEEF/BUMP Integration**: Critical for BSV SPV - enables efficient transaction validation without full blockchain download, integrates with ARC nodes for merkle proofs

## **Production-Ready Components Available**
- **ARC Service** ⭐ Complete implementation in speculative_code/services/arc_service.dart
  - Full HTTP client with error handling, authentication, batch operations
  - All ARC transaction states and status tracking
  - Policy and health endpoint integration
  - Production-tested with proper lifecycle management
- **BEEF Format** ⭐ Complete implementation in speculative_code/utils/beef.dart
  - Full BEEF parsing/serialization with 0100BEEF magic bytes
  - Multi-transaction BEEF support with merkle proof validation
  - Block header integration and validation algorithms
- **BUMP Format** ⭐ Complete implementation in speculative_code/utils/bump.dart
  - Complete merkle path validation and root computation
  - Block height tracking and tree traversal algorithms
  - Production-tested byte order handling and hash computations
- **Secure Storage Service** ⭐ Reference implementation in speculative_code/services/secure_storage_service.dart
  - Complete FlutterSecureStorage wrapper with platform-specific optimizations
  - Wallet private key and mnemonic storage
  - Identity key management and account metadata
  - Production-tested with proper error handling and edge cases
  - **USE AS REFERENCE**: Extract interface and operations for platform-agnostic design
- **HD Wallet Implementation** ⭐ Reference implementation in speculative_code/accounts/xpriv_account.dart
  - Complete BIP32/BIP44 HD wallet with DartSV integration
  - Mnemonic validation and secure key derivation
  - Child key derivation and address generation
  - Account serialization with AES-256-CBC encryption
  - Production-tested validation and error handling
  - **USE AS REFERENCE**: Port patterns for WalletAccount hierarchy
- **Transaction Building & BEEF Integration** ⭐ Reference implementation in speculative_code/protocol/spv_protocol.dart
  - Complete DartSV transaction building patterns with `TransactionBuilder()`
  - UTXO selection and locking mechanisms (`getUtxosForAmount`, `lockUtxosForTransaction`)
  - BEEF creation with merkle proofs for SPV payments
  - Script validation using DartSV's `Interpreter` with proper flags
  - BRC-71 to BUMP conversion utilities
  - BEEF validation against BlockHeaderService
  - **USE AS REFERENCE**: Port transaction building, UTXO management, and BEEF patterns

These implementations significantly reduce Phase 1 development time - focus shifts from "build" to "port and integrate".

## **📤 CURRENT LIBRARY EXPORTS** ✅ **IMPLEMENTED**
```dart
// libspiffy/lib/libspiffy.dart - Current Status
library libspiffy;

// Core Models ✅ COMPLETE
export 'src/models/wallet_event.dart';
export 'src/models/bitcoin_utxo.dart';
export 'src/models/wallet_state.dart';
export 'src/models/bitcoin_transaction.dart';

// Storage Interfaces ✅ COMPLETE
export 'src/storage/wallet_storage.dart';
export 'src/storage/secure_storage.dart';

// Storage Implementations ✅ COMPLETE
export 'src/storage/in_memory_wallet_storage.dart';
export 'src/storage/in_memory_secure_storage.dart';
```

## **Future Considerations**
- **Isar Storage Implementation**: Production persistence layer
- **CryptoPeer Integration**: Advanced P2P networking features  
- **Hardware Wallet Support**: External signing device integration
- **Multi-signature Support**: Complex signature schemes
- **Privacy Features**: CoinJoin, coin mixing, address reuse prevention

---

*This roadmap is a living document and will be updated as implementation progresses and requirements evolve.* 