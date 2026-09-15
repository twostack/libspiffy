/// Deferred payments a journal recorded before their holds were journaled
/// (bead libspiffy-7p2), inferred from the wallet state (bead
/// libspiffy-8j9w). Pure; the state caches the result
/// (`WalletState.legacyDeferredSpends`).
library;

import '../../models/bitcoin_utxo.dart';
import '../../models/wallet_state.dart';
import 'state_records.dart';

/// An outgoing transaction recorded with a deferred spend before holds were
/// journaled, with the inputs it still holds ([inferLegacyDeferredSpends]).
class LegacyDeferredSpend {
  final String txid;
  final List<String> heldKeys;
  final Map record;

  LegacyDeferredSpend(this.txid, this.heldKeys, this.record);
}

/// Outgoing transactions recorded with a deferred spend before holds were
/// journaled, still outstanding, in [state]: a record with no
/// deferred-payment record, not confirmed, whose inputs the wallet still has
/// unspent and no journaled hold names. A record without deferSpend spent
/// its inputs in its own command, so it never qualifies. Oldest record
/// first; an input two records list is held by the older one.
///
/// Such a payment holds its inputs from the moment its record is in the
/// state: every rule that respects a hold (reservations, cleanup, channel
/// funding, and the aggregate's spendable rule `WalletBalances.isSpendable`)
/// respects the inferred one, before `ReconcileDeferredSpendsCommand`
/// journals it.
List<LegacyDeferredSpend> inferLegacyDeferredSpends(WalletState state) {
  final records = state.metadata[WalletMetadataKeys.outgoingTransactions];
  final deferred = state.metadata[WalletMetadataKeys.deferredSpends];
  final holds = state.metadata[WalletMetadataKeys.deferredHolds];

  // One pass over the records keeps the candidates (usually none); only
  // those are ordered.
  bool unheldUnspent(Object? key) {
    final utxo = state.utxos[key.toString()];
    return utxo != null && utxo.status != UTXOStatus.spent && !(holds is Map && holds.containsKey(key.toString()));
  }

  final candidates = <Map>[
    for (final record in <Object?>[
      if (records is Map) ...records.values,
      if (records is List) ...records,
    ])
      if (record is Map &&
          record['txid'] != null &&
          !(deferred is Map && deferred.containsKey(record['txid'].toString())) &&
          record['status'] != 'confirmed' &&
          record['spentUtxoKeys'] is List &&
          (record['spentUtxoKeys'] as List).any(unheldUnspent))
        record,
  ]..sort((a, b) => (a['recordedAt']?.toString() ?? '').compareTo(b['recordedAt']?.toString() ?? ''));

  final claimed = <String>{};
  final result = <LegacyDeferredSpend>[];
  for (final record in candidates) {
    final held = <String>[
      for (final k in record['spentUtxoKeys'] as List)
        if (unheldUnspent(k) && claimed.add(k.toString())) k.toString(),
    ];
    if (held.isNotEmpty) result.add(LegacyDeferredSpend(record['txid'].toString(), held, record));
  }
  return result;
}
