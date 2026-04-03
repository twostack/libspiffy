import 'package:dartsv/dartsv.dart';

import '../models/bitcoin_utxo.dart';

/// Callback for resolving raw transaction hex by txid from the wallet's
/// append-only transaction log.
///
/// Plugins use this to look up parent or witness transactions without
/// receiving external hex — all data flows through the wallet's read model.
/// Returns the raw transaction hex, or null if not found.
typedef TransactionLookup = Future<String?> Function(String txid);

/// Parameters for building an unlocking script to spend a plugin-managed UTXO.
class PluginUnlockSpec {
  /// Which plugin handles this script type.
  final String pluginId;

  /// Specific script type within the plugin (e.g., 'pp1_nft', 'pp1_ft').
  final String scriptType;

  /// The locking script being spent.
  final SVScript lockingScript;

  /// Satoshi value of the output being spent.
  final BigInt satoshis;

  /// Plugin-specific parameters needed to build the unlocking script
  /// (e.g., action type, parent transaction bytes, Rabin signatures).
  final Map<String, dynamic> params;

  const PluginUnlockSpec({
    required this.pluginId,
    required this.scriptType,
    required this.lockingScript,
    required this.satoshis,
    required this.params,
  });
}

/// Request for a [TransactionBuilderPlugin] to build a complete transaction.
///
/// libspiffy provides the funding UTXOs, a [TransactionSigner] for signing
/// inputs, and a change address. The plugin constructs the full transaction
/// (which may have a protocol-specific multi-output structure, e.g.,
/// tstokenlib's 5-output token transactions).
///
/// The [signer] is a [CallbackTransactionSigner] — it signs transaction
/// inputs by calling back into the wallet aggregate. The private key never
/// leaves the secure context. Plugins use the signer the same way they would
/// use a [DefaultTransactionSigner]; the interface is identical.
class PluginTransactionRequest {
  /// UTXOs selected by libspiffy to fund the transaction.
  final List<BitcoinUtxo> fundingUtxos;

  /// Signer provided by libspiffy for signing transaction inputs.
  /// This is a [CallbackTransactionSigner] — the private key stays in the
  /// wallet aggregate. Plugins pass this to [TransactionBuilder.spendFromTxnWithSigner].
  final TransactionSigner signer;

  /// Public keys for the funding UTXOs (for building unlock scripts).
  final List<SVPublicKey> publicKeys;

  /// Plugin-specific parameters (e.g., tokenId, action, recipientAddress,
  /// rabinKeyPair, witnessData).
  final Map<String, dynamic> params;

  /// Optional callback for resolving raw transaction hex by txid.
  ///
  /// When provided, plugins can look up parent or witness transactions
  /// from the wallet's append-only log instead of receiving external hex.
  final TransactionLookup? transactionLookup;

  const PluginTransactionRequest({
    required this.fundingUtxos,
    required this.signer,
    required this.publicKeys,
    required this.params,
    this.transactionLookup,
  });
}

/// Result of a plugin's [TransactionBuilderPlugin.buildTransaction] call.
///
/// For single-TX actions (transfer, burn), use the default constructor.
/// For paired actions (issuance + witness), use [TransactionBuilderResult.paired]
/// so the coordinator can record and broadcast both atomically from the same
/// UTXO reservation.
class TransactionBuilderResult {
  /// The primary transaction (e.g., token issuance or transfer).
  final Transaction primaryTx;

  /// Fee paid by the primary transaction in satoshis.
  final BigInt primaryFeeSats;

  /// Optional paired witness transaction.
  final Transaction? witnessTx;

  /// Fee paid by the witness transaction in satoshis (zero if no witness).
  final BigInt witnessFeeSats;

  /// Single-TX result (no witness).
  TransactionBuilderResult({
    required this.primaryTx,
    required this.primaryFeeSats,
  })  : witnessTx = null,
        witnessFeeSats = BigInt.zero;

  /// Paired result with both primary and witness TX.
  TransactionBuilderResult.paired({
    required this.primaryTx,
    required this.primaryFeeSats,
    required Transaction this.witnessTx,
    required this.witnessFeeSats,
  });

  /// Whether this result includes a paired witness TX.
  bool get hasPairedWitness => witnessTx != null;

  /// Primary transaction ID (hex).
  String get txid => primaryTx.id;

  /// Primary raw transaction hex.
  String get rawHex => primaryTx.serialize();

  /// Witness transaction ID (hex), or null.
  String? get witnessTxid => witnessTx?.id;

  /// Witness raw transaction hex, or null.
  String? get witnessRawHex => witnessTx?.serialize();
}
