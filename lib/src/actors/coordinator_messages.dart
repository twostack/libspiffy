import 'dart:typed_data';

import 'package:dactor/dactor.dart';

import '../models/bitcoin_transaction.dart';
import '../models/bitcoin_utxo.dart';
import '../models/invoice_output_spec.dart';
import 'invoice_messages.dart' show InvoiceStatus;

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

/// Balance query response
class BalanceResponse extends CoordinatorEvent {
  @override
  final String walletId;
  final String queryId;
  final BigInt confirmedBalance;
  final BigInt unconfirmedBalance;
  final BigInt totalBalance;

  BalanceResponse({
    required this.walletId,
    required this.queryId,
    required this.confirmedBalance,
    required this.unconfirmedBalance,
    required this.totalBalance,
  });

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

  SPVValidationResultEvent({
    this.walletId,
    required this.txid,
    required this.isValid,
    this.validationError,
    this.spendableUTXOs = const [],
    this.spentUTXOs = const [],
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
