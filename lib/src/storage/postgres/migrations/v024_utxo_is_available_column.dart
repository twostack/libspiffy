/// Migration v024: the UTXO row's status flag is named after what it holds.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Bead libspiffy-p8qc: `bitcoin_utxos.is_spendable` (v001) was written as
/// `status = 'available'` and nothing else, while its name is the name of
/// `WalletBalances.isSpendable` — the rule the whole wallet selects by.
/// Plugin-managed outputs (a token, a funding earmark), watch-only funds and
/// outputs the wallet cannot unlock alone were all stored as spendable.
///
/// Nothing read the column back, so no balance was ever wrong. It was a
/// trap: the first query to filter on `is_spendable` would have selected
/// outputs the wallet must not spend — exactly the defect bead
/// libspiffy-qfmb (V-85) had just fixed one layer up, where channel funding
/// hand-rolled its own spendability predicate and let a token output fund a
/// channel.
///
/// **Renamed rather than corrected.** `WalletBalances.isSpendable` takes
/// `(WalletState, BitcoinUtxo)`: it depends on the wallet's watch addresses,
/// on the wallet's own addresses (an output it cannot unlock alone) and on
/// its deferred holds — none of which live in the row. A per-row boolean
/// therefore cannot stay correct: registering one watch address or deriving
/// one key changes the answer for every row already written, and nothing
/// rewrites them. A denormalised copy of a rule whose inputs live elsewhere
/// is a rule that drifts, and a stale "spendable" is the dangerous
/// direction. The read side answers the question live instead, over the
/// state it depends on (`splitBalanceUtxos`), which is what every balance
/// already used. What the column actually records is `BitcoinUtxo.isAvailable`,
/// so that is what it is called.
///
/// `ALTER TABLE ... RENAME COLUMN` renames in place: every row keeps its
/// value, nothing is rewritten and nothing is deleted. Guarded on the
/// catalog so a database already at v024 (or one created after it) is left
/// alone rather than failing.
class V024UtxoIsAvailableColumn extends Migration {
  @override
  int get version => 24;

  @override
  String get name => 'utxo_is_available_column';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      DO \$\$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = 'bitcoin_utxos' AND column_name = 'is_spendable'
        ) AND NOT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = 'bitcoin_utxos' AND column_name = 'is_available'
        ) THEN
          ALTER TABLE bitcoin_utxos RENAME COLUMN is_spendable TO is_available;
        END IF;
      END
      \$\$;
    ''');
  }

  /// Renames back, on the same guard. A rename loses nothing in either
  /// direction — the column's values are unchanged, and they are derivable
  /// from `status` in any case — so unlike v021 and v023 (which keep their
  /// columns because they hold evidence nothing can supply again) this one
  /// can be undone honestly. A v023 schema expects `is_spendable`.
  @override
  Future<void> down(Session conn) async {
    await conn.execute('''
      DO \$\$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = 'bitcoin_utxos' AND column_name = 'is_available'
        ) AND NOT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = 'bitcoin_utxos' AND column_name = 'is_spendable'
        ) THEN
          ALTER TABLE bitcoin_utxos RENAME COLUMN is_available TO is_spendable;
        END IF;
      END
      \$\$;
    ''');
  }
}
