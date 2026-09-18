# Reachability sweep: commands, events and placeholders (bead libspiffy-1kd5)

Dated 2026-09-18, against `main` at 502979c (audit report section 11 through V-86).

Filed because the same defect was found three times by accident: **an aggregate handles a
command, the command has tests, and nothing in `lib/` ever constructs it**. The capability
reads as finished and is not reachable. `FinalizeCloseCommand` was the worst case — a
cooperatively closed channel hung in `closing` forever, and `ChannelClosedEvent` (and with it
the peer's `channel_closed`) was unreachable — and nobody noticed because no test drove a
close to completion.

This is the systematic version. Method: for every command and event class declared in
`lib/src/core/*_commands.dart` and `*_events.dart`, count construction sites in `lib/`
(excluding the declaring file), then check the aggregate dispatch, the aggregate's
`applyEvent`, and the projections. The inventory is recorded in full, including the entries
that need no action, so the next reader does not rediscover it.

Scope note: commands and events are exported from `package:libspiffy/internals.dart`, not
from `libspiffy.dart`. `internals.dart` is a supported but advanced surface ("building custom
actors, extending aggregates, or writing integration tests"), so a broken entry there is a
narrower promise than a `libspiffy.dart` export — not a private detail.

## 1. Commands with zero construction sites in `lib/`

| Command | lib | test | Verdict |
|---|---|---|---|
| `ImportWalletFromXprivCommand` | 0 | 0 | **DEAD — no handler.** See D-4. |
| `CheckInvoiceStatusCommand` | 0 | 0 | **DEAD — no handler.** See D-4. |
| `ClaimRefundCommand` | 0 | 8 | **Real gap.** Handled by the channel aggregate; nothing reaches it. Tracked by libspiffy-cqc (part b). |
| `UpdateUTXOConfirmationsCommand` | 0 | 14 | Deprecated in V-78; kept for replay of existing journals. No action. |
| `UpdateWalletConfigurationCommand` | 0 | 16 | Legitimately caller-only: the app changes its own wallet configuration. Keep. |
| `UpdateAddressLabelCommand` | 0 | 7 | Legitimately caller-only. Keep. |
| `ReleaseUTXOCommand` | 0 | 19 | Caller-only half of a reservation API whose other half (`ReserveUTXOCommand`, 2 lib senders) is used internally. Keep; note the asymmetry. |
| `RenewUTXOReservationCommand` | 0 | 12 | As above. Keep. |
| `ReserveUTXOsCommand` | 0 | 12 | As above (`ReleaseUTXOsCommand` has 4 lib senders). Keep. |

Every other command in the three files has at least one `lib/` sender.

## 2. Events never emitted anywhere in `lib/`

| Event | Registered for replay | Aggregate applies | Projection handles |
|---|---|---|---|
| `UTXOReservationPlacedEvent` | yes | no-op case | no |
| `UTXOReservationReleasedEvent` | yes | no-op case | no |
| `UTXOReservationExpiredEvent` | yes | no-op case | no |
| `UTXOSplitCompletedEvent` | yes | no-op case | no |
| `AllUTXOsSplitCompletedEvent` | yes | no-op case | no |
| `InvoiceStatusChangedEvent` | yes | not referenced | **yes** |

**Decision: deprecate, never delete.** All six are registered in the replay registry in
`libspiffy_actor_system.dart`. A journal written by an earlier release may contain them, and
a journal is permanent — removing the class would make that journal unreplayable, which the
data-retention rule forbids. Commands are transient and carry no such constraint.

`InvoiceStatusChangedEvent` is the odd one out: the invoice projection has a handler for an
event nothing emits. Harmless, but it is the shape that hides a gap, so it is recorded.

## 3. Events emitted but handled by no projection

`TransactionSignedEvent` and `TransactionBroadcastEvent` are emitted (by
`OutgoingTransactions.signed`/`.broadcast`) and reach neither the aggregate state (an explicit
"just update version" case) nor any projection. Both are audit-trail only, which is
defensible — but see D-2 for what `TransactionBroadcastEvent` actually records.

`UTXOSplitInitiatedEvent` is emitted by `UtxoLedger.splitToBenford` and handled by no
projection; the aggregate documents why (the split's spends, receipts and records arrive as
their own commands). No action.

Channel and invoice projections are complete: every emitted event is either handled or
carries an explicit no-op case with a reason.

## 4. Defects found

### D-1 (high) `BitcoinTransaction.lockTime` and `.version` do not survive storage

The write path has the real values: `TransactionImportedEvent` carries `txLockTime` and
`txVersion`, and `wallet_projection.dart` puts them on the row. Neither the Isar entity nor
the Postgres table has a column for them, so both `toDomain()` paths fabricate a value:

- `libspiffy_schemas.dart:872` — `lockTime: 0, // Would need to parse from rawHex or store separately`
- `postgres_wallet_storage.dart:1217` — `lockTime: 0, // Not stored in DB, default to 0`

The in-memory backend keeps the object and returns the real values. **So the same wallet
answers differently depending on the backend**, and the read-model contract tests do not
cover it. A refund transaction's `nLockTime` read back as `0` says "spendable now" about a
transaction that is not — the reading is not merely absent, it is inverted.

`rawHex` is stored, so the values are recoverable.

### D-2 (medium) `TransactionBroadcastEvent.broadcastResponse` is a constant

`outgoing_transactions.dart:587` — `broadcastResponse: 'broadcast_success', // Placeholder -
will be set by ARC service`. Every broadcast event ever journaled carries that literal.
`BroadcastTransactionCommand` has no field to carry ARC's actual answer, so the ARC service
never does set it.

Nothing downstream is wrong today: all four senders (`arc_actor.dart`) send the command only
after `submitTransaction` returns, and ARC's real status is recorded separately through
`UpdateTransactionStatusCommand`. But a fabricated field sits permanently in the journal, and
the comment promises a wiring that does not exist — the same species as V-78/79/80/86.

### D-3 (medium) Transaction-address junctions cover only imported transactions

`_createTransactionAddressJunctions` has exactly one caller: `_handleTransactionImported`.
`TransactionRecordedEvent` — our own outgoing transactions — never builds junctions, so
`getTransactionAddresses` is blind to everything the wallet sent. This is the one-of-N-routes
pattern that V-81 hit on the channel closing txid.

Within that method, input links are also wrong twice over
(`wallet_projection.dart:1607-1617`):

- `amount: BigInt.zero, // Would need parent tx to get exact amount` — a fabricated zero in a
  public read model. The parent amounts are available: the import event carries its BEEF
  ancestors, and `_storeAncestors` is called a few lines earlier on the same event.
- the loop pairs `sendingAddresses[i]` with `parsedTx.inputs[i]` positionally.
  `sendingAddresses` is a derived list of addresses, not a per-input list, so the `vin` index
  on each link is unfounded whenever the two lists do not correspond.

`getTransactionAddresses` has no `lib/` consumer; it exists for applications.

### D-4 (low) Two command classes no aggregate handles

Sending either throws `ArgumentError('Unknown command type: ...')` from the aggregate's
default branch.

- `ImportWalletFromXprivCommand` — superseded: `CreateWalletCommand.xpriv` is the live path
  (`wallet/wallet_keys.dart:150`). Referenced nowhere in `lib/`, not even by the dispatch.
- `CheckInvoiceStatusCommand` — referenced nowhere; the invoice aggregate's `switch` has no
  arm for it.

Both are transient, so both can be deprecated and then removed.

## 5. Placeholder comments triaged (no defect)

- `spv_actor.dart:236` — `txid: msg.transactionId, // Placeholder`. It *is* the txid; the
  comment is stale. Delete the comment.
- `script_type_registry.dart:202,227` — "a simplified approach - in a real implementation we
  would use the appropriate network type". The line below it passes `_networkType`. Stale.
- `TransactionLifecycleCoordinator` — a deliberate, documented no-op since audit A-L4; the
  class is kept because `LibSpiffyActorSystem` still exposes it. No action.
- `payment_coordinator_actor.dart:570` — `'multisig:2-of-3'` / `'op_return'` in
  `receivingAddresses` are descriptive markers, not fabricated addresses. Defensible, but
  readers treating that list as addresses will be surprised; worth a doc line.
- `postgres_secure_storage.dart` "NOT IMPLEMENTED" sections — private keys are deliberately
  absent server-side. Confirm they throw rather than return a default.

## 6. Unimplemented `parse()` in script builders

`partial_witness_unlock_builder.dart:32`, `pp2_lock_builder.dart:34`,
`pp2_unlock_builder.dart:22` have empty `parse(SVScript)` overrides; `hodl_lockbuilder.dart:27`
carries a TODO above code that does parse; `pp1_lock_builder.dart:52` has a TODO for issuance
identity anchor signature validation. dartsv calls `parse` when a builder is constructed from
an existing script: an empty override leaves every field at its default and any script rebuilt
from it is wrong, silently. Separate area from this sweep; filed as its own bead.
