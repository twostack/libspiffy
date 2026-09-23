/// Static guard for bead libspiffy-7ye4: a public event nothing emits is a
/// promise the library does not keep.
///
/// Four exported things were found that an application could build against
/// and hear nothing from, and three of them were `CoordinatorEvent`
/// subclasses: `BalanceUpdatedEvent`, `UTXOSplitStartedEvent` and
/// `HeaderSyncProgressEvent`. Each had a name, fields and a doc comment that
/// described exactly what an app wanted, and nothing in `lib/` ever
/// constructed one. Two are now emitted (V-166, V-167) and the third was
/// deleted, because the CDN sync already reports its progress through
/// `LibSpiffyActorSystem.initialize(onHeaderSyncProgress:)` and stored
/// headers already arrive as `BlockHeadersStoredEvent`.
///
/// They were found by reading the whole event list against the library, one
/// name at a time. That is how the next one would have to be found too, and
/// it is not the kind of check anyone repeats. So it is a test.
///
/// Nothing here is exempt, and nothing should need to be. An event the
/// library cannot emit is either a defect (emit it) or dead (delete it);
/// there is no third answer that leaves an application listening to silence.
library;

import 'dart:io';
import 'package:test/test.dart';

const _events = 'lib/src/actors/coordinator_messages.dart';

/// Every `class X extends CoordinatorEvent` declared in [_events].
List<String> _declaredEvents() {
  final source = File(_events).readAsStringSync();
  return RegExp(r'^class (\w+) extends CoordinatorEvent\b', multiLine: true)
      .allMatches(source)
      .map((m) => m.group(1)!)
      .toList();
}

/// Every Dart file of the library except the one that declares the events.
List<File> _libraryFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart') && f.path != _events)
    .toList();

void main() {
  test('every public coordinator event is emitted by the library', () {
    final declared = _declaredEvents();
    expect(declared, isNotEmpty,
        reason: 'the scan found no events at all, so it is not scanning');

    final sources = {
      for (final file in _libraryFiles()) file.path: file.readAsStringSync(),
    };

    final unemitted = <String>[];
    for (final event in declared) {
      // A constructor call: the name followed by its argument list. Import
      // prefixes (`coord.ErrorEvent(`) match too, since the name is what is
      // looked for and the prefix sits before it.
      final constructed = RegExp('\\b$event\\s*\\(');
      if (!sources.values.any(constructed.hasMatch)) unemitted.add(event);
    }

    expect(unemitted, isEmpty,
        reason: 'These public events are declared and nothing in lib/ ever '
            'constructs one, so an application that listens for them waits '
            'forever. Emit each, or delete it (bead libspiffy-7ye4):\n'
            '  ${unemitted.join('\n  ')}');
  });
}
