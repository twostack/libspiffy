import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';

/// Resolves with null once [projection] has applied an event satisfying
/// [matches], or its effect is already in the read model
/// ([alreadyApplied]); otherwise with the reason it was not applied.
///
/// A command's events may be applied before an awaiter can be registered,
/// and an awaiter only matches events applied after it (A-M2). So:
/// 1. register the awaiter;
/// 2. send GetProjectionInfo behind it. The projection's mailbox is FIFO,
///    so its reply proves the awaiter is registered: every event applied
///    from then on resolves the awaiter, and every event applied before
///    has finished its read-model write;
/// 3. then ask [alreadyApplied]. True means "already applied".
Future<String?> awaitProjectionApplied(
  ActorRef projection, {
  required bool Function(Event e) matches,
  required Future<bool> Function() alreadyApplied,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final applied = projection.ask<dynamic>(
    AwaitEventApplied(matches, timeout: timeout),
    // The ask must outlast the awaiter's own window, otherwise dactor's
    // default (5 s) fires first and a slow projection looks like a failure.
    timeout + const Duration(seconds: 2),
  );
  // Whichever branch loses must not surface as an unhandled error.
  final appliedOutcome = applied.then<String?>(
    (response) => response is AwaitFailed ? response.reason : null,
    onError: (Object e) => e.toString(),
  );

  final applyVisible = () async {
    try {
      await projection.ask<dynamic>(GetProjectionInfo(), timeout);
      return await alreadyApplied();
    } catch (_) {
      return false; // No barrier answer: rely on the awaiter alone.
    }
  }();

  final first = await Future.any<Object?>([
    appliedOutcome.then((reason) => _AwaiterOutcome(reason)),
    applyVisible,
  ]);
  if (first is _AwaiterOutcome) return first.reason;
  if (first == true) return null;
  return appliedOutcome;
}

class _AwaiterOutcome {
  final String? reason;
  const _AwaiterOutcome(this.reason);
}
