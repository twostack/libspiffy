# SPV Understanding - LibSpiffy Implementation Guide

## Overview

This document outlines the correct understanding of **Simplified Payment Verification (SPV)** as described in Section 8 of the Bitcoin whitepaper and specifically how it applies to Bitcoin SV.

## Fundamental SPV Concepts

### What SPV Actually Is

SPV allows transaction recipients to **prove that the sender has control of source funds** without downloading the entire blockchain, by utilizing Merkle proofs. It does **NOT** guarantee funds haven't been previously spent - that assurance comes from submitting the transaction to Bitcoin miners.

### Key Data Requirements

Based on the [BSV Wiki on SPV](https://wiki.bitcoinsv.io/index.php/Simplified_Payment_Verification):

- **Block Headers Only**: ~50MB covers entire blockchain (80 bytes × ~620,000 blocks as of 2020)
- **Linear Growth**: ~4MB per year (80 bytes per block regardless of block size)
- **Merkle Paths**: Maximum 64×log₂(n) bytes where n = transactions in block
- **No Full Blocks**: Never need to download or store complete blocks

## The Real SPV Transaction Flow

### 1. Peer-to-Peer Transaction Negotiation

**Key Insight**: Transactions are **negotiated peer-to-peer** and **settled on the ledger** through network nodes.

**Analogy**: Like receiving a cheque - the customer hands you the signed cheque (transaction), you then bank/cash it (settle on-chain).

### 2. What the Receiver Gets

When receiving a transaction, the sender provides:

1. **Transaction₀** - the transaction containing the UTXO as output
2. **Merkle Path** of Transaction₀  
3. **Block Header** containing the Merkle root (or block identifier)
4. **Transaction₁** - the new transaction spending the UTXO

### 3. SPV Validation Process

The receiver validates by:

1. **Computing Merkle Root** from the Merkle path of Transaction₀
2. **Comparing** with Merkle root in the block header
3. **If match**: Accept that Transaction₀ is in the chain
4. **Validate** Transaction₁ can legitimately spend from Transaction₀

### 4. Broadcasting & Settlement

- **Primary**: Broadcast via **ARC Service**
- **Backup**: SpiffyNode for transaction broadcast  
- **Monitor**: Poll ARC for transaction lifecycle (pending → confirmed)
- **Proof Retrieval**: Get merkle proof from ARC once transaction is mined

## LibSpiffy Implementation Requirements

### Core Data Management

LibSpiffy must maintain:

1. **Full Transaction History**
   - All transactions ever received/sent by the wallet
   - Complete transaction data (not just references)
   - Transaction metadata and status

2. **Complete UTXO Management**  
   - Track all UTXOs (available, reserved, spent)
   - UTXO genealogy and spending history
   - Confirmation status and block heights

3. **Merkle Proof Storage**
   - **Every UTXO must have its merkle proof**
   - Proofs for both incoming and outgoing UTXOs
   - Proof validation against block header chain

4. **Block Header Chain**
   - Full chain of block headers (~50MB)
   - Kept in sync via SpiffyNode integration
   - Used for merkle proof validation

## Architecture Implications

### SPVActor Responsibilities

**✅ Correct Responsibilities:**
- Block header synchronization (via SpiffyNode)
- Merkle proof validation for received transactions
- BEEF/BUMP proof validation
- Transaction broadcasting coordination

**❌ Incorrect Assumptions (Previous):**
- ~~Address monitoring~~ - Transactions come directly from counterparties
- ~~Block scanning~~ - We don't scan blocks for transactions
- ~~Transaction discovery~~ - Transactions are handed to us

### Transaction Receipt Flow

```
1. Counterparty sends transaction + proofs → SPVActor
2. SPVActor validates merkle proofs against block headers
3. SPVActor sends ValidatedTransactionMessage → WalletManagerActor  
4. WalletManagerActor routes to appropriate wallet aggregate
5. Wallet aggregate processes UTXO updates and events
```

This understanding fundamentally changes the SPVActor implementation from a "scanning" model to a "validation" model, which is the correct SPV approach.

## Storage Requirements for LibSpiffy

### Enhanced UTXO Storage

Each `BitcoinUtxo` must be enhanced to include SPV-specific data:

```dart
class BitcoinUtxo {
  // Existing core fields...
  final String txid;
  final int vout;
  final BigInt satoshis;
  final String scriptPubKey;
  final String? address;
  
  // SPV Requirements - CRITICAL
  final MerkleProof? merkleProof;      // Proof of inclusion in block
  final int? blockHeight;              // Block containing this UTXO
  final String? blockHash;             // Block hash for verification
  final Transaction sourceTransaction; // Complete source transaction
  
  // Validation status
  final bool spvValidated;             // Has merkle proof been validated
  final DateTime? proofRetrievedAt;    // When proof was obtained
  final String? proofSource;           // 'arc' | 'counterparty' | 'restored'
}
```

### Transaction History Database

LibSpiffy must maintain comprehensive transaction history:

```dart
class WalletTransactionHistory {
  // Complete transaction storage
  final Map<String, Transaction> allTransactions;
  
  // Merkle proof storage - EVERY transaction needs its proof
  final Map<String, MerkleProof> transactionProofs;
  
  // Transaction lifecycle tracking
  final Map<String, TransactionStatus> transactionStatus;
  final Map<String, DateTime> broadcastTimes;
  final Map<String, DateTime> confirmationTimes;
  
  // Counterparty information
  final Map<String, String> transactionCounterparties;
  
  // Block inclusion data
  final Map<String, int> transactionBlockHeights;
  final Map<String, String> transactionBlockHashes;
}
```

### Block Header Chain Storage

Similar to SpiffyNode's approach, LibSpiffy needs:

```dart
class BlockHeaderChain {
  // Complete chain of block headers (~50MB total, grows ~4MB/year)
  final Map<int, BlockHeader> headersByHeight;
  final Map<String, BlockHeader> headersByHash;
  
  // Chain tip tracking
  final BlockHeader currentTip;
  final int currentHeight;
  
  // Reorganization handling
  final List<BlockHeader> reorgBuffer;
}
```

## New Message Types for Correct SPV

### Direct Transaction Receipt

```dart
/// Receive transaction directly from counterparty with proofs
class ReceiveTransactionMessage implements Message {
  final Transaction transaction;
  final List<MerkleProof> inputProofs;  // Proofs for all input UTXOs
  final String fromCounterparty;
  final DateTime receivedAt;
}

/// SPV validation result  
class SPVValidationResult implements Message {
  final String txid;
  final bool isValid;
  final String? validationError;
  final List<UTXO> spendableUTXOs;     // UTXOs we can now spend
  final List<UTXO> spentUTXOs;         // UTXOs that were spent
}
```

### Block Header Synchronization

```dart
/// Block header update from SpiffyNode
class BlockHeaderUpdateMessage implements Message {
  final BlockHeader newHeader;
  final int height;
  final bool isReorganization;
  final List<BlockHeader>? orphanedHeaders; // If reorg
}

/// Request merkle proof retrieval from ARC
class RetrieveMerkleProofMessage implements Message {
  final String txid;
  final int? knownBlockHeight;
  final String walletId;
}
```

## Revised Actor Responsibilities

### SPVActor (Corrected)

**Primary Functions:**
1. **Block Header Sync**: Maintain full header chain via SpiffyNode
2. **Transaction Validation**: Validate received transactions using merkle proofs
3. **BEEF/BUMP Processing**: Handle enhanced transaction formats
4. **Proof Management**: Coordinate merkle proof retrieval from ARC

**Key Methods:**
```dart
class SPVActor extends Actor {
  // Block header management
  Future<void> _handleBlockHeaderUpdate(BlockHeaderUpdateMessage msg);
  Future<void> _handleReorganization(List<BlockHeader> orphanedHeaders);
  
  // Transaction validation (NOT discovery)
  Future<void> _handleReceivedTransaction(ReceiveTransactionMessage msg);
  Future<SPVValidationResult> _validateTransaction(Transaction tx, List<MerkleProof> proofs);
  
  // Proof validation
  Future<bool> _validateMerkleProof(MerkleProof proof, String txid, BlockHeader header);
  Future<void> _requestMerkleProofFromARC(String txid, int blockHeight);
}
```

### WalletManagerActor (Enhanced)

Must coordinate SPV validation with business logic:

```dart
class WalletManagerActor extends Actor {
  // Handle SPV validation results
  Future<void> _handleSPVValidationResult(SPVValidationResult result);
  
  // Route validated transactions to appropriate wallet
  Future<void> _routeValidatedTransaction(String walletId, SPVValidationResult result);
  
  // Coordinate proof retrieval for wallet transactions
  Future<void> _ensureTransactionHasProof(String walletId, String txid);
}
```

### ARCActor (Enhanced)

Extended to handle merkle proof retrieval:

```dart
class ARCActor extends Actor {
  // Existing broadcast functionality...
  
  // New: Merkle proof retrieval
  Future<void> _handleRetrieveMerkleProof(RetrieveMerkleProofMessage msg);
  Future<MerkleProof?> _getMerkleProofFromARC(String txid);
  
  // Enhanced status monitoring with proof retrieval
  Future<void> _checkTransactionAndRetrieveProof(String txid);
}
```

## Critical Implementation Notes

### 1. Every UTXO Needs Its Proof

This is **non-negotiable** for SPV wallets:
- Cannot spend UTXOs without proving their existence
- Must validate the entire chain of UTXOs back to coinbase
- Proofs must be stored permanently with each UTXO

### 2. No Address Monitoring

The fundamental paradigm shift:
- ❌ Don't monitor addresses on the network
- ❌ Don't scan blocks for transactions  
- ✅ Receive transactions directly from counterparties
- ✅ Validate received transactions using proofs

### 3. Full Transaction History Required

Unlike traditional SPV descriptions, LibSpiffy needs complete history:
- Store every transaction ever processed
- Maintain merkle proofs for all transactions
- Enable spending from any historical UTXO
- Support wallet restoration from transaction history

### 4. Offline Capability

As noted in the BSV Wiki:
> "By storing Transaction₀ locally, a user will be able to sign Transaction₁ offline"

LibSpiffy must enable:
- Offline transaction creation
- Offline transaction signing  
- Online transaction validation and broadcasting

This document represents the corrected understanding of SPV and serves as the implementation guide for refactoring the current LibSpiffy actors to work correctly with the SPV model. 