/// The wallet's type-42 (BRC-42) records (bead libspiffy-zxkd; part of
/// `BitcoinWalletAggregate`).
library;

import 'package:dartsv/dartsv.dart' as dartsv;

import '../../models/key_path.dart';
import '../../models/persistent_map.dart';
import '../../models/wallet_state.dart';
import '../wallet_events.dart';
import 'state_records.dart';

/// Type-42 records of the wallet aggregate, kept in `WalletState.metadata`
/// as plain data so a snapshot carries them. Pure: every member works on
/// the state (or a draft of the next state) it is given.
///
/// * [WalletMetadataKeys.addressType42]: address -> derivation of each
///   address a payer derived from the wallet's anchor key. The address is
///   also in `state.addresses`, as every address the wallet signs for is;
///   its key is the anchor key's type-42 child, never an HD path.
/// * [WalletMetadataKeys.type42Destinations]: address -> destination of
///   each type-42 destination the wallet derived as a payer.
/// * [WalletMetadataKeys.type42PayerKeys]: how many payer keys it used.
/// * [WalletMetadataKeys.type42Anchors]: anchor -> context of each anchor
///   it issued.
abstract final class Type42Book {
  /// The derivation of every type-42 address the wallet recorded.
  static Map<String, Type42Derivation> addressDerivations(Map<String, dynamic> metadata) => {
        for (final MapEntry(:key, :value) in _records(metadata[WalletMetadataKeys.addressType42]))
          if (key is String)
            if (Type42Derivation.fromMap(value) case final derivation?) key: derivation,
      };

  /// Every type-42 destination the wallet derived as a payer.
  static Map<String, Type42Destination> destinations(Map<String, dynamic> metadata) => {
        for (final MapEntry(:key, :value) in _records(metadata[WalletMetadataKeys.type42Destinations]))
          if (key is String)
            if (Type42Destination.fromMap(value) case final destination?) key: destination,
      };

  /// Every anchor the wallet issued, with the context (hex) it issued it for.
  static Map<String, String> issuedAnchors(Map<String, dynamic> metadata) => {
        for (final MapEntry(:key, :value) in _records(metadata[WalletMetadataKeys.type42Anchors]))
          if (key is String && value is String) key: value,
      };

  /// How many payer keys the wallet used: the index of the next.
  static int payerKeysUsed(Map<String, dynamic> metadata) =>
      metadata[WalletMetadataKeys.type42PayerKeys] as int? ?? 0;

  static Iterable<MapEntry<Object?, Object?>> _records(Object? value) =>
      value is Map ? value.entries : const [];

  /// The type-42 addresses the transaction [rawTransaction] pays that the
  /// wallet knows a derivation of — ones payers derived from its anchor
  /// key, and ones it derived as a payer — with those derivations.
  static Map<String, Type42Derivation> paidBy(WalletState state, String rawTransaction) {
    final known = {
      for (final MapEntry(:key, :value) in destinations(state.metadata).entries) key: value.derivation,
      ...addressDerivations(state.metadata),
    };
    if (known.isEmpty) return const {};
    final scripts = {for (final output in dartsv.Transaction.fromHex(rawTransaction).outputs) output.script.toHex()};
    return {
      for (final MapEntry(key: address, value: derivation) in known.entries)
        if (scripts.contains(
            dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex()))
          address: derivation,
    };
  }

  /// The label of a type-42 address, the same in the aggregate and the read
  /// model.
  static String label(Type42Derivation derivation) => 'Type-42 (${derivation.invoiceNumber})';

  static PersistentMap<String, dynamic> _put(Object? records, String address, Map<String, Object> record) =>
      (records is Map ? freezeMap(records) : PersistentMap<String, dynamic>.empty()).put(address, freezeMap(record));

  static void applyAddressRecorded(WalletStateBuilder state, Type42AddressRecordedEvent event) {
    state.addresses = state.addresses.put(event.address, label(event.derivation));
    state.metadata = state.metadata.put(WalletMetadataKeys.addressType42,
        _put(state.metadata[WalletMetadataKeys.addressType42], event.address, event.derivation.toMap()));
    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  static void applyAnchorKeyIssued(WalletStateBuilder state, AnchorKeyIssuedEvent event) {
    final anchors = state.metadata[WalletMetadataKeys.type42Anchors];
    state.metadata = state.metadata.put(
        WalletMetadataKeys.type42Anchors,
        (anchors is Map ? freezeMap(anchors) : PersistentMap<String, dynamic>.empty())
            .put(event.anchorPublicKey, event.anchorContext));
    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  static void applyDestinationDerived(WalletStateBuilder state, Type42DestinationDerivedEvent event) {
    final destination = event.destination;
    final used = payerKeysUsed(state.metadata);
    state.metadata = state.metadata
        .put(WalletMetadataKeys.type42Destinations,
            _put(state.metadata[WalletMetadataKeys.type42Destinations], destination.address, destination.toMap()))
        .put(WalletMetadataKeys.type42PayerKeys,
            destination.payerKeyIndex >= used ? destination.payerKeyIndex + 1 : used);
    state.version = event.version;
    state.lastModified = event.timestamp;
  }
}
