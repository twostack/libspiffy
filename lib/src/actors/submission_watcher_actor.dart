import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:logging/logging.dart';

import '../models/deferred_payment.dart' show DeferredNetworkStatus;
import '../services/arc_service.dart';

/// Follows a submission ARC answered in flight
/// ([DeferredNetworkStatus.inFlight]) until ARC gives it a status that is
/// not, and hands that answer back to whoever asked.
///
/// ARC's answer to a submission says where it had got to. ARC itself waited
/// for the network a few seconds before answering; Arcade answers every
/// submission RECEIVED at once and takes it to the network afterwards
/// (ACCEPTED_BY_NETWORK, then SEEN_ON_NETWORK when a miner has it in a
/// subtree). A caller deciding on the answer (a payment's invoice, a
/// channel's funding) needs the status the network got to, so ARCActor
/// hands every in-flight answer here and answers its caller with what this
/// actor finds.
///
/// It asks ARC after each of [delays] (measured from the previous answer)
/// and stops at the first status that is not in flight, or after the last
/// delay with the latest answer it has. Nothing here waits in the mailbox:
/// each wait is a timer message and each query's answer is a message to
/// itself, so any number of submissions are followed at once and ARCActor
/// is never held.
class SubmissionWatcherActor extends Actor {
  final _log = Logger('SubmissionWatcherActor');

  /// The ARC client (an [ArcService], or a test double with the same
  /// `getTransaction`).
  final dynamic _arcService;

  /// How long to wait before each query of a followed submission.
  final List<Duration> delays;

  final Map<int, _Followed> _followed = {};

  SubmissionWatcherActor({required dynamic arcService, required this.delays}) : _arcService = arcService;

  @override
  Future<void> onMessage(dynamic message) async {
    switch (message) {
      case final FollowSubmissionMessage msg:
        _followed[msg.token] = _Followed(msg.txid, msg.answer, msg.owner);
        _schedule(msg.token);
      case _Query(:final token):
        _query(token);
      case final _Answered answered:
        _onAnswer(answered);
      case StopFollowingMessage():
        for (final token in _followed.keys) {
          context.timers.cancel(_timerKey(token));
        }
        _followed.clear();
    }
  }

  static String _timerKey(int token) => 'follow-$token';

  void _schedule(int token) {
    final followed = _followed[token];
    if (followed == null) return;
    if (followed.queries >= delays.length) {
      _settle(token);
      return;
    }
    context.timers.startSingleTimer(_timerKey(token), _Query(token), delays[followed.queries]);
  }

  void _query(int token) {
    final followed = _followed[token];
    if (followed == null) return;
    followed.queries++;
    final self = context.self;
    unawaited(Future(() => _arcService.getTransaction(followed.txid) as Future<ArcTransactionResponse>).then(
      (status) => self.tell(LocalMessage(payload: _Answered(token, ArcSubmitResponse.fromStatus(status)))),
      onError: (Object e) => self.tell(LocalMessage(payload: _Answered(token, null, e))),
    ));
  }

  void _onAnswer(_Answered answered) {
    final followed = _followed[answered.token];
    if (followed == null) return;
    final answer = answered.answer;
    if (answer == null) {
      // Not known yet (404) or not reachable: the answer in hand stands.
      _log.fine('Following ${followed.txid}: ARC did not answer (${answered.error}); '
          'keeping ${followed.answer.status.wireName}');
    } else {
      if (answer.status != followed.answer.status) {
        _log.info('Following ${followed.txid}: ${followed.answer.status.wireName} -> ${answer.status.wireName}');
      }
      followed.answer = answer;
      if (!DeferredNetworkStatus.isInFlight(answer.status.wireName)) {
        _settle(answered.token);
        return;
      }
    }
    _schedule(answered.token);
  }

  void _settle(int token) {
    final followed = _followed.remove(token);
    if (followed == null) return;
    context.timers.cancel(_timerKey(token));
    followed.owner.tell(LocalMessage(payload: SubmissionSettledMessage(token, followed.answer)));
  }
}

class _Followed {
  final String txid;
  final ActorRef owner;
  ArcSubmitResponse answer;
  int queries = 0;

  _Followed(this.txid, this.answer, this.owner);
}

class _Query {
  final int token;
  const _Query(this.token);
}

class _Answered {
  final int token;
  final ArcSubmitResponse? answer;
  final Object? error;
  const _Answered(this.token, this.answer, [this.error]);
}

/// Follow the submission of [txid], which ARC answered [answer] (in
/// flight), and tell [owner] [SubmissionSettledMessage] with [token] once
/// ARC gives it a status that is not in flight, or the follow runs out.
class FollowSubmissionMessage {
  final int token;
  final String txid;
  final ArcSubmitResponse answer;
  final ActorRef owner;

  const FollowSubmissionMessage({required this.token, required this.txid, required this.answer, required this.owner});
}

/// The answer ARC got to for the submission followed under [token]: the
/// first that is not in flight, or the latest when the follow ran out.
class SubmissionSettledMessage {
  final int token;
  final ArcSubmitResponse answer;

  const SubmissionSettledMessage(this.token, this.answer);
}

/// Stop following every submission; nobody is told of them.
class StopFollowingMessage {
  const StopFollowingMessage();
}
