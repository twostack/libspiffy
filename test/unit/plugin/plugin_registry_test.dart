import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart';
import 'package:libspiffy/libspiffy.dart';

/// Mock plugin for testing
class MockScriptPlugin extends ScriptPlugin {
  @override
  final String pluginId;
  @override
  final String displayName;
  @override
  final List<String> scriptTypes;

  final String? Function(SVScript)? _identifyScript;

  MockScriptPlugin({
    required this.pluginId,
    this.displayName = 'Mock Plugin',
    this.scriptTypes = const ['mock_type'],
    String? Function(SVScript)? identifyScript,
  }) : _identifyScript = identifyScript;

  @override
  String? identifyScript(SVScript script) {
    if (_identifyScript != null) return _identifyScript(script);
    // Default: always identify as first script type
    return scriptTypes.first;
  }

  @override
  Map<String, dynamic>? extractMetadata(SVScript script) => {
        'pluginId': pluginId,
        'scriptType': scriptTypes.first,
        'mockData': true,
      };

  @override
  LockingScriptBuilder? createLockBuilder(PluginOutputSpec spec) => null;

  @override
  UnlockingScriptBuilder? createUnlockBuilder(PluginUnlockSpec spec) => null;
}

void main() {
  late PluginRegistry registry;

  setUp(() {
    registry = PluginRegistry();
    registry.clear();
  });

  tearDown(() {
    registry.clear();
  });

  group('PluginRegistry', () {
    test('register and retrieve a plugin', () {
      final plugin = MockScriptPlugin(pluginId: 'test_plugin');
      registry.register(plugin);

      expect(registry.getPlugin('test_plugin'), same(plugin));
      expect(registry.isRegistered('test_plugin'), isTrue);
      expect(registry.hasPlugins, isTrue);
    });

    test('throws on duplicate registration', () {
      registry.register(MockScriptPlugin(pluginId: 'dup'));

      expect(
        () => registry.register(MockScriptPlugin(pluginId: 'dup')),
        throwsA(isA<StateError>()),
      );
    });

    test('unregister removes plugin', () {
      registry.register(MockScriptPlugin(pluginId: 'removable'));
      registry.unregister('removable');

      expect(registry.getPlugin('removable'), isNull);
      expect(registry.isRegistered('removable'), isFalse);
      expect(registry.hasPlugins, isFalse);
    });

    test('unregister is no-op for unknown plugin', () {
      registry.unregister('nonexistent'); // Should not throw
    });

    test('getPlugin returns null for unknown', () {
      expect(registry.getPlugin('nonexistent'), isNull);
    });

    test('allPlugins returns all registered', () {
      final p1 = MockScriptPlugin(pluginId: 'p1');
      final p2 = MockScriptPlugin(pluginId: 'p2');
      registry.register(p1);
      registry.register(p2);

      expect(registry.allPlugins, hasLength(2));
      expect(registry.allPlugins, containsAll([p1, p2]));
    });

    test('allPlugins returns unmodifiable list', () {
      registry.register(MockScriptPlugin(pluginId: 'p1'));
      final plugins = registry.allPlugins;

      expect(
        () => (plugins as List).add(MockScriptPlugin(pluginId: 'p2')),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('identifyScript delegates to plugins', () {
      final plugin = MockScriptPlugin(
        pluginId: 'identifier',
        scriptTypes: ['my_token'],
        identifyScript: (_) => 'my_token',
      );
      registry.register(plugin);

      final script = SVScript.fromHex('76a914' + '00' * 20 + '88ac');
      final result = registry.identifyScript(script);

      expect(result, isNotNull);
      expect(result!.pluginId, equals('identifier'));
      expect(result.scriptType, equals('my_token'));
    });

    test('identifyScript returns null when no plugin matches', () {
      final plugin = MockScriptPlugin(
        pluginId: 'picky',
        identifyScript: (_) => null,
      );
      registry.register(plugin);

      final script = SVScript.fromHex('76a914' + '00' * 20 + '88ac');
      expect(registry.identifyScript(script), isNull);
    });

    test('identifyScript tries plugins in registration order', () {
      final calls = <String>[];

      registry.register(MockScriptPlugin(
        pluginId: 'first',
        identifyScript: (_) {
          calls.add('first');
          return null; // doesn't match
        },
      ));
      registry.register(MockScriptPlugin(
        pluginId: 'second',
        identifyScript: (_) {
          calls.add('second');
          return 'found_it';
        },
      ));

      final script = SVScript.fromHex('00');
      final result = registry.identifyScript(script);

      expect(result!.pluginId, equals('second'));
      expect(calls, equals(['first', 'second']));
    });

    test('clear removes all plugins', () {
      registry.register(MockScriptPlugin(pluginId: 'a'));
      registry.register(MockScriptPlugin(pluginId: 'b'));
      registry.clear();

      expect(registry.hasPlugins, isFalse);
      expect(registry.allPlugins, isEmpty);
    });

    test('can re-register after unregister', () {
      registry.register(MockScriptPlugin(pluginId: 'reusable'));
      registry.unregister('reusable');

      final newPlugin = MockScriptPlugin(pluginId: 'reusable');
      registry.register(newPlugin);

      expect(registry.getPlugin('reusable'), same(newPlugin));
    });
  });
}
