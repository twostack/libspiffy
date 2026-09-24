# Multi-Output Invoice Guide

This guide explains how to use the multi-output invoice feature in LibSpiffy for SPV payments. This feature enables invoices to request payment to multiple distinct UTXOs with mixed output types (P2PKH and P2MS multisig).

## Overview

Traditional invoices specify a single payment address and amount. Multi-output invoices extend this by allowing:

- **Multiple P2PKH outputs**: Split payments across multiple addresses
- **P2MS (multisig) outputs**: Require m-of-n signatures to spend
- **Mixed outputs**: Combine P2PKH and P2MS in a single invoice

Common use cases include:
- Marketplace payments with escrow portions
- Split payments (merchant + platform fee + escrow)
- Multi-party transactions requiring multiple signatures

## InvoiceOutputSpec Model

The `InvoiceOutputSpec` is a sealed class hierarchy that defines output specifications:

```dart
import 'package:libspiffy/src/models/invoice_output_spec.dart';

// Base sealed class
sealed class InvoiceOutputSpec {
  final BigInt amount;      // Amount in satoshis
  final String? label;      // Human-readable label (optional)
  BitcoinScriptType get scriptType;
}

// P2PKH output (standard address-based)
class P2PKHOutputSpec extends InvoiceOutputSpec {
  final String address;     // Bitcoin address (base58)
}

// P2MS output (multisig)
class P2MSOutputSpec extends InvoiceOutputSpec {
  final List<String> publicKeys;  // Hex-encoded compressed public keys
  final int threshold;            // Required signatures (m in m-of-n)
  int get totalKeys;              // Total keys (n in m-of-n)
  bool get isValid;               // Validates threshold and key format
}
```

## Creating Multi-Output Invoices

### Multiple P2PKH Outputs

Split a payment across multiple addresses:

```dart
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';

final message = CreateInvoiceMessage(
  walletId: 'merchant-wallet',
  outputs: [
    P2PKHOutputSpec(
      address: 'mMerchantAddress123',
      amount: BigInt.from(80000),  // 80,000 satoshis
      label: 'Merchant payment',
    ),
    P2PKHOutputSpec(
      address: 'mPlatformFeeAddress',
      amount: BigInt.from(5000),   // 5,000 satoshis
      label: 'Platform fee',
    ),
    P2PKHOutputSpec(
      address: 'mTaxAddress',
      amount: BigInt.from(2000),   // 2,000 satoshis
      label: 'Tax withholding',
    ),
  ],
  description: 'Order #12345 - Split payment',
);

invoiceCoordinator.tell(message, sender: responseReceiver);
```

### P2MS (Multisig) Output

Create an invoice requiring multiple signatures:

```dart
// 2-of-3 multisig escrow
final message = CreateInvoiceMessage(
  walletId: 'escrow-wallet',
  outputs: [
    P2MSOutputSpec(
      publicKeys: [
        '0335cd55d33889f942e8c445cf4d9e9488a3be4bc4d4e91ccc9b57dcaa49c0f7a8',  // Buyer
        '028f10cd0e0e9bc7352adb192484d576867a71cbd82295cd87c3ceffc5fbd74acc',  // Seller
        '02a7472269ad70ea6cf1ecc7fe25a23fb6bc47f928a9ec755e34bada052bd355ce',  // Arbitrator
      ],
      threshold: 2,  // Requires 2 of 3 signatures
      amount: BigInt.from(100000),
      label: '2-of-3 escrow',
    ),
  ],
  description: 'Escrow for transaction #789',
);
```

### Mixed P2PKH and P2MS Outputs

Combine standard payments with escrow:

```dart
// Marketplace order: merchant payment + platform fee + escrow
final message = CreateInvoiceMessage(
  walletId: 'marketplace-wallet',
  outputs: [
    // Immediate payment to merchant
    P2PKHOutputSpec(
      address: 'mMerchantAddr',
      amount: BigInt.from(80000),
      label: 'Merchant payment',
    ),
    // Platform fee
    P2PKHOutputSpec(
      address: 'mPlatformFee',
      amount: BigInt.from(5000),
      label: 'Platform fee',
    ),
    // Escrow portion requiring buyer+seller or buyer+arbitrator
    P2MSOutputSpec(
      publicKeys: [buyerPubKey, sellerPubKey, arbitratorPubKey],
      threshold: 2,
      amount: BigInt.from(15000),
      label: 'Escrow - released on delivery',
    ),
  ],
  description: 'Marketplace order with escrow',
);
```

## P2MS Validation Rules

The `P2MSOutputSpec.isValid` getter validates:

1. **Threshold**: Must be > 0 and <= total keys
2. **Key count**: Maximum 16 keys (Bitcoin script limit)
3. **Public key format**: Each key must be:
   - 66 hex characters (compressed) or 130 hex characters (uncompressed)
   - Valid secp256k1 elliptic curve point

```dart
final output = P2MSOutputSpec(
  publicKeys: [pubKey1, pubKey2, pubKey3],
  threshold: 2,
  amount: BigInt.from(50000),
);

if (!output.isValid) {
  // Handle invalid configuration
  throw ArgumentError('Invalid multisig configuration');
}
```

## Handling Invoice Responses

The `InvoiceCreatedMessage` response includes:

```dart
// Handle response
if (response is InvoiceCreatedMessage) {
  if (response.success) {
    print('Invoice created: ${response.invoiceId}');
    print('Total amount: ${response.effectiveAmount} satoshis');

    // Access outputs
    for (final output in response.outputs ?? []) {
      switch (output) {
        case P2PKHOutputSpec p2pkh:
          print('P2PKH: ${p2pkh.address} - ${p2pkh.amount} sats');
        case P2MSOutputSpec p2ms:
          print('P2MS: ${p2ms.threshold}-of-${p2ms.totalKeys} - ${p2ms.amount} sats');
      }
    }

    // Legacy addresses (P2PKH only, for backward compatibility)
    print('Addresses: ${response.addresses}');
  } else {
    print('Error: ${response.error}');
  }
}
```

## SPV Payment Validation

When a payment is received, the SPVActor validates:

1. **P2PKH outputs**: Matches addresses against invoice
2. **P2MS outputs**: Compares public key sets and threshold
3. **Total amount**: Verifies payment meets `effectiveAmount`

The validation uses set comparison for P2MS (order-independent):

```dart
// SPVActor internally performs:
// 1. Extract public keys from transaction output script
// 2. Compare against invoice P2MSOutputSpec public keys (as sets)
// 3. Verify threshold matches
// 4. If all match, output is valid for this invoice
```

## Backward Compatibility

Multi-output invoices are fully backward compatible:

### Legacy Invoice Creation

```dart
// Old style still works
final legacyMessage = CreateInvoiceMessage(
  walletId: 'wallet-123',
  amount: BigInt.from(50000),  // Single amount
  numberOfAddresses: 1,        // Single address
);
```

### Computed Properties

Both legacy and multi-output invoices support:

```dart
// Works for both legacy and multi-output invoices
final totalAmount = invoice.effectiveAmount;  // Total from outputs or amount field
final addresses = invoice.addresses;           // P2PKH addresses only
```

## Serialization

Output specs serialize to/from maps for storage:

```dart
// Serialize
final map = output.toMap();
// {
//   'type': 'p2ms',
//   'publicKeys': ['03abc...', '03def...'],
//   'threshold': 2,
//   'amount': '50000',
//   'label': 'Escrow'
// }

// Deserialize
final restored = InvoiceOutputSpec.fromMap(map);
```

## Storage

Multi-output invoices are stored in the `InvoiceEntity` with:

- `addressesJson`: Legacy P2PKH addresses (comma-separated)
- `outputsJson`: Full output specs (JSON array)

The `InvoiceProjection` automatically populates both fields from `InvoiceCreatedEvent`.

## Example: Complete Flow

```dart
import 'dart:async';
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';

Future<void> createMarketplaceInvoice(
  ActorRef invoiceCoordinator,
  String merchantAddress,
  String platformFeeAddress,
  List<String> escrowPubKeys,
) async {
  final completer = Completer<InvoiceCreatedMessage>();

  // Create receiver for response
  final receiver = await actorSystem.spawn(
    'invoice-receiver',
    () => ResponseReceiver(completer),
  );

  // Create multi-output invoice
  invoiceCoordinator.tell(
    CreateInvoiceMessage(
      walletId: 'marketplace',
      outputs: [
        P2PKHOutputSpec(
          address: merchantAddress,
          amount: BigInt.from(85000),
          label: 'Merchant',
        ),
        P2PKHOutputSpec(
          address: platformFeeAddress,
          amount: BigInt.from(5000),
          label: 'Platform fee',
        ),
        P2MSOutputSpec(
          publicKeys: escrowPubKeys,
          threshold: 2,
          amount: BigInt.from(10000),
          label: 'Escrow',
        ),
      ],
      description: 'Marketplace order',
      expiresIn: Duration(hours: 24),
    ),
    sender: receiver,
  );

  // Wait for response
  final response = await completer.future.timeout(Duration(seconds: 10));

  if (response.success) {
    print('Invoice ${response.invoiceId} created');
    print('Total: ${response.effectiveAmount} satoshis');
    print('Outputs: ${response.outputs?.length ?? 0}');
  }
}
```

## Best Practices

1. **Validate P2MS configs**: Always check `isValid` before creating invoices
2. **Use meaningful labels**: Help users understand each output's purpose
3. **Keep escrow amounts reasonable**: Don't lock too much in multisig
4. **Test with valid keys**: Use real secp256k1 public keys in tests
5. **Handle backward compatibility**: Support both legacy and multi-output flows

## Related Files

- `lib/src/models/invoice_output_spec.dart` - Output spec model
- `lib/src/actors/invoice_messages.dart` - Invoice messages
- `lib/src/actors/invoice_coordinator_actor.dart` - Invoice creation
- `lib/src/actors/payment_coordinator_actor.dart` - Payment building
- `lib/src/actors/spv_actor.dart` - Payment validation
- `lib/src/storage/libspiffy_schemas.dart` - Storage schema
- `lib/src/projections/invoice_projection.dart` - Read model projection
