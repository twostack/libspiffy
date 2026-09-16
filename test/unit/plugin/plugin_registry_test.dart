import 'dart:async';

import 'package:logging/logging.dart' as log;
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

  /// libspiffy-u150: one faulty third-party plugin must never take out the
  /// registry. Every method that hands a script to a plugin catches what the
  /// plugin throws, logs it against the plugin, and carries on: a plugin that
  /// throws while identifying a script must not stop the plugins behind it
  /// from claiming that script (the output was reported unreadable instead of
  /// attributed, found in libspiffy-rp6x).
  group('libspiffy-u150: a faulty plugin does not take out the registry', () {
    /// `<"boom"> OP_DROP OP_1`: no dartsv template recognises it, so script
    /// identification falls through to the plugins.
    final script = SVScript.fromHex('04626f6f6d7551');
    late List<log.LogRecord> logs;
    late log.Level rootLevel;
    late StreamSubscription<log.LogRecord> logSub;

    setUp(() {
      logs = [];
      rootLevel = log.Logger.root.level;
      log.Logger.root.level = log.Level.ALL;
      logSub = log.Logger.root.onRecord.listen(logs.add);
    });

    tearDown(() async {
      await logSub.cancel();
      log.Logger.root.level = rootLevel;
    });

    /// The registry with [FaultyPlugin] registered ahead of a plugin that
    /// claims [script] as `claimed`.
    void registerFaultyThenGood() {
      registry.register(FaultyPlugin());
      registry.register(MockScriptPlugin(
        pluginId: 'second',
        scriptTypes: ['claimed'],
        identifyScript: (s) => s.toHex() == script.toHex() ? 'claimed' : null,
      ));
    }

    test('identifyScript skips the plugin that throws and lets the next one claim the script', () {
      registerFaultyThenGood();

      final result = registry.identifyScript(script);

      expect(result?.pluginId, 'second');
      expect(result?.scriptType, 'claimed');
      expect(
        logs.where((r) => r.level >= log.Level.WARNING).map((r) => r.message),
        contains(allOf(contains(FaultyPlugin.id), contains('identify exploded'))),
        reason: 'the throw is logged against the plugin, not propagated',
      );
    });

    test('ScriptTypeRegistry attributes the script to the working plugin', () {
      registerFaultyThenGood();

      expect(ScriptTypeRegistry().identifyScriptType(script), 'second:claimed');
      expect(ScriptTypeRegistry().extractScriptMetadata(script)?['pluginId'], 'second');
    });

    test('extractMetadata of a plugin that throws is null, and the caller keeps its reading', () {
      registry.register(BrokenReadingPlugin());

      expect(registry.extractMetadata(BrokenReadingPlugin.id, script), isNull);
      expect(
        logs.where((r) => r.level >= log.Level.WARNING).map((r) => r.message),
        contains(allOf(contains(BrokenReadingPlugin.id), contains('metadata exploded'))),
      );
      // The script is still the faulty plugin's, and ScriptTypeRegistry says so
      // instead of throwing its caller's read of the transaction away.
      final metadata = ScriptTypeRegistry().extractScriptMetadata(script);
      expect(metadata?['pluginId'], BrokenReadingPlugin.id);
      expect(metadata?['scriptType'], '${BrokenReadingPlugin.id}:boom');
    });

    test('createLockBuilder and createUnlockBuilder of a plugin that throws are null', () {
      registry.register(BrokenReadingPlugin());

      expect(
        registry.createLockBuilder(PluginOutputSpec(
          pluginId: BrokenReadingPlugin.id,
          pluginScriptType: 'boom',
          params: const {},
          amount: BigInt.from(1000),
        )),
        isNull,
      );
      expect(
        registry.createUnlockBuilder(PluginUnlockSpec(
          pluginId: BrokenReadingPlugin.id,
          scriptType: 'boom',
          lockingScript: script,
          satoshis: BigInt.from(1000),
          params: const {},
        )),
        isNull,
      );
      expect(logs.where((r) => r.level >= log.Level.WARNING).map((r) => r.message),
          contains(allOf(contains(BrokenReadingPlugin.id), contains('lock exploded'))));
      expect(logs.where((r) => r.level >= log.Level.WARNING).map((r) => r.message),
          contains(allOf(contains(BrokenReadingPlugin.id), contains('unlock exploded'))));
    });

    test('an unregistered plugin id is null, not an error', () {
      expect(registry.extractMetadata('nobody', script), isNull);
      expect(
        registry.createLockBuilder(PluginOutputSpec(
          pluginId: 'nobody',
          pluginScriptType: 'boom',
          params: const {},
          amount: BigInt.from(1000),
        )),
        isNull,
      );
    });
  });
}

/// A third-party plugin that throws from every method libspiffy calls,
/// script identification included.
class FaultyPlugin extends ScriptPlugin {
  static const id = 'faulty';

  @override
  String get pluginId => id;
  @override
  String get displayName => 'Faulty';
  @override
  List<String> get scriptTypes => const ['boom'];
  @override
  String? identifyScript(SVScript script) => throw StateError('identify exploded');
  @override
  Map<String, dynamic>? extractMetadata(SVScript script) => throw StateError('metadata exploded');
  @override
  LockingScriptBuilder? createLockBuilder(PluginOutputSpec spec) => throw StateError('lock exploded');
  @override
  UnlockingScriptBuilder? createUnlockBuilder(PluginUnlockSpec spec) => throw StateError('unlock exploded');
}

/// A plugin that recognises its own script but throws on everything it is
/// then asked about it.
class BrokenReadingPlugin extends ScriptPlugin {
  static const id = 'broken';

  @override
  String get pluginId => id;
  @override
  String get displayName => 'Broken reading';
  @override
  List<String> get scriptTypes => const ['boom'];
  @override
  String? identifyScript(SVScript script) => script.toHex() == '04626f6f6d7551' ? 'boom' : null;
  @override
  Map<String, dynamic>? extractMetadata(SVScript script) => throw StateError('metadata exploded');
  @override
  LockingScriptBuilder? createLockBuilder(PluginOutputSpec spec) => throw StateError('lock exploded');
  @override
  UnlockingScriptBuilder? createUnlockBuilder(PluginUnlockSpec spec) => throw StateError('unlock exploded');
}
