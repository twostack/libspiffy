/// Wallet creation, configuration and deletion events (bead libspiffy-dp4;
/// part of `BitcoinWalletAggregate`).
library;

import 'package:eventador/eventador.dart';
import 'package:uuid/uuid.dart';

import '../../models/persistent_map.dart';
import '../../models/wallet_state.dart';
import '../../utils/network_name.dart';
import '../wallet_commands.dart';
import '../wallet_events.dart';
import 'address_book.dart';
import 'state_records.dart';
import 'wallet_keys.dart';

/// Lifecycle commands and events of the wallet aggregate. Pure.
abstract final class WalletLifecycle {
  /// Throws when [currentState] is already a created wallet.
  static void requireNotCreated(WalletState currentState, CreateWalletCommand command) {
    // Business rule: Cannot create wallet that already exists
    if (currentState.isCreated) {
      throw StateError('Wallet ${command.walletId} already exists');
    }
  }

  /// Throws an [ArgumentError] when [command]'s wallet metadata names a key
  /// reserved for the wallet's own records (bead libspiffy-hfai); its
  /// network is a creation input. Checked before any key material is stored.
  static void requireHostCreationMetadata(CreateWalletCommand command) =>
      WalletMetadataKeys.requireHostMetadata(command.walletMetadata, 'walletMetadata', creation: true);

  /// The [WalletCreatedEvent] of [command], whose keys give [root].
  static WalletCreatedEvent created(WalletState currentState, CreateWalletCommand command, WalletRoot root) =>
      WalletCreatedEvent(
        walletId: command.walletId,
        walletName: command.walletName,
        rootAddress: root.rootAddress,
        walletType: root.walletType,
        walletMetadata: {
          ...?command.walletMetadata,
          WalletMetadataKeys.network: root.networkName,
        },
        version: currentState.version + 1,
        timestamp: DateTime.now(),
      );

  static List<Event> updateConfiguration(WalletState currentState, UpdateWalletConfigurationCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot update configuration of non-existent wallet');
    }

    // Business rule: Must have something to update
    if (command.newName == null && command.newMetadata == null) {
      throw ArgumentError('Must specify newName or newMetadata to update');
    }

    // Business rule: host metadata cannot overwrite the wallet's own records
    // (bead libspiffy-hfai). Rejected before anything is journaled.
    WalletMetadataKeys.requireHostMetadata(command.newMetadata, 'newMetadata');

    final event = WalletConfigurationUpdatedEvent(
      eventId: const Uuid().v4(),
      walletId: command.walletId,
      timestamp: DateTime.now(),
      version: currentState.version + 1,
      newName: command.newName,
      newMetadata: command.newMetadata,
    );

    return [event];
  }

  static List<Event> delete(WalletState currentState, DeleteWalletCommand command) {
    if (!currentState.isCreated) {
      throw StateError('Cannot delete wallet ${command.walletId}: wallet does not exist');
    }
    if (currentState.isDeleted) {
      throw StateError('Wallet ${command.walletId} is already deleted');
    }

    return [
      WalletDeletedEvent(
        walletId: command.walletId,
        reason: command.reason,
        version: currentState.version + 1,
        timestamp: DateTime.now(),
      ),
    ];
  }

  static void applyWalletCreated(WalletStateBuilder state, WalletCreatedEvent event) {
    state.isCreated = true;
    state.name = event.walletName;
    state.rootAddress = event.rootAddress;
    state.walletType = event.walletType;
    state.networkType = NetworkName.canonical(event.walletMetadata?[WalletMetadataKeys.network] as String?);
    state.timestamp = event.timestamp;
    state.nextDerivationIndex = 1; // Root address is index 0
    // A creation journaled before reserved keys were rejected may name one:
    // it seeds no record (bead libspiffy-hfai).
    state.metadata = freezeMap(
        WalletMetadataKeys.hostEntries(event.walletMetadata ?? const <String, dynamic>{}, creation: true));

    // Initialize the derivation records
    AddressBook.normaliseDerivationRecords(state);

    state.version = event.version;
    state.lastModified = event.timestamp;

    // Add root address to addresses map with derivation index 0 (receive chain)
    if (event.rootAddress.isNotEmpty) {
      state.addresses = state.addresses.put(event.rootAddress, null);
      AddressBook.recordAddressDerivation(state, event.rootAddress, 0, isChange: false);
    }
  }

  static void applyWalletDeleted(WalletStateBuilder state, WalletDeletedEvent event) {
    state.isDeleted = true;
    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  static void applyWalletConfigurationUpdated(WalletStateBuilder state, WalletConfigurationUpdatedEvent event) {
    if (event.newName != null) {
      state.name = event.newName!;
    }
    if (event.newMetadata != null) {
      // An update journaled before reserved keys were rejected may name one:
      // only its host keys apply, the event stays (bead libspiffy-hfai).
      state.metadata = state.metadata.putAll(freezeMap(WalletMetadataKeys.hostEntries(event.newMetadata!)));
    }
    state.version = event.version;
    state.lastModified = event.timestamp;
  }
}
