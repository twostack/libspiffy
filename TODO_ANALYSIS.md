# LibSpiffy TODO and Unimplemented Code Analysis

## Summary
- **Total TODOs Found:** 21
- **Unimplemented Methods:** 5
- **Placeholder Code:** 8

---

## 🔴 HIGH PRIORITY (Affects Core Functionality)

### 1. Command/Event Handler Registration
**File:** `lib/src/core/bitcoin_wallet_aggregate.dart:46`
```dart
// TODO: Register command and event handlers when we implement them
```
**Impact:** HIGH - Currently using direct `handleCommand()` override, but proper handler registry is not populated  
**Recommendation:** Either implement handler registration OR remove the TODO if current pattern is intentional  
**Status:** Works currently but violates framework pattern

### 2. Transaction Fee Calculation
**File:** `lib/src/actors/wallet_manager_actor.dart:262`
```dart
fee: BigInt.zero, // TODO: Get actual fee from transaction
```
**Impact:** HIGH - Incorrect fee reporting to wallet  
**Recommendation:** Parse transaction to extract actual fee  
**Status:** Bug - reports zero fees

### 3. HODL Unlock Builder
**File:** `lib/src/services/transaction/builder/hodl_unlockbuilder.dart:28`
```dart
throw UnimplementedError();
```
**Impact:** HIGH - Will crash if HODL transactions are used  
**Recommendation:** Implement HODL unlock logic or remove if not needed  
**Status:** Unimplemented - will throw exception

---

## 🟡 MEDIUM PRIORITY (Affects Specific Features)

### 4. SPV Actor - Multi-sig Recognition
**File:** `lib/src/actors/spv_actor.dart:347`
```dart
// TODO: Implement multi-sig UTXO recognition
```
**Impact:** MEDIUM - Multi-sig UTXOs won't be recognized  
**Recommendation:** Implement P2SH/multi-sig script parsing  
**Status:** Single-sig only

### 5. SPV Actor - Wallet Key Management Integration
**File:** `lib/src/actors/spv_actor.dart:379`
```dart
/// TODO: This needs integration with wallet key management
```
**Impact:** MEDIUM - Cannot verify transaction outputs belong to wallet  
**Recommendation:** Query wallet for address ownership  
**Status:** Placeholder - accepts all outputs

### 6. SPV Actor - Previous Transaction Retrieval
**File:** `lib/src/actors/spv_actor.dart:407`
```dart
// TODO: Retrieve the previous transaction to analyze the spent output
```
**Impact:** MEDIUM - Cannot fully validate spending transactions  
**Recommendation:** Implement transaction lookup from storage/Arc  
**Status:** Incomplete validation

### 7. SPV Actor - UTXO Storage Integration
**File:** `lib/src/actors/spv_actor.dart:440`
```dart
/// TODO: This needs integration with UTXO storage and wallet management
```
**Impact:** MEDIUM - UTXOs extracted from BEEF not persisted properly  
**Recommendation:** Store UTXOs in wallet storage  
**Status:** Data loss risk

### 8. Transaction Builder Parsers (Multiple)
**Files:**
- `lib/src/services/transaction/builder/pp2_lock_builder.dart:34`
- `lib/src/services/transaction/builder/pp2_unlock_builder.dart:22`
- `lib/src/services/transaction/builder/pp1_lock_builder.dart:52`
- `lib/src/services/transaction/builder/partial_witness_unlock_builder.dart:32`
- `lib/src/services/transaction/builder/hodl_lockbuilder.dart:27`

**Impact:** MEDIUM - Cannot parse these script types  
**Recommendation:** Implement if these protocols are used, otherwise document as unsupported  
**Status:** Read-only not supported

---

## 🟢 LOW PRIORITY (Minor Issues / Future Enhancements)

### 9. Placeholder Merkle Root
**File:** `lib/src/actors/spv_actor.dart:561`
```dart
merkleRoot: 'placeholder_merkle_root', // TODO: Extract actual merkle root
```
**Impact:** LOW - Testing/debugging only  
**Recommendation:** Extract from BEEF data  
**Status:** Cosmetic issue

### 10. BEEF Counterparty Tracking
**File:** `lib/src/actors/spv_actor.dart:576`
```dart
fromCounterparty: 'beef_bundle', // TODO: Update to actual peer ID
```
**Impact:** LOW - Audit/debugging only  
**Recommendation:** Track actual peer ID  
**Status:** Cosmetic issue

### 11. Header Sync Status Tracking
**Files:**
- `lib/src/actors/header_sync_actor.dart:84` - merkleProofsStored
- `lib/src/actors/header_sync_actor.dart:86` - connectedPeers
- `lib/src/actors/header_sync_actor.dart:253` (duplicates)

**Impact:** LOW - Status reporting only  
**Recommendation:** Integrate with storage/SpiffyNode  
**Status:** Cosmetic - status incomplete

### 12. Header Queuing for Early Messages
**File:** `lib/src/actors/header_sync_actor.dart:97`
```dart
// TODO: Implement header queuing for early messages
```
**Impact:** LOW - Edge case handling  
**Recommendation:** Queue messages arriving before initialization  
**Status:** May drop early messages

### 13. Placeholder Transaction Creation
**File:** `lib/src/core/bitcoin_wallet_aggregate.dart:551`
```dart
// For now, create a placeholder transaction hex
```
**Impact:** LOW - Testing code  
**Recommendation:** Use proper transaction builder  
**Status:** Works for testing

### 14. Placeholder Broadcast Response
**File:** `lib/src/core/bitcoin_wallet_aggregate.dart:615`
```dart
broadcastResponse: 'broadcast_success', // Placeholder - will be set by ARC service
```
**Impact:** LOW - Overwritten by Arc  
**Recommendation:** Remove placeholder  
**Status:** Cosmetic

### 15. BUMP Placeholder Returns
**Files:**
- `lib/src/services/spv_service.dart:453`
- `lib/src/services/spv_service.dart:460`

```dart
return BUMP.fromBytes(Uint8List(0)); // Placeholder
```
**Impact:** LOW - If BUMP not used  
**Recommendation:** Implement if BUMP protocol needed  
**Status:** Returns empty BUMP

---

## 📋 PHASE 1D ITEMS (Deferred Features)

### 16. Logging Infrastructure
**File:** `lib/src/core/bitcoin_wallet_aggregate.dart:473`
```dart
// TODO: Add proper logging in Phase 1D
```
**Recommendation:** Implement structured logging with log levels

### 17. Reservation Tracking
**Files:**
- `lib/src/core/bitcoin_wallet_aggregate.dart:662`
- `lib/src/core/bitcoin_wallet_aggregate.dart:956`
- `lib/src/core/bitcoin_wallet_aggregate.dart:964`
- `lib/src/core/bitcoin_wallet_aggregate.dart:972`

```dart
// TODO: In Phase 1D, implement proper reservation tracking
```
**Impact:** MEDIUM - UTXO reservation may not expire properly  
**Recommendation:** Implement reservation expiry and cleanup  
**Status:** Basic version works, advanced features missing

---

## 🔍 EXPECTED RETURNS (Not Bugs)

### Arc Service Merkle Proof Returns
**File:** `lib/src/services/arc_service.dart:419, 422`
```dart
return null; // Proof not available yet
```
**Status:** CORRECT - Merkle proofs may not be available immediately after broadcast

---

## Priority Action Items

### Immediate (Before Production)
1. ✅ Fix transaction fee calculation (wallet_manager_actor.dart:262)
2. ✅ Implement or remove HODL unlock builder
3. ✅ Integrate SPV wallet key management (verify outputs belong to wallet)
4. ✅ Implement UTXO storage integration in SPVActor

### Short Term (Next Sprint)
5. Implement multi-sig UTXO recognition
6. Implement previous transaction retrieval for validation
7. Add structured logging
8. Implement UTXO reservation expiry tracking

### Long Term (Future Features)
9. Implement protocol-specific builders (PP1, PP2, Partial Witness, HODL)
10. Add header message queuing
11. Implement BUMP protocol support
12. Add merkle proof tracking from BEEF

### Can Be Removed (If Not Needed)
- Protocol builders that aren't used
- BUMP support if not needed
- Multi-sig if only P2PKH supported

---

## Recommendations by Category

### Critical Path to Production
1. Fix fee calculation bug
2. Implement SPV-wallet integration
3. Handle unimplemented protocol builders (implement or remove)
4. Add proper UTXO storage

### Code Quality
1. Decide on handler registration pattern
2. Remove or implement placeholder code
3. Add comprehensive logging
4. Document unsupported features

### Future Enhancements
1. Multi-sig support
2. Advanced protocols (HODL, PP1/PP2)
3. BUMP protocol
4. Merkle proof tracking

---

## Testing Recommendations

Each TODO should have:
1. **Test that exercises the code path**
2. **Expected behavior documented**
3. **Decision**: Implement, remove, or defer

### Tests Needed
- [ ] Transaction fee extraction test
- [ ] Multi-sig UTXO recognition test
- [ ] Wallet ownership verification test
- [ ] UTXO persistence test
- [ ] HODL transaction test (or removal)
- [ ] Reservation expiry test

---

## Next Steps

1. **Review with team** - Determine which features are actually needed
2. **Create tickets** - One ticket per TODO with acceptance criteria
3. **Prioritize** - Based on user needs and production readiness
4. **Test coverage** - Add tests before implementing TODOs
5. **Documentation** - Document intentional limitations

**Estimated Effort:**
- Critical fixes: 2-3 days
- Medium priority: 1-2 weeks
- Low priority: 2-4 weeks
- All protocol builders: 3-4 weeks

