// An actor reaching its own context is the intended use of dactor's
// @internal `Actor.context`.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

/// The failure a command gets when it reaches an aggregate that an earlier
/// journal failure took out of service (bead libspiffy-u0x): the command was
/// not processed and nothing was journaled for it. Sending it again reaches
/// an aggregate recovered from the journal.
class AggregateOutOfServiceException implements Exception {
  final String persistenceId;
  final String commandType;

  AggregateOutOfServiceException(this.persistenceId, this.commandType);

  @override
  String toString() => 'AggregateOutOfServiceException: $commandType not processed: $persistenceId is out '
      'of service after a journal write failed for an earlier command; send it again to reach an aggregate '
      'recovered from the journal';
}

/// Keeps a rejected command from stopping the aggregate actor
/// (libspiffy-201), and never drops a command queued behind a journal failure
/// (libspiffy-u0x).
///
/// eventador's [AggregateRoot] answers a failed command through
/// `onCommandFailure` and then rethrows, and dactor stops an unsupervised
/// actor whose `onMessage` throws. libspiffy's managers spawn their
/// aggregates unsupervised, so every command the aggregate rejected used to
/// stop it while the manager kept the dead ref. This mixin splits command
/// failures in two:
///
/// * A **rejection** fails before anything is written to the journal: a
///   business rule, an invalid argument, command validation. The aggregate's
///   state is untouched, the caller has its failure reply, and the actor
///   keeps running. A bad command costs no journal recovery, so a peer
///   cannot make a large wallet replay its journal by sending invalid
///   requests.
/// * An **infrastructure failure** happens once a journal write has started
///   (the event store threw, an event could not be applied, the snapshot or
///   post-persist hook failed) or is an [OptimisticConcurrencyException].
///   The in-memory state and sequence number may no longer match the
///   journal, so this incarnation must not serve another command. It is
///   marked retiring ([isRetiring]) before the failure reply is sent, so a
///   manager that sees the reply already replaces it with an aggregate
///   recovered from the journal. It returns normally rather than rethrowing,
///   so dactor does not stop it.
///
/// A retiring incarnation keeps running until its manager [retire]s it:
/// dactor discards the mailbox of a stopped actor, so stopping at once lost
/// every command already queued behind the failed one. Until then each
/// command that reaches it is answered with its usual failure reply for an
/// [AggregateOutOfServiceException] (not processed, safe to send again), and
/// it stops when the retire request, which its manager sends after its last
/// command to it, comes out of the mailbox. A failure reply rather than a
/// retry: a queued command may have been sent on the assumption that the one
/// ahead of it succeeded, so only its caller can decide to send it again.
/// Other messages queued to it are not answered (logged): its state may not
/// match the journal.
///
/// The classification is [isInfrastructureFailure]. Outside an actor system
/// (aggregates driven directly through `commandHandler` in tests) nothing
/// changes: failures still throw.
mixin CommandFailureContainment<TState extends State> on AggregateRoot<TState> {
  static final _log = Logger('CommandFailureContainment');

  /// Retirement of each out-of-service incarnation, by its ref; completed
  /// when it has stopped.
  static final Expando<Completer<void>> _retirements = Expando('aggregate retirement');

  /// Whether the aggregate behind [ref] was taken out of service by a journal
  /// failure. A manager must not send it further commands: [retire] it and
  /// recover a replacement from the journal.
  static bool isRetiring(ActorRef ref) => _retirements[ref] != null;

  /// Asks the out-of-service aggregate behind [ref] to stop once it has
  /// answered every message queued to it before this request. Completes when
  /// it has stopped (at once for an aggregate that is not retiring).
  static Future<void> retire(ActorRef ref) {
    final retirement = _retirements[ref];
    if (retirement == null || retirement.isCompleted) return Future.value();
    if (ref.isAlive) {
      ref.tell(LocalMessage(payload: _retireRequest));
    } else {
      retirement.complete();
    }
    return retirement.future;
  }

  static const Object _retireRequest = _RetireAggregate();

  /// Whether the command being processed has started writing to the journal.
  ///
  /// Set and cleared only under PersistentActor's command lock (in
  /// [commandHandler] and the persist calls it makes), so one flag suffices.
  /// It is cleared again when a command succeeds, so a command that fails
  /// before reaching [commandHandler] (command validation) does not see a
  /// previous command's write. After an infrastructure failure it stays set,
  /// but that incarnation serves no further command.
  bool _journalWriteStarted = false;

  bool _outOfService = false;

  /// True once an infrastructure failure has taken this incarnation out of
  /// service.
  @visibleForTesting
  bool get isOutOfService => _outOfService;

  /// Whether [error], raised while processing the current command, is an
  /// infrastructure failure (see the mixin documentation) rather than a
  /// rejection of the command.
  @protected
  bool isInfrastructureFailure(Object? error) =>
      _journalWriteStarted || error is OptimisticConcurrencyException;

  @override
  Future<void> commandHandler(Command command) async {
    _journalWriteStarted = false;
    await super.commandHandler(command);
    _journalWriteStarted = false;
  }

  @override
  Future<void> persistEvent(Event event) {
    _journalWriteStarted = true;
    return super.persistEvent(event);
  }

  @override
  Future<void> persistEvents(List<Event> events) {
    if (events.isNotEmpty) _journalWriteStarted = true;
    return super.persistEvents(events);
  }

  /// Runs before the subclass sends its failure reply (subclasses call
  /// `super.onCommandFailure` first), so an infrastructure failure marks the
  /// actor retiring before the caller hears about it.
  @override
  Future<void> onCommandFailure(Command command, dynamic error) async {
    await super.onCommandFailure(command, error);
    if (_outOfService || !isInfrastructureFailure(error) || !_runsAsActor) {
      return;
    }
    _outOfService = true;
    _retirements[context.self] = Completer<void>();
    _log.severe('$persistenceId: ${command.runtimeType} failed after the '
        'journal write started; this aggregate is out of service: commands '
        'queued to it are answered with a failure, and the next command '
        'reaches an aggregate recovered from the journal: $error');
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (identical(message, _retireRequest)) {
      if (_runsAsActor) await context.system.stop(context.self);
      return;
    }
    if (_outOfService) {
      if (message is Command) {
        // Answered like any failure of this command; nothing is processed.
        await onCommandFailure(message, AggregateOutOfServiceException(persistenceId, message.runtimeType.toString()));
      } else {
        _log.warning('$persistenceId is out of service after a journal failure; '
            '${message.runtimeType} not answered');
      }
      return;
    }
    if (message is! Command) {
      return super.onMessage(message);
    }
    try {
      await super.onMessage(message);
    } catch (error) {
      if (_outOfService) {
        // An infrastructure failure: onCommandFailure (under the command
        // lock) took this incarnation out of service and the caller has
        // been answered. Rethrowing would make dactor stop it and discard
        // the commands queued behind this one.
        return;
      }
      if (isInfrastructureFailure(error)) {
        rethrow;
      }
      // A rejection: onCommandFailure has answered the caller.
      _log.fine('$persistenceId: rejected ${message.runtimeType}: $error');
    }
  }

  @override
  void postStop() {
    super.postStop();
    if (!_runsAsActor) return;
    final retirement = _retirements[context.self];
    if (retirement != null && !retirement.isCompleted) retirement.complete();
  }

  bool get _runsAsActor {
    try {
      context;
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// The request [CommandFailureContainment.retire] sends.
class _RetireAggregate {
  const _RetireAggregate();
}
