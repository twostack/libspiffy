import 'package:dartsv/dartsv.dart';

import 'script_plugin.dart';
import 'plugin_types.dart';

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
  /// The [request] provides funding UTXOs, signing keys, change address,
  /// and plugin-specific parameters. The plugin returns a fully constructed
  /// (but potentially unsigned) [Transaction].
  ///
  /// Signing may be handled by the plugin itself (if it needs protocol-specific
  /// sighash computation) or deferred to libspiffy for standard P2PKH inputs.
  Future<Transaction> buildTransaction(PluginTransactionRequest request);

  /// List of transaction actions this plugin supports
  /// (e.g., ['issuance', 'transfer', 'burn', 'witness']).
  List<String> get supportedActions;

  /// Validate that a transaction conforms to this plugin's protocol structure.
  ///
  /// Returns true if the transaction has the expected output count,
  /// script types, and internal consistency for the given action.
  bool validateTransactionStructure(Transaction tx, String action);
}
