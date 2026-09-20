/// Static guard for bead libspiffy-6r5w: an event or command never keeps a
/// caller's collection.
///
/// mmb made aggregate state copy-on-write but left the events and commands
/// that carry collections into it sharing the caller's list or map. An event
/// is not private: the projection, every coordinator subscriber and the P2P
/// broadcaster all read the same instance, so a caller that went on
/// modifying the list it had passed changed what all of them saw. The
/// journal escaped only because serialization copies.
///
/// The fix is one line per field - `x = frozenList(x)` and friends from
/// `models/persistent_map.dart` - which is exactly the kind of fix that
/// drifts: the next event class is written by copying an existing one, and
/// `required this.x` is shorter than the initializer. The behavioural tests
/// in aggregate_state_immutability_test.dart ('6r5w: events and commands')
/// pin a handful of fields; this pins all of them, so a 69th arrives red
/// rather than unnoticed.
///
/// Scope is what a caller outside libspiffy hands IN: the aggregate events
/// and commands, and the app -> coordinator commands. The coordinator's
/// outbound events (below the EVENTS banner in coordinator_messages.dart)
/// carry lists libspiffy built for that one message and are a separate
/// question - freezing them would change what an app may do with a result
/// it was given (bead libspiffy-a0fk).
library;

import 'dart:io';
import 'package:test/test.dart';

/// Sources scanned, with the marker that ends the scanned region (null for
/// the whole file).
const _sources = <String, String?>{
  'lib/src/core/wallet_events.dart': null,
  'lib/src/core/wallet_commands.dart': null,
  'lib/src/core/invoice_events.dart': null,
  'lib/src/core/invoice_commands.dart': null,
  'lib/src/core/channel_events.dart': null,
  'lib/src/core/channel_commands.dart': null,
  'lib/src/actors/coordinator_messages.dart':
      '// EVENTS (coordinator → app via broadcast stream)',
};

/// Collection fields the scan found when 6r5w closed. A new one must be
/// frozen, and adding it must bump this number deliberately.
const _expectedFields = 68;

final _classStart = RegExp(r'^(?:abstract |sealed )?class (\w+)', multiLine: true);
final _field = RegExp(r'^  final ((?:List|Map|Set)<.*?>\??) (\w+);(?: *//.*)?$', multiLine: true);

void main() {
  test('every collection an event or command is handed is copied and frozen', () {
    final unfrozen = <String>[];
    var found = 0;
    for (final entry in _sources.entries) {
      final path = entry.key;
      var source = File(path).readAsStringSync();
      final marker = entry.value;
      if (marker != null) {
        expect(source, contains(marker), reason: '$path: scan marker moved');
        source = source.substring(0, source.indexOf(marker));
      }
      var fileFound = 0;
      for (final body in _classBodies(source)) {
        for (final field in _field.allMatches(body.source)) {
          final name = field.group(2)!;
          found++;
          fileFound++;
          if (!RegExp('\\b$name = frozen\\w*\\(').hasMatch(body.source)) {
            unfrozen.add('$path: ${body.name}.$name (${field.group(1)})');
          }
        }
      }
      expect(fileFound, greaterThan(0), reason: '$path: no collection fields found - moved?');
    }

    expect(unfrozen, isEmpty,
        reason: 'these fields keep the caller\'s collection:\n${unfrozen.join('\n')}');
    expect(found, _expectedFields,
        reason: 'the scan found $found collection fields, not $_expectedFields: '
            'a field was added or removed - freeze it and update the count');
  });
}

/// The classes in [source], each with its body text.
Iterable<({String name, String source})> _classBodies(String source) sync* {
  final starts = _classStart.allMatches(source).toList();
  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1].start : source.length;
    yield (name: starts[i].group(1)!, source: source.substring(starts[i].start, end));
  }
}
