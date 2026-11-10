import 'dart:async';

import 'package:logging/logging.dart';

import 'cdn_manifest.dart';

/// Fills in the headers below a chain that started at a built-in checkpoint
/// (epic spiffyvault-emk, step emk.3), one step at a time, in the
/// background, until it reaches genesis.
///
/// * Before each step it asks [mayDownload] (an app on a phone answers
///   true only on Wi-Fi); while the answer is no it asks again every
///   [notAllowedWait].
/// * A step that fails (no network, the CDN down, a chunk that does not
///   check out) is tried again after [firstRetry], doubling up to
///   [maxRetry].
/// * [stop] ends it between steps, and cuts short any wait.
///
/// Where the fill stopped is read from storage by each step, so nothing
/// needs saving here: a restart carries on.
class HeaderBackfillRunner {
  /// One step: `CdnHeaderSyncService.backfillNext`.
  final Future<CdnBackfillStep> Function() step;
  final Future<bool> Function() mayDownload;

  /// Called after every step that stored headers.
  final void Function(CdnBackfillStep step) onStored;

  final Duration notAllowedWait;
  final Duration firstRetry;
  final Duration maxRetry;

  final Logger _log;
  final _stopped = Completer<void>();

  HeaderBackfillRunner({
    required this.step,
    required this.onStored,
    Future<bool> Function()? mayDownload,
    this.notAllowedWait = const Duration(minutes: 5),
    this.firstRetry = const Duration(minutes: 1),
    this.maxRetry = const Duration(minutes: 30),
    Logger? logger,
  })  : mayDownload = mayDownload ?? _always,
        _log = logger ?? Logger('HeaderBackfill');

  static Future<bool> _always() async => true;

  bool get isStopped => _stopped.isCompleted;

  /// Ends the fill between steps; any wait ends at once.
  void stop() {
    if (!_stopped.isCompleted) _stopped.complete();
  }

  /// Runs until every header down to genesis is held, or until [stop].
  /// Returns true when the fill is complete.
  Future<bool> run() async {
    var retry = firstRetry;
    while (!isStopped) {
      bool allowed;
      try {
        allowed = await mayDownload();
      } catch (e) {
        _log.warning('Could not tell whether headers may be downloaded now: $e');
        allowed = false;
      }
      if (isStopped) break;
      if (!allowed) {
        await _wait(notAllowedWait);
        continue;
      }
      try {
        final done = await step();
        if (isStopped) break;
        if (done.headersStored > 0) onStored(done);
        if (done.complete) {
          _log.info('Every header down to genesis is held');
          return true;
        }
        retry = firstRetry;
      } catch (e) {
        if (isStopped) break;
        _log.warning('Filling in older headers stopped: $e; trying again in ${retry.inSeconds}s');
        await _wait(retry);
        final doubled = retry * 2;
        retry = doubled > maxRetry ? maxRetry : doubled;
      }
    }
    return false;
  }

  Future<void> _wait(Duration d) => Future.any([Future<void>.delayed(d), _stopped.future]);
}
