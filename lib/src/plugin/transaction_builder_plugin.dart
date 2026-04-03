import 'package:dartsv/dartsv.dart';

import 'script_plugin.dart';
import 'plugin_types.dart';
import 'provisioned_transaction.dart';

/// Extended plugin interface for protocols that build complete multi-output
/// transactions with protocol-specific structure.
///
/// Standard [ScriptPlugin] handles single-output lock/unlock builders.
/// [TransactionBuilderPlugin] adds the ability to construct an entire
/// transaction, which is necessary for protocols like tstokenlib where
/// a token transaction has a fixed 5-output structure:
///   output[0]: Change
///   output[1]: PP1 (inductive proof)
///   output[2]: PP2 (witness bridge)
///   output[3]: PartialWitness
///   output[4]: Metadata
///
/// libspiffy handles UTXO selection, provides funding UTXOs and signing keys,
/// and packages the result into BEEF format. The plugin controls the
/// transaction structure itself.
abstract class TransactionBuilderPlugin extends ScriptPlugin {
  /// Build a complete transaction for this plugin's protocol.
  ///
  /// The [request] provides funding UTXOs, signing keys, and plugin-specific
  /// parameters. Returns a [TransactionBuilderResult]
  /// containing the primary transaction and, for paired actions (e.g.,
  /// issuance + witness), an optional witness transaction.
  ///
  /// Signing may be handled by the plugin itself (if it needs protocol-specific
  /// sighash computation) or deferred to libspiffy for standard P2PKH inputs.
  Future<TransactionBuilderResult> buildTransaction(PluginTransactionRequest request);

  /// List of transaction actions this plugin supports
  /// (e.g., ['issuance', 'transfer', 'burn', 'witness']).
  List<String> get supportedActions;

  /// Number of distinct funding UTXOs required for [action].
  ///
  /// Each funding UTXO must be a separate transaction with the funding
  /// amount at vout=1 (tstokenlib convention). Paired actions (e.g.,
  /// issuance + witness) typically need 2; single-TX actions need 1.
  ///
  /// When the coordinator has fewer UTXOs than required, it will
  /// auto-provision by splitting available funds into earmark TXs.
  int requiredFundingUtxoCount(String action) => 1;

  /// Validate that a transaction conforms to this plugin's protocol structure.
  ///
  /// Returns true if the transaction has the expected output count,
  /// script types, and internal consistency for the given action.
  bool validateTransactionStructure(Transaction tx, String action);

  /// Provision funding for a token lifecycle by building a tree of
  /// transactions from a single large input UTXO.
  ///
  /// Returns an ordered list of [ProvisionedTransaction]s for sequential
  /// broadcast (split TX first, then earmark TXs). Override in plugins
  /// that support funding provisioning.
  Future<List<ProvisionedTransaction>> provisionFunding(
      PluginTransactionRequest request) async {
    throw UnsupportedError(
        'Provisioning not supported by plugin "$pluginId"');
  }
}
