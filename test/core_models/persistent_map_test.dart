/// libspiffy-mmb: PersistentMap, the structurally shared map behind the
/// immutable aggregate states. Checked against a LinkedHashMap model over
/// random operation sequences (contents, insertion order, length), for
/// persistence (every earlier version keeps its contents), and for the cost
/// of an update (slots copied, not the whole map).
library;

import 'dart:math';

import 'package:test/test.dart';

import 'package:libspiffy/src/models/persistent_map.dart';

/// A key whose hash is chosen, to force hash collisions.
class _CollidingKey {
  final int id;
  final int hash;
  const _CollidingKey(this.id, this.hash);

  @override
  bool operator ==(Object other) => other is _CollidingKey && other.id == id;

  @override
  int get hashCode => hash;

  @override
  String toString() => 'k$id';
}

void _expectSame<K, V>(PersistentMap<K, V> actual, Map<K, V> model, String when) {
  expect(actual.length, model.length, reason: 'length $when');
  expect(actual.isEmpty, model.isEmpty, reason: 'isEmpty $when');
  expect(actual.keys.toList(), model.keys.toList(), reason: 'key order $when');
  expect(actual.values.toList(), model.values.toList(), reason: 'values $when');
  expect([for (final e in actual.entries) '${e.key}=${e.value}'],
      [for (final e in model.entries) '${e.key}=${e.value}'], reason: 'entries $when');
  for (final key in model.keys) {
    expect(actual.containsKey(key), isTrue, reason: 'containsKey $key $when');
    expect(actual[key], model[key], reason: '[$key] $when');
  }
}

void main() {
  group('mmb: PersistentMap', () {
    test('matches a LinkedHashMap over random puts and removals, and every version persists', () {
      final random = Random(20260915);
      for (final keySpace in [8, 64, 2000]) {
        var map = PersistentMap<int, int>.empty();
        final model = <int, int>{};
        final versions = <(PersistentMap<int, int>, Map<int, int>)>[];
        for (var step = 0; step < 6000; step++) {
          final key = random.nextInt(keySpace);
          final roll = random.nextInt(10);
          if (roll < 6) {
            final value = random.nextInt(1 << 20);
            map = map.put(key, value);
            model[key] = value;
          } else if (roll < 9) {
            map = map.without(key);
            model.remove(key);
          } else {
            map = map.without(keySpace + 1); // absent: unchanged
          }
          expect(map[key], model[key], reason: 'key $key after step $step');
          if (step % 500 == 0) versions.add((map, Map.of(model)));
        }
        _expectSame(map, model, 'at the end (key space $keySpace)');
        for (final (version, snapshot) in versions) {
          _expectSame(version, snapshot, 'for an earlier version (key space $keySpace)');
        }
        expect(map.containsKey(-1), isFalse);
        expect(map[-1], isNull);
      }
    });

    test('colliding hashes are kept apart', () {
      var map = PersistentMap<_CollidingKey, int>.empty();
      final model = <_CollidingKey, int>{};
      final random = Random(7);
      for (var step = 0; step < 3000; step++) {
        final id = random.nextInt(300);
        final key = _CollidingKey(id, id % 4); // four hashes only
        if (random.nextBool()) {
          map = map.put(key, step);
          model[key] = step;
        } else {
          map = map.without(key);
          model.remove(key);
        }
      }
      _expectSame(map, model, 'with colliding hashes');
    });

    test('of() keeps the source order and does not share it; every mutator throws', () {
      final source = {'b': 1, 'a': 2, 'c': 3};
      final map = PersistentMap<String, int>.of(source);
      source['d'] = 4;
      source.remove('a');
      expect(map.keys.toList(), ['b', 'a', 'c']);
      expect(identical(PersistentMap<String, int>.of(map), map), isTrue);

      expect(() => map['x'] = 1, throwsUnsupportedError);
      expect(() => map.remove('a'), throwsUnsupportedError);
      expect(() => map.clear(), throwsUnsupportedError);
      expect(() => map.addAll({'x': 1}), throwsUnsupportedError);
      expect(() => map.putIfAbsent('x', () => 1), throwsUnsupportedError);
      expect(() => map.update('a', (v) => v), throwsUnsupportedError);
      expect(map, {'b': 1, 'a': 2, 'c': 3});
    });

    test('replacing a value keeps its position; a removed key comes back at the end', () {
      var map = PersistentMap<String, int>.of({'a': 1, 'b': 2, 'c': 3});
      map = map.put('a', 10).without('b').put('b', 20).updated('c', (v) => v + 1);
      expect(map.entries.map((e) => '${e.key}${e.value}').toList(), ['a10', 'c4', 'b20']);
      expect(map.updated('zz', (v) => v), same(map));
      expect(map.updated('zz', (v) => v, ifAbsent: () => 5)['zz'], 5);
    });

    test('freezeDeep makes nested maps and lists unmodifiable copies', () {
      final nested = {'ids': [1, 2]};
      final source = <String, dynamic>{'nested': nested, 'n': 1};
      final frozen = freezeMap(source);
      nested['ids']!.add(3);
      expect(frozen, {'nested': {'ids': [1, 2]}, 'n': 1});
      expect(() => (frozen['nested'] as Map)['x'] = 1, throwsUnsupportedError);
      expect(() => ((frozen['nested'] as Map)['ids'] as List).add(9), throwsUnsupportedError);
      final plain = unmodifiableDeepCopy(source) as Map<String, dynamic>;
      expect(() => plain['x'] = 1, throwsUnsupportedError);
      expect(plain['nested'], {'ids': [1, 2, 3]});
    });

    test('an update copies O(log n) slots, not the map', () {
      const n = 20000;
      PersistentMapStats.reset();
      var map = PersistentMap<String, int>.empty();
      for (var i = 0; i < n; i++) {
        map = map.put('${i.toRadixString(16).padLeft(64, '0')}:0', i);
      }
      final perInsert = PersistentMapStats.copiedSlots / n;
      PersistentMapStats.reset();
      for (var i = 0; i < n; i += 7) {
        map = map.put('${i.toRadixString(16).padLeft(64, '0')}:0', -i);
      }
      final perReplace = PersistentMapStats.copiedSlots / (n / 7);
      // A LinkedHashMap copy per update would copy n / 2 entries on average.
      expect(perInsert, lessThan(200), reason: 'slots copied per insert into a map of up to $n');
      expect(perReplace, lessThan(200), reason: 'slots copied per replacement in a map of $n');
      expect(PersistentMapStats.fullBuilds, 0);
      expect(map.length, n);
    });
  });
}
