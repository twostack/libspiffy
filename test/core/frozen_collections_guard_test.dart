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
/// Scope was first what a caller outside libspiffy hands IN: the aggregate
/// events and commands, and the app -> coordinator commands (68 fields).
///
/// Bead libspiffy-a0fk extended it to both remaining directions (71 more):
///
/// * The coordinator's **outbound** events, below the EVENTS banner in
///   coordinator_messages.dart. Freezing a result is a behaviour change - an
///   app that sorts one in place now gets UnsupportedError - and it was
///   settled on the same evidence as 6r5w, not by preference: `events` is a
///   `StreamController.broadcast`, so one instance reaches EVERY subscriber,
///   and an app listener sorting its "own" result reorders it for the
///   others. It is not the app's copy.
/// * The **internal** actor messages (wallet, spv, invoice, payment). These
///   are libspiffy -> libspiffy, the same property and the same one line.
///
/// Before freezing, lib/ was searched for in-place mutation of every one of
/// the 71: none. The whole of coordinator_messages.dart is scanned now.
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
  'lib/src/actors/coordinator_messages.dart': null,
  'lib/src/actors/wallet_messages.dart': null,
  'lib/src/actors/spv_messages.dart': null,
  'lib/src/actors/invoice_messages.dart': null,
  'lib/src/actors/payment_messages.dart': null,
};

/// Collection fields the scan finds: 68 when 6r5w closed, 139 once a0fk
/// added the outbound events and the internal messages, 140 with
/// `BEEFValidationResultEvent.unreadableOutputs` (xggs), 139 again once
/// `FeeQuoteMessage` went (bg7n: ARC answers a `FeeRate`, which holds no
/// collection). A new one must be frozen, and adding it must bump this
/// number deliberately: 140 with `SPVValidationResult.invoicePaidAddresses`
/// (yyby: what a payment pays its invoice, for the coordinator to mark it
/// paid with once the network holds the payment), 139 again once the dead
/// `SPVControlMessage` went with its frozen `parameters` map, 144 with the
/// offline-payee hand-off (m8qu: `RecordDelegatedAddressesCommand
/// .derivationIndices`, `ImportTransactionCommand.delegatedIndices`,
/// `TransactionExportedEvent.beef` and `DelegatedAddressesRecordedResponse
/// .addresses` and `.journaled`), 147 once an invoice reports the addresses
/// it issued and an export the delegated indices it pays
/// (`InvoiceCreatedMessage.issuedAddresses`, `InvoiceCreatedEvent
/// .issuedAddresses`, `TransactionExportedEvent.delegatedIndices`).
const _expectedFields = 147;

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
