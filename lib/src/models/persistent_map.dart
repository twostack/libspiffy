/// An immutable, insertion-ordered map with structural sharing, for the
/// aggregate state objects (bead libspiffy-mmb).
///
/// Aggregate state is copy-on-write: applying an event yields a new state and
/// leaves the previous one untouched. Copying a wallet's UTXO map (or its
/// address or transaction records) on every event would make replaying a
/// journal O(N^2); [PersistentMap.put] and [PersistentMap.without] instead
/// copy only the O(log32 n) nodes on the path to the changed entry and share
/// everything else with the map they were derived from.
///
/// Iteration follows insertion order like a `LinkedHashMap`: replacing the
/// value of a key keeps its position, a key removed and added again moves to
/// the end. Every `Map` mutator throws [UnsupportedError].
library;

import 'dart:collection';

import 'package:meta/meta.dart';

/// Counts the work [PersistentMap] does, so tests can observe that an
/// update copies a bounded number of slots rather than the whole map.
@visibleForTesting
abstract final class PersistentMapStats {
  /// Slots (node array elements) copied or written by updates since the last
  /// [reset], including the entries a bulk build writes.
  static int copiedSlots = 0;

  /// Maps built from every entry of another map ([PersistentMap.of] on a map
  /// that is not already persistent, and tombstone compaction).
  static int fullBuilds = 0;

  /// Entries visited by iterating maps (keys, values, entries, forEach).
  static int iteratedEntries = 0;

  static void reset() {
    copiedSlots = 0;
    fullBuilds = 0;
    iteratedEntries = 0;
  }
}

/// An immutable, insertion-ordered map; see the library documentation.
final class PersistentMap<K, V> extends UnmodifiableMapBase<K, V> {
  /// Key -> position in [_entries].
  final Object? _index;

  /// Entries by insertion position; null marks a removed entry.
  final _Vector _entries;

  @override
  final int length;

  PersistentMap._(this._index, this._entries, this.length);

  /// The empty map.
  factory PersistentMap.empty() => PersistentMap<K, V>._(null, _Vector.empty, 0);

  /// [source] itself when it is already a `PersistentMap<K, V>`, otherwise a
  /// persistent copy of its entries in its iteration order.
  factory PersistentMap.of(Map<K, V> source) {
    if (source is PersistentMap<K, V>) return source;
    if (source.isEmpty) return PersistentMap<K, V>.empty();
    PersistentMapStats.fullBuilds++;
    return _build<K, V>(source.entries);
  }

  static PersistentMap<K, V> _build<K, V>(Iterable<MapEntry<K, V>> entries) {
    final builder = _Builder<K, V>();
    for (final entry in entries) {
      builder.put(entry.key, entry.value);
    }
    return builder.build();
  }

  int? _positionOf(Object? key) => _Hamt.find(_index, key, _hash(key));

  @override
  V? operator [](Object? key) {
    final position = _positionOf(key);
    if (position == null) return null;
    return (_entries.get(position) as _Entry<K, V>).value;
  }

  @override
  bool containsKey(Object? key) => _positionOf(key) != null;

  @override
  bool get isEmpty => length == 0;

  @override
  bool get isNotEmpty => length != 0;

  @override
  Iterable<K> get keys => _MappedIterable<K, V, K>(this, (e) => e.key);

  @override
  Iterable<V> get values => _MappedIterable<K, V, V>(this, (e) => e.value);

  @override
  Iterable<MapEntry<K, V>> get entries => _MappedIterable<K, V, MapEntry<K, V>>(this, (e) => MapEntry(e.key, e.value));

  @override
  void forEach(void Function(K key, V value) action) {
    for (final entry in _liveEntries()) {
      action(entry.key, entry.value);
    }
  }

  Iterable<_Entry<K, V>> _liveEntries() sync* {
    final count = _entries.length;
    for (var start = 0; start < count; start += _Vector.width) {
      final leaf = _entries.leafAt(start);
      for (final slot in leaf) {
        if (slot != null) {
          PersistentMapStats.iteratedEntries++;
          yield slot as _Entry<K, V>;
        }
      }
    }
  }

  /// This map with [key] mapped to [value]: an existing key keeps its
  /// position, a new key is added at the end.
  PersistentMap<K, V> put(K key, V value) {
    final hash = _hash(key);
    final position = _Hamt.find(_index, key, hash);
    if (position != null) {
      final existing = _entries.get(position) as _Entry<K, V>;
      if (identical(existing.value, value)) return this;
      return PersistentMap._(_index, _entries.set(position, _Entry<K, V>(existing.key, value)), length);
    }
    final newPosition = _entries.length;
    return PersistentMap._(
      _Hamt.insert(_index, 0, _Leaf(key, hash, newPosition)),
      _entries.append(_Entry<K, V>(key, value)),
      length + 1,
    );
  }

  /// This map with every entry of [other] put, in [other]'s order.
  PersistentMap<K, V> putAll(Map<K, V> other) {
    var result = this;
    other.forEach((k, v) => result = result.put(k, v));
    return result;
  }

  /// This map with [key]'s value replaced by `update(value)`, or with
  /// `ifAbsent()` added when [key] is absent (unchanged when [ifAbsent] is
  /// null).
  PersistentMap<K, V> updated(K key, V Function(V value) update, {V Function()? ifAbsent}) {
    final position = _positionOf(key);
    if (position == null) return ifAbsent == null ? this : put(key, ifAbsent());
    return put(key, update((_entries.get(position) as _Entry<K, V>).value));
  }

  /// This map without [key].
  PersistentMap<K, V> without(Object? key) {
    final hash = _hash(key);
    final position = _Hamt.find(_index, key, hash);
    if (position == null) return this;
    if (length == 1) return PersistentMap<K, V>.empty();
    final entries = _entries.set(position, null);
    final result = PersistentMap<K, V>._(_Hamt.remove(_index, 0, key, hash), entries, length - 1);
    // Removed entries leave holes that iteration skips; rebuild once they
    // outnumber the live entries, so the cost stays amortised O(1).
    final holes = entries.length - result.length;
    if (holes > _Vector.width && holes > result.length) {
      PersistentMapStats.fullBuilds++;
      return _build<K, V>(result.entries);
    }
    return result;
  }

  static int _hash(Object? key) {
    final h = key.hashCode;
    return (h ^ (h >>> 15)) & _Hamt.hashMask;
  }
}

/// Builds a [PersistentMap] by writing into nodes no other map shares yet.
class _Builder<K, V> {
  Object? _index;
  final List<List<Object?>> _leaves = [];
  int _count = 0;

  void put(K key, V value) {
    final hash = PersistentMap._hash(key);
    final position = _Hamt.find(_index, key, hash);
    if (position != null) {
      _leaves[position >> _Vector.bits][position & _Vector.mask] = _Entry<K, V>(key, value);
      return;
    }
    if (_count % _Vector.width == 0) _leaves.add(<Object?>[]);
    _leaves.last.add(_Entry<K, V>(key, value));
    _index = _Hamt.insert(_index, 0, _Leaf(key, hash, _count));
    _count++;
    PersistentMapStats.copiedSlots++;
  }

  PersistentMap<K, V> build() => PersistentMap<K, V>._(_index, _Vector.fromLeaves(_leaves, _count), _count);
}

class _Entry<K, V> {
  final K key;
  final V value;
  const _Entry(this.key, this.value);
}

/// Iterable over a [PersistentMap]'s live entries, with O(1) length and
/// emptiness.
class _MappedIterable<K, V, T> extends Iterable<T> {
  final PersistentMap<K, V> _map;
  final T Function(_Entry<K, V>) _project;

  _MappedIterable(this._map, this._project);

  @override
  Iterator<T> get iterator => _map._liveEntries().map(_project).iterator;

  @override
  int get length => _map.length;

  @override
  bool get isEmpty => _map.isEmpty;

  @override
  bool get isNotEmpty => _map.isNotEmpty;
}

// ---------------------------------------------------------------------------
// Persistent vector: a 32-way trie of positions.
// ---------------------------------------------------------------------------

class _Vector {
  static const int bits = 5;
  static const int width = 1 << bits;
  static const int mask = width - 1;

  static final _Vector empty = _Vector._(const <Object?>[], 0, 0);

  /// Leaves hold values; inner nodes hold child nodes. [shift] is the bit
  /// offset of the root's index digit (0 when the root is a leaf).
  final List<Object?> _root;
  final int _shift;
  final int length;

  _Vector._(this._root, this._shift, this.length);

  /// A vector over [leaves] (all full except possibly the last), which the
  /// caller hands over.
  factory _Vector.fromLeaves(List<List<Object?>> leaves, int length) {
    if (leaves.isEmpty) return empty;
    List<Object?> nodes = leaves;
    var shift = 0;
    while (nodes.length > 1) {
      final parents = <Object?>[
        for (var i = 0; i < nodes.length; i += width)
          nodes.sublist(i, i + width > nodes.length ? nodes.length : i + width),
      ];
      PersistentMapStats.copiedSlots += nodes.length;
      nodes = parents;
      shift += bits;
    }
    return _Vector._(nodes.single as List<Object?>, shift, length);
  }

  Object? get(int index) => leafAt(index)[index & mask];

  List<Object?> leafAt(int index) {
    var node = _root;
    for (var level = _shift; level > 0; level -= bits) {
      node = node[(index >> level) & mask] as List<Object?>;
    }
    return node;
  }

  _Vector set(int index, Object? value) => _Vector._(_setIn(_root, _shift, index, value), _shift, length);

  static List<Object?> _setIn(List<Object?> node, int level, int index, Object? value) {
    final copy = List<Object?>.of(node, growable: false);
    PersistentMapStats.copiedSlots += copy.length;
    final digit = (index >> level) & mask;
    copy[digit] = level == 0 ? value : _setIn(node[digit] as List<Object?>, level - bits, index, value);
    return copy;
  }

  _Vector append(Object? value) {
    final index = length;
    if (index == 0) {
      PersistentMapStats.copiedSlots++;
      return _Vector._(<Object?>[value], 0, 1);
    }
    if (index == 1 << (_shift + bits)) {
      // The trie is full: grow a level.
      PersistentMapStats.copiedSlots += 2;
      return _Vector._(<Object?>[_root, _path(_shift, value)], _shift + bits, length + 1);
    }
    return _Vector._(_pushIn(_root, _shift, index, value), _shift, length + 1);
  }

  static List<Object?> _path(int level, Object? value) {
    PersistentMapStats.copiedSlots++;
    return level == 0 ? <Object?>[value] : <Object?>[_path(level - bits, value)];
  }

  static List<Object?> _pushIn(List<Object?> node, int level, int index, Object? value) {
    final digit = (index >> level) & mask;
    final Object? child;
    if (level == 0) {
      child = value;
    } else if (digit < node.length) {
      child = _pushIn(node[digit] as List<Object?>, level - bits, index, value);
    } else {
      child = _path(level - bits, value);
    }
    final copy = List<Object?>.filled(digit < node.length ? node.length : node.length + 1, null);
    copy.setRange(0, node.length, node);
    copy[digit] = child;
    PersistentMapStats.copiedSlots += copy.length;
    return copy;
  }
}

// ---------------------------------------------------------------------------
// Hash array mapped trie: key -> position.
// ---------------------------------------------------------------------------

class _Leaf {
  final Object? key;
  final int hash;
  final int position;
  const _Leaf(this.key, this.hash, this.position);
}

/// Leaves whose keys have the same (masked) hash.
class _Collision {
  final int hash;
  final List<_Leaf> leaves;
  const _Collision(this.hash, this.leaves);
}

/// A node with a slot for each set bit of [bitmap], in bit order; a slot is a
/// [_Leaf], a [_Collision] or a child [_Node].
class _Node {
  final int bitmap;
  final List<Object> slots;
  const _Node(this.bitmap, this.slots);
}

abstract final class _Hamt {
  static const int _bits = 5;
  static const int _mask = (1 << _bits) - 1;

  /// Hashes are cut to 30 bits: six 5-bit digits, so two different hashes
  /// always part within the trie's depth.
  static const int hashMask = 0x3fffffff;

  static int? find(Object? node, Object? key, int hash) {
    var shift = 0;
    var current = node;
    while (true) {
      switch (current) {
        case _Node(:final bitmap, :final slots):
          final bit = 1 << ((hash >> shift) & _mask);
          if (bitmap & bit == 0) return null;
          current = slots[_bitCount(bitmap & (bit - 1))];
          shift += _bits;
        case _Leaf(key: final leafKey, hash: final leafHash, :final position):
          return leafHash == hash && leafKey == key ? position : null;
        case _Collision(hash: final collisionHash, :final leaves):
          if (collisionHash != hash) return null;
          for (final leaf in leaves) {
            if (leaf.key == key) return leaf.position;
          }
          return null;
        default:
          return null;
      }
    }
  }

  /// [node] with [leaf] added; [leaf]'s key must not be present.
  static Object insert(Object? node, int shift, _Leaf leaf) {
    switch (node) {
      case null:
        return leaf;
      case _Leaf():
        if (node.hash == leaf.hash) {
          PersistentMapStats.copiedSlots += 2;
          return _Collision(leaf.hash, [node, leaf]);
        }
        return _merge(node, node.hash, leaf, shift);
      case _Collision():
        if (node.hash == leaf.hash) {
          PersistentMapStats.copiedSlots += node.leaves.length + 1;
          return _Collision(node.hash, [...node.leaves, leaf]);
        }
        return _merge(node, node.hash, leaf, shift);
      case _Node(:final bitmap, :final slots):
        final bit = 1 << ((leaf.hash >> shift) & _mask);
        final at = _bitCount(bitmap & (bit - 1));
        if (bitmap & bit == 0) {
          PersistentMapStats.copiedSlots += slots.length + 1;
          return _Node(bitmap | bit, [...slots.sublist(0, at), leaf, ...slots.sublist(at)]);
        }
        final copy = List<Object>.of(slots, growable: false);
        PersistentMapStats.copiedSlots += copy.length;
        copy[at] = insert(slots[at], shift + _bits, leaf);
        return _Node(bitmap, copy);
      default:
        throw StateError('Corrupt PersistentMap index node: ${node.runtimeType}');
    }
  }

  /// A node holding [existing] (hash [existingHash]) and [leaf], whose
  /// hashes differ.
  static _Node _merge(Object existing, int existingHash, _Leaf leaf, int shift) {
    final a = (existingHash >> shift) & _mask;
    final b = (leaf.hash >> shift) & _mask;
    PersistentMapStats.copiedSlots += 2;
    if (a == b) return _Node(1 << a, [_merge(existing, existingHash, leaf, shift + _bits)]);
    return _Node((1 << a) | (1 << b), a < b ? [existing, leaf] : [leaf, existing]);
  }

  /// [node] without [key] (null when nothing is left); [node] itself when
  /// [key] is absent.
  static Object? remove(Object? node, int shift, Object? key, int hash) {
    switch (node) {
      case _Leaf():
        return node.hash == hash && node.key == key ? null : node;
      case _Collision():
        if (node.hash != hash) return node;
        final rest = [for (final leaf in node.leaves) if (leaf.key != key) leaf];
        if (rest.length == node.leaves.length) return node;
        PersistentMapStats.copiedSlots += rest.length;
        return rest.length == 1 ? rest.single : _Collision(hash, rest);
      case _Node(:final bitmap, :final slots):
        final bit = 1 << ((hash >> shift) & _mask);
        if (bitmap & bit == 0) return node;
        final at = _bitCount(bitmap & (bit - 1));
        final child = remove(slots[at], shift + _bits, key, hash);
        if (identical(child, slots[at])) return node;
        if (child == null) {
          if (slots.length == 1) return null;
          PersistentMapStats.copiedSlots += slots.length - 1;
          return _Node(bitmap & ~bit, [...slots.sublist(0, at), ...slots.sublist(at + 1)]);
        }
        final copy = List<Object>.of(slots, growable: false);
        PersistentMapStats.copiedSlots += copy.length;
        copy[at] = child;
        return _Node(bitmap, copy);
      default:
        return node;
    }
  }

  static int _bitCount(int value) {
    var v = value & 0xffffffff;
    v = v - ((v >>> 1) & 0x55555555);
    v = (v & 0x33333333) + ((v >>> 2) & 0x33333333);
    v = (v + (v >>> 4)) & 0x0f0f0f0f;
    return (_byteSum(v)) & 0x3f;
  }

  static int _byteSum(int v) => (v & 0xff) + ((v >>> 8) & 0xff) + ((v >>> 16) & 0xff) + ((v >>> 24) & 0xff);
}

/// [value] with every map a [PersistentMap] and every list unmodifiable,
/// recursively (map keys as strings). A [PersistentMap] is returned as is: it
/// was frozen when it was built.
Object? freezeDeep(Object? value) => switch (value) {
      PersistentMap() => value,
      Map() => PersistentMap<String, dynamic>.of(<String, dynamic>{
          for (final e in value.entries) e.key.toString(): freezeDeep(e.value),
        }),
      List() => List<dynamic>.unmodifiable(value.map(freezeDeep)),
      _ => value,
    };

/// [value] frozen as a `Map<String, dynamic>` ([freezeDeep]).
PersistentMap<String, dynamic> freezeMap(Map value) => freezeDeep(value) as PersistentMap<String, dynamic>;

/// [value] as an unmodifiable plain copy: maps `Map<String, dynamic>`,
/// lists unmodifiable, recursively. For values that leave the aggregate as
/// ordinary objects (a UTXO's plugin metadata).
Object? unmodifiableDeepCopy(Object? value) => switch (value) {
      Map() => Map<String, dynamic>.unmodifiable(<String, dynamic>{
          for (final e in value.entries) e.key.toString(): unmodifiableDeepCopy(e.value),
        }),
      List() => List<dynamic>.unmodifiable(value.map(unmodifiableDeepCopy)),
      _ => value,
    };

/// [value] copied into an unmodifiable list.
///
/// For the collections an event or command is handed (bead libspiffy-6r5w):
/// the caller keeps its own list and may go on changing it, and what the
/// event holds - what the projection, the subscribers and the broadcaster
/// read - is a copy nobody else has a handle on. Elements must be immutable
/// values; use [frozenMapList] for a list of maps.
List<T> frozenList<T>(Iterable<T> value) => List<T>.unmodifiable(value);

/// [frozenList] for a field that may be null.
List<T>? frozenListOrNull<T>(Iterable<T>? value) => value == null ? null : List<T>.unmodifiable(value);

/// A list of maps copied and frozen to every depth, so neither the list nor
/// any map in it can be changed through the caller's handle.
List<Map<String, dynamic>> frozenMapList(Iterable<Map<String, dynamic>> value) =>
    List<Map<String, dynamic>>.unmodifiable(
        value.map((entry) => unmodifiableDeepCopy(entry) as Map<String, dynamic>));

/// A map copied and frozen to every depth, as an ordinary [Map] rather than
/// the [PersistentMap] of [freezeMap]: events and commands carry plain maps.
Map<String, dynamic> frozenPlainMap(Map<String, dynamic> value) =>
    unmodifiableDeepCopy(value) as Map<String, dynamic>;

/// [frozenPlainMap] for a field that may be null.
Map<String, dynamic>? frozenPlainMapOrNull(Map<String, dynamic>? value) =>
    value == null ? null : unmodifiableDeepCopy(value) as Map<String, dynamic>;

/// [value] copied into an unmodifiable set, the [frozenList] of sets.
Set<T> frozenSet<T>(Iterable<T> value) => Set<T>.unmodifiable(value);

/// [frozenSet] for a field that may be null.
Set<T>? frozenSetOrNull<T>(Iterable<T>? value) => value == null ? null : Set<T>.unmodifiable(value);
