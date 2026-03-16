import 'package:dartsv/dartsv.dart';

import 'script_plugin.dart';

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
  ({String pluginId, String scriptType})? identifyScript(SVScript script) {
    for (final plugin in _plugins.values) {
      final type = plugin.identifyScript(script);
      if (type != null) {
        return (pluginId: plugin.pluginId, scriptType: type);
      }
    }
    return null;
  }

  /// Check if any plugin is registered.
  bool get hasPlugins => _plugins.isNotEmpty;

  /// Check if a specific plugin is registered.
  bool isRegistered(String pluginId) => _plugins.containsKey(pluginId);

  /// Clear all registered plugins. Intended for testing only.
  void clear() => _plugins.clear();
}
