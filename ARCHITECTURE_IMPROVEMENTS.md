# LibSpiffy Architecture Improvements

## Issues Resolved

### 1. ✅ Root Address Placeholder Issue
**Problem:** WalletManagerActor returned placeholder address `'placeholder_${walletId}'` instead of actual root address.

**Solution:** Implemented proper command-response pattern:
- `BitcoinWalletAggregate.onCommandProcessed()` sends `WalletCreatedResponse` with real root address from `WalletCreatedEvent`
- `WalletManagerActor` tracks pending requests and routes responses back to original callers
- Root address now comes from actual HD wallet derivation (m/44'/0'/0'/0/0)

### 2. ✅ Fee Estimation
**Problem:** Hardcoded 500 sat/KB fee rate.

**Solution:** 
- Updated to use 1 sat/KB default (current network standard)
- Added Arc policy query to get dynamic fee rates
- Falls back to default if Arc unavailable

### 3. ✅ Reorg Handling Documentation
**Problem:** SPVActor had TODO placeholder for reorg handling.

**Solution:** 
- Documented that full reorg implementation exists in service layer
- SPVService, WalletBalanceService, BlockHeaderService handle actual reorg work
- SPVActor coordinates at actor layer

### 4. ✅ EventStore Anti-Pattern
**Problem:** WalletManagerActor was querying EventStore directly, violating event sourcing separation.

**Solution:**
- Removed all EventStore queries from actor layer
- Actors now use command-response pattern only
- EventStore accessed only by:
  - Framework (Eventador) for persistence
  - Projection actors for read models
  - Never by command/coordination actors

### 5. ✅ Error Handling
**Added:** `BitcoinWalletAggregate.onCommandFailure()` override
- Sends error responses for failed commands
- Callers always receive feedback (success or failure)
- Errors properly propagated through actor hierarchy

### 6. ✅ Extended Response Messages
**Added responses for:**
- `WalletCreatedResponse` (with real root address)
- `AddressGeneratedResponse` 
- `TransactionCreatedResponse`

**Pattern:** All responses include:
- Relevant data from events
- Success/failure flag
- Error message (if failed)

### 7. ✅ Code Cleanup
- Removed unused `_spvActor` and `_arcActor` fields
- Added documentation about actor coordination
- No linter warnings

## Event Sourcing Architecture (Now Correct)

### Command Flow
```
User/Client
   ↓ CreateWalletMessage
WalletManagerActor (coordinator)
   ├─ Tracks original sender
   ↓ CreateWalletCommand
BitcoinWalletAggregate (domain logic)
   ├─ Validates business rules
   ├─ Emits WalletCreatedEvent
   ├─ Framework persists event
   ├─ Applies event to state
   ├─ onCommandProcessed() → WalletCreatedResponse
   ↓ 
WalletManagerActor
   ├─ Routes response to original sender
   ↓ WalletCreatedMessage (with real root address)
User/Client
```

### Error Flow
```
User/Client
   ↓ Command
WalletManagerActor
   ↓ Forward command
BitcoinWalletAggregate
   ├─ Validates business rule
   ├─ Throws error (e.g., "Wallet doesn't exist")
   ├─ onCommandFailure() → ErrorResponse
   ↓
WalletManagerActor
   ├─ Routes error to original sender
   ↓ Error message
User/Client
```

### Key Principles

1. **No EventStore queries in actors** - Framework handles persistence
2. **Command-response pattern** - Aggregates send responses via lifecycle hooks
3. **Events carry state** - Response data comes from events, not queries
4. **Business rules in aggregates** - Domain logic stays in aggregate layer
5. **Actors coordinate** - Routing and orchestration only

## Testing Recommendations

1. **Integration test:** Verify real root address is returned
2. **Error handling test:** Send command to non-existent wallet
3. **Concurrency test:** Multiple wallet creations simultaneously
4. **Reorg test:** Verify SPVService handles chain reorganization
5. **Fee estimation test:** Verify Arc policy integration

## Future Improvements

1. **Wallet Registry Projection**
   - Subscribe to `WalletCreatedEvent`
   - Maintain read model of existing wallets
   - Query before operations

2. **Add more response types**
   - UTXO operations
   - Transaction signing/broadcasting
   - Reservation management

3. **Implement timeout handling**
   - What if aggregate never responds?
   - Add timeout cleanup for pending requests

4. **Add correlation IDs**
   - Better request/response tracking
   - Improved observability

## Files Modified

- `lib/src/actors/wallet_manager_actor.dart` - Command-response pattern
- `lib/src/core/bitcoin_wallet_aggregate.dart` - Response hooks
- `lib/src/actors/wallet_messages.dart` - Response message types
- `lib/src/actors/arc_actor.dart` - Fee estimation
- `lib/src/actors/spv_actor.dart` - Reorg documentation

## Migration Notes

**Breaking Changes:**
- None - all changes are internal improvements

**Behavior Changes:**
- `WalletCreatedMessage` now contains real root address instead of placeholder
- Commands to non-existent wallets now receive proper error responses
- Fee estimation uses 1 sat/KB instead of 500 sat/KB

**Performance:**
- Slightly improved - removed unnecessary EventStore queries
- No blocking waits for event persistence

