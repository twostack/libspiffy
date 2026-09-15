/// The wallet's addresses: derived addresses with their derivation records,
/// watch addresses, and the commands and events that change them (bead
/// libspiffy-dp4; part of `BitcoinWalletAggregate`).
library;

import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../../models/persistent_map.dart';
import '../../models/wallet_state.dart';
import '../wallet_commands.dart';
import '../wallet_events.dart';
import 'state_records.dart';

final _log = Logger('BitcoinWalletAggregate');

/// Address records and address commands of the wallet aggregate. Pure: every
/// member works on the state (or a draft of the next state) it is given.
///
/// ADDRESS DERIVATION RECORDS. Every address the aggregate generates or
/// discovers is recorded with its derivation index
/// (metadata['address_indices']: address -> int) AND its chain
/// (metadata['address_chains']: address -> bool, true = change chain m/1/i,
/// false = receive chain m/0/i). Both are rebuilt from the journal:
/// AddressGeneratedEvent.purpose == 'change' and AddressDiscoveredEvent
/// .isChange carry the chain; events without either are receive-chain.
/// Before the 2026-09 audit (H3) only the index was kept and every signing
/// path derived m/0/i, so change outputs were unspendable.
///
/// WATCH ADDRESSES (bead libspiffy-p4kv). A watch address is attributed to
/// the wallet (it answers ownership for it) but the wallet holds no key for
/// it: it is kept in state.watchAddresses, never in state.addresses, whose
/// entries signing derives keys for.
abstract final class AddressBook {
  static const String addressIndicesKey = WalletMetadataKeys.addressIndices;
  static const String addressChainsKey = WalletMetadataKeys.addressChains;

  /// Chain discriminator on [AddressGeneratedEvent.purpose] /
  /// [GenerateAddressCommand.purpose].
  static const String changePurpose = 'change';

  /// The derivation indices in [metadata] as a typed map. A snapshot
  /// round-trip can hand back an untyped map; its int entries are kept.
  static PersistentMap<String, int> addressIndices(Map<String, dynamic> metadata) =>
      typedEntries<int>(metadata[addressIndicesKey]);

  static PersistentMap<String, bool> addressChains(Map<String, dynamic> metadata) =>
      typedEntries<bool>(metadata[addressChainsKey]);

  /// Stores both derivation records in [state] in their typed form (as the
  /// first read of an untyped record did).
  static void normaliseDerivationRecords(WalletStateBuilder state) {
    for (final (key, typed) in [
      (addressIndicesKey, addressIndices(state.metadata)),
      (addressChainsKey, addressChains(state.metadata)),
    ]) {
      if (!identical(state.metadata[key], typed)) state.metadata = state.metadata.put(key, typed);
    }
  }

  /// Types the derivation records of a state restored from a snapshot (the
  /// round trip hands back untyped maps).
  static void typeRestoredDerivationRecords(WalletStateBuilder state) {
    state.metadata = state.metadata
        .put(addressIndicesKey, typedEntries<int>(state.metadata[addressIndicesKey]))
        .put(addressChainsKey, typedEntries<bool>(state.metadata[addressChainsKey]));
  }

  static void recordAddressDerivation(WalletStateBuilder state, String address, int index, {required bool isChange}) {
    state.metadata = state.metadata
        .put(addressIndicesKey, addressIndices(state.metadata).put(address, index))
        .put(addressChainsKey, addressChains(state.metadata).put(address, isChange));
  }

  /// Whether [address] was derived on the change chain. Unknown addresses
  /// (and the root address) are receive-chain, matching every journal
  /// written before the chain was recorded.
  static bool isChangeAddress(WalletState state, String address) => addressChains(state.metadata)[address] ?? false;

  /// Whether [address] needs no watch-address event: already watched, or an
  /// address the wallet derived (owned already; its row keeps its index).
  static bool ownsWithoutWatch(WalletState state, String address) =>
      state.watchAddresses.containsKey(address) || state.addresses.containsKey(address);

  // ---------------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------------

  static List<Event> updateAddressLabel(WalletState currentState, UpdateAddressLabelCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot update address label for non-existent wallet');
    }

    // Get current label for old value tracking
    final oldLabel = currentState.addresses[command.address];

    final event = AddressLabelUpdatedEvent(
      eventId: const Uuid().v4(),
      walletId: command.walletId,
      timestamp: DateTime.now(),
      version: currentState.version + 1,
      address: command.address,
      newLabel: command.newLabel,
      oldLabel: oldLabel,
    );

    return [event];
  }

  static List<Event> registerDiscoveredAddress(WalletState currentState, RegisterDiscoveredAddressCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot register discovered address for non-existent wallet');
    }

    // If address already exists in state, this is idempotent (no-op)
    if (currentState.addresses.containsKey(command.address)) {
      return [];
    }

    final event = AddressDiscoveredEvent(
      eventId: const Uuid().v4(),
      walletId: command.walletId,
      timestamp: DateTime.now(),
      version: currentState.version + 1,
      address: command.address,
      derivationIndex: command.derivationIndex,
      isChange: command.isChange,
      transactionCount: command.transactionCount,
    );

    return [event];
  }

  static List<Event> addWatchAddress(WalletState currentState, AddWatchAddressCommand command) {
    if (!currentState.isCreated || currentState.isDeleted) {
      throw StateError('Cannot add a watch address to non-existent wallet ${command.walletId}');
    }
    if (command.address.trim().isEmpty) {
      throw ArgumentError('A watch address must not be empty');
    }
    if (ownsWithoutWatch(currentState, command.address)) return const [];
    final now = DateTime.now();
    return [
      WatchAddressAddedEvent(
        walletId: command.walletId,
        address: command.address,
        scriptType: command.scriptType,
        label: command.label,
        registeredAt: now,
        version: currentState.version + 1,
        timestamp: now,
      ),
    ];
  }

  static List<Event> reconcileWatchAddresses(WalletState currentState, ReconcileWatchAddressesCommand command) {
    if (!currentState.isCreated || currentState.isDeleted) return const [];
    final events = <Event>[];
    final added = <String>{};
    for (final legacy in command.addresses) {
      if (legacy.address.isEmpty || ownsWithoutWatch(currentState, legacy.address) || !added.add(legacy.address)) {
        continue;
      }
      events.add(WatchAddressAddedEvent(
        walletId: command.walletId,
        address: legacy.address,
        scriptType: legacy.scriptType,
        label: legacy.label,
        registeredAt: legacy.registeredAt,
        reconciled: true,
        version: currentState.version + events.length + 1,
        timestamp: DateTime.now(),
      ));
    }
    if (events.isNotEmpty) {
      _log.info('Wallet ${command.walletId}: journaled ${events.length} watch address(es) '
          'registered before watch addresses were journaled');
    }
    return events;
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  static void applyAddressGenerated(WalletStateBuilder state, AddressGeneratedEvent event) {
    state.addresses = state.addresses.put(event.address, event.label);
    state.nextDerivationIndex = event.derivationIndex + 1;

    // Store the derivation index and chain for key derivation during signing
    recordAddressDerivation(
      state,
      event.address,
      event.derivationIndex,
      isChange: event.purpose == changePurpose,
    );

    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  static void applyAddressLabelUpdated(WalletStateBuilder state, AddressLabelUpdatedEvent event) {
    state.addresses = state.addresses.put(event.address, event.newLabel);
    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  static void applyAddressDiscovered(WalletStateBuilder state, AddressDiscoveredEvent event) {
    // Add discovered address to wallet
    state.addresses = state.addresses
        .put(event.address, 'Imported (${event.isChange ? 'change' : 'receive'} #${event.derivationIndex})');

    // Store the derivation index and chain for key derivation during signing
    recordAddressDerivation(state, event.address, event.derivationIndex, isChange: event.isChange);

    // Update next derivation index if this is higher
    if (event.derivationIndex >= state.nextDerivationIndex) {
      state.nextDerivationIndex = event.derivationIndex + 1;
    }

    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  static void applyWatchAddressAdded(WalletStateBuilder state, WatchAddressAddedEvent event) {
    state.watchAddresses = state.watchAddresses.put(event.address, event.scriptType);
    state.version = event.version;
    state.lastModified = event.timestamp;
  }
}
