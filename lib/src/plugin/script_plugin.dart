import 'package:dartsv/dartsv.dart';

import '../models/invoice_output_spec.dart';
import 'plugin_types.dart';

/// Interface that external token/script libraries implement to teach
/// libspiffy how to identify, parse, and build their script types.
///
/// A host application registers plugin implementations with [PluginRegistry],
/// enabling libspiffy to natively handle UTXOs and transactions involving
/// the plugin's script types without a compile-time dependency on the
/// token library.
///
/// Example:
/// ```dart
/// class MyTokenPlugin extends ScriptPlugin {
///   @override
///   String get pluginId => 'mytoken';
///   // ...
/// }
///
/// PluginRegistry().register(MyTokenPlugin());
/// ```
abstract class ScriptPlugin {
  /// Unique identifier for this plugin (e.g., 'tstoken', 'ordinals').
  /// Used as a namespace to avoid conflicts between plugins.
  String get pluginId;

  /// Human-readable display name for UI purposes.
  String get displayName;

  /// List of script type identifiers this plugin handles
  /// (e.g., ['pp1_nft', 'pp1_ft', 'pp2', 'pp3_witness']).
  List<String> get scriptTypes;

  /// Try to identify a script as one of this plugin's types.
  ///
  /// Returns a script type string (from [scriptTypes]) if recognized,
  /// or null if this plugin doesn't handle the given script.
  String? identifyScript(SVScript script);

  /// Extract plugin-specific metadata from an identified script.
  ///
  /// Returns a map of metadata (e.g., tokenId, ownerPKH, amount, action)
  /// or null if the script is not recognized. The map contents are
  /// plugin-defined and stored in [BitcoinUtxo.pluginMetadata].
  Map<String, dynamic>? extractMetadata(SVScript script);

  /// Build a locking script for a [PluginOutputSpec].
  ///
  /// Returns a [LockingScriptBuilder] configured for the given output spec,
  /// or null if this plugin can't handle the spec's [scriptType].
  LockingScriptBuilder? createLockBuilder(PluginOutputSpec spec);

  /// Build an unlocking script to spend a plugin-managed UTXO.
  ///
  /// Returns an [UnlockingScriptBuilder] for the given unlock parameters,
  /// or null if this plugin can't handle the given script type.
  UnlockingScriptBuilder? createUnlockBuilder(PluginUnlockSpec spec);
}
