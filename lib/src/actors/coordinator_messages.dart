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

  PayInvoiceCommand({
    required this.walletId,
    required this.invoiceId,
    required this.addresses,
    required this.amount,
    this.outputs,
    this.changeAddress,
    this.paymentMetadata,
    this.feeEstimateSats,
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

  ValidateBEEFCommand({
    required this.walletId,
    required this.beefHex,
    this.invoiceId,
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
/// transaction unspendable, spend its inputs back to yourself instead (not
/// provided by this command).
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

  OpenChannelCommand({
    required this.walletId,
    required this.serverPeerId,
    required this.fundingAmountSats,
    required this.lockTimeDurationSeconds,
    this.context,
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

/// Accept an incoming channel request
class AcceptChannelCommand implements Message {
  final String channelId;
  final String walletId;
  final String clientPeerId;
  final String clientPubKey;
  final String clientAddress;
  final int fundingAmountSats;
  final int lockTimeUnix;

  AcceptChannelCommand({
    required this.channelId,
    required this.walletId,
    required this.clientPeerId,
    required this.clientPubKey,
    required this.clientAddress,
    required this.fundingAmountSats,
    required this.lockTimeUnix,
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

/// Incoming P2P message for a payment channel
class ChannelP2PReceived implements Message {
  final String fromPeerId;
  final String messageType;
  final Map<String, dynamic> payload;

  ChannelP2PReceived({
    required this.fromPeerId,
    required this.messageType,
    required this.payload,
  });

  @override
  String get correlationId => 'channel-p2p-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'fromPeerId': fromPeerId, 'messageType': messageType};
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
/// wallet manager reconciles it at spawn); the confirmed/unconfirmed
/// split here is by block height, not by the six confirmations of
/// `WalletBalances.confirmedAt`.
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

/// Transaction confirmed on-chain
class TransactionConfirmedEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String txid;
  final int blockHeight;
  final int confirmations;

  TransactionConfirmedEvent({
    required this.walletId,
    required this.txid,
    required this.blockHeight,
    this.confirmations = 1,
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
  DeferredPaymentState get state => payment.state;
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

/// Outgoing P2P message that the app must transmit to the peer
class ChannelP2PMessageToSendEvent extends CoordinatorEvent {
  @override
  String? get walletId => null;
  final String toPeerId;
  final String messageType;
  final Map<String, dynamic> payload;

  ChannelP2PMessageToSendEvent({
    required this.toPeerId,
    required this.messageType,
    required this.payload,
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

/// Benford UTXO split completed
class UTXOSplitCompleteEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final int transactionCount;
  final int newUtxoCount;
  final BigInt totalFeePaid;
  final bool success;
  final String? error;

  UTXOSplitCompleteEvent({
    required this.walletId,
    required this.transactionCount,
    required this.newUtxoCount,
    required this.totalFeePaid,
    required this.success,
    this.error,
  });

  @override
  DateTime get eventTimestamp => DateTime.now();
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
