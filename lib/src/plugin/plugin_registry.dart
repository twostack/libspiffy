import 'package:dartsv/dartsv.dart';
import 'package:logging/logging.dart';

import '../models/invoice_output_spec.dart';
import 'plugin_types.dart';
import 'script_plugin.dart';

final _log = Logger('PluginRegistry');

/// Central registry for script plugins. Singleton.
///
/// External libraries register [ScriptPlugin] implementations here
/// to teach libspiffy about their script types. The registry is consulted
/// during UTXO indexing (to identify and tag token outputs) and during
/// transaction building (to construct appropriate lock/unlock scripts).
///
/// Example:
/// ```dart
/// PluginRegistry().register(myTokenPlugin);
/// ```
///
/// A plugin is third-party code, so every call into one is guarded (bead
/// libspiffy-u150): what a plugin throws is logged against its `pluginId`
/// and never propagated out of the registry. One faulty plugin must not
/// stop the plugins behind it from claiming a script, nor make libspiffy's
/// reading of a transaction fail: [identifyScript] carries on with the next
/// plugin, and the single-plugin calls ([extractMetadata],
/// [createLockBuilder], [createUnlockBuilder]) answer null, which each
/// caller already handles as "this plugin cannot do it".
class PluginRegistry {
  static final PluginRegistry _instance = PluginRegistry._internal();
  PluginRegistry._internal();

  /// Returns the singleton instance.
  factory PluginRegistry() => _instance;

  final Map<String, ScriptPlugin> _plugins = {};

  /// Register a plugin. Throws [StateError] if [pluginId] is already taken.
  void register(ScriptPlugin plugin) {
    if (_plugins.containsKey(plugin.pluginId)) {
      throw StateError(
        'Plugin "${plugin.pluginId}" is already registered. '
        'Unregister it first if you need to replace it.',
      );
    }
    _plugins[plugin.pluginId] = plugin;
  }

  /// Unregister a plugin by its ID. No-op if not registered.
  void unregister(String pluginId) {
    _plugins.remove(pluginId);
  }

  /// Look up a plugin by ID. Returns null if not registered.
  ScriptPlugin? getPlugin(String pluginId) => _plugins[pluginId];

  /// All registered plugins.
  List<ScriptPlugin> get allPlugins => List.unmodifiable(_plugins.values);

  /// Try all registered plugins to identify a script.
  ///
  /// Returns a record of (pluginId, scriptType) if any plugin claims
  /// the script, or null if no plugin recognizes it.
  ///
  /// A plugin that throws is logged and skipped: the plugins registered
  /// after it still get their turn (bead libspiffy-u150).
  ({String pluginId, String scriptType})? identifyScript(SVScript script) {
    for (final plugin in _plugins.values) {
      final String? type;
      try {
        type = plugin.identifyScript(script);
      } catch (e, stackTrace) {
        _log.warning(
            'Plugin "${plugin.pluginId}" threw while identifying a script; '
            'skipping it and trying the other plugins: $e',
            e,
            stackTrace);
        continue;
      }
      if (type != null) {
        return (pluginId: plugin.pluginId, scriptType: type);
      }
    }
    return null;
  }

  /// The metadata plugin [pluginId] reads out of [script], or null when it
  /// is not registered, reads nothing, or throws (logged, bead
  /// libspiffy-u150): plugin metadata enriches a UTXO, so a plugin that
  /// cannot produce it must not take the whole reading down with it.
  Map<String, dynamic>? extractMetadata(String pluginId, SVScript script) {
    final plugin = _plugins[pluginId];
    if (plugin == null) return null;
    try {
      return plugin.extractMetadata(script);
    } catch (e, stackTrace) {
      _log.warning('Plugin "$pluginId" threw while extracting the metadata of a script; '
          'the script stays attributed to it with no metadata: $e', e, stackTrace);
      return null;
    }
  }

  /// The locking script builder of [spec]'s plugin, or null when the plugin
  /// is not registered, cannot build the spec, or throws (logged, bead
  /// libspiffy-u150). A caller that needs the lock reports the plugin's
  /// failure by its `pluginId`; the exception itself is in the log.
  LockingScriptBuilder? createLockBuilder(PluginOutputSpec spec) {
    final plugin = _plugins[spec.pluginId];
    if (plugin == null) return null;
    try {
      return plugin.createLockBuilder(spec);
    } catch (e, stackTrace) {
      _log.warning(
          'Plugin "${spec.pluginId}" threw while building a locking script for '
          '"${spec.pluginScriptType}": $e',
          e,
          stackTrace);
      return null;
    }
  }

  /// The unlocking script builder of [spec]'s plugin, or null when the
  /// plugin is not registered, cannot build it, or throws (logged, bead
  /// libspiffy-u150).
  UnlockingScriptBuilder? createUnlockBuilder(PluginUnlockSpec spec) {
    final plugin = _plugins[spec.pluginId];
    if (plugin == null) return null;
    try {
      return plugin.createUnlockBuilder(spec);
    } catch (e, stackTrace) {
      _log.warning(
          'Plugin "${spec.pluginId}" threw while building an unlocking script for '
          '"${spec.scriptType}": $e',
          e,
          stackTrace);
      return null;
    }
  }

  /// Check if any plugin is registered.
  bool get hasPlugins => _plugins.isNotEmpty;

  /// Check if a specific plugin is registered.
  bool isRegistered(String pluginId) => _plugins.containsKey(pluginId);

  /// Clear all registered plugins. Intended for testing only.
  void clear() => _plugins.clear();
}
