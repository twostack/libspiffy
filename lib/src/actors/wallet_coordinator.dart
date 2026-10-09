import 'dart:async';

import 'package:dactor/dactor.dart';

import 'coordinator_messages.dart';
import 'wallet_coordinator_actor.dart';

/// The coordinator, as an application talks to it: send a command and wait
/// for its own answer ([ask]), send one and leave the answer on the event
/// stream ([tell]), or follow the events of one kind ([on]).
///
/// ```dart
/// final invoice = await libspiffy.coordinator
///     .ask(CreateInvoiceCommand(walletId: 'bob', amount: BigInt.from(1000)));
/// libspiffy.coordinator.on<BalanceUpdatedEvent>(walletId: 'bob').listen(render);
/// ```
class WalletCoordinator {
  final ActorRef _ref;
  final WalletCoordinatorActor _actor;

  WalletCoordinator(this._ref, this._actor);

  /// Sends [command]. Its answer, if it has one, arrives on the event stream.
  void tell(Message command) => _ref.tell(command);

  /// Sends [request] and completes with its reply.
  ///
  /// The reply is the one carrying [request]'s `requestId`, whatever else
  /// is on the event stream: two requests of one kind running at once each
  /// get their own. It is still published on the event stream as well.
  ///
  /// Throws [CoordinatorFailure] when the request failed: its reply reports
  /// a [CoordinatorReply.failure], or an [ErrorEvent] names the request
  /// (the failure carries either as `event`), or the coordinator stopped
  /// before it answered ([CoordinatorFailure.closed]). A reply returned is
  /// therefore a success.
  ///
  /// Throws [TimeoutException] when no reply arrives within [timeout]
  /// (default [CoordinatorRequest.replyTimeout]). **A timeout does not
  /// cancel the request**: it may still finish — a payment it validated may
  /// already be broadcast — and its reply then arrives on the event stream
  /// only.
  Future<R> ask<R extends CoordinatorReply>(CoordinatorRequest<R> request, {Duration? timeout}) async {
    final answer = _actor.awaitReply(request.requestId);
    _ref.tell(request);
    final limit = timeout ?? request.replyTimeout;
    final CoordinatorEvent event;
    try {
      event = await answer.timeout(limit);
    } on TimeoutException {
      _actor.forgetReply(request.requestId);
      throw TimeoutException(
          'No reply to ${request.runtimeType} ${request.requestId} within $limit; '
          'it may still finish, and its reply then arrives on the event stream',
          limit);
    }
    switch (event) {
      case ErrorEvent(:final message):
        throw CoordinatorFailure(request.requestId, message, event: event);
      case CoordinatorReply(:final failure?):
        throw CoordinatorFailure(request.requestId, failure, event: event);
      case R():
        return event;
      default:
        throw StateError('${request.runtimeType} ${request.requestId} was answered with '
            '${event.runtimeType}, not $R');
    }
  }

  /// The events of type [E], of wallet [walletId] when given.
  Stream<E> on<E extends CoordinatorEvent>({String? walletId}) => _actor.events
      .where((event) => event is E && (walletId == null || event.walletId == walletId))
      .cast<E>();
}
