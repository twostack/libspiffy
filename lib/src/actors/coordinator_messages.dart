import 'dart:typed_data';

import 'package:dactor/dactor.dart';

import '../models/address_chain.dart';
import '../models/brc100_key_request.dart';
import '../models/bitcoin_transaction.dart';
import '../models/deferred_payment.dart';
import '../models/foreign_spend.dart';
import '../models/payment_privacy.dart';
import '../models/invoice_output_spec.dart';
import '../models/key_path.dart';
import '../models/persistent_map.dart';
import '../utils/unique_id.dart';

export '../models/deferred_payment.dart';

/// Base class for all coordinator events emitted on the event stream.
///
/// Third-party apps subscribe to `Stream<CoordinatorEvent>` to receive
/// async results from the coordinator, or wait for one request's answer
/// with `WalletCoordinator.ask`.
abstract class CoordinatorEvent {
  CoordinatorEvent() : eventTimestamp = DateTime.now();

  /// Optional wallet ID for filtering events by wallet
  String? get walletId;

  /// When the event was made.
  final DateTime eventTimestamp;
}

/// The event that answers a [CoordinatorRequest]: each request names its
/// reply type, and the coordinator answers it with exactly one, on success
/// and on failure, carrying the request's [requestId].
///
/// A reply is still published on the event stream like every other event.
/// The same type is also emitted without a request where something else
/// caused it (a receive replayed when its block header arrived, a peer's
/// batch of headers); [requestId] is null then.
abstract class CoordinatorReply extends CoordinatorEvent {
  /// The [CoordinatorRequest.requestId] of the request this answers; null
  /// when no request caused it.
  String? get requestId;

  /// Why the request failed, or null when it succeeded.
  /// `WalletCoordinator.ask` throws a [CoordinatorFailure] carrying this
  /// reply when it is not null.
  String? get failure;
}

/// A command or query the coordinator answers with one [R].
///
/// [requestId] is fixed when the request is made: given, or generated. The
/// reply carries it back, and so does an [ErrorEvent] the request causes,
/// so two requests of the same kind running at once each get their own
/// answer. `WalletCoordinator.ask` sends a request and completes with its
/// reply; `WalletCoordinator.tell` sends it and leaves the reply on the
/// event stream.
abstract class CoordinatorRequest<R extends CoordinatorReply> implements Message {
  CoordinatorRequest({String? requestId})
      : requestId = requestId ?? uniqueId('request'),
        timestamp = DateTime.now();

  /// Identifies this request; its reply carries it back.
  final String requestId;

  /// How long `WalletCoordinator.ask` waits for the reply when the caller
  /// gives no timeout. A request that is still running then is not
  /// cancelled: its reply arrives on the event stream later.
  Duration get replyTimeout => defaultTimeout;

  /// A request the coordinator answers from its own state, or after one
  /// round trip to the wallet (each of which waits up to 30 s).
  static const defaultTimeout = Duration(minutes: 1);

  /// Building a payment: reserving its inputs, building and signing it, and
  /// collecting its ancestry, each a wallet round trip.
  static const paymentTimeout = Duration(minutes: 3);

  /// Receiving a transaction: recording the addresses it pays when it
  /// names them, SPV validation, the read model holding it, and, for a
  /// payment, ARC's answer to its submission (up to 2 minutes) and the
  /// invoice it pays marked paid.
  static const receiveTimeout = Duration(minutes: 5);

  /// A request that waits on ARC: one broadcast or status check (up to 2
  /// minutes) and the read model showing the answer.
  static const networkTimeout = Duration(minutes: 3);

  /// A reclaim: ARC's fee quote, an address, signing, journaling, and the
  /// broadcast, each waited for in turn.
  static const reclaimTimeout = Duration(minutes: 6);

  /// A split: one transaction per source UTXO, each built, signed and
  /// broadcast and ARC's answer waited for.
  static const splitTimeout = Duration(minutes: 15);

  /// Checking outputs for a foreign spend: a data source lookup per output
  /// and a receive per proven spender.
  static const foreignSpendsTimeout = Duration(minutes: 15);

  /// A channel's open or close: messages to and from the counterparty, over
  /// the app's transport, and a broadcast ARC answers.
  static const channelTimeout = Duration(minutes: 5);

  /// An import: the wallet's whole history, fetched and proven.
  static const importTimeout = Duration(hours: 1);

  @override
  String get correlationId => requestId;
  @override
  ActorRef? get replyTo => null;
  @override
  final DateTime timestamp;
}

/// Why `WalletCoordinator.ask` has no reply to return.
///
/// [event] is what reported the failure: the request's own reply, whose
/// [CoordinatorReply.failure] is [message], or an [ErrorEvent] the request
/// caused. It is null when the coordinator stopped before answering
/// ([closed]).
class CoordinatorFailure implements Exception {
  final String requestId;
  final String message;
  final CoordinatorEvent? event;

  const CoordinatorFailure(this.requestId, this.message, {this.event});

  /// The coordinator stopped before it answered.
  bool get closed => event == null;

  @override
  String toString() => 'CoordinatorFailure($requestId: $message)';
}

// ==========================================================================
// COMMANDS (app → coordinator)
// ==========================================================================

/// Create a new wallet
class CreateWalletCommand extends CoordinatorRequest<WalletCreatedEvent> {
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
    Map<String, dynamic>? walletMetadata,
    super.requestId,
  }) : walletMetadata = frozenPlainMapOrNull(walletMetadata);

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Delete a wallet permanently (event-sourced)
class DeleteWalletCommand extends CoordinatorRequest<WalletDeletedEvent> {
  final String walletId;
  final String? reason;

  DeleteWalletCommand({required this.walletId, this.reason, super.requestId});

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Import a wallet from extended private key or WIF.
///
/// With [resume] the wallet must already exist and no key is given: the
/// ImportActor reads it from secure storage, skips the addresses and
/// transactions the wallet already holds and imports the rest. The same
/// command resumes an import after the host was killed, retries one that
/// finished with `ImportCompleteEvent.transactionsFailed` above zero, and
/// rescans a wallet for new history.
class ImportWalletCommand extends CoordinatorRequest<ImportCompleteEvent> {
  final String walletId;
  final String walletName;
  final String? xpriv;
  final String? mnemonic;
  final String? wif;
  final int gapLimit;
  final String networkType;
  final bool resume;

  ImportWalletCommand({
    required this.walletId,
    required this.walletName,
    this.xpriv,
    this.mnemonic,
    this.wif,
    this.gapLimit = 20,
    this.networkType = 'test',
    this.resume = false,
    super.requestId,
  });

  @override
  Duration get replyTimeout => CoordinatorRequest.importTimeout;
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Query wallet balance
class GetBalanceQuery extends CoordinatorRequest<BalanceResponse> {
  final String walletId;

  GetBalanceQuery({required this.walletId, super.requestId});

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Query wallet transactions
class GetTransactionsQuery extends CoordinatorRequest<TransactionsResponse> {
  final String walletId;
  final int limit;
  final int offset;

  GetTransactionsQuery({
    required this.walletId,
    this.limit = 50,
    this.offset = 0,
    super.requestId,
  });

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Query specific transaction detail
class GetTransactionDetailQuery extends CoordinatorRequest<TransactionDetailResponse> {
  final String walletId;
  final String txid;

  GetTransactionDetailQuery({
    required this.walletId,
    required this.txid,
    super.requestId,
  });

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
}

/// Create a payment invoice
class CreateInvoiceCommand extends CoordinatorRequest<InvoiceCreatedEvent> {
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
    List<InvoiceOutputSpec>? outputs,
    this.description,
    this.expiresIn,
    this.expiresInSeconds,
    Map<String, dynamic>? invoiceMetadata,
    this.numberOfAddresses = 1,
    super.requestId,
  })  : outputs = frozenOutputSpecsOrNull(outputs),
        invoiceMetadata = frozenPlainMapOrNull(invoiceMetadata);

  /// Effective expiry duration
  Duration? get effectiveExpiresIn =>
      expiresIn ?? (expiresInSeconds != null ? Duration(seconds: expiresInSeconds!) : null);

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Pay an invoice (builds BEEF, does NOT broadcast)
class PayInvoiceCommand extends CoordinatorRequest<PaymentReadyEvent> {
  final String walletId;
  final String invoiceId;
  final List<String> addresses;
  final BigInt amount;
  final List<InvoiceOutputSpec>? outputs;
  final String? changeAddress;
  final Map<String, dynamic>? paymentMetadata;

  /// The app's opaque marker for the counterparty of this payment (bead
  /// libspiffy-cq16, spv-understanding.md "Core Data Management"
  /// requirement 5): an Ed25519 identity key, an email address, a peer id,
  /// an internal account id — whatever the app uses for identity. It is
  /// stored with the payment and returned by the transaction queries;
  /// libspiffy never interprets, validates or parses it, and the identity
  /// record itself stays with the app. Null when none is supplied.
  final String? counterpartyMarker;

  /// The payment's note, written by the payer for the payee. libspiffy
  /// journals it and returns it and never interprets it. Null when none.
  final String? memo;

  /// When the wallet reclaims this payment by itself if it is still
  /// outstanding then (bead libspiffy-8442): a half the counterparty has
  /// not completed, a payment the recipient has not broadcast. Null for
  /// never. The deadline bounds the option; the reclaim ends it only once
  /// the network has it.
  final DateTime? deadline;

  /// Split change and spread inputs; null builds the payment as before.
  final PaymentPrivacy? privacy;

  PayInvoiceCommand({
    required this.walletId,
    required this.invoiceId,
    required List<String> addresses,
    required this.amount,
    List<InvoiceOutputSpec>? outputs,
    this.changeAddress,
    Map<String, dynamic>? paymentMetadata,
    this.counterpartyMarker,
    this.memo,
    this.deadline,
    this.privacy,
    super.requestId,
  })  : addresses = frozenList(addresses),
        outputs = frozenOutputSpecsOrNull(outputs),
        paymentMetadata = frozenPlainMapOrNull(paymentMetadata);

  @override
  Duration get replyTimeout => CoordinatorRequest.paymentTimeout;
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'invoiceId': invoiceId};
}

/// Provision earmark-aware funding UTXOs for a token lifecycle.
///
/// Triggers a plugin's [provisionFunding] method, which builds a tree of
/// transactions (split + earmarks) from a single large UTXO. The coordinator
/// records each transaction, marks the original UTXO as spent, and registers
/// the earmarked UTXOs in the wallet's read model.
class ProvisionFundingCommand extends CoordinatorRequest<ProvisioningCompleteEvent> {
  final String walletId;
  final String pluginId;
  final Map<String, dynamic> pluginParams;

  ProvisionFundingCommand({
    required this.walletId,
    required this.pluginId,
    required Map<String, dynamic> pluginParams,
    super.requestId,
  }) : pluginParams = frozenPlainMap(pluginParams);

  @override
  Duration get replyTimeout => CoordinatorRequest.paymentTimeout;
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'pluginId': pluginId};
}

/// Validate incoming BEEF data (structural + SPV validation)
class ValidateBEEFCommand extends CoordinatorRequest<BEEFValidationResultEvent> {
  final String walletId;
  final String beefHex;
  final String? invoiceId;

  /// The app's opaque marker for the counterparty that handed us this BEEF
  /// (bead libspiffy-cq16), journaled with the payment the receive records.
  /// Null when the app supplies none — no placeholder is invented.
  final String? fromCounterparty;

  /// The type-42 hand-off of a payment to one of this wallet's anchor keys
  /// (beads libspiffy-zxkd, libspiffy-fdal; spv-understanding.md, "Payment
  /// modes"): for each destination paid, the anchor and (when the payer had
  /// it) its context, the payer's public key and the invoice number. The
  /// wallet finds the anchor's context — among the anchors it issued, else
  /// the hand-off's, which must give that anchor — derives each address
  /// from its own anchor key and records it before the payment is
  /// validated, so it is attributed to the wallet and can be spent. The
  /// payer has broadcast the payment already; submitting it again is
  /// harmless.
  final List<Type42Derivation> type42Derivations;

  /// The payment's note, written by the payer for the payee. libspiffy
  /// journals it and returns it and never interprets it. Null when none.
  final String? memo;

  ValidateBEEFCommand({
    required this.walletId,
    required this.beefHex,
    this.invoiceId,
    this.fromCounterparty,
    this.memo,
    List<Type42Derivation> type42Derivations = const [],
    super.requestId,
  }) : type42Derivations = frozenList(type42Derivations);

  @override
  Duration get replyTimeout => CoordinatorRequest.receiveTimeout;
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Record an outgoing transaction in the wallet
class RecordOutgoingCommand extends CoordinatorRequest<TransactionRecordedEvent> {
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

  /// The payment's note, written by the payer for the payee. libspiffy
  /// journals it and returns it and never interprets it. Null when none.
  final String? memo;

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
    required List<String> spentUtxoKeys,
    required List<String> recipientAddresses,
    required this.paymentAmount,
    this.changeAddress,
    this.changeAmount,
    this.counterpartyMarker,
    this.memo,
    super.requestId,
  })  : spentUtxoKeys = frozenList(spentUtxoKeys),
        recipientAddresses = frozenList(recipientAddresses);

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
}

/// Import a transaction the wallet already knows to be mined: recovering a
/// wallet, or bringing in its own history.
///
/// The BEEF must carry the merkle proof of the transaction it imports (its
/// last transaction), so the wallet holds the proof its outputs are spent
/// with and nothing needs tracking on the network (bead libspiffy-ckr4).
/// One without is refused with a [TransactionImportedEvent] saying so: a
/// counterparty's payment is received with [ValidateBEEFCommand], which
/// submits it and follows it to its block. The txid is the BEEF's; it is
/// not the caller's to name.
///
/// [delegatedIndices] is the other half of a service's hand-off (bead
/// libspiffy-m8qu; spv-understanding.md, "Payment modes"): a service holding
/// this wallet's xpub took a payment for it on the delegated chain
/// (`m/2/{index}`), broadcast it and followed it to its block, and hands it
/// over with the indices it issued (`ExportTransactionQuery` on the
/// service's side). The wallet derives those addresses from its own key and
/// records them before the import, so the payment is attributed to it and
/// can be spent.
///
/// [type42Derivations] is the hand-off of a payer that paid one of this
/// wallet's anchor keys with type-42 (beads libspiffy-zxkd, libspiffy-fdal):
/// for each destination the anchor and its context, the payer's public key
/// and the invoice number, which the payer's own export carries
/// ([TransactionExportedEvent.type42Derivations]). The wallet finds the
/// anchor's context (its issued anchors first, else the hand-off's, which
/// must give the anchor: a wallet restored from its seed has issued none),
/// derives each address from its anchor key and records it before the
/// import, as for [delegatedIndices].
class ImportTransactionCommand extends CoordinatorRequest<TransactionImportedEvent> {
  final String walletId;
  final List<int> beef;
  final String? fromCounterparty;
  final List<int> delegatedIndices;
  final List<Type42Derivation> type42Derivations;

  /// The payment's note, written by the payer for the payee. libspiffy
  /// journals it and returns it and never interprets it. Null when none.
  final String? memo;

  ImportTransactionCommand({
    required this.walletId,
    required List<int> beef,
    this.fromCounterparty,
    this.memo,
    List<int> delegatedIndices = const [],
    List<Type42Derivation> type42Derivations = const [],
    super.requestId,
  })  : beef = frozenList(beef),
        delegatedIndices = frozenList(delegatedIndices),
        type42Derivations = frozenList(type42Derivations);

  @override
  Duration get replyTimeout => CoordinatorRequest.receiveTimeout;
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Export a transaction of the wallet with its merkle proof, as a BEEF that
/// another wallet imports with [ImportTransactionCommand] (bead
/// libspiffy-m8qu).
///
/// This is the sending side of the hand-off in both offline-payee modes
/// (spv-understanding.md, "Payment modes"): a service's xpub wallet that
/// received the payment, broadcast it and holds its proof once it is mined
/// (bead libspiffy-m8qu), or a payer that paid a type-42 destination and
/// broadcast the payment itself (bead libspiffy-zxkd).
/// Answered with a [TransactionExportedEvent]; refused while the
/// transaction has no proof verified on our header chain, because the
/// importing wallet accepts only a proven transaction.
class ExportTransactionQuery extends CoordinatorRequest<TransactionExportedEvent> {
  final String walletId;
  final String txid;

  ExportTransactionQuery({
    required this.walletId,
    required this.txid,
    super.requestId,
  });

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
}

/// Issues the wallet's anchor key for [anchorContext] (beads
/// libspiffy-zxkd, libspiffy-fdal): the key a payer derives type-42
/// destinations from to pay this wallet while it is offline
/// (spv-understanding.md, "Payment modes"). The app publishes it, bound to
/// the identity it is for. Answered with [AnchorPublicKeyEvent].
///
/// A wallet has one anchor per context, so identities that share it publish
/// unrelated anchors. The context is opaque bytes: an identity key, for
/// example, followed by a rotation epoch, which the app bumps to retire an
/// anchor (a leaked child key c = a + t gives away that anchor's a, since
/// the payer knows t). An empty context is refused. The same context always
/// gives the same anchor; the wallet journals it the first time, so a
/// hand-off that names only the anchor is matched to its context.
class IssueAnchorKeyCommand extends CoordinatorRequest<AnchorPublicKeyEvent> {
  final String walletId;
  final List<int> anchorContext;

  IssueAnchorKeyCommand({required this.walletId, required List<int> anchorContext, super.requestId})
      : anchorContext = frozenList(anchorContext);

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Signs `SHA-256(message)` with the wallet's anchor key for
/// [anchorContext] (beads libspiffy-zxkd, libspiffy-fdal), to bind that
/// anchor to an identity — a NodeCast registration, say. The message is
/// hashed by the wallet, so the anchor key never signs a digest the caller
/// chose; the message should name its purpose (domain separation).
/// Answered with [AnchorSignedEvent].
class SignWithAnchorKeyCommand extends CoordinatorRequest<AnchorSignedEvent> {
  final String walletId;
  final List<int> anchorContext;
  final List<int> message;

  SignWithAnchorKeyCommand({
    required this.walletId,
    required List<int> anchorContext,
    required List<int> message,
    super.requestId,
  })  : anchorContext = frozenList(anchorContext),
        message = frozenList(message);

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Runs the BRC-100 key operation [request] with a BRC-42 child of the
/// wallet's anchor key for [anchorContext], the anchor acting as BRC-100's
/// root key: an anchor issued for a BRC-100 identity signs (BRC-3),
/// encrypts (BRC-2), and derives keys as that identity. Answered with
/// [Brc100KeyOperationEvent].
///
/// The private keys stay in the wallet. Operations other than
/// `getPublicKey` are refused for the anchor's payment spend keys: the
/// BRC-29 protocol, and any type-42 address the wallet recorded.
class Brc100KeyOperationCommand extends CoordinatorRequest<Brc100KeyOperationEvent> {
  final String walletId;
  final List<int> anchorContext;
  final Brc100KeyRequest request;

  Brc100KeyOperationCommand({
    required this.walletId,
    required List<int> anchorContext,
    required this.request,
    super.requestId,
  }) : anchorContext = frozenList(anchorContext);

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Derives a type-42 destination for paying the holder of anchor key
/// [anchorPublicKey] while it is offline (beads libspiffy-zxkd,
/// libspiffy-fdal; spv-understanding.md, "Payment modes"). Answered with
/// [Type42DestinationEvent]: the address to pay, and the hand-off (A, its
/// [anchorContext] when given, the payer key B and the invoice number) the
/// payee takes the payment in with.
///
/// Pass the context the recipient published with its anchor when there is
/// one: the recipient's wallet then finds the anchor from the hand-off
/// alone, after a restore too. The payer passes it through unchecked; the
/// recipient's wallet refuses a context that does not give A.
///
/// The wallet uses a fresh payer key each time. Without an [invoiceNumber]
/// it makes up a BRC-29 one. The payee is offline, so the payer broadcasts
/// the payment itself (`BroadcastDeferredPaymentCommand`), follows it to
/// its block, and hands it over with `ExportTransactionQuery`.
class DeriveType42DestinationCommand extends CoordinatorRequest<Type42DestinationEvent> {
  final String walletId;
  final String anchorPublicKey;
  final List<int>? anchorContext;
  final String? invoiceNumber;

  /// The context of the wallet's own anchor to pay with, as payer key B,
  /// instead of a fresh payer key: a payment made as the identity that
  /// anchor stands for (the sender of a BRC-29 payment to a BRC-100
  /// wallet is its identity key).
  final List<int>? payerAnchorContext;

  DeriveType42DestinationCommand({
    required this.walletId,
    required this.anchorPublicKey,
    List<int>? anchorContext,
    this.invoiceNumber,
    List<int>? payerAnchorContext,
    super.requestId,
  })  : anchorContext = frozenListOrNull(anchorContext),
        payerAnchorContext = frozenListOrNull(payerAnchorContext);

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Store block headers for SPV validation.
///
/// The headers go through the header chain like headers from a peer:
/// validated, placed by their parents, and the tip moved by chainwork. A
/// header's `height` is informational; the chain derives it from the
/// parent. Answered with [BlockHeadersStoredEvent] (its `source` is
/// [source]).
class StoreHeadersCommand extends CoordinatorRequest<BlockHeadersStoredEvent> {
  final List<Map<String, dynamic>> headers;
  final String source;

  StoreHeadersCommand({
    required List<Map<String, dynamic>> headers,
    this.source = 'external',
    super.requestId,
  }) : headers = frozenMapList(headers);

  @override
  Map<String, dynamic> get metadata => {};
}

/// Asks wallet [walletId] for a fresh address of its own: a key no payment
/// has named yet, derived on its receive chain ([purpose] `'receive'`, the
/// default) or its change chain (`'change'`), with an optional [label]. With
/// [includePublicKey] the answer carries the key's public key, which a
/// counterparty needs to name the wallet's coin by key (a swap's funding, a
/// P2PK output) or to build a multisig with it. Answered with
/// [AddressGeneratedEvent] once the read model holds the address, so a
/// payment to it validates at once (SPV attributes outputs by the read
/// model's address rows).
class GenerateAddressCommand extends CoordinatorRequest<AddressGeneratedEvent> {
  final String walletId;
  final String? label;
  final String? purpose;
  final bool includePublicKey;

  GenerateAddressCommand({
    required this.walletId,
    this.label,
    this.purpose,
    this.includePublicKey = false,
    super.requestId,
  });

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Result of [GenerateAddressCommand]: the wallet's fresh [address], where
/// it sits on the wallet's keys ([chain], [derivationIndex]) and, when asked
/// for, its [publicKeyHex].
class AddressGeneratedEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final bool success;
  final String? address;
  final int? derivationIndex;
  final AddressChain? chain;
  final String? publicKeyHex;
  final String? error;

  AddressGeneratedEvent({
    required this.walletId,
    this.requestId,
    required this.success,
    this.address,
    this.derivationIndex,
    this.chain,
    this.publicKeyHex,
    this.error,
  });

  @override
  String? get failure => success ? null : error ?? 'No address was generated';
}

/// Register an address to watch for activity
class RegisterWatchAddressCommand extends CoordinatorRequest<WatchAddressRegisteredEvent> {
  final String walletId;
  final String address;
  final String scriptType;
  final String? label;

  RegisterWatchAddressCommand({
    required this.walletId,
    required this.address,
    required this.scriptType,
    this.label,
    super.requestId,
  });

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Release reserved UTXOs
class ReleaseUTXOsCommand extends CoordinatorRequest<UTXOsReleasedEvent> {
  final String walletId;
  final String reservationId;

  ReleaseUTXOsCommand({
    required this.walletId,
    required this.reservationId,
    super.requestId,
  });

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Answer to [ReleaseUTXOsCommand]: the UTXOs the reservation held are
/// available again. [releasedUtxoKeys] is empty when the reservation held
/// none (already released, or expired).
class UTXOsReleasedEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final String reservationId;
  final List<String> releasedUtxoKeys;
  final bool success;
  final String? error;

  UTXOsReleasedEvent({
    required this.walletId,
    required this.reservationId,
    required this.success,
    List<String> releasedUtxoKeys = const [],
    this.error,
    this.requestId,
  }) : releasedUtxoKeys = frozenList(releasedUtxoKeys);

  @override
  String? get failure => success ? null : error ?? 'The reservation was not released';
}

/// Split UTXOs using Benford's Law distribution for privacy
class SplitUTXOsCommand extends CoordinatorRequest<UTXOSplitCompleteEvent> {
  final String walletId;
  final int? targetUtxoCount;
  final int? maxUtxosToSplit;

  /// The UTXOs to split (`txid:vout`); null for any, the largest first
  /// (bead libspiffy-5hnt).
  final List<String>? utxoKeys;

  /// Pieces of about this many satoshis, at most [targetUtxoCount] per UTXO.
  final BigInt? partSats;

  /// No piece smaller than this.
  final BigInt? minPartSats;

  SplitUTXOsCommand({
    required this.walletId,
    this.targetUtxoCount,
    this.maxUtxosToSplit,
    List<String>? utxoKeys,
    this.partSats,
    this.minPartSats,
    super.requestId,
  }) : utxoKeys = frozenListOrNull(utxoKeys);

  @override
  Duration get replyTimeout => CoordinatorRequest.splitTimeout;
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Create a timestamp archive (OP_RETURN data on-chain)
class TimestampCommand extends CoordinatorRequest<TimestampCompleteEvent> {
  final String archiveId;
  final String walletId;
  final List<String> fileHashes;
  final String? archiveTitle;

  TimestampCommand({
    required this.archiveId,
    required this.walletId,
    required List<String> fileHashes,
    this.archiveTitle,
    super.requestId,
  }) : fileHashes = frozenList(fileHashes);

  /// Building the payment, then ARC's answer to its broadcast.
  @override
  Duration get replyTimeout => CoordinatorRequest.paymentTimeout + CoordinatorRequest.networkTimeout;
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'archiveId': archiveId};
}

/// Settle a BEEF by broadcasting all unsettled transactions (hasMerkle=false)
/// to ARC in dependency order.
///
/// Classic SPV payments (P2P transfer) don't need this — the recipient
/// settles when they choose to bank the cheque. Self-pay operations
/// (token issuance, identity anchor) must settle immediately because
/// there is no counterparty to hand the cheque to.
class SettleBEEFCommand extends CoordinatorRequest<BEEFSettledEvent> {
  final String walletId;
  final String beefHex;
  final String txid;

  SettleBEEFCommand({
    required this.walletId,
    required this.beefHex,
    required this.txid,
    super.requestId,
  });

  @override
  Duration get replyTimeout => CoordinatorRequest.networkTimeout;
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
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
class GetDeferredPaymentsQuery extends CoordinatorRequest<DeferredPaymentsResponse> {
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

  /// Only payments with a deadline at or before this instant (bead
  /// libspiffy-8442).
  final DateTime? dueBefore;

  /// Page size (1 to 1000).
  final int limit;

  /// [DeferredPaymentsResponse.nextCursor] of the previous page.
  final String? cursor;
  final bool oldestFirst;

  /// Rebuild each payment's BEEF from the stored ancestors and proofs.
  final bool includeBeef;

  GetDeferredPaymentsQuery({
    required this.walletId,
    Set<DeferredPaymentState>? states,
    this.includeResolved = false,
    this.createdBefore,
    this.createdAfter,
    this.olderThan,
    Set<String>? lastNetworkStatuses,
    this.invoiceId,
    this.recipientAddress,
    this.dueBefore,
    this.limit = 50,
    this.cursor,
    this.oldestFirst = false,
    this.includeBeef = true,
    super.requestId,
  })  : states = frozenSetOrNull(states),
        lastNetworkStatuses = frozenSetOrNull(lastNetworkStatuses);

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
      dueBefore: dueBefore,
      limit: limit,
      cursor: cursor,
      oldestFirst: oldestFirst,
    );
  }

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
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
class BroadcastDeferredPaymentCommand extends CoordinatorRequest<DeferredPaymentBroadcastEvent> {
  final String walletId;
  final String txid;
  final DeferredPaymentNetworkSource via;

  BroadcastDeferredPaymentCommand({
    required this.walletId,
    required this.txid,
    this.via = DeferredPaymentNetworkSource.arc,
    super.requestId,
  });

  @override
  Duration get replyTimeout => CoordinatorRequest.networkTimeout;
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
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
class CheckDeferredPaymentStatusCommand extends CoordinatorRequest<DeferredPaymentStatusEvent> {
  final String walletId;
  final String txid;
  final DeferredPaymentNetworkSource via;

  CheckDeferredPaymentStatusCommand({
    required this.walletId,
    required this.txid,
    this.via = DeferredPaymentNetworkSource.arc,
    super.requestId,
  });

  @override
  Duration get replyTimeout => CoordinatorRequest.networkTimeout;
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
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
class CancelDeferredPaymentCommand extends CoordinatorRequest<DeferredPaymentCancelledEvent> {
  final String walletId;
  final String txid;
  final String? reason;
  final DeferredPaymentNetworkSource via;

  /// Cancel even when the network could not be asked (never when it knows
  /// the transaction).
  final bool force;

  CancelDeferredPaymentCommand({
    required this.walletId,
    required this.txid,
    this.reason,
    this.via = DeferredPaymentNetworkSource.arc,
    this.force = false,
    super.requestId,
  });

  @override
  Duration get replyTimeout => CoordinatorRequest.networkTimeout;
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
}

// ==========================================================================
// CHANNEL COMMANDS
// ==========================================================================

/// Open a payment channel with a peer
class OpenChannelCommand extends CoordinatorRequest<ChannelOpenedEvent> {
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
    super.requestId,
  });

  @override
  Duration get replyTimeout => CoordinatorRequest.channelTimeout;
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Make a payment over an open channel
class ChannelPayCommand extends CoordinatorRequest<ChannelPaymentEvent> {
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
    super.requestId,
  });

  @override
  Map<String, dynamic> get metadata => {'channelId': channelId, 'walletId': walletId};
}

/// Close a payment channel
class CloseChannelCommand extends CoordinatorRequest<ChannelClosedEvent> {
  final String channelId;
  final String? reason;

  CloseChannelCommand({required this.channelId, this.reason, super.requestId});

  @override
  Duration get replyTimeout => CoordinatorRequest.channelTimeout;
  @override
  Map<String, dynamic> get metadata => {'channelId': channelId};
}

/// Record that a payment channel has expired (lockTime elapsed).
///
/// Issued by the expiry monitor on either side. Routes to PCMA via the
/// channel adapter and ultimately emits [ChannelExpiredEvent] through the
/// aggregate so the read model picks up the transition. Distinct from
/// [CloseChannelCommand] which is the cooperative-close pathway.
class ExpireChannelCommand extends CoordinatorRequest<ChannelExpiredEvent> {
  final String channelId;
  final String observedBy; // 'client' or 'server'
  final String? settlementOrRefundTxId;

  ExpireChannelCommand({
    required this.channelId,
    required this.observedBy,
    this.settlementOrRefundTxId,
    super.requestId,
  });

  @override
  Duration get replyTimeout => CoordinatorRequest.networkTimeout;
  @override
  Map<String, dynamic> get metadata => {'channelId': channelId};
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
class ClaimChannelRefundCommand extends CoordinatorRequest<ChannelRefundClaimedEvent> {
  final String channelId;

  /// The refund to claim. Null uses the fully signed refund the channel
  /// holds, which is the normal case; supply one only to name a specific
  /// transaction (it must still spend the channel's funding output, which
  /// the aggregate checks).
  final String? refundTxHex;

  ClaimChannelRefundCommand({required this.channelId, this.refundTxHex, super.requestId});

  @override
  Duration get replyTimeout => CoordinatorRequest.networkTimeout;
  @override
  Map<String, dynamic> get metadata => {'channelId': channelId};
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
class RetryChannelFundingCommand extends CoordinatorRequest<ChannelFundingRetriedEvent> {
  final String channelId;

  RetryChannelFundingCommand({required this.channelId, super.requestId});

  @override
  Duration get replyTimeout => CoordinatorRequest.networkTimeout;
  @override
  Map<String, dynamic> get metadata => {'channelId': channelId};
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
class ResendChannelOpenCommand extends CoordinatorRequest<ChannelOpenResentEvent> {
  final String channelId;

  ResendChannelOpenCommand({required this.channelId, super.requestId});

  @override
  Map<String, dynamic> get metadata => {'channelId': channelId};
}

/// Accept an incoming channel request
class AcceptChannelCommand extends CoordinatorRequest<ChannelAcceptedEvent> {
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
    super.requestId,
  });

  @override
  Map<String, dynamic> get metadata => {'channelId': channelId, 'walletId': walletId};
}

/// Reject an incoming channel request
class RejectChannelCommand extends CoordinatorRequest<ChannelRejectedEvent> {
  final String channelId;
  final String? reason;

  RejectChannelCommand({required this.channelId, this.reason, super.requestId});

  @override
  Map<String, dynamic> get metadata => {'channelId': channelId};
}

/// An inbound peer-to-peer message the app received on its own transport and
/// hands to the library (bead libspiffy-a2v3).
///
/// libspiffy owns no transport: the app carries bytes between peers and
/// describes what arrived as `(fromPeerId, messageType, payload)`. The
/// coordinator routes it by [messageType] — `proof_request` and
/// `proof_response` to the merkle-proof protocol (`ProofP2PAdapter`),
/// everything else to the payment-channel protocol (`ChannelP2PAdapter`).
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
    required Map<String, dynamic> payload,
  }) : payload = frozenPlainMap(payload);

  @override
  final String correlationId = uniqueId('p2p');
  @override
  Map<String, dynamic> get metadata => {'fromPeerId': fromPeerId, 'messageType': messageType};
  @override
  ActorRef? get replyTo => null;
  @override
  final DateTime timestamp = DateTime.now();
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
class RequestAncestorProofCommand extends CoordinatorRequest<AncestorProofRequestedEvent> {
  final String walletId;

  /// The transaction *we received* whose ancestry no longer reaches a proof.
  final String txid;

  /// The ancestors a proof is wanted for. Informational — the responder
  /// rebuilds the whole BEEF for [txid] — and filled in from
  /// `ReadModelStorage.getOutputsAwaitingAncestorProof` when left empty.
  final List<String> ancestorTxids;

  RequestAncestorProofCommand({
    required this.walletId,
    required this.txid,
    List<String> ancestorTxids = const [],
    super.requestId,
  }) : ancestorTxids = frozenList(ancestorTxids);

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
}

// ==========================================================================
// EVENTS (coordinator → app via broadcast stream)
// ==========================================================================

/// Answer to [CreateWalletCommand]: the wallet is created and the read
/// model holds it, or why not.
class WalletCreatedEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final String? rootAddress;
  final bool success;
  final String? error;

  WalletCreatedEvent({
    required this.walletId,
    this.rootAddress,
    required this.success,
    this.error,
    this.requestId,
  });

  @override
  String? get failure => success ? null : error ?? 'The wallet was not created';
}

/// Answer to [DeleteWalletCommand]: the wallet's deletion is journaled.
class WalletDeletedEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final bool success;
  final String? error;

  WalletDeletedEvent({required this.walletId, required this.success, this.error, this.requestId});

  @override
  String? get failure => success ? null : error ?? 'The wallet was not deleted';
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
}

/// Wallet import completed
class ImportCompleteEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final bool success;
  final String? error;
  final int addressCount;

  /// Transactions recorded by this run.
  final int transactionCount;

  /// Transactions the wallet already held (a resume or rescan skips them).
  final int transactionsSkipped;

  /// Transactions that could not be fetched or proven, so not recorded. A
  /// successful import with this above zero is incomplete: send
  /// [ImportWalletCommand] with `resume: true` to try them again.
  final int transactionsFailed;

  ImportCompleteEvent({
    required this.walletId,
    required this.success,
    this.error,
    this.addressCount = 0,
    this.transactionCount = 0,
    this.transactionsSkipped = 0,
    this.transactionsFailed = 0,
    this.requestId,
  });

  @override
  String? get failure => success ? null : error ?? 'The import failed';
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
}

/// Balance query response, computed from the read model.
///
/// [confirmedBalance], [unconfirmedBalance] and [totalBalance] are the
/// spendable balance: the wallet's payment UTXOs (status available, not
/// plugin-managed, i.e. no plugin metadata naming a `pluginId`), any number
/// of confirmations. Pending and spent UTXOs are left out; reserved UTXOs,
/// a deferred payment's held inputs included, are left out and reported in
/// [reservedBalance] (bead libspiffy-a5h8); UTXOs at watch addresses, which
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
class BalanceResponse extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;

  /// Payment UTXOs with a block height (greater than zero): mined, however
  /// few confirmations they have.
  final BigInt confirmedBalance;

  /// Payment UTXOs with no block height (not known to be mined).
  final BigInt unconfirmedBalance;

  /// [confirmedBalance] + [unconfirmedBalance].
  final BigInt totalBalance;

  /// Value of the wallet's unspent UTXOs that are not spendable yet: the
  /// network is not known to hold the transaction that pays them, or it held
  /// it and a reorganization took the proof away. The wallet's own money,
  /// and not part of [totalBalance] — the same treatment as
  /// [watchOnlyBalance] and [reservedBalance], which are also the wallet's
  /// and also unspendable (bead libspiffy-z84j).
  ///
  /// It was reported nowhere before, so an application saw it as zero: at
  /// its worst, a payment that confirmed and then lost its block to a
  /// reorganization read as money gone, for as long as it took a fresh proof
  /// to arrive. `TransactionConfirmationRevertedEvent` says when that
  /// happens and this says what it is worth.
  ///
  /// These outputs cannot be selected for spending, by design: an output
  /// whose proof left the active chain cannot be put in a BEEF anyone can
  /// verify (bead libspiffy-0lx). The wallet's own write model and the read
  /// model's wallet row count them as unconfirmed instead; this API reports
  /// them apart so that neither number claims the money can be spent.
  final BigInt pendingBalance;

  /// Value of the wallet's unspent UTXOs at watch addresses: credited to the
  /// wallet but not spendable by it, and not part of [totalBalance].
  final BigInt watchOnlyBalance;

  /// Value of the wallet's reserved UTXOs: its own funds, committed and so
  /// not spendable right now, and not part of [totalBalance] — the same
  /// treatment as [watchOnlyBalance], which is the wallet's and unspendable
  /// for a different reason (bead libspiffy-a5h8).
  ///
  /// A reservation an application placed, an in-flight payment's inputs, or
  /// a deferred payment's held inputs — handed to the recipient, held by the
  /// payment's txid with no expiry until the network settles it, ARC reports
  /// it failed, or the user cancels or reclaims it. Without this field money
  /// the wallet still owns vanished from every number the coordinator
  /// reported. Which payment holds what is `GetDeferredPaymentsQuery`; why
  /// nothing can be selected is the reason `WalletBalances.noneSelectableReason`
  /// names.
  ///
  /// Counted over the same UTXOs as the spendable balance — not
  /// plugin-managed, not watch-only, not one the wallet cannot unlock alone
  /// — so the four numbers here partition the wallet's own unspent funds,
  /// pending UTXOs apart. It is the read model's `reservedBalance`
  /// (`WalletReadModel.reservedBalance`), computed from the same rows rather
  /// than read from the wallet row's snapshot of it, so it cannot be a
  /// moment older than the numbers beside it.
  final BigInt reservedBalance;

  BalanceResponse({
    required this.walletId,
    this.requestId,
    required this.confirmedBalance,
    required this.unconfirmedBalance,
    required this.totalBalance,
    BigInt? pendingBalance,
    BigInt? watchOnlyBalance,
    BigInt? reservedBalance,
  })  : pendingBalance = pendingBalance ?? BigInt.zero,
        watchOnlyBalance = watchOnlyBalance ?? BigInt.zero,
        reservedBalance = reservedBalance ?? BigInt.zero;

  /// Never: a failure to answer arrives as an [ErrorEvent].
  @override
  String? get failure => null;
}

/// Transactions query response
class TransactionsResponse extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final List<BitcoinTransaction> transactions;

  TransactionsResponse({
    required this.walletId,
    this.requestId,
    required List<BitcoinTransaction> transactions,
  })  : transactions = frozenList(transactions);

  /// Never: a failure to answer arrives as an [ErrorEvent].
  @override
  String? get failure => null;
}

/// Transaction detail query response
class TransactionDetailResponse extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final BitcoinTransaction? transaction;
  final bool found;
  final String? error;

  TransactionDetailResponse({
    required this.walletId,
    this.requestId,
    this.transaction,
    this.found = true,
    this.error,
  });

  @override
  String? get failure => error;
}

/// The wallet's balance changed: the read model applied an event that moved
/// money, and these are the numbers it now holds (bead libspiffy-7ye4).
///
/// This event existed and nothing emitted it, so the only way an application
/// could learn its balance had changed was to send a [GetBalanceQuery] again
/// and compare — which means polling, or missing the change entirely.
///
/// **The numbers are the ones [BalanceResponse] answers with**, computed by
/// the same code over the same rows at the same moment
/// (`WalletCoordinatorActor._balancesOf`), so an application cannot be told
/// one balance by the event and a different one by the query. That mattered
/// enough to widen this event: it used to carry only the confirmed,
/// unconfirmed and total numbers, and would have left out the wallet's
/// reserved, watch-only and pending funds — exactly the money beads
/// libspiffy-a5h8, libspiffy-87a2 and libspiffy-z84j found reported nowhere.
///
/// Announced from the events the wallet read model applied, like
/// [TransactionConfirmedEvent] and [TransactionConfirmationRevertedEvent],
/// so a balance an app is told about is one the read model already holds
/// (bead libspiffy-mu09). It is emitted only when a number actually
/// differs from the one last announced for the wallet, so an event that
/// leaves the balance alone is silent.
class BalanceUpdatedEvent extends CoordinatorEvent {
  @override
  final String walletId;

  /// See [BalanceResponse.confirmedBalance].
  final BigInt confirmedBalance;

  /// See [BalanceResponse.unconfirmedBalance].
  final BigInt unconfirmedBalance;

  /// [confirmedBalance] + [unconfirmedBalance]; see
  /// [BalanceResponse.totalBalance].
  final BigInt totalBalance;

  /// See [BalanceResponse.pendingBalance]: the wallet's money the network is
  /// not known to hold, or whose proof a reorganization took away. Not part
  /// of [totalBalance].
  final BigInt pendingBalance;

  /// See [BalanceResponse.watchOnlyBalance]. Not part of [totalBalance].
  final BigInt watchOnlyBalance;

  /// See [BalanceResponse.reservedBalance]. Not part of [totalBalance].
  final BigInt reservedBalance;

  BalanceUpdatedEvent({
    required this.walletId,
    required this.confirmedBalance,
    required this.unconfirmedBalance,
    required this.totalBalance,
    BigInt? pendingBalance,
    BigInt? watchOnlyBalance,
    BigInt? reservedBalance,
  })  : pendingBalance = pendingBalance ?? BigInt.zero,
        watchOnlyBalance = watchOnlyBalance ?? BigInt.zero,
        reservedBalance = reservedBalance ?? BigInt.zero;
}

/// An outgoing transaction a [RecordOutgoingCommand] asked the wallet to
/// record is recorded: journaled by the wallet aggregate **and** applied to
/// the read model, so the transaction queries can already see it (bead
/// libspiffy-5ml6). The same promise `WalletCreatedEvent` and
/// [TransactionImportedEvent] make, for the same reason — an app told
/// "recorded" queries next.
///
/// Before this event existed a successful recording was announced nowhere.
/// The arm that would have announced it was dead, because the command was
/// sent with no sender, and bead libspiffy-kl4i deleted it rather than let
/// it go live: it published a manufactured `BigInt.zero` for an amount it
/// did not hold. Supplying that sender turned on a different arm, and what
/// an app actually received for its own payment was one
/// `TransactionReceivedEvent` per change output saying it had received zero
/// satoshis, incoming. That event is gone; an incoming receive is reported
/// by [SPVValidationResultEvent] and [TransactionImportedEvent], which
/// carry the amount the wallet measured.
class TransactionRecordedEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final String txid;

  /// What the recording says the transaction paid, read off the journaled
  /// event.
  ///
  /// **Null is an absence, not a zero** (spv-understanding.md: the library
  /// must not manufacture state it cannot evidence). It is null when this
  /// command journaled nothing because the wallet had recorded the
  /// transaction already (bead libspiffy-viy), so there is no event this
  /// announcement can read the amount off. The recording still stands —
  /// [success] says so — and the amount is on the transaction the queries
  /// return.
  final BigInt? amountSatoshis;

  final bool success;
  final String? error;

  TransactionRecordedEvent({
    required this.walletId,
    required this.txid,
    this.amountSatoshis,
    required this.success,
    this.error,
    this.requestId,
  });

  @override
  String? get failure => success ? null : error ?? 'The transaction was not recorded';
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
}

/// The chain no longer supports a confirmation this wallet announced.
///
/// Sent when a [TransactionConfirmedEvent] is taken back: the block the
/// transaction was proven in left the active chain in a reorganization, or
/// the header at the proof's height contradicts it. The transaction goes
/// back to unconfirmed and its outputs cannot be spent until a fresh proof
/// arrives — which it usually does, for the block that replaced the one
/// that left, and the wallet then announces [TransactionConfirmedEvent]
/// again.
///
/// An application that acted on the confirmation — shipped the goods,
/// credited an account — learns here that the evidence for it is gone.
class TransactionConfirmationRevertedEvent extends CoordinatorEvent {
  @override
  final String walletId;
  final String txid;

  /// The height the confirmation was recorded at; null when the row was
  /// confirmed without one.
  final int? blockHeight;

  /// The block the proof named, the one that left the active chain; null
  /// when the proof never named a block.
  final String? blockHash;

  /// Why it was taken back, as the wallet recorded it.
  final String reason;

  TransactionConfirmationRevertedEvent({
    required this.walletId,
    required this.txid,
    required this.reason,
    this.blockHeight,
    this.blockHash,
  });
}

/// Invoice created successfully
class InvoiceCreatedEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final String invoiceId;
  final List<String> addresses;
  final BigInt amount;
  final List<InvoiceOutputSpec>? outputs;

  /// The addresses the wallet issued for the invoice, each with its chain
  /// and derivation index (bead libspiffy-m8qu). The chain is the payment
  /// mode (spv-understanding.md, "Payment modes"): receive for a wallet
  /// that holds its keys; delegated for a service's xpub wallet answering
  /// for an offline payee, which hands the payment over later with the
  /// index ([TransactionExportedEvent.delegatedIndices] carries it too). An
  /// address the caller supplied in an output is not among them.
  final List<IssuedAddress> issuedAddresses;
  final String? description;
  final DateTime? expiresAt;
  final bool success;
  final String? error;

  InvoiceCreatedEvent({
    required this.walletId,
    required this.invoiceId,
    required List<String> addresses,
    required this.amount,
    List<InvoiceOutputSpec>? outputs,
    List<IssuedAddress> issuedAddresses = const [],
    this.description,
    this.expiresAt,
    required this.success,
    this.error,
    this.requestId,
  })  : addresses = frozenList(addresses),
        outputs = frozenOutputSpecsOrNull(outputs),
        issuedAddresses = frozenList(issuedAddresses);

  @override
  String? get failure => success ? null : error ?? 'The invoice was not created';
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
}

/// BEEF payment constructed and ready for transmission to counterparty
class PaymentReadyEvent extends CoordinatorReply {
  @override
  final String? walletId;
  @override
  final String? requestId;
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
    this.requestId,
  });

  @override
  String? get failure => success ? null : error ?? 'The payment was not built';
}

/// Funding provisioning completed (earmarked UTXOs created).
class ProvisioningCompleteEvent extends CoordinatorReply {
  @override
  final String? walletId;
  @override
  final String? requestId;
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
    this.requestId,
  });

  @override
  String? get failure => success ? null : error ?? 'The funding was not provisioned';
}

/// The answer to a [ValidateBEEFCommand]: a counterparty's payment, checked,
/// recorded and submitted.
///
/// In the peer-to-peer model the receiver broadcasts the payment it cares
/// about (spv-understanding.md), so a payment whose transaction carries no
/// merkle proof of its own is submitted to ARC once it validates and the
/// wallet's read model holds it, and ARC then tracks it to its block. The
/// event is emitted after both (bead libspiffy-xggs): [valid] means the
/// payment is recorded and queryable, [broadcasted] that ARC accepted it.
/// It used to claim `broadcasted: true` the moment the submission was
/// handed to ARC's mailbox — before ARC answered, and with no ARC at all.
///
/// A payment whose proofs name a block header we have not synced is not
/// decided yet: [awaitingHeader], with [valid] false, and this is not a
/// failure (`ask` returns it). A second event, the verdict, follows once the
/// header arrives, carrying the same [requestId] while this process runs;
/// after a restart the receive is replayed from storage and its verdict
/// carries none.
class BEEFValidationResultEvent extends CoordinatorReply {
  @override
  final String? walletId;
  @override
  final String? requestId;
  final String? invoiceId;
  final String? txid;
  final bool valid;

  /// Why it is not [valid], or why the read model could not be shown to
  /// hold it.
  final String? error;

  /// ARC accepted the submission ([networkStatus] says how far it got).
  /// False when it was not submitted: invalid, waiting for a header,
  /// already mined (it carried its own proof, which verified), or ARC
  /// refused or could not be reached ([broadcastError]).
  final bool broadcasted;

  /// ARC's status for the submission, by its wire name, when ARC answered.
  final String? networkStatus;

  /// Why the submission failed, when one was made and did not succeed.
  final String? broadcastError;

  /// Not a verdict: the payment waits for a block header (see above).
  final bool awaitingHeader;

  final List<Map<String, dynamic>>? spendableUTXOs;

  /// Outputs of the payment whose locking script could not be read, so they
  /// were not credited (bead libspiffy-rp6x; see
  /// [SPVValidationResultEvent.unreadableOutputs]). The payment path now
  /// carries them as the import path always did.
  final List<Map<String, dynamic>> unreadableOutputs;

  BEEFValidationResultEvent({
    this.walletId,
    this.invoiceId,
    this.txid,
    required this.valid,
    this.error,
    this.broadcasted = false,
    this.networkStatus,
    this.broadcastError,
    this.awaitingHeader = false,
    List<Map<String, dynamic>>? spendableUTXOs,
    List<Map<String, dynamic>> unreadableOutputs = const [],
    this.requestId,
  })  : spendableUTXOs = frozenListOrNull(spendableUTXOs),
        unreadableOutputs = frozenMapList(unreadableOutputs);

  @override
  String? get failure => valid || awaitingHeader ? null : error ?? 'The payment did not validate';
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
    List<Map<String, dynamic>> spendableUTXOs = const [],
    List<Map<String, dynamic>> spentUTXOs = const [],
    List<Map<String, dynamic>> unreadableOutputs = const [],
  })  : spendableUTXOs = frozenMapList(spendableUTXOs),
        spentUTXOs = frozenMapList(spentUTXOs),
        unreadableOutputs = frozenMapList(unreadableOutputs);
}

/// A broadcast to ARC failed that no request is waiting on (a durable
/// retry, or a broadcast another actor started).
class BroadcastFailureEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String txid;
  final String error;

  /// ARCActor queued the broadcast for a durable retry. False for a
  /// definitive refusal, and on a backend without the retry queue.
  final bool willRetry;

  BroadcastFailureEvent({
    this.walletId,
    required this.txid,
    required this.error,
    required this.willRetry,
  });
}

/// Result of settling a BEEF via ARC.
///
/// `submittedCount` is the number of TXs successfully accepted by ARC.
/// `skippedCount` is the number of TXs skipped because they were already on
/// chain (hasMerkle=true). `failedCount` is the number of TXs that ARC
/// rejected; their txids and per-tx error messages are in `failedTxids`
/// and `failureErrors` (same length, same index). `error` is an
/// aggregated summary for display.
class BEEFSettledEvent extends CoordinatorReply {
  @override
  final String? walletId;
  @override
  final String? requestId;
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
    List<String> failedTxids = const [],
    List<String> failureErrors = const [],
    this.requestId,
  })  : failedTxids = frozenList(failedTxids),
        failureErrors = frozenList(failureErrors);

  @override
  String? get failure => success ? null : error ?? 'The BEEF was not settled';
}

/// Transaction imported into wallet
class TransactionImportedEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
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
    this.requestId,
  });

  @override
  String? get failure => success ? null : error ?? 'The transaction was not imported';
}

/// Answer to [ExportTransactionQuery]: the transaction with its proof and
/// what proves its ancestry, as BEEF bytes, or why there is none.
class TransactionExportedEvent extends CoordinatorReply {
  @override
  final String walletId;
  final String txid;
  @override
  final String? requestId;
  final bool success;
  final List<int>? beef;

  /// The derivation indices of the wallet's delegated addresses the
  /// transaction pays: what the payee's wallet imports it with
  /// ([ImportTransactionCommand.delegatedIndices]). Empty when it pays none.
  final List<int> delegatedIndices;

  /// The type-42 derivations of the destinations the transaction pays that
  /// the wallet knows (bead libspiffy-zxkd): ones it derived as the payer,
  /// and ones payers derived from its anchor key. What the payee's wallet
  /// imports it with ([ImportTransactionCommand.type42Derivations]). Empty
  /// when it pays none.
  final List<Type42Derivation> type42Derivations;
  final String? error;

  TransactionExportedEvent({
    required this.walletId,
    required this.txid,
    this.requestId,
    required this.success,
    List<int>? beef,
    List<int> delegatedIndices = const [],
    List<Type42Derivation> type42Derivations = const [],
    this.error,
  })  : beef = frozenListOrNull(beef),
        delegatedIndices = frozenList(delegatedIndices),
        type42Derivations = frozenList(type42Derivations);

  @override
  String? get failure => success ? null : error ?? 'The transaction was not exported';
}

/// Answer to [IssueAnchorKeyCommand]: the wallet's anchor public key for
/// the context (compressed, hex), or why there is none (an xpub or WIF
/// wallet has no anchor key; an empty context is refused).
class AnchorPublicKeyEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final String? publicKey;
  final bool success;
  final String? error;

  AnchorPublicKeyEvent({
    required this.walletId,
    this.requestId,
    this.publicKey,
    required this.success,
    this.error,
  });

  @override
  String? get failure => success ? null : error ?? 'No anchor key was issued';
}

/// Answer to [SignWithAnchorKeyCommand]: the DER signature (hex) of
/// SHA-256 of the message by the anchor key [publicKey], or why there is
/// none. The signature is deterministic (RFC 6979) with a low S.
class AnchorSignedEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final String? publicKey;
  final String? signatureDer;
  final bool success;
  final String? error;

  AnchorSignedEvent({
    required this.walletId,
    this.requestId,
    this.publicKey,
    this.signatureDer,
    required this.success,
    this.error,
  });

  @override
  String? get failure => success ? null : error ?? 'Nothing was signed';
}

/// Answer to [Brc100KeyOperationCommand]: the operation's [result], or why
/// there is none.
class Brc100KeyOperationEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final Brc100KeyResult? result;
  final bool success;
  final String? error;

  Brc100KeyOperationEvent({
    required this.walletId,
    this.requestId,
    this.result,
    required this.success,
    this.error,
  });

  @override
  String? get failure => success ? null : error ?? 'The key operation failed';
}

/// Answer to [DeriveType42DestinationCommand]: the destination, or why
/// there is none. [Type42Destination.address] is what the payer pays;
/// [Type42Destination.derivation] is the hand-off.
class Type42DestinationEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final Type42Destination? destination;
  final bool success;
  final String? error;

  Type42DestinationEvent({
    required this.walletId,
    this.requestId,
    this.destination,
    required this.success,
    this.error,
  });

  @override
  String? get failure => success ? null : error ?? 'No destination was derived';
}

/// Block headers were stored: how many, and the heights they span.
///
/// This is how an application follows the header chain. The initial CDN
/// download reports its own progress through
/// `LibSpiffyActorSystem.initialize(onHeaderSyncProgress:)`, which gives the
/// headers downloaded, the total, and the phase; every batch of headers
/// stored after that — a peer's answer to header sync, or a
/// [StoreHeadersCommand] — is this event. Whether the chain has caught up
/// with its peers is [HeaderSyncStatusEvent].
///
/// A batch whose headers were all known already stores nothing and is not
/// announced. [success] is false when a header of the batch was rejected;
/// [error] says why the first one was.
class BlockHeadersStoredEvent extends CoordinatorReply {
  @override
  String? get walletId => null;
  @override
  final String? requestId;
  final int headersStored;

  /// Height of the first and the last header stored; 0 when none was.
  final int startHeight;
  final int endHeight;
  final bool success;
  final String? error;

  /// Where the headers came from: [peerSource] for header sync from peers,
  /// otherwise the [StoreHeadersCommand]'s `source`.
  final String source;

  /// [source] of headers a peer sent.
  static const peerSource = 'p2p';

  BlockHeadersStoredEvent({
    required this.headersStored,
    required this.startHeight,
    required this.endHeight,
    required this.success,
    this.error,
    this.source = peerSource,
    this.requestId,
  });

  @override
  String? get failure => success ? null : error ?? 'A header was rejected';
}

/// Where header sync stands: the chain's height, the height its peers
/// reported, and whether it has caught up with them.
///
/// The actor system is ready before its headers are: wallets can be
/// created and payments made at once, and a payment whose block header has
/// not arrived yet waits for it. [synced] is how an application tells when
/// that wait is over for the chain as a whole (bead libspiffy-ndfr).
class HeaderSyncStatus {
  /// Height of the active chain's tip.
  final int height;

  /// The higher of [height] and the heights the connected peers reported
  /// in their version handshake, as `LibSpiffyActorSystem.networkHeight`;
  /// 0 while no peer reported one. A peer's handshake height is from when it
  /// connected, so this is for showing progress; [synced] is the verdict.
  final int networkHeight;

  /// Whether the last answer a peer gave header sync held fewer headers
  /// than a full batch (2,000): the peer had nothing more after them.
  /// False until the first answer, and while a sync from far behind is
  /// still receiving full batches.
  final bool synced;

  /// Peers connected now. With none, nothing syncs: P2P is disabled, or
  /// every peer has dropped and the system is dialling again.
  final int peerCount;

  const HeaderSyncStatus({
    required this.height,
    required this.networkHeight,
    required this.synced,
    required this.peerCount,
  });

  @override
  bool operator ==(Object other) =>
      other is HeaderSyncStatus &&
      other.height == height &&
      other.networkHeight == networkHeight &&
      other.synced == synced &&
      other.peerCount == peerCount;

  @override
  int get hashCode => Object.hash(height, networkHeight, synced, peerCount);

  @override
  String toString() => 'HeaderSyncStatus(height: $height/$networkHeight, '
      'synced: $synced, peers: $peerCount)';
}

/// Asks where header sync stands; answered with [HeaderSyncStatusResponse].
class GetHeaderSyncStatusQuery extends CoordinatorRequest<HeaderSyncStatusResponse> {

  GetHeaderSyncStatusQuery({super.requestId});

  @override
  Map<String, dynamic> get metadata => {};
}

/// Answer to [GetHeaderSyncStatusQuery].
class HeaderSyncStatusResponse extends CoordinatorReply {
  @override
  String? get walletId => null;
  @override
  final String? requestId;
  final HeaderSyncStatus status;

  HeaderSyncStatusResponse({this.requestId, required this.status});

  /// Never: a failure to answer arrives as an [ErrorEvent].
  @override
  String? get failure => null;
}

/// Header sync caught up with its peers, or fell behind them: emitted when
/// [HeaderSyncStatus.synced] changes. Each batch of headers stored on the
/// way is a [BlockHeadersStoredEvent].
class HeaderSyncStatusEvent extends CoordinatorEvent {
  @override
  String? get walletId => null;
  final HeaderSyncStatus status;

  HeaderSyncStatusEvent({required this.status});
}

/// Watch address registered
class WatchAddressRegisteredEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final String address;
  final bool success;
  final String? error;

  WatchAddressRegisteredEvent({
    required this.walletId,
    required this.address,
    required this.success,
    this.error,
    this.requestId,
  });

  @override
  String? get failure => success ? null : error ?? 'The watch address was not registered';
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
class DeferredPaymentsResponse extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final List<DeferredPaymentDetail> payments;

  /// Pass as [GetDeferredPaymentsQuery.cursor] for the next page; null on
  /// the last page.
  final String? nextCursor;

  DeferredPaymentsResponse({
    required this.walletId,
    this.requestId,
    required List<DeferredPaymentDetail> payments,
    this.nextCursor,
  })  : payments = frozenList(payments);

  /// Never: a failure to answer arrives as an [ErrorEvent].
  @override
  String? get failure => null;
}

/// Result of [BroadcastDeferredPaymentCommand].
class DeferredPaymentBroadcastEvent extends CoordinatorReply {
  @override
  final String walletId;
  final String txid;
  @override
  final String? requestId;

  /// The network holds the transaction (`SEEN_ON_NETWORK` or `MINED`), or
  /// already did. An answer ARC gave in flight (it stopped waiting for the
  /// network) is followed for up to 30 s until ARC gives a verdict; one
  /// still in flight then, in the orphan mempool, contested or rejected is
  /// not a success, and [error] says why.
  final bool success;

  /// The source's last answer (`SEEN_ON_NETWORK`, `MINED`, `REJECTED`, ...).
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
    this.requestId,
    required this.success,
    this.networkStatus,
    this.source,
    this.confirmed = false,
    this.willRetry = false,
    this.error,
    List<String> competingTxids = const [],
  })  : competingTxids = frozenList(competingTxids);

  @override
  String? get failure => success ? null : error ?? 'The network does not hold the payment';
}

/// Result of [CheckDeferredPaymentStatusCommand].
class DeferredPaymentStatusEvent extends CoordinatorReply {
  @override
  final String walletId;
  final String txid;
  @override
  final String? requestId;

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
    this.requestId,
    required this.success,
    this.networkStatus,
    this.source,
    this.blockHeight,
    this.proofStatus,
    this.confirmed = false,
    this.error,
    List<String> competingTxids = const [],
  })  : competingTxids = frozenList(competingTxids);

  @override
  String? get failure => success ? null : error ?? 'No source answered';
}

/// Result of [CancelDeferredPaymentCommand].
class DeferredPaymentCancelledEvent extends CoordinatorReply {
  @override
  final String walletId;
  final String txid;
  @override
  final String? requestId;
  final bool success;

  /// What the network check before the cancellation answered.
  final String? networkStatus;

  /// Inputs returned to their previous status.
  final List<String> releasedUtxoKeys;
  final String? error;

  DeferredPaymentCancelledEvent({
    required this.walletId,
    required this.txid,
    this.requestId,
    required this.success,
    this.networkStatus,
    List<String> releasedUtxoKeys = const [],
    this.error,
  })  : releasedUtxoKeys = frozenList(releasedUtxoKeys);

  @override
  String? get failure => success ? null : error ?? 'The payment was not cancelled';
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
}

/// Channel opened successfully
class ChannelOpenedEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final String channelId;
  final String? fundingTxId;
  final int fundingAmountSats;

  ChannelOpenedEvent({
    required this.walletId,
    required this.channelId,
    this.fundingTxId,
    required this.fundingAmountSats,
    this.requestId,
  });
  /// Never: a failure to answer arrives as an [ErrorEvent].
  @override
  String? get failure => null;
}

/// The outcome of a [ClaimChannelRefundCommand] (bead libspiffy-cqc, the
/// V-99 follow-up).
///
/// The claim broadcasts the refund, journals it and records the money back
/// in the wallet. None of that reaches the host on its own: unlike a close,
/// which surfaces through the channel's own `ChannelClosedEvent`, a claim
/// has no event the adapter forwards. Without this the host could not tell
/// a refund that landed from one the network refused as a double spend.
class ChannelRefundClaimedEvent extends CoordinatorReply {
  @override
  final String? walletId;
  @override
  final String? requestId;
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
    this.requestId,
  });
  @override
  String? get failure => success ? null : error ?? 'The refund was not claimed';
}

/// Answer to [AcceptChannelCommand]: the acceptance is journaled and
/// `channel_accept` handed to the app's transport for the client. The
/// channel opens when the client funds it ([ChannelOpenedEvent]).
class ChannelAcceptedEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final String channelId;
  final bool success;
  final String? error;

  ChannelAcceptedEvent({required this.walletId, required this.channelId, required this.success, this.error, this.requestId});
  @override
  String? get failure => success ? null : error ?? 'The channel was not accepted';
}

/// Answer to [RejectChannelCommand]: `channel_reject` is handed to the app's
/// transport for the client, when the request is one this side holds.
class ChannelRejectedEvent extends CoordinatorReply {
  @override
  String? get walletId => null;
  @override
  final String? requestId;
  final String channelId;

  /// Whether a request from the client was held, and the client told.
  final bool clientTold;

  ChannelRejectedEvent({required this.channelId, required this.clientTold, this.requestId});
  /// Never: a failure to answer arrives as an [ErrorEvent].
  @override
  String? get failure => null;
}

/// Answer to [ExpireChannelCommand]: the expiry is journaled, or why not.
class ChannelExpiredEvent extends CoordinatorReply {
  @override
  final String? walletId;
  @override
  final String? requestId;
  final String channelId;
  final bool success;
  final String? error;

  ChannelExpiredEvent({this.walletId, required this.channelId, required this.success, this.error, this.requestId});
  @override
  String? get failure => success ? null : error ?? 'The expiry was not recorded';
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
/// another retry.
class ChannelFundingRetriedEvent extends CoordinatorReply {
  @override
  final String? walletId;
  @override
  final String? requestId;
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
    this.requestId,
  });
  @override
  String? get failure => success ? null : error ?? 'The funding was not broadcast';
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
class ChannelOpenResentEvent extends CoordinatorReply {
  @override
  final String? walletId;
  @override
  final String? requestId;
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
    this.requestId,
  });
  @override
  String? get failure => success ? null : error ?? 'channel_open was not re-sent';
}

/// Payment made or received on a channel
class ChannelPaymentEvent extends CoordinatorReply {
  @override
  final String? walletId;
  @override
  final String? requestId;
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
    this.requestId,
  });
  /// Never: a failure to answer arrives as an [ErrorEvent].
  @override
  String? get failure => null;
}

/// A payment the client signed and sent, not yet acknowledged by the server
/// (bead overnode_v2-0o5.3.2). The [ChannelPayCommand] is answered by its
/// [ChannelPaymentEvent] once the server acknowledges it, or by an
/// [ErrorEvent] when it does not within `ChannelTiming.confirmWithin`; it is
/// still resent then, and a later acknowledgement brings a
/// [ChannelPaymentEvent] that answers no request.
class ChannelPaymentPendingEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String channelId;
  final int amountSats;
  final int sequence;
  final int clientBalance;
  final int serverBalance;

  ChannelPaymentPendingEvent({
    this.walletId,
    required this.channelId,
    required this.amountSats,
    required this.sequence,
    required this.clientBalance,
    required this.serverBalance,
  });
}

/// Channel closed
class ChannelClosedEvent extends CoordinatorReply {
  @override
  final String? walletId;
  @override
  final String? requestId;
  final String channelId;
  final String? reason;
  final String? settlementTxId;

  /// What the settlement pays each side (bead overnode_v2-0o5.3.2): the
  /// server's output carries its whole balance, and the client's balance is
  /// the rest of the funding. On a client whose latest payment the server
  /// never received, less than its latest payment gave the server. Null
  /// when this answers a close of a channel already closed.
  final int? finalClientBalance;
  final int? finalServerBalance;

  ChannelClosedEvent({
    this.walletId,
    required this.channelId,
    this.reason,
    this.settlementTxId,
    this.finalClientBalance,
    this.finalServerBalance,
    this.requestId,
  });
  /// Never: a failure to answer arrives as an [ErrorEvent].
  @override
  String? get failure => null;
}

/// One channel that started opening and never finished (bead
/// libspiffy-29jd).
class UnfinishedChannel {
  final String channelId;

  /// The read model's state: `opening` (requested, accepted, or its refund
  /// signed) or `funding` (a funding broadcast was started).
  final String state;

  /// The counterparty this side was talking to, so the app can decide
  /// whether the channel is still worth anything.
  final String? counterpartyPeerId;
  final BigInt fundingAmountSats;

  /// When the client can take its funding back with a refund claim.
  final int lockTimeUnix;

  const UnfinishedChannel({
    required this.channelId,
    required this.state,
    required this.fundingAmountSats,
    required this.lockTimeUnix,
    this.counterpartyPeerId,
  });

  @override
  String toString() =>
      'UnfinishedChannel($channelId, $state, $fundingAmountSats sats, '
      'lockTime $lockTimeUnix)';
}

/// Channels of [walletId] that started opening and never reached `open`,
/// reported once at startup (bead libspiffy-29jd).
///
/// Restart recovery is otherwise **reactive**: the channel adapter rebuilds
/// a record when an inbound stimulus names a channel. A channel whose
/// funding broadcast failed, or whose `channel_open` the peer never
/// received, is exactly the case where the counterparty has gone silent —
/// so nothing ever arrives to trigger it, and an app that does not poll its
/// own channel list never learns the channel is stuck.
///
/// **This event only reports.** Nothing is retried and nothing is journaled
/// by the sweep: a funding broadcast whose outcome was lost may already be
/// in a mempool, and BSV is first-seen-wins, so re-driving channels on
/// startup would be the library deciding policy. The levers are the app's:
/// `RetryChannelFundingCommand` and `ResendChannelOpenCommand` to carry on,
/// or `CancelDeferredPaymentCommand` to take the funding inputs back.
///
/// Not emitted when there is nothing to report, so no event means no
/// channel of that wallet is stuck.
class UnfinishedChannelsFoundEvent extends CoordinatorEvent {
  @override
  final String? walletId;

  /// Never empty.
  final List<UnfinishedChannel> channels;

  UnfinishedChannelsFoundEvent({
    required this.walletId,
    required List<UnfinishedChannel> channels,
  })  : channels = frozenList(channels);
}

/// An outgoing peer-to-peer message the app must transmit to [toPeerId] on
/// its own transport (bead libspiffy-a2v3).
///
/// The library builds the payload and names the peer; carrying it is the
/// app's job. The payment-channel protocol and the merkle-proof protocol
/// (`messageType` `proof_request` / `proof_response`) both send through it.
class P2PMessageToSendEvent extends CoordinatorEvent {
  @override
  String? get walletId => null;
  final String toPeerId;
  final String messageType;
  final Map<String, dynamic> payload;

  P2PMessageToSendEvent({
    required this.toPeerId,
    required this.messageType,
    required Map<String, dynamic> payload,
  })  : payload = frozenPlainMap(payload);
}

/// The app could not hand a [P2PMessageToSendEvent] to [toPeerId] (bead
/// overnode_v2-0o5.3.2): its transport failed to reach the peer. The
/// payment-channel protocol sends it again sooner than it would otherwise;
/// the rest of the library has nothing to retry.
class P2PSendFailed implements Message {
  final String toPeerId;
  final String messageType;
  final Map<String, dynamic> payload;
  final String? error;

  P2PSendFailed({
    required this.toPeerId,
    required this.messageType,
    required Map<String, dynamic> payload,
    this.error,
  }) : payload = frozenPlainMap(payload);

  @override
  final String correlationId = uniqueId('p2p-failed');
  @override
  Map<String, dynamic> get metadata => {'toPeerId': toPeerId, 'messageType': messageType};
  @override
  ActorRef? get replyTo => null;
  @override
  final DateTime timestamp = DateTime.now();
}

/// What became of a [RequestAncestorProofCommand] (bead libspiffy-a2v3).
///
/// [success] only says the request went out (as a [P2PMessageToSendEvent] to
/// [toPeerId]); the answer arrives later as an [AncestorProofResponseEvent].
/// [success] is false, with [toPeerId] null, when nobody can be asked: the
/// transaction is not stored, or its row carries no counterparty marker, in
/// which case the output is unrecoverable by request and only the block
/// returning to the active chain can restore it.
class AncestorProofRequestedEvent extends CoordinatorReply {
  @override
  final String walletId;

  /// The received transaction whose ancestry is missing a proof.
  final String txid;

  /// The counterparty marker recorded on [txid], which is who was asked.
  /// Null when there is none to ask.
  final String? toPeerId;

  /// The ancestors named in the request.
  final List<String> ancestorTxids;

  @override
  final String? requestId;
  final bool success;
  final String? error;

  AncestorProofRequestedEvent({
    required this.walletId,
    required this.txid,
    this.requestId,
    required this.success,
    this.toPeerId,
    List<String> ancestorTxids = const [],
    this.error,
  })  : ancestorTxids = frozenList(ancestorTxids);

  @override
  String? get failure => success ? null : error ?? 'Nobody could be asked';
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
}

// --- Benford Split Events ---

/// A Benford UTXO split has started: the wallet's spendable outputs have
/// been chosen and the first split transaction is about to be built.
///
/// This event was exported and nothing in the library constructed it, while
/// [UTXOSplitCompleteEvent] was emitted — so an application heard a split
/// finish and never heard one start (bead libspiffy-7ye4). That gap is not
/// cosmetic: a split of several UTXOs builds, signs and broadcasts one
/// transaction per source output and waits for ARC's answer to each, so the
/// silence could last a long time.
///
/// Emitted when the split can actually start, and never when it cannot: a
/// missing wallet, a watch-only wallet, no spendable UTXOs, or no policy fee
/// rate from ARC all end in [UTXOSplitCompleteEvent] with an error and no
/// start, because nothing was started.
///
/// The numbers are `BenfordCoordinatorActor`'s own, measured rather than
/// restated from the command: [utxoCount] is how many of the wallet's
/// spendable UTXOs this split will take, which `SplitUTXOsCommand`'s
/// `maxUtxosToSplit` bounds but does not decide.
class UTXOSplitStartedEvent extends CoordinatorEvent {
  @override
  final String walletId;

  /// The wallet's spendable UTXOs this split will take.
  final int utxoCount;

  /// The outputs each of them is split into.
  final int targetOutputsPerUtxo;

  UTXOSplitStartedEvent({
    required this.walletId,
    required this.utxoCount,
    required this.targetOutputsPerUtxo,
  });
}

/// Benford UTXO split completed.
///
/// [success] follows ARC's answer to every split transaction (bead
/// libspiffy-wdch): a split ARC accepted or queued for a retry succeeds, one
/// it rejected or reports contested does not; [splits] tells each apart.
class UTXOSplitCompleteEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;

  /// Split transactions ARC accepted or queued: the length of [txids]. Not
  /// the number of outputs, which is [newUtxoCount] (bead libspiffy-q28i).
  final int transactionCount;

  /// New UTXOs those transactions create.
  final int newUtxoCount;

  /// The fees of the splits that succeeded, summed. Zero here is a
  /// measurement — no split succeeded — and not a placeholder for an unknown
  /// fee: an outcome whose fee is unknown carries a null
  /// [SplitTransactionOutcome.feePaid] and is not counted (libspiffy-q28i).
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
    List<String> txids = const [],
    List<SplitTransactionOutcome> splits = const [],
    this.requestId,
  })  : txids = frozenList(txids),
        splits = frozenList(splits);

  @override
  String? get failure => success ? null : error ?? 'The split failed';
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

  /// No transaction was built for the source at all: it was too small to
  /// cover the fee and an output each, the wallet would not reserve it, or
  /// it could not be built or signed. Nothing was recorded, nothing is held,
  /// and the source is still the wallet's to spend. [SplitTransactionOutcome.txid]
  /// is null, because there is no transaction to name (bead libspiffy-q28i).
  notBuilt,
}

/// One Benford split transaction and how it ended ([SplitTransactionStatus]).
class SplitTransactionOutcome {
  /// The split transaction, or **null for [SplitTransactionStatus.notBuilt]**,
  /// where no transaction exists to name (bead libspiffy-q28i).
  final String? txid;

  /// The UTXO the transaction splits (`txid:vout`). Always known: it is the
  /// source the split was attempted for, whatever became of it.
  final String sourceUtxoKey;
  final SplitTransactionStatus status;

  /// ARC's status, when ARC answered with one.
  final String? networkStatus;

  /// Why the split did not succeed, or what ARC said about it.
  final String? error;

  /// The fee this split pays, in satoshis: the source minus the outputs of
  /// the signed transaction. Null when no transaction was built, and null is
  /// the honest answer there — a fee of zero would be an invention, not a
  /// measurement (bead libspiffy-q28i).
  ///
  /// A fee here is what the transaction *carries*, not proof that it reached
  /// a miner: only [isSuccess] outcomes have been accepted or queued.
  final BigInt? feePaid;

  const SplitTransactionOutcome({
    required this.txid,
    required this.sourceUtxoKey,
    required this.status,
    this.networkStatus,
    this.error,
    this.feePaid,
  });

  /// ARC accepted the split or queued it for a retry.
  bool get isSuccess => status == SplitTransactionStatus.accepted || status == SplitTransactionStatus.queued;

  @override
  String toString() => 'SplitTransactionOutcome(${txid ?? 'no transaction'} of $sourceUtxoKey: ${status.name}'
      '${networkStatus != null ? ' $networkStatus' : ''}${error != null ? ', $error' : ''})';
}

// --- Archive Events ---

/// Timestamp archive completed
class TimestampCompleteEvent extends CoordinatorReply {
  @override
  final String? walletId;
  @override
  final String? requestId;
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
    this.requestId,
  });

  @override
  String? get failure => success ? null : error ?? 'The timestamp was not made';
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
}

/// Something failed that has no reply of its own to report it in.
///
/// When a request caused it, [requestId] names that request, and
/// `WalletCoordinator.ask` fails with it; otherwise it is null.
class ErrorEvent extends CoordinatorEvent {
  @override
  final String? walletId;
  final String source;
  final String message;
  final String? stackTrace;

  /// The [CoordinatorRequest.requestId] of the request that failed; null
  /// when no request caused this.
  final String? requestId;

  ErrorEvent({
    this.walletId,
    required this.source,
    required this.message,
    this.stackTrace,
    this.requestId,
  });
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
class ReclaimDeferredPaymentCommand extends CoordinatorRequest<DeferredPaymentReclaimedEvent> {
  final String walletId;

  /// The outstanding deferred payment to reclaim.
  final String txid;

  /// Where the self-spend is broadcast.
  final DeferredPaymentNetworkSource via;

  /// Recorded as the reclaimed payment's resolution reason.
  final String? reason;

  ReclaimDeferredPaymentCommand({
    required this.walletId,
    required this.txid,
    this.via = DeferredPaymentNetworkSource.arc,
    this.reason,
    super.requestId,
  });

  @override
  Duration get replyTimeout => CoordinatorRequest.reclaimTimeout;
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
}

/// Completes an outstanding deferred payment that the wallet signed only in
/// part, with [rawHex]: the same transaction carrying the counterparty's
/// signatures on the inputs the wallet does not hold.
///
/// A sale in one transaction is the case: the first side to sign records a
/// half that cannot be broadcast, and holds its inputs. When the other side
/// returns the completed transaction, the wallet records it in the half's
/// place: same inputs, sequences, outputs, version and lock time, the
/// wallet's own unlocking scripts unchanged. The completed transaction
/// takes over the hold, and the half is
/// [DeferredPaymentState.completed]. Nothing is broadcast here: settle the
/// completed transaction as any other deferred payment (or the counterparty
/// broadcasts it). Replied with [DeferredPaymentCompletedEvent].
class CompleteDeferredPaymentCommand extends CoordinatorRequest<DeferredPaymentCompletedEvent> {
  final String walletId;

  /// The half-signed deferred payment.
  final String txid;

  /// The completed transaction.
  final String rawHex;

  CompleteDeferredPaymentCommand({
    required this.walletId,
    required this.txid,
    required this.rawHex,
    super.requestId,
  });

  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
}

/// Result of [CompleteDeferredPaymentCommand]: on [success] the completed
/// transaction [completedTxid] is recorded and holds the half's inputs.
class DeferredPaymentCompletedEvent extends CoordinatorReply {
  @override
  final String walletId;
  final String txid;
  final String? completedTxid;
  @override
  final String? requestId;
  final bool success;
  final String? error;

  DeferredPaymentCompletedEvent({
    required this.walletId,
    required this.txid,
    this.requestId,
    required this.success,
    this.completedTxid,
    this.error,
  });

  @override
  String? get failure => success ? null : error ?? 'The payment was not completed';
}

/// Asks whether outputs the wallet holds were spent by someone else: by
/// default every plugin output (a token) the wallet has not spent. For each
/// one the configured data source answers who spent it. A spender that is
/// mined and proven against the local headers (`ForeignSpend.proven`) is
/// received by the wallet as any mined transaction of its is: the output it
/// spends is marked spent, its outputs that pay the wallet's addresses are
/// received as available in the block its proof names, and it joins the
/// wallet's transaction history (`ForeignSpend.recorded`). Its raw
/// transaction and its BEEF come back too. Anything less is a lead,
/// reported and not acted on.
///
/// A token the wallet holds can be spent without the wallet: a Voucher NFT
/// the issuer forced back after its expiry, a listing a stranger bought, a
/// pot seized. The wallet learns of it by asking about what it holds, one
/// output at a time; it never scans the chain. A listing bought: the token
/// output goes and the price arrives, both in the same check. Replied with
/// [ForeignSpendsCheckedEvent] once the read model shows what was
/// recorded, so a balance read on hearing it is current.
class CheckForeignSpendsCommand extends CoordinatorRequest<ForeignSpendsCheckedEvent> {
  final String walletId;

  /// `txid:vout` keys to check; null for every unspent plugin output.
  final List<String>? utxoKeys;

  CheckForeignSpendsCommand({required this.walletId, List<String>? utxoKeys, super.requestId})
      : utxoKeys = frozenListOrNull(utxoKeys);

  @override
  Duration get replyTimeout => CoordinatorRequest.foreignSpendsTimeout;
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
}

/// Result of [CheckForeignSpendsCommand].
class ForeignSpendsCheckedEvent extends CoordinatorReply {
  @override
  final String walletId;
  @override
  final String? requestId;
  final bool success;

  /// The outputs checked.
  final List<String> checked;

  /// The ones another transaction spends, each saying whether its spender
  /// is proven and recorded in the wallet.
  final List<ForeignSpend> spends;

  /// Outputs whose check failed, with why.
  final Map<String, String> unchecked;
  final String? error;

  ForeignSpendsCheckedEvent({
    required this.walletId,
    this.requestId,
    required this.success,
    List<String> checked = const [],
    List<ForeignSpend> spends = const [],
    Map<String, String> unchecked = const {},
    this.error,
  })  : checked = frozenList(checked),
        spends = frozenList(spends),
        unchecked = frozenMap(unchecked);

  @override
  String? get failure => success ? null : error ?? 'The check failed';
}

/// Result of [ReclaimDeferredPaymentCommand].
///
/// [success] says the self-spend was journaled and the network holds it
/// (`SEEN_ON_NETWORK` or `MINED`; an answer ARC gave in flight is followed
/// for up to 30 s until it gives a verdict), and the payment is then
/// [DeferredPaymentState.reclaimed]. Otherwise the payment stays
/// outstanding with its inputs held by the self-spend, and it resolves as
/// reclaimed if the network reports the self-spend later (watch it with
/// [GetDeferredPaymentsQuery] or [CheckDeferredPaymentStatusCommand] on
/// [reclaimTxid]).
class DeferredPaymentReclaimedEvent extends CoordinatorReply {
  @override
  final String walletId;

  /// The deferred payment being reclaimed.
  final String txid;

  /// The wallet's self-spend of its held inputs, null when none was built.
  final String? reclaimTxid;
  @override
  final String? requestId;
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
    this.requestId,
    required this.success,
    this.reclaimTxid,
    List<String> reclaimedUtxoKeys = const [],
    this.reclaimedSatoshis,
    this.fee,
    this.toAddress,
    this.networkStatus,
    this.source,
    List<String> competingTxids = const [],
    this.error,
  })  : reclaimedUtxoKeys = frozenList(reclaimedUtxoKeys),
        competingTxids = frozenList(competingTxids);

  @override
  String? get failure => success ? null : error ?? 'The payment was not reclaimed';
}
