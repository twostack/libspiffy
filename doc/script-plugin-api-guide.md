# Script Plugin API Guide

LibSpiffy provides an extensible plugin system that allows external token and script libraries to integrate with the wallet without being a compile-time dependency. A host application registers plugins at runtime, and libspiffy immediately gains the ability to identify, track, and build transactions involving the plugin's script types.

## Architecture

```
dartsv (shared foundation)
  ^          ^
  |          |
libspiffy    tstokenlib    (no dependency between them)
  ^          ^
  |          |
  +--- host app ---+       (registers plugin, wires both together)
```

LibSpiffy defines abstract interfaces. External libraries (or the host app) implement those interfaces. Registration is a one-liner. No bridge package is needed.

## Core Concepts

### ScriptPlugin

The base interface. Implement this to teach libspiffy how to identify and work with your script types.

```dart
import 'package:dartsv/dartsv.dart';
import 'package:libspiffy/libspiffy.dart';

class MyTokenPlugin extends ScriptPlugin {
  @override
  String get pluginId => 'mytoken';

  @override
  String get displayName => 'My Token Protocol';

  @override
  List<String> get scriptTypes => ['token_v1', 'token_v1_witness'];

  @override
  String? identifyScript(SVScript script) {
    // Try to parse the script as one of your types.
    // Return the type string if recognized, null otherwise.
    try {
      MyTokenLockBuilder.fromScript(script);
      return 'token_v1';
    } catch (_) {}
    return null;
  }

  @override
  Map<String, dynamic>? extractMetadata(SVScript script) {
    // Parse protocol-specific data from the locking script.
    // Returned map is stored in BitcoinUtxo.pluginMetadata.
    final builder = MyTokenLockBuilder.fromScript(script);
    return {
      'pluginId': pluginId,
      'scriptType': 'token_v1',
      'tokenId': builder.tokenId,
      'ownerPKH': builder.ownerPKH,
    };
  }

  @override
  LockingScriptBuilder? createLockBuilder(PluginOutputSpec spec) {
    if (spec.pluginScriptType == 'token_v1') {
      return MyTokenLockBuilder(
        tokenId: spec.params['tokenId'],
        ownerPKH: spec.params['ownerPKH'],
      );
    }
    return null;
  }

  @override
  UnlockingScriptBuilder? createUnlockBuilder(PluginUnlockSpec spec) {
    if (spec.scriptType == 'token_v1') {
      return MyTokenUnlockBuilder(
        action: spec.params['action'],
        parentTxBytes: spec.params['parentTxBytes'],
      );
    }
    return null;
  }
}
```

### TransactionBuilderPlugin

An extended interface for protocols that produce multi-output transactions with a fixed structure. Standard `ScriptPlugin` works output-by-output; `TransactionBuilderPlugin` builds the entire transaction.

This is necessary for protocols like TSL1 tokens, where a single token operation produces a 5-output transaction (change, PP1, PP2, partial witness, metadata) with interdependent scripts.

```dart
class MyTokenTransactionPlugin extends TransactionBuilderPlugin {
  // ... all ScriptPlugin methods ...

  @override
  List<String> get supportedActions => ['issuance', 'transfer', 'burn'];

  @override
  Future<TransactionBuilderResult> buildTransaction(PluginTransactionRequest request) async {
    final action = request.params['action'] as String;
    final tokenId = request.params['tokenId'] as String;

    // Use funding UTXOs provided by libspiffy
    final fundingUtxo = request.fundingUtxos.first;

    // Build the full multi-output transaction using your protocol's logic,
    // signing with the signer libspiffy provides (the key stays in the wallet)
    final (tx, fee) = myProtocol.buildTokenTransaction(
      action: action,
      tokenId: tokenId,
      fundingTxId: fundingUtxo.txid,
      fundingVout: fundingUtxo.vout,
      signer: request.signer,
      fundingPubKey: request.publicKeys.first,
      feeRate: request.feeRate,
    );
    return TransactionBuilderResult(primaryTx: tx, primaryFeeSats: fee);
  }

  @override
  bool validateTransactionStructure(Transaction tx, String action) {
    // Verify output count and script patterns match protocol spec
    if (action == 'transfer' && tx.outputs.length != 5) return false;
    return true;
  }
}
```

A payment reaches `buildTransaction` only when its `PluginOutputSpec` names a `TransactionBuilderPlugin` and its `params['action']` is one of the plugin's `supportedActions`. The `PluginTransactionRequest` carries `fundingUtxos` (and the same coins as `fundingInputs`, over their real locking scripts), a `signer` that signs through the wallet, the funding `publicKeys`, the spec's `params`, the `feeRate` every wallet transaction pays, and a `transactionLookup` for raw transactions the wallet holds. For a paired action (issuance and its witness), return `TransactionBuilderResult.paired`.

A `TransactionBuilderPlugin` can also override:

- **`requiredFundingUtxoCount(action)`** (default 1): how many separate funding UTXOs the action needs. When the wallet selects fewer, libspiffy splits its funds into earmark transactions first.
- **`spendsAnyWalletOutput`** (default false): true when the plugin spends every funding coin through `fundingInputs`. Only then is it funded from bare multisig and P2PK outputs as well as P2PKH ones.
- **`provisionFunding(request)`**: builds a split transaction and its earmarks, returned as `ProvisionedTransaction`s in broadcast order. The default throws `UnsupportedError`.

### Signing an input whose owner the signed script does not name

libspiffy signs each input a plugin adds with the wallet key that the spent script names: a 20-byte push (a public key hash) or a public key push that matches a wallet address. That fails for a covenant whose signature covers only the code after an `OP_CODESEPARATOR` while its owner sits in a header before it. The script the signature covers then names nobody, and libspiffy would fall back to the funding key.

The plugin names the key itself with `request.keyFor(pubkeyHash)`, giving the HASH160 as 40 hex characters. It returns a `PluginKey`:

- **`signer`:** signs with that key and no other. It shares the request signer's signing passes.
- **`publicKey`:** for the unlocking script.

It fails, and so does the payment, when the wallet holds no key with that hash.

```dart
final owner = await request.keyFor(ownerHashHex);
builder.spendFromOutpointWithSigner(
  owner.signer,
  TransactionOutpoint(tokenTxid, 1, BigInt.one, codeAfterSeparator), // the subscript the signature covers
  TransactionInput.MAX_SEQ_NUMBER,
  P2PKHUnlockBuilder(owner.publicKey),
);
```

### PluginRegistry

Singleton that manages all registered plugins.

```dart
// Register (typically during app initialization)
PluginRegistry().register(MyTokenPlugin());

// Query
final plugin = PluginRegistry().getPlugin('mytoken');
final allPlugins = PluginRegistry().allPlugins;
final isRegistered = PluginRegistry().isRegistered('mytoken');

// Identify an unknown script through all plugins
final result = PluginRegistry().identifyScript(someScript);
if (result != null) {
  print('Plugin: ${result.pluginId}, Type: ${result.scriptType}');
}

// Unregister
PluginRegistry().unregister('mytoken');

// Clear all (testing only)
PluginRegistry().clear();
```

## Integration Points

### 1. UTXO Identification and Metadata

When libspiffy encounters a new UTXO, `ScriptTypeRegistry` delegates to `PluginRegistry` for scripts that dartsv's built-in templates don't recognize. If a plugin claims the script, its `extractMetadata()` output is stored in `BitcoinUtxo.pluginMetadata`.

```dart
// After registration, plugin-identified UTXOs carry metadata:
final utxos = await storage.getAvailableUTXOs(walletId);
for (final utxo in utxos) {
  if (utxo.pluginMetadata != null) {
    print('Token UTXO: ${utxo.pluginMetadata}');
    // e.g. {pluginId: 'tstoken', scriptType: 'pp1_nft', tokenId: 'abc...'}
  }
}

// Query UTXOs by plugin directly:
final tokenUtxos = await storage.getUTXOsByPlugin(walletId, 'tstoken');

// Filter further by metadata:
final nftUtxos = await storage.getUTXOsByPlugin(
  walletId, 'tstoken',
  metadataFilter: {'scriptType': 'pp1_nft'},
);
```

### 2. Script Type Identification

`ScriptTypeRegistry` automatically incorporates plugins. Plugin-identified scripts use a `pluginId:scriptType` format.

```dart
final registry = ScriptTypeRegistry();

// Returns 'tstoken:pp1_nft' for a token script, 'p2pkh' for standard
final type = registry.identifyScriptType(script);

// Metadata extraction also delegates to plugins
final meta = registry.extractScriptMetadata(script);
// For plugin scripts, meta includes: pluginId, pluginScriptType, plus
// whatever extractMetadata() returns
```

### 3. Transaction Building via PluginOutputSpec

To include plugin-managed outputs in a payment, use `PluginOutputSpec`:

```dart
final payment = await coordinator.ask(PayInvoiceCommand(
  walletId: 'my-wallet',
  invoiceId: 'inv-001',
  addresses: [],
  amount: BigInt.zero,
  outputs: [
    // Standard P2PKH output
    P2PKHOutputSpec(
      address: 'mRecipientAddr',
      amount: BigInt.from(50000),
    ),
    // Plugin-managed output
    PluginOutputSpec(
      pluginId: 'mytoken',
      pluginScriptType: 'token_v1',
      params: {
        'tokenId': 'abc123',
        'ownerPKH': 'def456',
        'action': 'transfer',
      },
      amount: BigInt.from(546), // dust limit for token carrier
    ),
  ],
));
```

The payment calls `plugin.createLockBuilder(spec)` to produce the locking script for the output. When the plugin is a `TransactionBuilderPlugin` and `params['action']` is one of its `supportedActions`, its `buildTransaction()` builds the whole transaction instead.

### 4. Serialization

`PluginOutputSpec` serializes to and from maps for event storage:

```dart
final spec = PluginOutputSpec(
  pluginId: 'tstoken',
  pluginScriptType: 'pp1_nft',
  params: {'tokenId': 'abc'},
  amount: BigInt.from(546),
);

final map = spec.toMap();
// {type: 'plugin', pluginId: 'tstoken', pluginScriptType: 'pp1_nft',
//  params: {tokenId: 'abc'}, amount: '546'}

final restored = InvoiceOutputSpec.fromMap(map); // returns PluginOutputSpec
```

`BitcoinUtxo.pluginMetadata` is included in `toMap()`/`fromMap()` round-trips. It is omitted from the map when null (no overhead for standard UTXOs).

## Example: TSTokenLib Integration

A host application using both libspiffy and tstokenlib would wire them together like this:

```dart
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:tstokenlib/tstokenlib.dart';

/// Adapter that bridges tstokenlib to libspiffy's plugin system.
class TsTokenNftPlugin extends TransactionBuilderPlugin {
  final TokenTool _tokenTool;

  TsTokenNftPlugin({NetworkType networkType = NetworkType.TEST})
      : _tokenTool = TokenTool(networkType: networkType);

  @override
  String get pluginId => 'tstoken_nft';

  @override
  String get displayName => 'TSL1 NFT Tokens';

  @override
  List<String> get scriptTypes => ['pp1_nft', 'pp2', 'pp3_witness'];

  @override
  List<String> get supportedActions => ['issuance', 'transfer', 'burn'];

  @override
  String? identifyScript(SVScript script) {
    try {
      PP1NftLockBuilder.fromScript(script);
      return 'pp1_nft';
    } catch (_) {}
    try {
      PP2LockBuilder.fromScript(script);
      return 'pp2';
    } catch (_) {}
    return null;
  }

  @override
  Map<String, dynamic>? extractMetadata(SVScript script) {
    try {
      final builder = PP1NftLockBuilder.fromScript(script);
      return {
        'pluginId': pluginId,
        'scriptType': 'pp1_nft',
        'tokenId': hex.encode(builder.tokenId!),
        'ownerAddress': builder.recipientAddress?.toBase58(),
        'rabinPubKeyHash': hex.encode(builder.rabinPubKeyHash!),
      };
    } catch (_) {}
    return null;
  }

  @override
  LockingScriptBuilder? createLockBuilder(PluginOutputSpec spec) {
    if (spec.pluginScriptType == 'pp1_nft') {
      return PP1NftLockBuilder(
        Address.fromBase58(spec.params['ownerAddress']),
        hex.decode(spec.params['tokenId']),
        hex.decode(spec.params['rabinPubKeyHash']),
      );
    }
    return null;
  }

  @override
  UnlockingScriptBuilder? createUnlockBuilder(PluginUnlockSpec spec) {
    // Delegate to tstokenlib's unlock builders
    return null; // Simplified - real impl would build PP1NftUnlockBuilder
  }

  @override
  Future<TransactionBuilderResult> buildTransaction(
      PluginTransactionRequest request) async {
    final action = request.params['action'] as String;

    // tstokenlib signs with request.signer and request.publicKeys.first
    switch (action) {
      case 'issuance':
        final tx = await _tokenTool.createTokenIssuanceTxn(/* ... */);
        return TransactionBuilderResult(primaryTx: tx, primaryFeeSats: /* ... */);
      case 'transfer':
        final tx = _tokenTool.createTokenTransferTxn(/* ... */);
        return TransactionBuilderResult(primaryTx: tx, primaryFeeSats: /* ... */);
      default:
        throw ArgumentError('Unsupported action: $action');
    }
  }

  @override
  bool validateTransactionStructure(Transaction tx, String action) {
    // Token transactions must have 5 outputs
    return tx.outputs.length == 5;
  }
}

// --- App initialization ---
void main() {
  // One-liner registration
  PluginRegistry().register(TsTokenNftPlugin());

  // Now libspiffy natively:
  // - Identifies PP1_NFT scripts in wallet UTXOs
  // - Tags them with tokenId, ownerAddress metadata
  // - Builds token outputs via PluginOutputSpec
  // - Queries token UTXOs via getUTXOsByPlugin()
}
```

## API Reference

### Classes

| Class | Purpose |
|-------|---------|
| `ScriptPlugin` | Base interface for script identification and lock/unlock building |
| `TransactionBuilderPlugin` | Extended interface for multi-output transaction building |
| `PluginRegistry` | Singleton registry for managing plugins |
| `PluginOutputSpec` | Sealed variant of `InvoiceOutputSpec` for plugin-delegated outputs |
| `PluginUnlockSpec` | Parameters for building an unlocking script |
| `PluginTransactionRequest` | Request object for `TransactionBuilderPlugin.buildTransaction()`; `keyFor(pubkeyHash)` names a wallet key |
| `PluginFundingInput` | One funding UTXO over its real locking script, with the unlocking script the wallet writes for it |
| `PluginKey` | A wallet key named by hash: a signer bound to it and its public key |
| `TransactionBuilderResult` | What `buildTransaction()` returns: the transaction and its fee, or a paired transaction and witness |
| `ProvisionedTransaction` | One transaction of a funding provision: the split or an earmark |

### BitcoinUtxo.pluginMetadata

| Key | Type | Description |
|-----|------|-------------|
| `pluginId` | `String` | Which plugin identified this UTXO |
| `scriptType` | `String` | Script type within the plugin |
| *(additional)* | `dynamic` | Plugin-specific (tokenId, ownerPKH, amount, etc.) |

### Storage Methods

| Method | Description |
|--------|-------------|
| `getUTXOsByPlugin(walletId, pluginId)` | Get UTXOs managed by a specific plugin |
| `getUTXOsByPlugin(walletId, pluginId, metadataFilter: {...})` | Filter by additional metadata keys |

### Files

| File | Contents |
|------|----------|
| `lib/src/plugin/script_plugin.dart` | `ScriptPlugin` abstract class |
| `lib/src/plugin/transaction_builder_plugin.dart` | `TransactionBuilderPlugin` abstract class |
| `lib/src/plugin/plugin_registry.dart` | `PluginRegistry` singleton |
| `lib/src/plugin/plugin_types.dart` | `PluginUnlockSpec`, `PluginTransactionRequest`, `PluginFundingInput`, `PluginKey`, `TransactionBuilderResult` |
| `lib/src/plugin/provisioned_transaction.dart` | `ProvisionedTransaction` |
| `lib/src/models/invoice_output_spec.dart` | `PluginOutputSpec` (alongside other sealed variants) |
