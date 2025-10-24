# Issue: Transaction Address Information Not Persisted to Read Models

**Status:** Bug  
**Priority:** High  
**Component:** Storage Layer / Projections  
**Created:** 2025-10-24

---

## Summary

Transaction receiving and sending addresses are correctly extracted from wallet events and passed through the `WalletProjection`, but they are **not persisted** to the `BitcoinTransactionEntity` Isar schema. This causes address information to be lost when querying transaction history, making it impossible to display "From:" or "To:" addresses in the UI.

---

## Data Flow Analysis

### ✅ What's Working

1. **Event Level** - Events contain address information:
   - `TransactionImportedEvent` has:
     - `walletReceivingAddresses: List<String>`
     - `sendingAddresses: List<String>`
   - `TransactionCreatedEvent` has:
     - `receivingAddresses: List<String>`
     - `sendingAddresses: List<String>`

2. **Projection Level** - Addresses are correctly extracted:
   ```dart
   // wallet_projection.dart lines 353-354
   receivingAddresses: event.walletReceivingAddresses,
   sendingAddresses: event.sendingAddresses,
   
   // wallet_projection.dart lines 411-412
   receivingAddresses: event.receivingAddresses,
   sendingAddresses: event.sendingAddresses,
   ```

3. **Domain Model** - `BitcoinTransaction` includes addresses:
   ```dart
   final List<String> receivingAddresses;
   final List<String> sendingAddresses;
   ```

### ❌ What's Broken

**Storage Layer** - Addresses are NOT persisted to Isar:

```dart
// isar_wallet_storage.dart lines 330-349
final entity = BitcoinTransactionEntity()
  ..walletId = walletId
  ..txid = transaction.txid
  ..rawHex = transaction.rawHex
  // ... other fields ...
  ..status = transaction.status.name
  ..createdAt = transaction.createdAt;
  // ❌ receivingAddresses NOT copied
  // ❌ sendingAddresses NOT copied
  // ❌ memo NOT copied

await _isar.bitcoinTransactionEntitys.put(entity);
```

**Schema** - No fields to store address lists:

```dart
// libspiffy_schemas.dart lines 284-344
@collection
class BitcoinTransactionEntity {
  // ... existing fields ...
  String? counterparty;  // ❌ Only single optional address
  String? notes;         // ❌ Not populated
  
  // ❌ MISSING:
  // String receivingAddressesJson;
  // String sendingAddressesJson;
}
```

The schema has a TODO comment acknowledging this:
```dart
// Line 382-383 in toDomain() method:
receivingAddresses: [], // Would need to store these separately
sendingAddresses: [], // Would need to store these separately
```

---

## Impact

### User Experience Issues

1. **Transaction History Display**: Cannot show "From: 1A1zP1..." or "To: 3J98t1..." in transaction lists
2. **Transaction Detail Screens**: Missing counterparty information for transaction details
3. **Contact/Address Book**: Cannot build automatic contact lists from transaction history
4. **Transaction Search**: Cannot filter or search by sending/receiving address
5. **Audit/Compliance**: Missing critical information for transaction tracking

### Current Workarounds

- Display truncated `txid` instead of addresses
- Use `counterparty` field (but it's optional and not populated)
- Show generic "Received" / "Sent" without address details

---

## Proposed Solution

### 1. Update BitcoinTransactionEntity Schema

**File:** `lib/src/storage/libspiffy_schemas.dart`

Add fields to store address lists (around line 342):

```dart
@collection
class BitcoinTransactionEntity {
  // ... existing fields ...
  
  /// Receiving addresses (stored as JSON array string)
  late String receivingAddressesJson;
  
  /// Sending addresses (stored as JSON array string)
  late String sendingAddressesJson;
  
  /// Counterparty address (primary address for display)
  String? counterparty;
  
  /// Notes or metadata about this transaction
  String? notes;
  
  // ... rest of fields ...
}
```

Update `fromDomain()` factory (around line 347):

```dart
factory BitcoinTransactionEntity.fromDomain(BitcoinTransaction tx) {
  final netAmount = tx.netAmount;
  
  return BitcoinTransactionEntity()
    // ... existing assignments ...
    ..receivingAddressesJson = jsonEncode(tx.receivingAddresses)
    ..sendingAddressesJson = jsonEncode(tx.sendingAddresses)
    ..counterparty = netAmount > BigInt.zero
        ? (tx.sendingAddresses.isNotEmpty ? tx.sendingAddresses.first : null)
        : (tx.receivingAddresses.isNotEmpty ? tx.receivingAddresses.first : null)
    ..notes = tx.memo;
}
```

Update `toDomain()` method (around line 372):

```dart
BitcoinTransaction toDomain() {
  final receiving = receivingAddressesJson.isNotEmpty 
      ? (jsonDecode(receivingAddressesJson) as List).cast<String>()
      : <String>[];
  final sending = sendingAddressesJson.isNotEmpty
      ? (jsonDecode(sendingAddressesJson) as List).cast<String>()
      : <String>[];
  
  return BitcoinTransaction(
    // ... existing fields ...
    receivingAddresses: receiving,
    sendingAddresses: sending,
    memo: notes,
    // ... rest of fields ...
  );
}
```

### 2. Update IsarWalletStorage.storeTransaction()

**File:** `lib/src/storage/isar_wallet_storage.dart`

Update the insert section (around line 330-349):

```dart
// Insert new transaction
final entity = BitcoinTransactionEntity()
  ..walletId = walletId
  ..txid = transaction.txid
  ..rawHex = transaction.rawHex
  ..blockHeight = transaction.blockHeight
  ..blockHash = null
  ..confirmations = transaction.confirmations ?? 0
  ..totalInput = transaction.inputValue.toString()
  ..totalOutput = transaction.outputValue.toString()
  ..fee = transaction.fee.toString()
  ..isIncoming = transaction.netAmount > BigInt.zero
  ..isOutgoing = transaction.netAmount < BigInt.zero
  ..status = transaction.status.name
  ..createdAt = transaction.createdAt
  ..confirmedAt = (transaction.blockHeight != null && transaction.blockHeight! > 0) 
      ? transaction.updatedAt 
      : null
  ..broadcastAt = null
  // NEW: Persist addresses
  ..receivingAddressesJson = jsonEncode(transaction.receivingAddresses)
  ..sendingAddressesJson = jsonEncode(transaction.sendingAddresses)
  ..counterparty = transaction.netAmount > BigInt.zero
      ? (transaction.sendingAddresses.isNotEmpty ? transaction.sendingAddresses.first : null)
      : (transaction.receivingAddresses.isNotEmpty ? transaction.receivingAddresses.first : null)
  ..notes = transaction.memo;

await _isar.bitcoinTransactionEntitys.put(entity);
```

Update the update section (around line 312-327) similarly:

```dart
if (existing != null) {
  existing
    ..rawHex = transaction.rawHex
    ..status = transaction.status.name
    ..blockHeight = transaction.blockHeight
    ..confirmations = transaction.confirmations ?? 0
    ..totalInput = transaction.inputValue.toString()
    ..totalOutput = transaction.outputValue.toString()
    ..fee = transaction.fee.toString()
    // NEW: Update addresses if transaction details changed
    ..receivingAddressesJson = jsonEncode(transaction.receivingAddresses)
    ..sendingAddressesJson = jsonEncode(transaction.sendingAddresses)
    ..notes = transaction.memo;
  
  // ... rest of update logic ...
}
```

### 3. Add dart:convert Import

**File:** `lib/src/storage/libspiffy_schemas.dart`

Add at the top:
```dart
import 'dart:convert';
```

---

## Additional Missing APIs for Transaction History

While fixing the address persistence issue, consider adding these APIs to improve transaction history support:

### 1. Get All Transactions (Unlimited)

**File:** `lib/src/storage/read_model_storage.dart`

Add interface method:
```dart
/// Get all transactions for a wallet
Future<List<BitcoinTransaction>> getAllTransactions(
  String walletId, {
  bool? isIncoming,
  bool? isOutgoing,
  int? limit,
  int? offset,
});
```

**File:** `lib/src/storage/isar_wallet_storage.dart`

Implement:
```dart
@override
Future<List<BitcoinTransaction>> getAllTransactions(
  String walletId, {
  bool? isIncoming,
  bool? isOutgoing,
  int? limit,
  int? offset,
}) async {
  var query = _isar.bitcoinTransactionEntitys
      .filter()
      .walletIdEqualTo(walletId);
  
  if (isIncoming != null) {
    query = query.isIncomingEqualTo(isIncoming);
  }
  if (isOutgoing != null) {
    query = query.isOutgoingEqualTo(isOutgoing);
  }
  
  var orderedQuery = query.sortByCreatedAtDesc();
  
  if (offset != null) {
    orderedQuery = orderedQuery.offset(offset);
  }
  if (limit != null) {
    orderedQuery = orderedQuery.limit(limit);
  }
  
  final entities = await orderedQuery.findAll();
  return entities.map((e) => e.toDomain()).toList();
}
```

### 2. Transaction Count Query

```dart
Future<int> getTransactionCount(
  String walletId, {
  bool? isIncoming,
  bool? isOutgoing,
}) async {
  var query = _isar.bitcoinTransactionEntitys
      .filter()
      .walletIdEqualTo(walletId);
  
  if (isIncoming != null) {
    query = query.isIncomingEqualTo(isIncoming);
  }
  if (isOutgoing != null) {
    query = query.isOutgoingEqualTo(isOutgoing);
  }
  
  return await query.count();
}
```

### 3. Get Transaction by ID

```dart
Future<BitcoinTransaction?> getTransaction(String txid) async {
  final entity = await _isar.bitcoinTransactionEntitys
      .filter()
      .txidEqualTo(txid)
      .findFirst();
  
  return entity?.toDomain();
}
```

---

## Testing Requirements

After implementing these changes:

1. ✅ **Schema Generation**: Run `dart run build_runner build` to regenerate Isar schemas
2. ✅ **Migration Test**: Verify existing transactions migrate gracefully (new fields should be empty strings)
3. ✅ **Import Test**: Import a wallet and verify:
   - Addresses are populated in `BitcoinTransactionEntity`
   - `receivingAddressesJson` contains valid JSON array
   - `sendingAddressesJson` contains valid JSON array
   - `counterparty` field is set to primary address
4. ✅ **Query Test**: Retrieve transactions and verify:
   - `toDomain()` correctly deserializes address lists
   - UI can display "From: [address]" and "To: [address]"
5. ✅ **Send Test**: Create a transaction and verify addresses are persisted
6. ✅ **Update Test**: Update a transaction status and verify addresses remain intact

---

## Migration Considerations

### Backward Compatibility

- New fields should have default values (empty strings for JSON fields)
- Existing transactions without address data will have empty address lists
- The `counterparty` field (already optional) remains optional

### Data Migration Script (Optional)

For existing installations, consider providing a migration that:
1. Replays transaction events to populate address fields
2. Or accepts empty address lists for historical transactions

---

## Related Issues

- Transaction detail screen needs address information (#TBD)
- Contact/address book feature depends on transaction address history (#TBD)
- Transaction search/filter by address (#TBD)

---

## References

- **Events with Addresses**: `lib/src/core/wallet_events.dart`
  - Lines 320-340: `TransactionImportedEvent`
  - Lines 367-387: `TransactionCreatedEvent`
- **Projection Logic**: `lib/src/projections/wallet_projection.dart`
  - Lines 313-371: `_handleTransactionImported()`
  - Lines 373-429: `_handleTransactionCreated()`
- **Domain Model**: `lib/src/models/bitcoin_transaction.dart`
  - Lines 86-90: Address fields definition
- **Current Schema**: `lib/src/storage/libspiffy_schemas.dart`
  - Lines 284-344: `BitcoinTransactionEntity`
- **Storage Implementation**: `lib/src/storage/isar_wallet_storage.dart`
  - Lines 304-352: `storeTransaction()` method

---

## Priority Justification

**High Priority** because:
1. Transaction history is a core wallet feature
2. Addresses are already available in events but being discarded
3. Fix is straightforward (schema + storage updates)
4. Blocks implementation of transaction detail screens
5. Required for user-facing features in consuming applications

---

## Estimated Effort

- Schema updates: 30 minutes
- Storage implementation: 1 hour
- Testing: 1 hour
- **Total: ~2.5 hours**

---

## Owner

Assign to: LibSpiffy Core Team

## Labels

`bug`, `storage`, `projections`, `transaction-history`, `high-priority`

