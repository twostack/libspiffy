// An actor reaching its own context is the intended use of dactor's
// @internal `Actor.context`.
// ignore_for_file: invalid_use_of_internal_member

import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

/// Keeps a rejected command from stopping the aggregate actor
/// (libspiffy-201).
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
///   journal, so this incarnation must not serve another command. It stops
///   itself before the failure reply is sent: a manager that sees the reply
///   already sees a dead ref and replaces it with an aggregate recovered
///   from the journal. It then returns normally rather than rethrowing, so
///   dactor (which stops actors by id) cannot stop that replacement.
///
/// The classification is [isInfrastructureFailure]. Outside an actor system
/// (aggregates driven directly through `commandHandler` in tests) nothing
/// changes: failures still throw.
mixin CommandFailureContainment<TState extends State> on AggregateRoot<TState> {
  static final _log = Logger('CommandFailureContainment');

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

  /// True once an infrastructure failure has stopped this incarnation.
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
  /// `super.onCommandFailure` first), so an infrastructure failure stops the
  /// actor before the caller hears about it.
  @override
  Future<void> onCommandFailure(Command command, dynamic error) async {
    await super.onCommandFailure(command, error);
    if (_outOfService || !isInfrastructureFailure(error) || !_runsAsActor) {
      return;
    }
    _outOfService = true;
    _log.severe('$persistenceId: ${command.runtimeType} failed after the '
        'journal write started; stopping this aggregate so the next command '
        'recovers it from the journal: $error');
    await context.system.stop(context.self);
  }

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! Command) {
      return super.onMessage(message);
    }
    try {
      await super.onMessage(message);
    } catch (error) {
      if (_outOfService) {
        // An infrastructure failure: onCommandFailure (under the command
        // lock) stopped this incarnation and the caller has been answered.
        return;
      }
      if (isInfrastructureFailure(error)) {
        rethrow;
      }
      // A rejection: onCommandFailure has answered the caller.
      _log.fine('$persistenceId: rejected ${message.runtimeType}: $error');
    }
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
