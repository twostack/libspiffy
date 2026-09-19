import 'dart:typed_data';

import 'package:dactor/dactor.dart';

import '../models/bitcoin_transaction.dart';
import '../models/bitcoin_utxo.dart';
import '../models/deferred_payment.dart';
import '../models/invoice_output_spec.dart';
import 'invoice_messages.dart' show InvoiceStatus;

export '../models/deferred_payment.dart';

/// Base class for all coordinator events emitted on the event stream.
///
/// Third-party apps subscribe to `Stream<CoordinatorEvent>` to receive
/// async results from the coordinator.
abstract class CoordinatorEvent {
  /// Optional wallet ID for filtering events by wallet
  String? get walletId;

  /// Timestamp of the event
  DateTime get eventTimestamp;
}

// ==========================================================================
// COMMANDS (app → coordinator)
// ==========================================================================

/// Create a new wallet
class CreateWalletCommand implements Message {
  final String walletId;
  final String name;
  final String? mnemonic;
  final String? wif;
  final String? xpriv;
  final String? xpub;
  final Map<String, dynamic>? walletMetadata;

  CreateWalletCommand({
    required this.walletId,
    required this.name,
    this.mnemonic,
    this.wif,
    this.xpriv,
    this.xpub,
    this.walletMetadata,
  });

  @override
  String get correlationId => 'create-wallet-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Delete a wallet permanently (event-sourced)
class DeleteWalletCommand implements Message {
  final String walletId;
  final String? reason;

  DeleteWalletCommand({required this.walletId, this.reason});

  @override
  String get correlationId => 'delete-wallet-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Import a wallet from extended private key or WIF
class ImportWalletCommand implements Message {
  final String walletId;
  final String walletName;
  final String? xpriv;
  final String? mnemonic;
  final String? wif;
  final int gapLimit;
  final String networkType;

  ImportWalletCommand({
    required this.walletId,
    required this.walletName,
    this.xpriv,
    this.mnemonic,
    this.wif,
    this.gapLimit = 20,
    this.networkType = 'test',
  });

  @override
  String get correlationId => 'import-wallet-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Query wallet balance
class GetBalanceQuery implements Message {
  final String walletId;
  final String? queryId;

  GetBalanceQuery({required this.walletId, this.queryId});

  @override
  String get correlationId => queryId ?? 'get-balance-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Query wallet transactions
class GetTransactionsQuery implements Message {
  final String walletId;
  final int limit;
  final int offset;
  final String? queryId;

  GetTransactionsQuery({
    required this.walletId,
    this.limit = 50,
    this.offset = 0,
    this.queryId,
  });

  @override
  String get correlationId => queryId ?? 'get-transactions-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Query specific transaction detail
class GetTransactionDetailQuery implements Message {
  final String walletId;
  final String txid;
  final String? queryId;

  GetTransactionDetailQuery({
    required this.walletId,
    required this.txid,
    this.queryId,
  });

  @override
  String get correlationId => queryId ?? 'get-tx-detail-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Create a payment invoice
class CreateInvoiceCommand implements Message {
  final String walletId;
  final BigInt? amount;
  final List<InvoiceOutputSpec>? outputs;
  final String? description;
  final Duration? expiresIn;
  final int? expiresInSeconds;
  final Map<String, dynamic>? invoiceMetadata;
  final int numberOfAddresses;

  CreateInvoiceCommand({
    required this.walletId,
    this.amount,
    this.outputs,
    this.description,
    this.expiresIn,
    this.expiresInSeconds,
    this.invoiceMetadata,
    this.numberOfAddresses = 1,
  });

  /// Effective expiry duration
  Duration? get effectiveExpiresIn =>
      expiresIn ?? (expiresInSeconds != null ? Duration(seconds: expiresInSeconds!) : null);

  @override
  String get correlationId => 'create-invoice-$walletId-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Pay an invoice (builds BEEF, does NOT broadcast)
class PayInvoiceCommand implements Message {
  final String walletId;
  final String invoiceId;
  final List<String> addresses;
  final BigInt amount;
  final List<InvoiceOutputSpec>? outputs;
  final String? changeAddress;
  final Map<String, dynamic>? paymentMetadata;
  final BigInt? feeEstimateSats;

  /// The app's opaque marker for the counterparty of this payment (bead
  /// libspiffy-cq16, spv-understanding.md "Core Data Management"
  /// requirement 5): an Ed25519 identity key, an email address, a peer id,
  /// an internal account id — whatever the app uses for identity. It is
  /// stored with the payment and returned by the transaction queries;
  /// libspiffy never interprets, validates or parses it, and the identity
  /// record itself stays with the app. Null when none is supplied.
  final String? counterpartyMarker;

  PayInvoiceCommand({
    required this.walletId,
    required this.invoiceId,
    required this.addresses,
    required this.amount,
    this.outputs,
    this.changeAddress,
    this.paymentMetadata,
    this.feeEstimateSats,
    this.counterpartyMarker,
  });

  @override
  String get correlationId => 'pay-invoice-$invoiceId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'invoiceId': invoiceId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Provision earmark-aware funding UTXOs for a token lifecycle.
///
/// Triggers a plugin's [provisionFunding] method, which builds a tree of
/// transactions (split + earmarks) from a single large UTXO. The coordinator
/// records each transaction, marks the original UTXO as spent, and registers
/// the earmarked UTXOs in the wallet's read model.
class ProvisionFundingCommand implements Message {
  final String walletId;
  final String pluginId;
  final Map<String, dynamic> pluginParams;

  ProvisionFundingCommand({
    required this.walletId,
    required this.pluginId,
    required this.pluginParams,
  });

  @override
  String get correlationId => 'provision-funding-${walletId}-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'pluginId': pluginId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Validate incoming BEEF data (structural + SPV validation)
class ValidateBEEFCommand implements Message {
  final String walletId;
  final String beefHex;
  final String? invoiceId;

  /// The app's opaque marker for the counterparty that handed us this BEEF
  /// (bead libspiffy-cq16), journaled with the payment the receive records.
  /// Null when the app supplies none — no placeholder is invented.
  final String? fromCounterparty;

  ValidateBEEFCommand({
    required this.walletId,
    required this.beefHex,
    this.invoiceId,
    this.fromCounterparty,
  });

  @override
  String get correlationId => 'validate-beef-$walletId-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Receive a transaction via BEEF (combined structural + SPV validation + wallet update)
class ReceiveTransactionCommand implements Message {
  final String walletId;
  final String beefHex;
  final String? invoiceId;
  final String? fromCounterparty;

  ReceiveTransactionCommand({
    required this.walletId,
    required this.beefHex,
    this.invoiceId,
    this.fromCounterparty,
  });

  @override
  String get correlationId => 'receive-tx-$walletId-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Record an outgoing transaction in the wallet
class RecordOutgoingCommand implements Message {
  final String walletId;
  final String txid;
  final String rawHex;
  final int totalInputSats;
  final int totalOutputSats;
  final int fee;
  final int numInputs;
  final int numOutputs;
  final int txVersion;
  final int txLockTime;
  final List<String> spentUtxoKeys;
  final List<String> recipientAddresses;
  final int paymentAmount;
  final String? changeAddress;
  final int? changeAmount;

  /// The app's opaque marker for the counterparty of this payment (bead
  /// libspiffy-cq16, spv-understanding.md "Core Data Management"
  /// requirement 5): an Ed25519 identity key, an email address, a peer id,
  /// an internal account id — whatever the app uses for identity. It is
  /// stored with the payment and returned by the transaction queries;
  /// libspiffy never interprets, validates or parses it, and the identity
  /// record itself stays with the app. Null when none is supplied.
  final String? counterpartyMarker;

  RecordOutgoingCommand({
    required this.walletId,
    required this.txid,
    required this.rawHex,
    required this.totalInputSats,
    required this.totalOutputSats,
    required this.fee,
    required this.numInputs,
    required this.numOutputs,
    required this.txVersion,
    required this.txLockTime,
    required this.spentUtxoKeys,
    required this.recipientAddresses,
    required this.paymentAmount,
    this.changeAddress,
    this.changeAmount,
    this.counterpartyMarker,
  });

  @override
  String get correlationId => 'record-outgoing-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Import a transaction into the wallet
class ImportTransactionCommand implements Message {
  final String walletId;
  final String transactionId;
  final List<int> beef;
  final String? fromCounterparty;

  ImportTransactionCommand({
    required this.walletId,
    required this.transactionId,
    required this.beef,
    this.fromCounterparty,
  });

  @override
  String get correlationId => 'import-tx-$transactionId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Store block headers for SPV validation
class StoreHeadersCommand implements Message {
  final List<Map<String, dynamic>> headers;
  final String source;

  StoreHeadersCommand({
    required this.headers,
    this.source = 'external',
  });

  @override
  String get correlationId => 'store-headers-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Register an address to watch for activity
class RegisterWatchAddressCommand implements Message {
  final String walletId;
  final String address;
  final String scriptType;
  final String? label;

  RegisterWatchAddressCommand({
    required this.walletId,
    required this.address,
    required this.scriptType,
    this.label,
  });

  @override
  String get correlationId => 'register-watch-$address';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Release reserved UTXOs
class ReleaseUTXOsCommand implements Message {
  final String walletId;
  final String reservationId;

  ReleaseUTXOsCommand({
    required this.walletId,
    required this.reservationId,
  });

  @override
  String get correlationId => 'release-utxos-$reservationId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Split UTXOs using Benford's Law distribution for privacy
class SplitUTXOsCommand implements Message {
  final String walletId;
  final int? targetUtxoCount;
  final int? feeRateSatsPerByte;
  final int? maxUtxosToSplit;

  SplitUTXOsCommand({
    required this.walletId,
    this.targetUtxoCount,
    this.feeRateSatsPerByte,
    this.maxUtxosToSplit,
  });

  @override
  String get correlationId => 'split-utxos-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Create a timestamp archive (OP_RETURN data on-chain)
class TimestampCommand implements Message {
  final String archiveId;
  final String walletId;
  final List<String> fileHashes;
  final String? archiveTitle;

  TimestampCommand({
    required this.archiveId,
    required this.walletId,
    required this.fileHashes,
    this.archiveTitle,
  });

  @override
  String get correlationId => 'timestamp-$archiveId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'archiveId': archiveId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Refresh wallet data
class RefreshWalletCommand implements Message {
  final String walletId;

  RefreshWalletCommand({required this.walletId});

  @override
  String get correlationId => 'refresh-wallet-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Settle a BEEF by broadcasting all unsettled transactions (hasMerkle=false)
/// to ARC in dependency order.
///
/// Classic SPV payments (P2P transfer) don't need this — the recipient
/// settles when they choose to bank the cheque. Self-pay operations
/// (token issuance, identity anchor) must settle immediately because
/// there is no counterparty to hand the cheque to.
class SettleBEEFCommand implements Message {
  final String walletId;
  final String beefHex;
  final String txid;

  SettleBEEFCommand({
    required this.walletId,
    required this.beefHex,
    required this.txid,
  });

  @override
  String get correlationId => 'settle-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Gracefully shutdown the coordinator
class ShutdownCommand implements Message {
  ShutdownCommand();

  @override
  String get correlationId => 'shutdown';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}


// ==========================================================================
// DEFERRED PAYMENT COMMANDS (bead libspiffy-7p2)
// ==========================================================================
//
// A payment built by PayInvoiceCommand is handed to the recipient, who
// normally broadcasts it (spv-understanding.md). Until the network has it,
// the wallet holds its inputs: no reservation expiry or other payment can
// take them. These messages list those payments, broadcast one yourself,
// check its status now, or cancel it.

/// List or search the wallet's deferred payments. Answered with
/// [DeferredPaymentsResponse] (or an [ErrorEvent] with source
/// `getDeferredPayments`).
///
/// By default only outstanding payments (still held, not known to be on the
/// network), newest first, 50 per page. Use [olderThan] or [createdBefore]
/// to find the payments whose recipient has not broadcast them yet, and
/// [includeResolved] (or [states]) to include seen, mined, failed and
/// cancelled ones: nothing is ever deleted.
class GetDeferredPaymentsQuery implements Message {
  final String walletId;

  /// States to list; overrides [includeResolved]. Default: outstanding only.
  final Set<DeferredPaymentState>? states;

  /// List every state (outstanding, seen, mined, failed, cancelled).
  final bool includeResolved;

  /// Only payments recorded strictly before this instant.
  final DateTime? createdBefore;

  /// Only payments recorded at or after this instant.
  final DateTime? createdAfter;

  /// Only payments recorded more than this long ago (combined with
  /// [createdBefore]: the earlier bound wins).
  final Duration? olderThan;

  /// Only payments whose last recorded network status is one of these
  /// (ARC names such as `SEEN_ON_NETWORK`, `NOT_FOUND`, or
  /// [DeferredNetworkStatus.unchecked] for never checked).
  final Set<String>? lastNetworkStatuses;
  final String? invoiceId;

  /// Only payments paying this address.
  final String? recipientAddress;

  /// Page size (1 to 1000).
  final int limit;

  /// [DeferredPaymentsResponse.nextCursor] of the previous page.
  final String? cursor;
  final bool oldestFirst;

  /// Rebuild each payment's BEEF from the stored ancestors and proofs.
  final bool includeBeef;
  final String? queryId;

  GetDeferredPaymentsQuery({
    required this.walletId,
    this.states,
    this.includeResolved = false,
    this.createdBefore,
    this.createdAfter,
    this.olderThan,
    this.lastNetworkStatuses,
    this.invoiceId,
    this.recipientAddress,
    this.limit = 50,
    this.cursor,
    this.oldestFirst = false,
    this.includeBeef = true,
    this.queryId,
  });

  /// The storage query this message asks for, evaluated at [now].
  DeferredPaymentQuery toStorageQuery({DateTime? now}) {
    DateTime? before = createdBefore;
    if (olderThan != null) {
      final cutoff = (now ?? DateTime.now()).subtract(olderThan!);
      if (before == null || cutoff.isBefore(before)) before = cutoff;
    }
    return DeferredPaymentQuery(
      states: states ??
          (includeResolved ? DeferredPaymentQuery.allStates : const {DeferredPaymentState.outstanding}),
      createdBefore: before,
      createdAfter: createdAfter,
      lastNetworkStatuses: lastNetworkStatuses,
      invoiceId: invoiceId,
      recipientAddress: recipientAddress,
      limit: limit,
      cursor: cursor,
      oldestFirst: oldestFirst,
    );
  }

  @override
  String get correlationId => queryId ?? 'get-deferred-payments-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Broadcast a deferred payment yourself, e.g. when the recipient is slow to
/// do it. Its unconfirmed ancestors (from the BEEF rebuilt from storage) are
/// submitted first. Idempotent: a transaction the network already has is
/// reported as such. Answered with [DeferredPaymentBroadcastEvent].
///
/// On an on-network answer the payment's inputs are marked spent; ARC's
/// REJECTED fails the payment and releases them. DOUBLE_SPEND_ATTEMPTED (a
/// competing transaction; not final) keeps the payment outstanding with its
/// inputs held, and is reported with success false.
/// With [via] including the data source, a transaction ARC refuses to take
/// is submitted to the configured `BlockchainDataSource`.
class BroadcastDeferredPaymentCommand implements Message {
  final String walletId;
  final String txid;
  final DeferredPaymentNetworkSource via;
  final String? requestId;

  BroadcastDeferredPaymentCommand({
    required this.walletId,
    required this.txid,
    this.via = DeferredPaymentNetworkSource.arc,
    this.requestId,
  });

  @override
  String get correlationId => requestId ?? 'broadcast-deferred-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Ask the network about a deferred payment now instead of waiting for the
/// periodic ARC scan. Answered with [DeferredPaymentStatusEvent].
///
/// The wallet is updated as for a scan result: SEEN_ON_NETWORK or MINED
/// spends the inputs; a MINED merkle proof is checked against the local
/// headers and confirms the transaction only when it matches (never on a
/// status string alone, whichever source reported it); REJECTED fails the
/// payment and releases its inputs; DOUBLE_SPEND_ATTEMPTED is recorded and
/// keeps them held (ARC may still mine the payment). The
/// status is journaled. [via]: ARC, the configured `BlockchainDataSource`
/// (does it know the transaction; its merkle proof), or ARC then the data
/// source when ARC fails or does not know it.
class CheckDeferredPaymentStatusCommand implements Message {
  final String walletId;
  final String txid;
  final DeferredPaymentNetworkSource via;
  final String? requestId;

  CheckDeferredPaymentStatusCommand({
    required this.walletId,
    required this.txid,
    this.via = DeferredPaymentNetworkSource.arc,
    this.requestId,
  });

  @override
  String get correlationId => requestId ?? 'check-deferred-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Cancel an outstanding deferred payment and release its inputs. Answered
/// with [DeferredPaymentCancelledEvent].
///
/// The network is checked first ([via]); the cancellation is refused when
/// the transaction is known to it (any status other than "not found" and
/// DOUBLE_SPEND_ATTEMPTED, where a competing transaction contests it), and
/// when the check fails, unless [force]. The cancellation is journaled.
///
/// **Cancelling does not revoke the signed transaction the recipient
/// holds.** If they broadcast it later and it still reaches miners, it
/// spends those inputs, and a later payment that reused them will fail (the
/// wallet then records the original payment as seen). To make the old
/// transaction unspendable, spend its inputs back to yourself:
/// [ReclaimDeferredPaymentCommand] does that.
class CancelDeferredPaymentCommand implements Message {
  final String walletId;
  final String txid;
  final String? reason;
  final DeferredPaymentNetworkSource via;

  /// Cancel even when the network could not be asked (never when it knows
  /// the transaction).
  final bool force;
  final String? requestId;

  CancelDeferredPaymentCommand({
    required this.walletId,
    required this.txid,
    this.reason,
    this.via = DeferredPaymentNetworkSource.arc,
    this.force = false,
    this.requestId,
  });

  @override
  String get correlationId => requestId ?? 'cancel-deferred-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

// ==========================================================================
// CHANNEL COMMANDS
// ==========================================================================

/// Open a payment channel with a peer
class OpenChannelCommand implements Message {
  final String walletId;
  final String serverPeerId;
  final int fundingAmountSats;
  final int lockTimeDurationSeconds;
  final String? context;

  /// The app's opaque marker for the counterparty of this channel (bead
  /// libspiffy-bps1, spv-understanding.md "Core Data Management"
  /// requirement 5): it is stamped on the wallet transactions the channel
  /// records — the funding it pays out and the settlement or refund that
  /// comes back. Opaque and app-chosen, exactly as on every other payment;
  /// libspiffy never interprets it.
  ///
  /// Null means "the app supplied none", and the channel then falls back to
  /// the counterparty's peer id, which is a fact it knows rather than one it
  /// invents. Deliberately NOT [context], which is address-derivation and
  /// labelling metadata: one field cannot carry two meanings.
  final String? counterpartyMarker;

  OpenChannelCommand({
    required this.walletId,
    required this.serverPeerId,
    required this.fundingAmountSats,
    required this.lockTimeDurationSeconds,
    this.context,
    this.counterpartyMarker,
  });

  @override
  String get correlationId => 'open-channel-$walletId-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Make a payment over an open channel
class ChannelPayCommand implements Message {
  final String channelId;
  final String walletId;
  final int amountSats;
  final String? purpose;
  final String? invoiceId;

  ChannelPayCommand({
    required this.channelId,
    required this.walletId,
    required this.amountSats,
    this.purpose,
    this.invoiceId,
  });

  @override
  String get correlationId => 'channel-pay-$channelId';
  @override
  Map<String, dynamic> get metadata => {'channelId': channelId, 'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Close a payment channel
class CloseChannelCommand implements Message {
  final String channelId;
  final String? reason;

  CloseChannelCommand({required this.channelId, this.reason});

  @override
  String get correlationId => 'close-channel-$channelId';
  @override
  Map<String, dynamic> get metadata => {'channelId': channelId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Record that a payment channel has expired (lockTime elapsed).
///
/// Issued by the expiry monitor on either side. Routes to PCMA via the
/// channel adapter and ultimately emits [ChannelExpiredEvent] through the
/// aggregate so the read model picks up the transition. Distinct from
/// [CloseChannelCommand] which is the cooperative-close pathway.
class ExpireChannelCommand implements Message {
  final String channelId;
  final String observedBy; // 'client' or 'server'
  final String? settlementOrRefundTxId;

  ExpireChannelCommand({
    required this.channelId,
    required this.observedBy,
    this.settlementOrRefundTxId,
  });

  @override
  String get correlationId => 'expire-channel-$channelId';
  @override
  Map<String, dynamic> get metadata => {'channelId': channelId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Claim the refund of an expired channel (non-cooperative close).
///
/// The client side of a channel holds a fully signed refund from the moment
/// the server countersigns it, valid from the channel's `lockTime` on. This
/// is the command that actually uses it: the library broadcasts the refund
/// through ARC — a transaction WE broadcast, so ARC has standing to answer
/// for it (spv-understanding.md) — journals the claim, and records the
/// refund and its output in the wallet as an unproven receive.
///
/// Distinct from [ExpireChannelCommand], which journals that a channel
/// passed its lockTime and records the refund WITHOUT broadcasting it (an
/// observer of the expiry may not be the one holding the transaction). The
/// two converge: whichever runs first records the refund, and the other
/// records nothing new.
///
/// There is no replace-by-fee on BSV. A broadcast rejected as a double spend
/// is a terminal answer — the response says so and nothing is journaled as
/// claimed; it is never retried at a higher fee.
class ClaimChannelRefundCommand implements Message {
  final String channelId;

  /// The refund to claim. Null uses the fully signed refund the channel
  /// holds, which is the normal case; supply one only to name a specific
  /// transaction (it must still spend the channel's funding output, which
  /// the aggregate checks).
  final String? refundTxHex;

  ClaimChannelRefundCommand({required this.channelId, this.refundTxHex});

  @override
  String get correlationId => 'claim-refund-$channelId';
  @override
  Map<String, dynamic> get metadata => {'channelId': channelId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

// --- Repairing an open that did not finish (bead libspiffy-1n3) ---
//
// Two things can leave a client-side open unfinished, and they are different
// enough to have one command each rather than one command with a mode:
//
//   * the funding broadcast failed (ARC unreachable, the process died
//     mid-broadcast). The channel sits in `refundSigned` and the fix is to
//     broadcast the same transaction again — [RetryChannelFundingCommand].
//   * the funding reached the network and the channel is `open` here, but
//     the `channel_open` message never reached the server. Nothing has to
//     happen on chain and nothing has to be journaled; the fix is to send
//     that one message again — [ResendChannelOpenCommand].
//
// Their preconditions are mutually exclusive (`refundSigned` vs `open`), so
// a single command would have to guess which the host meant from the state
// it finds — and would do something quite different depending on the answer.
//
// **Neither command ever sends the counterparty a `channel_error`.** Driving
// the ordinary open flow again for an already-open channel is worse than
// useless: the aggregate refuses it ('Refund not signed yet'), the refusal
// comes back as a failed open, and the adapter tells the peer the channel
// failed — a host trying to repair a lost message would abandon the channel
// instead. Both commands are answered locally, on the coordinator event
// stream, and change nothing the peer can see except the one message a
// successful resend re-sends.

/// Broadcast the funding transaction of a channel whose funding broadcast
/// failed, so the open can finish (bead libspiffy-1n3).
///
/// For the client side of a channel still in `refundSigned`: its refund is
/// countersigned and journaled, its funding transaction is built and signed,
/// and the broadcast that should have put it on the network did not (ARC was
/// unreachable, or the process died before the answer arrived). Restart
/// recovery reacts to inbound messages; this is how a host asks for the
/// retry itself.
///
/// The funding transaction is **not** supplied by the caller: it is read
/// from the channel's own journaled state, which is the only place it can
/// honestly come from. The aggregate refuses a start naming a different
/// transaction, so a retry can only ever re-broadcast the one the refund
/// spends.
///
/// Safe to issue more than once. The inputs of a failed funding broadcast
/// stay **reserved**, never spent — they are marked spent only after ARC
/// accepts — so a retry cannot double-spend them; there is no replace-by-fee
/// on BSV and no fee is changed. The funding is recorded in the wallet once,
/// guarded by the journal and the wallet read model alike.
///
/// Answered with [ChannelFundingRetriedEvent], on success and failure.
class RetryChannelFundingCommand implements Message {
  final String channelId;

  RetryChannelFundingCommand({required this.channelId});

  @override
  String get correlationId => 'retry-channel-funding-$channelId';
  @override
  Map<String, dynamic> get metadata => {'channelId': channelId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Send `channel_open` again for a channel that is already open on this
/// side, when the counterparty never received it (bead libspiffy-1n3).
///
/// `channel_open` is emitted once, when the channel's `ChannelOpenedEvent`
/// reaches the adapter; nothing re-reads the state and re-emits it. A
/// message the app's transport dropped therefore left the client open and
/// the server still waiting, with no way to repair it.
///
/// This is a **state-driven re-send, not a second open**: the payload is
/// rebuilt from the channel's journaled funding transaction, output index
/// and BEEF, exactly as the first one was. Nothing is journaled — a re-send
/// is not a new fact about the channel — no second `channel.opened` event is
/// written, and the channel's balances and sequence are untouched. The
/// server treats the repeat as it treats the original.
///
/// Refused, locally and without telling the peer anything, for a channel
/// that is not open on this side or that this node is not the client of.
///
/// Answered with [ChannelOpenResentEvent], on success and failure.
class ResendChannelOpenCommand implements Message {
  final String channelId;

  ResendChannelOpenCommand({required this.channelId});

  @override
  String get correlationId => 'resend-channel-open-$channelId';
  @override
  Map<String, dynamic> get metadata => {'channelId': channelId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Accept an incoming channel request
class AcceptChannelCommand implements Message {
  final String channelId;
  final String walletId;
  final String clientPeerId;
  final String clientPubKey;
  final String clientAddress;
  final int fundingAmountSats;
  final int lockTimeUnix;

  /// The app's opaque marker for the counterparty of this channel (bead
  /// libspiffy-bps1, spv-understanding.md "Core Data Management"
  /// requirement 5): it is stamped on the wallet transactions the channel
  /// records — the funding it pays out and the settlement or refund that
  /// comes back. Opaque and app-chosen, exactly as on every other payment;
  /// libspiffy never interprets it.
  ///
  /// Null means "the app supplied none", and the channel then falls back to
  /// the counterparty's peer id, which is a fact it knows rather than one it
  /// invents. Deliberately NOT [context], which is address-derivation and
  /// labelling metadata: one field cannot carry two meanings.
  final String? counterpartyMarker;

  AcceptChannelCommand({
    required this.channelId,
    required this.walletId,
    required this.clientPeerId,
    required this.clientPubKey,
    required this.clientAddress,
    required this.fundingAmountSats,
    required this.lockTimeUnix,
    this.counterpartyMarker,
  });

  @override
  String get correlationId => 'accept-channel-$channelId';
  @override
  Map<String, dynamic> get metadata => {'channelId': channelId, 'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Reject an incoming channel request
class RejectChannelCommand implements Message {
  final String channelId;
  final String? reason;

  RejectChannelCommand({required this.channelId, this.reason});

  @override
  String get correlationId => 'reject-channel-$channelId';
  @override
  Map<String, dynamic> get metadata => {'channelId': channelId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// An inbound peer-to-peer message the app received on its own transport and
/// hands to the library (bead libspiffy-a2v3).
///
/// libspiffy owns no transport: the app carries bytes between peers and
/// describes what arrived as `(fromPeerId, messageType, payload)`. The
/// coordinator routes it by [messageType] — `proof_request` and
/// `proof_response` to the merkle-proof protocol (`ProofP2PAdapter`),
/// everything else to the payment-channel protocol (`ChannelP2PAdapter`).
///
/// [ChannelP2PReceived] is the same thing under its original, channel-named
/// class; it is kept so existing apps compile unchanged, and it is routed by
/// [messageType] exactly like this one.
class P2PMessageReceived implements Message {
  /// The peer that sent it, as the app names peers. The proof protocol
  /// compares this to the counterparty marker recorded on a transaction, so
  /// it must be drawn from the same identity scheme the app puts in
  /// `BitcoinTransaction.counterpartyMarker`.
  final String fromPeerId;
  final String messageType;
  final Map<String, dynamic> payload;

  P2PMessageReceived({
    required this.fromPeerId,
    required this.messageType,
    required this.payload,
  });

  @override
  String get correlationId => 'p2p-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'fromPeerId': fromPeerId, 'messageType': messageType};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Incoming P2P message for a payment channel.
///
/// A [P2PMessageReceived] under its original name: the coordinator routes
/// both by `messageType`, so an app that already wraps everything its
/// transport delivers in this class also reaches the proof protocol.
class ChannelP2PReceived extends P2PMessageReceived {
  ChannelP2PReceived({
    required super.fromPeerId,
    required super.messageType,
    required super.payload,
  });

  @override
  String get correlationId => 'channel-p2p-${DateTime.now().millisecondsSinceEpoch}';
}

/// Ask the counterparty who handed us [txid] for a fresh merkle proof for its
/// ancestry (bead libspiffy-a2v3).
///
/// When a reorganization takes an ancestor's block off the active chain the
/// wallet can no longer walk [txid] back to a proof, so the outputs it gave
/// us cannot go into a BEEF and cannot be spent
/// (`ReadModelStorage.getOutputsAwaitingAncestorProof` lists them). There are
/// exactly two recoveries: the block comes back, or **the counterparty who
/// sent us the payment supplies a fresh BEEF**. This command is the second.
///
/// It is app-triggered: libspiffy never polls a peer for proofs.
///
/// Who is asked is `BitcoinTransaction.counterpartyMarker` on [txid]'s row —
/// the sender of *that* payment, who owed us its ancestry's proofs in the
/// first place, not the ancestor's own (unknown) counterparty. The request
/// goes out as a [P2PMessageToSendEvent] with `messageType` `proof_request`
/// addressed to the marker; the app delivers it. When no marker is recorded
/// (a payment received before markers existed, or an app that supplied none)
/// nobody can be asked: [AncestorProofRequestedEvent] reports the output as
/// unrecoverable by request.
class RequestAncestorProofCommand implements Message {
  final String walletId;

  /// The transaction *we received* whose ancestry no longer reaches a proof.
  final String txid;

  /// The ancestors a proof is wanted for. Informational — the responder
  /// rebuilds the whole BEEF for [txid] — and filled in from
  /// `ReadModelStorage.getOutputsAwaitingAncestorProof` when left empty.
  final List<String> ancestorTxids;

  /// Correlates the answer with this request; generated when omitted.
  final String? requestId;

  RequestAncestorProofCommand({
    required this.walletId,
    required this.txid,
    this.ancestorTxids = const [],
    this.requestId,
  });

  @override
  String get correlationId => requestId ?? 'proof-request-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

// ==========================================================================
// EVENTS (coordinator → app via broadcast stream)
// ==========================================================================

/// Wallet successfully created
class WalletCreatedEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String? rootAddress;
  final bool success;
  final String? error;

  WalletCreatedEvent({
    required this.walletId,
    this.rootAddress,
    required this.success,
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Wallet import progress update
class ImportProgressEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String phase;
  final double progress;
  final String message;
  final int addressesFound;
  final int totalAddresses;
  final int transactionsProcessed;
  final int totalTransactions;

  ImportProgressEvent({
    required this.walletId,
    required this.phase,
    required this.progress,
    required this.message,
    this.addressesFound = 0,
    this.totalAddresses = 0,
    this.transactionsProcessed = 0,
    this.totalTransactions = 0,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Wallet import completed
class ImportCompleteEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final bool success;
  final String? error;
  final int addressCount;
  final int transactionCount;

  ImportCompleteEvent({
    required this.walletId,
    required this.success,
    this.error,
    this.addressCount = 0,
    this.transactionCount = 0,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// UTXO confirmed by aggregate during import
class ImportUTXOConfirmedEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String txid;
  final int vout;
  final bool success;
  final String? error;

  ImportUTXOConfirmedEvent({
    required this.walletId,
    required this.txid,
    required this.vout,
    required this.success,
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Transaction confirmed by aggregate during import
class ImportTransactionConfirmedEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String txid;
  final bool success;
  final String? error;

  ImportTransactionConfirmedEvent({
    required this.walletId,
    required this.txid,
    required this.success,
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Balance query response, computed from the read model.
///
/// [confirmedBalance], [unconfirmedBalance] and [totalBalance] are the
/// spendable balance: the wallet's payment UTXOs
/// (`ReadModelStorage.getPaymentUTXOs`: status available, not
/// plugin-managed, i.e. no plugin metadata naming a `pluginId`), any number
/// of confirmations. Pending, reserved (a deferred payment's held inputs
/// included) and spent UTXOs are left out; UTXOs at watch addresses, which
/// the wallet holds no key for, are left out and reported in
/// [watchOnlyBalance] (bead libspiffy-87a2); bare multisig UTXOs the wallet
/// cannot spend alone are left out (bead libspiffy-0k8). [totalBalance] is
/// `ReadModelStorage.getBalance`.
///
/// The UTXOs are those `WalletState.availableBalance` counts on the wallet
/// aggregate (spv-understanding.md, "Balances"; the inputs of a deferred
/// payment recorded before holds were journaled leave the read side when the
/// wallet manager reconciles it at spawn); the confirmed/unconfirmed split
/// here is by block height, which since bead libspiffy-jc3h is the split
/// every layer makes (`WalletBalances.bucketOf`): a merkle proof on our
/// active chain confirms at depth one, and no threshold of confirmations
/// exists anywhere.
class BalanceResponse extends CoordinatorEvent {
  @override
  final String walletId;
  final String queryId;

  /// Payment UTXOs with a block height (greater than zero): mined, however
  /// few confirmations they have.
  final BigInt confirmedBalance;

  /// Payment UTXOs with no block height (not known to be mined).
  final BigInt unconfirmedBalance;

  /// [confirmedBalance] + [unconfirmedBalance].
  final BigInt totalBalance;

  /// Value of the wallet's unspent UTXOs at watch addresses: credited to the
  /// wallet but not spendable by it, and not part of [totalBalance].
  final BigInt watchOnlyBalance;

  BalanceResponse({
    required this.walletId,
    required this.queryId,
    required this.confirmedBalance,
    required this.unconfirmedBalance,
    required this.totalBalance,
    BigInt? watchOnlyBalance,
  }) : watchOnlyBalance = watchOnlyBalance ?? BigInt.zero;

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Transactions query response
class TransactionsResponse extends CoordinatorEvent {
  @override
  final String walletId;
  final String queryId;
  final List<BitcoinTransaction> transactions;

  TransactionsResponse({
    required this.walletId,
    required this.queryId,
    required this.transactions,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Transaction detail query response
class TransactionDetailResponse extends CoordinatorEvent {
  @override
  final String walletId;
  final String queryId;
  final BitcoinTransaction? transaction;
  final bool found;
  final String? error;

  TransactionDetailResponse({
    required this.walletId,
    required this.queryId,
    this.transaction,
    this.found = true,
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Balance updated asynchronously (e.g., new UTXO received)
class BalanceUpdatedEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final BigInt confirmedBalance;
  final BigInt unconfirmedBalance;
  final BigInt totalBalance;

  BalanceUpdatedEvent({
    required this.walletId,
    required this.confirmedBalance,
    required this.unconfirmedBalance,
    required this.totalBalance,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Transaction received (incoming or outgoing detected)
class TransactionReceivedEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String txid;
  final BigInt amountSatoshis;
  final bool isIncoming;

  TransactionReceivedEvent({
    required this.walletId,
    required this.txid,
    required this.amountSatoshis,
    required this.isIncoming,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// A merkle proof put the transaction in the block at [blockHeight], whose
/// header we hold on our active chain: confirmed, and there is nothing more
/// to it (bead libspiffy-jc3h).
///
/// It carries no confirmation count. It used to default one to 1 — a number
/// nothing measured and nothing advanced — and a count is not evidence of
/// anything in any case. An application that wants a depth computes
/// `tip height - blockHeight + 1`.
class TransactionConfirmedEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String txid;
  final int blockHeight;

  TransactionConfirmedEvent({
    required this.walletId,
    required this.txid,
    required this.blockHeight,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Invoice created successfully
class InvoiceCreatedEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String invoiceId;
  final List<String> addresses;
  final BigInt amount;
  final List<InvoiceOutputSpec>? outputs;
  final String? description;
  final DateTime? expiresAt;
  final bool success;
  final String? error;

  InvoiceCreatedEvent({
    required this.walletId,
    required this.invoiceId,
    required this.addresses,
    required this.amount,
    this.outputs,
    this.description,
    this.expiresAt,
    required this.success,
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Invoice paid
class InvoicePaidEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String invoiceId;
  final String txid;
  final BigInt amountReceived;

  InvoicePaidEvent({
    required this.walletId,
    required this.invoiceId,
    required this.txid,
    required this.amountReceived,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// BEEF payment constructed and ready for transmission to counterparty
class PaymentReadyEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String invoiceId;
  final Uint8List beefBytes;
  final String txid;
  final BigInt amountPaid;
  final BigInt changeAmount;
  final int ancestorCount;
  final bool success;
  final String? error;

  /// Witness transaction ID (null if no paired witness).
  final String? witnessTxid;

  /// Serialized BEEF for the witness transaction (null if no paired witness).
  final Uint8List? witnessBeefBytes;

  PaymentReadyEvent({
    this.walletId,
    required this.invoiceId,
    required this.beefBytes,
    required this.txid,
    required this.amountPaid,
    required this.changeAmount,
    required this.ancestorCount,
    required this.success,
    this.error,
    this.witnessTxid,
    this.witnessBeefBytes,
  });

  PaymentReadyEvent.error({
    this.walletId,
    required this.invoiceId,
    required String errorMessage,
  })  : beefBytes = Uint8List(0),
        txid = '',
        amountPaid = BigInt.zero,
        changeAmount = BigInt.zero,
        ancestorCount = 0,
        success = false,
        error = errorMessage,
        witnessTxid = null,
        witnessBeefBytes = null;

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Funding provisioning completed (earmarked UTXOs created).
class ProvisioningCompleteEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final int transactionCount;
  final int earmarkCount;
  final bool success;
  final String? error;

  ProvisioningCompleteEvent({
    this.walletId,
    required this.transactionCount,
    required this.earmarkCount,
    required this.success,
    this.error,
  });

  ProvisioningCompleteEvent.error({
    this.walletId,
    required String errorMessage,
  })  : transactionCount = 0,
        earmarkCount = 0,
        success = false,
        error = errorMessage;

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// BEEF validation result
class BEEFValidationResultEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String? invoiceId;
  final String? txid;
  final bool valid;
  final String? error;
  final bool broadcasted;
  final List<Map<String, dynamic>>? spendableUTXOs;

  BEEFValidationResultEvent({
    this.walletId,
    this.invoiceId,
    this.txid,
    required this.valid,
    this.error,
    this.broadcasted = false,
    this.spendableUTXOs,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// SPV validation result for a received transaction
class SPVValidationResultEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String txid;
  final bool isValid;
  final String? validationError;
  final List<Map<String, dynamic>> spendableUTXOs;
  final List<Map<String, dynamic>> spentUTXOs;

  /// Outputs whose locking script could not be read, so they were not
  /// attributed (see SPVValidationResult.unreadableOutputs).
  final List<Map<String, dynamic>> unreadableOutputs;

  SPVValidationResultEvent({
    this.walletId,
    required this.txid,
    required this.isValid,
    this.validationError,
    this.spendableUTXOs = const [],
    this.spentUTXOs = const [],
    this.unreadableOutputs = const [],
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Broadcast to Arc failed (transaction queued for retry via duraq)
class BroadcastFailureEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String txid;
  final String error;
  final bool willRetry;

  BroadcastFailureEvent({
    this.walletId,
    required this.txid,
    required this.error,
    this.willRetry = true,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Result of settling a BEEF via ARC.
///
/// `submittedCount` is the number of TXs successfully accepted by ARC.
/// `skippedCount` is the number of TXs skipped because they were already on
/// chain (hasMerkle=true). `failedCount` is the number of TXs that ARC
/// rejected; their txids and per-tx error messages are in `failedTxids`
/// and `failureErrors` (same length, same index). `error` is an
/// aggregated summary for display.
class BEEFSettledEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String txid;
  final bool success;
  final String? error;
  final int submittedCount;
  final int skippedCount;
  final int failedCount;
  final List<String> failedTxids;
  final List<String> failureErrors;

  BEEFSettledEvent({
    this.walletId,
    required this.txid,
    required this.success,
    this.error,
    this.submittedCount = 0,
    this.skippedCount = 0,
    this.failedCount = 0,
    this.failedTxids = const [],
    this.failureErrors = const [],
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Transaction imported into wallet
class TransactionImportedEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String transactionId;
  final bool success;
  final int? utxosCreated;
  final String? totalValueReceived;
  final String? error;

  TransactionImportedEvent({
    required this.walletId,
    required this.transactionId,
    required this.success,
    this.utxosCreated,
    this.totalValueReceived,
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Block headers stored
class BlockHeadersStoredEvent extends CoordinatorEvent {
  @override
  String? get walletId => null;
  final int headersStored;
  final int startHeight;
  final int endHeight;
  final bool success;
  final String? error;

  BlockHeadersStoredEvent({
    required this.headersStored,
    required this.startHeight,
    required this.endHeight,
    required this.success,
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Watch address registered
class WatchAddressRegisteredEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String address;
  final bool success;
  final String? error;

  WatchAddressRegisteredEvent({
    required this.walletId,
    required this.address,
    required this.success,
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}


// --- Deferred Payment Events (bead libspiffy-7p2) ---

/// One deferred payment in a [DeferredPaymentsResponse], with what is needed
/// to act on it.
class DeferredPaymentDetail {
  final DeferredPayment payment;

  /// The signed transaction (null only if its row is missing).
  final String? rawTxHex;

  /// The BEEF rebuilt from stored ancestors and proofs, when requested and
  /// the chain back to proven ancestors is stored.
  final Uint8List? beef;

  /// Why [beef] is null although it was requested.
  final String? beefError;

  const DeferredPaymentDetail({required this.payment, this.rawTxHex, this.beef, this.beefError});

  String get txid => payment.txid;
  String? get invoiceId => payment.invoiceId;
  List<String> get recipientAddresses => payment.recipientAddresses;
  BigInt get amount => payment.amount;
  BigInt get fee => payment.fee;
  DateTime get createdAt => payment.createdAt;
  List<DeferredPaymentInput> get heldInputs => payment.heldInputs;
  String? get lastNetworkStatus => payment.lastNetworkStatus;
  DateTime? get lastCheckedAt => payment.lastCheckedAt;

  /// The competing transactions ARC named for this payment (bead
  /// libspiffy-pkum; see [DeferredPayment.competingTxids]).
  List<String> get competingTxids => payment.competingTxids;
  DeferredPaymentState get state => payment.state;

  /// What this payment is for, as the wallet recorded it (bead
  /// libspiffy-fzjv; see [DeferredPayment.purpose]).
  ///
  /// The values the wallet sets itself are in [DeferredPaymentPurpose]: a
  /// reclaim's self-spend carries `reclaim:<txid of the payment it
  /// reclaims>`, and [reclaimsTxid] reads that txid off it.
  String? get purpose => payment.purpose;

  /// Why this payment is in the state it is: ARC's reason for a failure, the
  /// user's reason for a cancellation, or — for a payment a reclaim
  /// resolved — the self-spend that reclaimed it (bead libspiffy-fzjv; see
  /// [DeferredPayment.resolutionReason]). Null while it is outstanding.
  String? get resolutionReason => payment.resolutionReason;

  /// The deferred payment this one reclaims, when it is a reclaim's
  /// self-spend; null for every other payment (bead libspiffy-fzjv).
  ///
  /// The link runs both ways: the self-spend names the payment here, and the
  /// payment names the self-spend in its [resolutionReason] once the network
  /// has it (`DeferredPayment.reclaimedBy`).
  String? get reclaimsTxid => DeferredPaymentPurpose.reclaimedTxid(payment.purpose);

  /// Whether this payment is a reclaim's self-spend ([reclaimsTxid] is set).
  bool get isReclaim => reclaimsTxid != null;
}

/// Answer to [GetDeferredPaymentsQuery].
class DeferredPaymentsResponse extends CoordinatorEvent {
  @override
  final String walletId;
  final String queryId;
  final List<DeferredPaymentDetail> payments;

  /// Pass as [GetDeferredPaymentsQuery.cursor] for the next page; null on
  /// the last page.
  final String? nextCursor;

  DeferredPaymentsResponse({
    required this.walletId,
    required this.queryId,
    required this.payments,
    this.nextCursor,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Result of [BroadcastDeferredPaymentCommand].
class DeferredPaymentBroadcastEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String txid;
  final String requestId;

  /// The source took the transaction (or already had it).
  final bool success;

  /// The source's answer (`SEEN_ON_NETWORK`, `MINED`, `REJECTED`, ...).
  final String? networkStatus;

  /// `arc` or `dataSource`.
  final String? source;

  /// A MINED answer's merkle proof checked against the local headers
  /// confirmed the transaction.
  final bool confirmed;

  /// The failed broadcast was queued for a durable retry.
  final bool willRetry;
  final String? error;

  /// The competing transactions ARC named with a DOUBLE_SPEND_ATTEMPTED
  /// answer (bead libspiffy-pkum); empty otherwise.
  final List<String> competingTxids;

  DeferredPaymentBroadcastEvent({
    required this.walletId,
    required this.txid,
    required this.requestId,
    required this.success,
    this.networkStatus,
    this.source,
    this.confirmed = false,
    this.willRetry = false,
    this.error,
    this.competingTxids = const [],
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Result of [CheckDeferredPaymentStatusCommand].
class DeferredPaymentStatusEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String txid;
  final String requestId;

  /// A source answered ([networkStatus] set).
  final bool success;

  /// `SEEN_ON_NETWORK`, `MINED`, `REJECTED`, `NOT_FOUND`, ...
  final String? networkStatus;

  /// `arc` or `dataSource`.
  final String? source;
  final int? blockHeight;

  /// Outcome of checking a MINED merkle proof against the local headers:
  /// `verified`, `headerUnknown` (confirmed once the header arrives),
  /// `rootMismatch` or `malformed` (not confirmed), or null without a proof.
  final String? proofStatus;

  /// The proof matched the stored header and the transaction is confirmed.
  final bool confirmed;
  final String? error;

  /// The competing transactions ARC named with a DOUBLE_SPEND_ATTEMPTED
  /// answer (bead libspiffy-pkum); empty otherwise.
  final List<String> competingTxids;

  DeferredPaymentStatusEvent({
    required this.walletId,
    required this.txid,
    required this.requestId,
    required this.success,
    this.networkStatus,
    this.source,
    this.blockHeight,
    this.proofStatus,
    this.confirmed = false,
    this.error,
    this.competingTxids = const [],
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Result of [CancelDeferredPaymentCommand].
class DeferredPaymentCancelledEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String txid;
  final String requestId;
  final bool success;

  /// What the network check before the cancellation answered.
  final String? networkStatus;

  /// Inputs returned to their previous status.
  final List<String> releasedUtxoKeys;
  final String? error;

  DeferredPaymentCancelledEvent({
    required this.walletId,
    required this.txid,
    required this.requestId,
    required this.success,
    this.networkStatus,
    this.releasedUtxoKeys = const [],
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

// --- Channel Events ---

/// Incoming channel request from a peer (app should show UI for approval)
class ChannelRequestReceivedEvent extends CoordinatorEvent {
  @override
  String? get walletId => null;
  final String channelId;
  final String clientPeerId;
  final String clientPubKey;
  final String clientAddress;
  final int fundingAmountSats;
  final int lockTimeUnix;
  final String? context;

  ChannelRequestReceivedEvent({
    required this.channelId,
    required this.clientPeerId,
    required this.clientPubKey,
    required this.clientAddress,
    required this.fundingAmountSats,
    required this.lockTimeUnix,
    this.context,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Channel opened successfully
class ChannelOpenedEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String channelId;
  final String? fundingTxId;
  final int fundingAmountSats;

  ChannelOpenedEvent({
    required this.walletId,
    required this.channelId,
    this.fundingTxId,
    required this.fundingAmountSats,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// The outcome of a [RetryChannelFundingCommand] (bead libspiffy-1n3).
///
/// [success] means the funding transaction reached the network on this
/// attempt and the channel is open on this side; the ordinary
/// [ChannelOpenedEvent] follows, and `channel_open` goes to the server as it
/// does on a first open.
///
/// A failure is reported here and nowhere else: the counterparty is told
/// nothing, so a retry that fails again leaves the channel exactly as it
/// was, its inputs still reserved for the same transaction, ready for
/// The outcome of a [ClaimChannelRefundCommand] (bead libspiffy-cqc, the
/// V-99 follow-up).
///
/// The claim broadcasts the refund, journals it and records the money back
/// in the wallet. None of that reaches the host on its own: unlike a close,
/// which surfaces through the channel's own `ChannelClosedEvent`, a claim
/// has no event the adapter forwards. Without this the host could not tell
/// a refund that landed from one the network refused as a double spend.
class ChannelRefundClaimedEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String channelId;

  /// The refund that was broadcast and journaled; null when the claim
  /// failed before one was read from the channel's state.
  final String? refundTxId;

  final bool success;
  final String? error;

  ChannelRefundClaimedEvent({
    this.walletId,
    required this.channelId,
    this.refundTxId,
    required this.success,
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// another retry.
class ChannelFundingRetriedEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String channelId;

  /// The funding transaction that was re-broadcast; null when the retry was
  /// refused before one was read from the channel's state.
  final String? fundingTxId;

  final bool success;
  final String? error;

  ChannelFundingRetriedEvent({
    this.walletId,
    required this.channelId,
    this.fundingTxId,
    required this.success,
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// The outcome of a [ResendChannelOpenCommand] (bead libspiffy-1n3).
///
/// [success] means `channel_open` was handed to the app's transport again,
/// with the same payload as the first one ([toPeerId] names the peer it was
/// addressed to). Nothing was journaled and nothing about the channel
/// changed.
///
/// A failure — the channel is not open here, this node is not its client,
/// no counterparty peer is known — is reported here only. No
/// `channel_error` is sent: a re-send that cannot happen is not a channel
/// that has been abandoned.
class ChannelOpenResentEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String channelId;

  /// The peer `channel_open` was re-sent to; null when it was not sent.
  final String? toPeerId;

  /// The funding transaction the re-sent message names; null on failure.
  final String? fundingTxId;

  final bool success;
  final String? error;

  ChannelOpenResentEvent({
    this.walletId,
    required this.channelId,
    this.toPeerId,
    this.fundingTxId,
    required this.success,
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Payment made or received on a channel
class ChannelPaymentEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String channelId;
  final int amountSats;
  final int sequence;
  final int clientBalance;
  final int serverBalance;

  ChannelPaymentEvent({
    this.walletId,
    required this.channelId,
    required this.amountSats,
    required this.sequence,
    required this.clientBalance,
    required this.serverBalance,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Channel closed
class ChannelClosedEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String channelId;
  final String? reason;
  final String? settlementTxId;

  ChannelClosedEvent({
    this.walletId,
    required this.channelId,
    this.reason,
    this.settlementTxId,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// An outgoing peer-to-peer message the app must transmit to [toPeerId] on
/// its own transport (bead libspiffy-a2v3).
///
/// The library builds the payload and names the peer; carrying it is the
/// app's job. [ChannelP2PMessageToSendEvent] is this event under its
/// original, channel-named class, so an app that listens for the channel
/// class keeps working; the merkle-proof protocol emits this base class with
/// `messageType` `proof_request` / `proof_response`, so **an app that wants
/// proof recovery must listen for [P2PMessageToSendEvent]**.
class P2PMessageToSendEvent extends CoordinatorEvent {
  @override
  String? get walletId => null;
  final String toPeerId;
  final String messageType;
  final Map<String, dynamic> payload;

  P2PMessageToSendEvent({
    required this.toPeerId,
    required this.messageType,
    required this.payload,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Outgoing P2P message that the app must transmit to the peer
class ChannelP2PMessageToSendEvent extends P2PMessageToSendEvent {
  ChannelP2PMessageToSendEvent({
    required super.toPeerId,
    required super.messageType,
    required super.payload,
  });
}

/// What became of a [RequestAncestorProofCommand] (bead libspiffy-a2v3).
///
/// [success] only says the request went out (as a [P2PMessageToSendEvent] to
/// [toPeerId]); the answer arrives later as an [AncestorProofResponseEvent].
/// [success] is false, with [toPeerId] null, when nobody can be asked: the
/// transaction is not stored, or its row carries no counterparty marker, in
/// which case the output is unrecoverable by request and only the block
/// returning to the active chain can restore it.
class AncestorProofRequestedEvent extends CoordinatorEvent {
  @override
  final String walletId;

  /// The received transaction whose ancestry is missing a proof.
  final String txid;

  /// The counterparty marker recorded on [txid], which is who was asked.
  /// Null when there is none to ask.
  final String? toPeerId;

  /// The ancestors named in the request.
  final List<String> ancestorTxids;

  final String requestId;
  final bool success;
  final String? error;

  AncestorProofRequestedEvent({
    required this.walletId,
    required this.txid,
    required this.requestId,
    required this.success,
    this.toPeerId,
    this.ancestorTxids = const [],
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// What became of a `proof_response` a counterparty sent back
/// (bead libspiffy-a2v3).
///
/// The BEEF went through the ordinary receive path, so it was verified
/// against our own header chain like every other incoming proof. [success] is
/// true only when it verified and the fresh proof was stored; a response that
/// does not verify is rejected here (the output stays awaiting a proof) and
/// the BEEF is still retained as evidence of what the counterparty handed us.
class AncestorProofResponseEvent extends CoordinatorEvent {
  @override
  final String? walletId;

  /// The transaction the response was about.
  final String txid;

  /// The peer that answered.
  final String fromPeerId;

  /// The request this answers, when it named one.
  final String? requestId;

  final bool success;
  final String? error;

  AncestorProofResponseEvent({
    required this.walletId,
    required this.txid,
    required this.fromPeerId,
    required this.success,
    this.requestId,
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// A `proof_request` a peer sent us, and what we did about it
/// (bead libspiffy-a2v3).
///
/// Emitted on the *responder*. [answered] is false when the request was
/// refused: we hold no such transaction, its row records no counterparty
/// marker, the requester is not the counterparty we recorded for it, or we
/// cannot prove it ourselves either. [reason] says which, for our own logs
/// only: the refusal that goes back on the wire is uniform, so a peer cannot
/// learn which transactions we know by asking.
class AncestorProofRequestReceivedEvent extends CoordinatorEvent {
  @override
  String? get walletId => null;

  final String fromPeerId;
  final String txid;
  final String? requestId;
  final bool answered;
  final String? reason;

  AncestorProofRequestReceivedEvent({
    required this.fromPeerId,
    required this.txid,
    required this.answered,
    this.requestId,
    this.reason,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

// --- Benford Split Events ---

/// Benford UTXO split started
class UTXOSplitStartedEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final int utxoCount;
  final int targetOutputsPerUtxo;

  UTXOSplitStartedEvent({
    required this.walletId,
    required this.utxoCount,
    required this.targetOutputsPerUtxo,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Benford UTXO split completed.
///
/// [success] follows ARC's answer to every split transaction (bead
/// libspiffy-wdch): a split ARC accepted or queued for a retry succeeds, one
/// it rejected or reports contested does not; [splits] tells each apart.
class UTXOSplitCompleteEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final int transactionCount;
  final int newUtxoCount;
  final BigInt totalFeePaid;
  final bool success;
  final String? error;

  /// The split transactions ARC accepted or queued for a retry.
  final List<String> txids;

  /// How each split transaction that was built and signed ended, in the
  /// order the source UTXOs were split.
  final List<SplitTransactionOutcome> splits;

  UTXOSplitCompleteEvent({
    required this.walletId,
    required this.transactionCount,
    required this.newUtxoCount,
    required this.totalFeePaid,
    required this.success,
    this.error,
    this.txids = const [],
    this.splits = const [],
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// How one Benford split transaction ended (bead libspiffy-wdch). A split is
/// recorded as a deferred payment before it is broadcast (bead
/// libspiffy-ypp), so every status but [notRecorded] names a transaction the
/// wallet lists (`GetDeferredPaymentsQuery`) until the network settles it.
enum SplitTransactionStatus {
  /// ARC accepted the broadcast: `SEEN_ON_NETWORK`, `MINED`, or another
  /// status of a transaction ARC holds on its way to miners.
  accepted,

  /// ARC could not be reached; ARCActor queued the broadcast for a durable
  /// retry. The split holds its source meanwhile.
  queued,

  /// ARC reports `DOUBLE_SPEND_ATTEMPTED`: a competing transaction spends
  /// the source. Not final (bead libspiffy-ey2): the source stays held until
  /// ARC reports one of them mined, or the split is cancelled.
  contested,

  /// ARC reports `REJECTED`: the split failed and its source is released.
  rejected,

  /// Recorded (its source held) but neither broadcast nor queued: no ARC
  /// service, or a failed submission with no retry queue. Broadcast it with
  /// `BroadcastDeferredPaymentCommand` or cancel it with
  /// `CancelDeferredPaymentCommand`.
  notBroadcast,

  /// ARCActor did not answer the broadcast in time. The split is recorded
  /// and holds its source; its network status is not known yet.
  unanswered,

  /// The wallet refused the recording, or did not acknowledge it in time;
  /// not broadcast. A recording the wallet journals late is cancelled.
  notRecorded,
}

/// One Benford split transaction and how it ended ([SplitTransactionStatus]).
class SplitTransactionOutcome {
  final String txid;

  /// The UTXO the transaction splits (`txid:vout`).
  final String sourceUtxoKey;
  final SplitTransactionStatus status;

  /// ARC's status, when ARC answered with one.
  final String? networkStatus;

  /// Why the split did not succeed, or what ARC said about it.
  final String? error;

  const SplitTransactionOutcome({
    required this.txid,
    required this.sourceUtxoKey,
    required this.status,
    this.networkStatus,
    this.error,
  });

  /// ARC accepted the split or queued it for a retry.
  bool get isSuccess => status == SplitTransactionStatus.accepted || status == SplitTransactionStatus.queued;

  @override
  String toString() => 'SplitTransactionOutcome($txid of $sourceUtxoKey: ${status.name}'
      '${networkStatus != null ? ' $networkStatus' : ''}${error != null ? ', $error' : ''})';
}

// --- Archive Events ---

/// Timestamp archive completed
class TimestampCompleteEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String archiveId;
  final String? transactionId;
  final bool success;
  final String? error;

  TimestampCompleteEvent({
    this.walletId,
    required this.archiveId,
    this.transactionId,
    required this.success,
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

// --- Header Sync Events ---

/// CDN/P2P header sync progress
class HeaderSyncProgressEvent extends CoordinatorEvent {
  @override
  String? get walletId => null;
  final int currentHeight;
  final int totalHeight;
  final String phase;

  HeaderSyncProgressEvent({
    required this.currentHeight,
    required this.totalHeight,
    required this.phase,
  });

  double get progress => totalHeight > 0 ? currentHeight / totalHeight : 0;

  @override
  DateTime get eventTimestamp => DateTime.now();
}

// --- Status & Error Events ---

/// Wallet status update
class WalletStatusEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String status;
  final String message;

  WalletStatusEvent({
    this.walletId,
    required this.status,
    required this.message,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

/// Error from the coordinator
class ErrorEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String source;
  final String message;
  final String? stackTrace;

  ErrorEvent({
    this.walletId,
    required this.source,
    required this.message,
    this.stackTrace,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}

// ==========================================================================
// RECLAIMING A DEFERRED PAYMENT (bead libspiffy-87a)
// ==========================================================================

/// Reclaim an outstanding deferred payment: spend the inputs it holds back
/// into this wallet and broadcast that transaction. Answered with
/// [DeferredPaymentReclaimedEvent].
///
/// **Immediate and irreversible.** There is no confirmation step, no dry
/// run: the self-spend is built, signed, journaled and broadcast by this one
/// command. libspiffy does not own confirmation UX — warn the user first if
/// your app wants that.
///
/// **It invalidates the signed transaction the recipient holds.** Both spend
/// the same inputs, and only one of two transactions spending an input can
/// be mined. Unlike [CancelDeferredPaymentCommand], which only releases the
/// hold and leaves the recipient's copy spendable, a reclaim takes the coins
/// out of its reach.
///
/// This is Bitcoin SV: there is no replace-by-fee, and **first seen wins**.
/// The self-spend pays the standard ARC policy fee, like every other
/// transaction the wallet builds; paying more would buy nothing. If the
/// recipient already got their copy to the network first, theirs is the one
/// that is mined and the self-spend is the one rejected — an ordering fact,
/// decided before this command was sent.
///
/// The payment is **not** resolved at broadcast time: it stays outstanding,
/// with its inputs now held by the self-spend, until the network reports the
/// self-spend. It is then [DeferredPaymentState.reclaimed] and the coins are
/// back in the wallet, less the fee.
///
/// Nothing is deleted: the reclaimed payment keeps its row, its stored
/// transaction and its raw hex, and both txids stay queryable
/// ([GetDeferredPaymentsQuery] with `includeResolved`).
class ReclaimDeferredPaymentCommand implements Message {
  final String walletId;

  /// The outstanding deferred payment to reclaim.
  final String txid;

  /// Where the self-spend is broadcast.
  final DeferredPaymentNetworkSource via;

  /// Recorded as the reclaimed payment's resolution reason.
  final String? reason;
  final String? requestId;

  ReclaimDeferredPaymentCommand({
    required this.walletId,
    required this.txid,
    this.via = DeferredPaymentNetworkSource.arc,
    this.reason,
    this.requestId,
  });

  @override
  String get correlationId => requestId ?? 'reclaim-deferred-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Result of [ReclaimDeferredPaymentCommand].
///
/// [success] says the self-spend was journaled and the network took it, not
/// that the payment is reclaimed yet: it resolves as
/// [DeferredPaymentState.reclaimed] when the network reports the self-spend
/// (watch it with [GetDeferredPaymentsQuery] or
/// [CheckDeferredPaymentStatusCommand] on [reclaimTxid]).
class DeferredPaymentReclaimedEvent extends CoordinatorEvent {
  @override
  final String walletId;

  /// The deferred payment being reclaimed.
  final String txid;

  /// The wallet's self-spend of its held inputs, null when none was built.
  final String? reclaimTxid;
  final String requestId;
  final bool success;

  /// The inputs the self-spend spends.
  final List<String> reclaimedUtxoKeys;

  /// What comes back to the wallet: the held satoshis less [fee].
  final BigInt? reclaimedSatoshis;

  /// The standard policy fee the self-spend pays (ARC's published mining
  /// fee for its size). Never raised to outbid anything: on BSV a
  /// conflicting transaction cannot be displaced by paying more.
  final BigInt? fee;

  /// The wallet address the self-spend pays.
  final String? toAddress;

  /// The network's answer to the broadcast of the self-spend.
  final String? networkStatus;
  final String? source;

  /// Transactions the network named as spending the same inputs — the
  /// recipient's copy, when they got it out first.
  final List<String> competingTxids;
  final String? error;

  DeferredPaymentReclaimedEvent({
    required this.walletId,
    required this.txid,
    required this.requestId,
    required this.success,
    this.reclaimTxid,
    this.reclaimedUtxoKeys = const [],
    this.reclaimedSatoshis,
    this.fee,
    this.toAddress,
    this.networkStatus,
    this.source,
    this.competingTxids = const [],
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
}
