import 'dart:async';
import 'package:isar/isar.dart';

/// Process-wide singleton for Isar native library initialization.
///
/// Ensures [Isar.initializeIsarCore] is called exactly once, even when
/// multiple test files run concurrently in the same VM process.
///
/// Usage in test files:
/// ```dart
/// setUpAll(() async {
///   await ensureIsarInitialized();
/// });
/// ```
Completer<void>? _initCompleter;

Future<void> ensureIsarInitialized() async {
  if (_initCompleter != null) {
    return _initCompleter!.future;
  }
  _initCompleter = Completer<void>();
  try {
    await Isar.initializeIsarCore(download: true);
    _initCompleter!.complete();
  } catch (e) {
    // initializeIsarCore throws if already initialized — that's fine
    if (e.toString().contains('already initialized') ||
        e.toString().contains('Isar Core is already initialized')) {
      _initCompleter!.complete();
    } else {
      _initCompleter!.completeError(e);
      _initCompleter = null;
      rethrow;
    }
  }
}
