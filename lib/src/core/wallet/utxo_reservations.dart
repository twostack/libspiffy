/// UTXO reservations: reserve, release, renew and expire (bead
/// libspiffy-dp4; part of `BitcoinWalletAggregate`).
library;

import 'package:eventador/eventador.dart';

import '../../models/bitcoin_utxo.dart';
import '../../models/wallet_state.dart';
import '../wallet_commands.dart';
import '../wallet_events.dart';
import 'deferred_payments.dart';

/// Reservation commands and events of one wallet aggregate. A deferred
/// payment's hold is a reservation no command here takes or releases
/// ([DeferredPayments]).
class UtxoReservations {
  final DeferredPayments deferred;

  UtxoReservations(this.deferred);

  /// Reserve every UTXO in [ReserveUTXOsCommand.utxoKeys] for
  /// [ReserveUTXOsCommand.reservationId], under the same rules as
  /// [ReserveUTXOCommand] (priority 0). All-or-nothing: if any key cannot be
  /// reserved the command fails and nothing is reserved. Emits one
  /// [UTXOReservedEvent] per UTXO so the aggregate and the read model both
  /// see the reservation (audit 2026-09-14 M3: this used to emit a
  /// [UTXOReservationPlacedEvent] that nothing applied).
  List<Event> reserveMany(WalletState currentState, ReserveUTXOsCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot reserve UTXOs for non-existent wallet');
    }

    final duration = command.reservationDuration ?? const Duration(minutes: 30);
    final events = <Event>[];
    for (final utxoKey in command.utxoKeys.toSet()) {
      events.add(_reservationEvent(
        currentState,
        walletId: command.walletId,
        utxoKey: utxoKey,
        reservedByTxId: command.reservationId,
        reservationReason: 'Reservation ${command.reservationId}',
        duration: duration,
        priority: 0,
        version: currentState.version + events.length + 1,
      ));
    }
    return events;
  }

  /// Release every UTXO currently reserved by
  /// [ReleaseUTXOsCommand.reservationId] (whether it was reserved with
  /// [ReserveUTXOsCommand], [ReserveUTXOCommand] or a funding build), each
  /// back to the status it had before the reservation. The coordinators send
  /// this to clean up abandoned payments; a reservation with no reserved
  /// UTXOs left is a no-op (audit 2026-09-14 M3: this used to emit a
  /// [UTXOReservationReleasedEvent] that released nothing).
  List<Event> releaseMany(WalletState currentState, ReleaseUTXOsCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot release UTXOs for non-existent wallet');
    }

    final events = <Event>[];
    final legacyHeld = deferred.legacyHeldKeys(currentState);
    for (final utxo in currentState.utxos.values) {
      if (utxo.status != UTXOStatus.reserved || utxo.reservedByTxId != command.reservationId) {
        continue;
      }
      // A deferred payment's hold is released only by its failure or
      // cancellation (bead libspiffy-7p2).
      if (DeferredPayments.explicitHolder(currentState, utxo.key) != null || legacyHeld.contains(utxo.key)) {
        continue;
      }
      events.add(UTXOReleasedEvent(
        walletId: command.walletId,
        txid: utxo.txid,
        vout: utxo.vout,
        releaseReason: 'Reservation ${command.reservationId} released',
        wasExpired: utxo.isReservationExpired,
        restoredStatus: utxo.statusToRestoreOnRelease,
        version: currentState.version + events.length + 1,
        timestamp: DateTime.now(),
      ));
    }
    return events;
  }

  /// A [UTXOReservedEvent] for [utxoKey], enforcing the reservation rules:
  /// the UTXO exists, is not spent, and is not held by a live reservation of
  /// equal or higher priority.
  UTXOReservedEvent _reservationEvent(
    WalletState currentState, {
    required String walletId,
    required String utxoKey,
    required String reservedByTxId,
    required String? reservationReason,
    required Duration duration,
    required int priority,
    required int version,
  }) {
    final utxo = currentState.utxos[utxoKey];
    if (utxo == null) {
      throw StateError('UTXO $utxoKey not found in wallet');
    }

    if (utxo.status == UTXOStatus.spent) {
      throw StateError('Cannot reserve spent UTXO $utxoKey');
    }

    // A deferred payment's input is not reservable at any priority, whatever
    // its (possibly expired) reservation says (bead libspiffy-7p2).
    final holder = deferred.holderOf(currentState, utxoKey);
    if (holder != null) {
      throw StateError('UTXO $utxoKey is held by deferred payment $holder until the network '
          'settles it, ARC reports it failed, or it is cancelled');
    }

    if (utxo.status == UTXOStatus.reserved && !utxo.isReservationExpired) {
      // Check priority - higher priority can override lower priority
      final currentPriority = utxo.reservationPriority ?? 0;
      if (priority <= currentPriority) {
        throw StateError('UTXO $utxoKey is already reserved with higher or equal priority');
      }
    }

    return UTXOReservedEvent(
      walletId: walletId,
      txid: utxo.txid,
      vout: utxo.vout,
      reservedByTxId: reservedByTxId,
      reservationReason: reservationReason,
      expiresAt: DateTime.now().add(duration),
      priority: priority,
      version: version,
      timestamp: DateTime.now(),
    );
  }

  List<Event> reserve(WalletState currentState, ReserveUTXOCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot reserve UTXO for non-existent wallet');
    }

    return [
      _reservationEvent(
        currentState,
        walletId: command.walletId,
        utxoKey: command.utxoKey,
        reservedByTxId: command.reservedByTxId,
        reservationReason: command.reservationReason,
        duration: command.reservationDuration ?? const Duration(minutes: 30),
        priority: command.priority,
        version: currentState.version + 1,
      ),
    ];
  }

  List<Event> release(WalletState currentState, ReleaseUTXOCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot release UTXO for non-existent wallet');
    }

    // Business rule: UTXO must exist and be reserved
    final utxo = currentState.utxos[command.utxoKey];
    if (utxo == null) {
      throw StateError('UTXO ${command.utxoKey} not found in wallet');
    }

    if (utxo.status != UTXOStatus.reserved) {
      throw StateError('UTXO ${command.utxoKey} is not reserved and cannot be released');
    }

    final holder = deferred.holderOf(currentState, command.utxoKey);
    if (holder != null) {
      throw StateError('UTXO ${command.utxoKey} is held by deferred payment $holder; '
          'cancel the payment to release it');
    }

    // Parse txid and vout from utxoKey
    final parts = command.utxoKey.split(':');
    final txid = parts[0];
    final vout = int.parse(parts[1]);

    final event = UTXOReleasedEvent(
      walletId: command.walletId,
      txid: txid,
      vout: vout,
      releaseReason: command.releaseReason,
      wasExpired: utxo.isReservationExpired,
      restoredStatus: utxo.statusToRestoreOnRelease,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  List<Event> renew(WalletState currentState, RenewUTXOReservationCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot renew UTXO reservation for non-existent wallet');
    }

    // Business rule: UTXO must exist and be reserved
    final utxo = currentState.utxos[command.utxoKey];
    if (utxo == null) {
      throw StateError('UTXO ${command.utxoKey} not found in wallet');
    }

    if (utxo.status != UTXOStatus.reserved) {
      throw StateError('UTXO ${command.utxoKey} is not reserved and cannot be renewed');
    }

    final holder = deferred.holderOf(currentState, command.utxoKey);
    if (holder != null) {
      throw StateError('UTXO ${command.utxoKey} is held by deferred payment $holder, '
          'which has no expiry to renew');
    }

    // Parse txid and vout from utxoKey
    final parts = command.utxoKey.split(':');
    final txid = parts[0];
    final vout = int.parse(parts[1]);

    final oldExpiresAt = utxo.reservationExpiresAt ?? DateTime.now();
    final newExpiresAt = oldExpiresAt.add(command.extensionDuration);

    final event = UTXOReservationRenewedEvent(
      walletId: command.walletId,
      txid: txid,
      vout: vout,
      newExpiresAt: newExpiresAt,
      oldExpiresAt: oldExpiresAt,
      renewalReason: command.renewalReason,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  List<Event> cleanupExpired(WalletState currentState, CleanupExpiredReservationsCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot cleanup reservations for non-existent wallet');
    }

    final cutoffTime = command.cutoffTime ?? DateTime.now();

    // Holds a journal written before bead libspiffy-7p2 did not record are
    // journaled first, and nothing a deferred payment holds is released.
    final events = <Event>[
      ...deferred.inferredHoldEvents(currentState, command.walletId, currentState.version + 1),
    ];
    final legacyHeld = {
      for (final e in events) ...(e as TransactionSpendDeferredEvent).heldUtxoKeys,
    };

    // Find expired reservations
    for (final utxo in currentState.utxos.values) {
      if (utxo.status == UTXOStatus.reserved &&
          utxo.reservationExpiresAt != null &&
          cutoffTime.isAfter(utxo.reservationExpiresAt!)) {
        if (DeferredPayments.explicitHolder(currentState, utxo.key) != null || legacyHeld.contains(utxo.key)) {
          continue;
        }

        // Create release event for expired reservation
        final event = UTXOReleasedEvent(
          walletId: command.walletId,
          txid: utxo.txid,
          vout: utxo.vout,
          releaseReason: 'Expired reservation cleanup',
          wasExpired: true,
          restoredStatus: utxo.statusToRestoreOnRelease,
          version: currentState.version + events.length + 1,
          timestamp: DateTime.now(),
        );

        events.add(event);
      }
    }

    return events;
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  static void applyReserved(WalletStateBuilder state, UTXOReservedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = state.utxos[utxoKey];

    if (utxo != null) {
      final reservedUtxo = utxo.copyWith(
        status: UTXOStatus.reserved,
        statusBeforeReservation: utxo.statusToRestoreOnRelease,
        reservedByTxId: event.reservedByTxId,
        reservationExpiresAt: event.expiresAt,
        reservationPriority: event.priority,
        reservationReason: event.reservationReason,
        updatedAt: event.timestamp,
      );

      state.putUtxo(utxoKey, reservedUtxo);
    }

    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  static void applyReleased(WalletStateBuilder state, UTXOReleasedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = state.utxos[utxoKey];

    if (utxo != null && utxo.status == UTXOStatus.reserved) {
      // Events journaled before restoredStatus existed released to
      // available; replay them that way.
      final releasedUtxo = utxo.releaseReservation(
        restoreStatus: event.restoredStatus ?? UTXOStatus.available,
        timestamp: event.timestamp,
      );
      state.putUtxo(utxoKey, releasedUtxo);
    }

    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  static void applyRenewed(WalletStateBuilder state, UTXOReservationRenewedEvent event) {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = state.utxos[utxoKey];

    if (utxo != null && utxo.status == UTXOStatus.reserved) {
      // The event carries the new expiry; recomputing it from the state
      // (extension added to the current expiry, or to "now" when there was
      // none) made the result depend on when the event was applied (L1).
      // Renewal moves no amount between balances.
      state.utxos = state.utxos.put(
        utxoKey,
        utxo.copyWith(
          reservationExpiresAt: event.newExpiresAt,
          reservationReason: event.renewalReason ?? utxo.reservationReason,
          updatedAt: event.timestamp,
        ),
      );
    }

    state.version = event.version;
    state.lastModified = event.timestamp;
  }
}
