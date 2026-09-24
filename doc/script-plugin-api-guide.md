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
  Future<Transaction> buildTransaction(PluginTransactionRequest request) async {
    final action = request.params['action'] as String;
    final tokenId = request.params['tokenId'] as String;

    // Use funding UTXOs provided by libspiffy
    final fundingUtxo = request.fundingUtxos.first;

    // Build the full multi-output transaction using your protocol's logic
    return myProtocol.buildTokenTransaction(
      action: action,
      tokenId: tokenId,
      fundingTxId: fundingUtxo.txid,
      fundingVout: fundingUtxo.vout,
      changeAddress: request.changeAddress,
      signingKeys: request.signingKeys,
    );
  }

  @override
  bool validateTransactionStructure(Transaction tx, String action) {
    // Verify output count and script patterns match protocol spec
    if (action == 'transfer' && tx.outputs.length != 5) return false;
    return true;
  }
}
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
final message = PayInvoiceMessage(
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
);
```

The `PaymentCoordinatorActor` calls `plugin.createLockBuilder(spec)` to produce the locking script for the output.

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
        'tokenId': builder.tokenId,
        'ownerPKH': builder.ownerPKH,
        'rabinPubKeyHash': builder.rabinPubKeyHash,
      };
    } catch (_) {}
    return null;
  }

  @override
  LockingScriptBuilder? createLockBuilder(PluginOutputSpec spec) {
    if (spec.pluginScriptType == 'pp1_nft') {
      return PP1NftLockBuilder(
        recipientPKH: spec.params['ownerPKH'],
        tokenId: spec.params['tokenId'],
        rabinPubKeyHash: spec.params['rabinPubKeyHash'],
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
  Future<Transaction> buildTransaction(
      PluginTransactionRequest request) async {
    final action = request.params['action'] as String;

    switch (action) {
      case 'issuance':
        return _tokenTool.createTokenIssuanceTxn(/* ... */);
      case 'transfer':
        return _tokenTool.createTokenTransferTxn(/* ... */);
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
  // - Tags them with tokenId, ownerPKH metadata
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
| `PluginTransactionRequest` | Request object for `TransactionBuilderPlugin.buildTransaction()` |

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
| `lib/src/plugin/plugin_types.dart` | `PluginUnlockSpec`, `PluginTransactionRequest` |
| `lib/src/models/invoice_output_spec.dart` | `PluginOutputSpec` (alongside other sealed variants) |
