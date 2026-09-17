/// Migration v021: the app's opaque counterparty marker on a transaction row.
library;

import 'package:postgres/postgres.dart';

import '../postgres_migrations.dart';

/// Bead libspiffy-cq16, spv-understanding.md "Core Data Management"
/// requirement 5: every payment the wallet records, incoming and outgoing,
/// carries a marker identifying the counterparty it was with. The marker is
/// an opaque string the app chooses — an Ed25519 identity key, an email
/// address, a peer id, an internal account id — which libspiffy stores and
/// returns but never interprets, validates or parses. The identity record
/// itself stays with the app.
///
/// This is **not** `counterparty` / `primary_counterparty` (migration v015),
/// which are derived from bitcoin ADDRESSES: the first sending address of an
/// incoming transaction, the first receiving address of an outgoing one. An
/// address is not an identity, so the marker gets its own column and the
/// address-derived ones are left exactly as they are.
///
/// TEXT, nullable: existing rows have no marker and none can be invented for
/// them (nobody can be asked who a past payment was with). It is written once,
/// by the first record that carries one, and no later update blanks it or
/// replaces it — the retention rule every backend shares
/// (`TransactionRowRules.counterpartyMarkerAfter`).
class V021TransactionCounterpartyMarker extends Migration {
  @override
  int get version => 21;

  @override
  String get name => 'transaction_counterparty_marker';

  @override
  Future<void> up(Session conn) async {
    await conn.execute('''
      ALTER TABLE bitcoin_transactions
        ADD COLUMN IF NOT EXISTS counterparty_marker TEXT
    ''');
  }

  /// The column is kept. It holds identities an app handed us that no
  /// service can supply again (spv-understanding.md, Data Retention), and
  /// dropping it would destroy them to undo a schema change that costs
  /// nothing to leave in place. A v020 schema ignores the extra column.
  @override
  Future<void> down(Session conn) async {}
}
