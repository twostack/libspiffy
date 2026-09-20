import 'package:dactor/dactor.dart';
import 'package:libspiffy/libspiffy.dart';
import '../core/wallet_commands.dart';
import '../models/deferred_payment.dart';

// The reply bases and the actor wiring messages live in
// internal_messages.dart; re-exported so importing this file is enough to
// build or recognise a reply.
export 'internal_messages.dart'
    show
        ActorResponse,
        FailureResponse,
        SetBenfordCoordinatorMessage,
        SetArcActorForSPVMessage,
        SetHeaderSyncActorMessage,
        SetCoordinatorForSPVMessage;
// A Benford split's per-transaction outcome (bead libspiffy-wdch), shared
// with the public UTXOSplitCompleteEvent.
export 'coordinator_messages.dart' show SplitTransactionOutcome, SplitTransactionStatus;
import 'coordinator_messages.dart' show SplitTransactionOutcome;

/// Messages for coordinating between actors in the LibSpiffy system

// ==========================================================================
// WALLET MANAGER MESSAGES
// ==========================================================================

/// Request to create a new wallet
class CreateWalletMessage implements Message {
  final String walletId;
  final String name;
  final String? mnemonic;
  final String? wif;
  final String? xpriv;
  final String? xpub;
  final Map<String, dynamic>? walletMetadata;

  CreateWalletMessage(
    this.walletId,
    this.name, {
    this.mnemonic,
    this.wif,
    this.xpriv,
    this.xpub,
    this.walletMetadata,
  });

  @override
  String get correlationId => 'create-wallet-$walletId';
  @override
  Map<String, dynamic> get metadata => walletMetadata ?? {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response containing wallet creation result (from WalletManagerActor to external caller)
class WalletCreatedMessage extends ActorResponse {
  final String walletId;
  final String rootAddress;
  @override
  final bool success;
  @override
  final String? error;

  WalletCreatedMessage(this.walletId, this.rootAddress, this.success, {this.error});

  @override
  String get correlationId => 'wallet-created-$walletId';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response from BitcoinWalletAggregate after processing CreateWalletCommand
class WalletCreatedResponse extends ActorResponse {
  final String walletId;
  final String rootAddress;
  @override
  final bool success;
  @override
  final String? error;

  WalletCreatedResponse({
    required this.walletId,
    required this.rootAddress,
    required this.success,
    this.error,
  });

  @override
  String get correlationId => 'wallet-created-response-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response from BitcoinWalletAggregate after processing GenerateAddressCommand
class AddressGeneratedResponse extends ActorResponse {
  final String walletId;
  final String address;
  final int derivationIndex;
  @override
  final bool success;
  @override
  final String? error;
  final String? publicKeyHex; // Included when GenerateAddressCommand.includePublicKey is true

  AddressGeneratedResponse({
    required this.walletId,
    required this.address,
    required this.derivationIndex,
    required this.success,
    this.error,
    this.publicKeyHex,
    Map<String, dynamic>? metadata,
  }) : super(
          metadata: {
            'walletId': walletId,
            'address': address,
            'derivationIndex': derivationIndex,
            'success': success,
            if (publicKeyHex != null) 'publicKeyHex': publicKeyHex,
            ...?metadata,
          },
        );
}


/// Response from BitcoinWalletAggregate after signing transaction
class TransactionSignedResponse extends ActorResponse {
  final String walletId;
  final String txid;
  final String signedHex;
  @override
  final bool success;
  @override
  final String? error;

  TransactionSignedResponse({
    required this.walletId,
    required this.txid,
    required this.signedHex,
    required this.success,
    this.error,
  });

  @override
  String get correlationId => 'transaction-signed-response-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response for multisig transaction signing
class MultisigTransactionSignedResponse extends ActorResponse {
  final String walletId;
  final String txid; // The actual signed transaction ID (hash)
  final String? originalTransactionId; // The transactionId from the original command (for correlation)
  final String signedHex; // Partially or fully signed TX
  final String signatureHex; // Just our signature (for verification/building)
  @override
  final bool success;
  @override
  final String? error;

  MultisigTransactionSignedResponse({
    required this.walletId,
    required this.txid,
    this.originalTransactionId,
    required this.signedHex,
    required this.signatureHex,
    required this.success,
    this.error,
  });

  @override
  String get correlationId => 'multisig-signed-response-${originalTransactionId ?? txid}';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid, 'originalTransactionId': originalTransactionId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Reply to `SignInputCommand`: the signature for one input and the public
/// key of the wallet key that produced it.
class InputSignedResponse extends ActorResponse {
  final String walletId;

  /// Id of the `SignInputCommand` this answers.
  final String commandId;
  final int inputIndex;

  /// Signature in transaction format (DER plus the sighash byte); empty on
  /// failure.
  final String signatureHex;

  /// Compressed public key of the signing key (hex); empty on failure.
  final String publicKeyHex;
  @override
  final bool success;
  @override
  final String? error;

  InputSignedResponse({
    required this.walletId,
    required this.commandId,
    required this.inputIndex,
    required this.signatureHex,
    required this.publicKeyHex,
    required this.success,
    this.error,
  });

  @override
  String get correlationId => 'input-signed-$commandId';
  @override
  Map<String, dynamic> get metadata =>
      {'walletId': walletId, 'commandId': commandId, 'inputIndex': inputIndex};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response from building and signing a funding transaction
class FundingTransactionBuiltResponse extends ActorResponse {
  final String walletId;
  final String correlationId_;
  final String channelId;
  final String fundingTxHex;
  final String fundingTxId;
  final int fundingOutputIndex; // Always 0 for multisig output
  @override
  final bool success;
  @override
  final String? error;
  
  // Fields for recording the transaction and updating UTXOs
  final List<String> spentUtxoKeys; // e.g., ['txid:vout', ...]
  final String? changeAddress;
  final int? changeAmount;
  final int? changeOutputIndex;
  final int fee;
  final int totalInputSats;
  final int totalOutputSats;

  FundingTransactionBuiltResponse({
    required this.walletId,
    required String correlationId,
    required this.channelId,
    required this.fundingTxHex,
    required this.fundingTxId,
    required this.fundingOutputIndex,
    required this.success,
    this.error,
    this.spentUtxoKeys = const [],
    this.changeAddress,
    this.changeAmount,
    this.changeOutputIndex,
    this.fee = 0,
    this.totalInputSats = 0,
    this.totalOutputSats = 0,
  }) : correlationId_ = correlationId;

  @override
  String get correlationId => 'funding-tx-response-$correlationId_';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'correlationId': correlationId_, 'channelId': channelId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response from BenfordCoordinatorActor or BitcoinWalletAggregate for SplitUTXOsToBenfordCommand
class SplitUTXOsResponse extends ActorResponse {
  final String walletId;
  @override
  final bool success;
  @override
  final String? error;
  final int? splitCount; // Number of UTXOs created
  final List<String>? txids; // Split transactions ARC accepted or queued

  /// How each split transaction that was built and signed ended (bead
  /// libspiffy-wdch), in the order the source UTXOs were split. [success] is
  /// false when any of them did not succeed
  /// ([SplitTransactionOutcome.isSuccess]); [error] names each.
  final List<SplitTransactionOutcome> splits;

  SplitUTXOsResponse({
    required this.walletId,
    required this.success,
    this.error,
    this.splitCount,
    this.txids,
    this.splits = const [],
  });

  @override
  String get correlationId => 'split-utxos-response-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response from BitcoinWalletAggregate after processing ReceiveUTXOCommand
/// Reply to [ReserveUTXOCommand]. Sent on success as well as failure so
/// callers no longer have to treat "no reply within 2 s" as success.
class UTXOReservedResponse extends ActorResponse {
  final String walletId;
  final String utxoKey;
  final String reservedByTxId;
  @override
  final bool success;
  @override
  final String? error;

  UTXOReservedResponse({
    required this.walletId,
    required this.utxoKey,
    required this.reservedByTxId,
    required this.success,
    this.error,
  });

  @override
  String get correlationId => 'utxo-reserved-response-$utxoKey';
  @override
  Map<String, dynamic> get metadata =>
      {'walletId': walletId, 'utxoKey': utxoKey, 'reservedByTxId': reservedByTxId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();

  @override
  String toString() =>
      'UTXOReservedResponse($walletId, $utxoKey, success: $success${error != null ? ', error: $error' : ''})';
}

class UTXOReceivedResponse extends ActorResponse {
  final String walletId;
  final String txid;
  final int vout;
  @override
  final bool success;
  @override
  final String? error;

  UTXOReceivedResponse({
    required this.walletId,
    required this.txid,
    required this.vout,
    required this.success,
    this.error,
  });

  @override
  String get correlationId => 'utxo-received-response-$txid:$vout';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid, 'vout': vout};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response from BitcoinWalletAggregate after processing RecordImportedTransactionCommand
class TransactionRecordedResponse extends ActorResponse {
  final String walletId;
  final String txid;
  @override
  final bool success;
  @override
  final String? error;

  TransactionRecordedResponse({
    required this.walletId,
    required this.txid,
    required this.success,
    this.error,
  });

  @override
  String get correlationId => 'transaction-recorded-response-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Route a command to a specific wallet
class WalletCommandMessage implements Message {
  final String walletId;
  final WalletCommand command;

  WalletCommandMessage(this.walletId, this.command);

  @override
  String get correlationId => 'wallet-cmd-${walletId}-${command.commandId}';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// WalletManagerActor could not carry out a request (bead libspiffy-kl4i).
///
/// The manager has no reply of its own for most requests: a
/// [WalletCommandMessage] is routed to the wallet aggregate, which answers
/// the caller directly, so there is no success reply here to carry a
/// failure. This is that missing half — sent when the wallet has no journal,
/// when loading it throws, and from the manager's catch-all when handling a
/// request throws without answering.
///
/// It replaced a bare `{'error': ..., 'walletId': ...}` map, which callers
/// could only recognise by testing `payload is Map`, and which
/// `WalletCoordinatorActor` did not recognise at all — a failed delete,
/// recording, release or split left the app waiting for an answer that
/// never came.
///
/// Failure only: [success] is always false and [error] is never null.
class WalletManagerFailure extends FailureResponse {
  /// The wallet the request named, or null when it named none (the
  /// catch-all does not know which wallet, if any, a request was about).
  final String? walletId;

  /// The request that failed, by type name — `WalletCommandMessage`,
  /// `CreateWalletMessage`, and so on. Diagnostic only.
  @override
  final String request;

  @override
  final String error;

  WalletManagerFailure({
    required this.error,
    required this.request,
    this.walletId,
  });

  @override
  String get correlationId => 'wallet-manager-failure-${walletId ?? '-'}';
  @override
  Map<String, dynamic> get metadata =>
      {if (walletId != null) 'walletId': walletId, 'request': request};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
  @override
  String toString() => 'WalletManagerFailure($request'
      '${walletId != null ? ', $walletId' : ''}: $error)';
}

/// BitcoinWalletAggregate refused or failed a command it has no specific
/// reply for (bead libspiffy-kl4i).
///
/// The aggregate answers thirteen command types with a typed response; the
/// rest — roughly twenty of the thirty-five in `wallet_commands.dart` —
/// used to land in a bare `{'error': ..., 'command': ...}` map. Callers had
/// to test `payload is Map`, which also caught [WalletManagerFailure] and so
/// could not tell which of the two had answered.
///
/// Failure only: [success] is always false and [error] is never null. A
/// command that succeeds is answered by its own response type, or by
/// nothing at all.
class WalletCommandFailed extends FailureResponse {
  final String walletId;

  /// The command that failed, by type name.
  @override
  final String request;

  @override
  final String error;

  WalletCommandFailed({
    required this.walletId,
    required this.request,
    required this.error,
  });

  @override
  String get correlationId => 'wallet-command-failed-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'request': request};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
  @override
  String toString() => 'WalletCommandFailed($request, $walletId: $error)';
}

/// WalletManagerActor's reply to a [PreloadWalletCommand] that was sent with
/// a sender (a plain `tell` without one gets no reply). [success] is true
/// when the wallet's aggregate is loaded; otherwise [error] says why.
class WalletPreloadedResponse extends ActorResponse {
  final String walletId;
  @override
  final bool success;
  @override
  final String? error;

  WalletPreloadedResponse({
    required this.walletId,
    required this.success,
    this.error,
  });

  @override
  String get correlationId => 'wallet-preloaded-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Request list of all wallets
class ListWalletsMessage implements Message {
  @override
  String get correlationId => 'list-wallets-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response with list of wallet IDs
class WalletListMessage implements Message {
  final List<String> walletIds;

  WalletListMessage(this.walletIds);

  @override
  String get correlationId => 'wallet-list-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

// ==========================================================================
// SPV ACTOR MESSAGES - CORRECTED FOR TRUE SPV
// ==========================================================================

/// Receive transaction directly from counterparty with proofs (CORE SPV)
class ReceiveTransactionMessage implements Message {
  final String transactionId;
  final BEEF beef; //BEEF data for transactionId
  final String fromCounterparty;
  final String? targetWalletId; // Which wallet this transaction is for
  final String? invoiceId; // Invoice ID for payment matching (transmitted in BEEF metadata)
  final DateTime receivedAt;

  /// A caller's own id for this receive, echoed on the
  /// [SPVValidationResult] it produces (bead libspiffy-l8uf).
  ///
  /// SPVActor's reply is not a dactor `LocalMessage`, so `ActorRef.ask`
  /// cannot be used for it and a caller that needs the verdict has it told
  /// back through another actor. Matching those verdicts by txid pairs them
  /// by arrival order: two receives of the same transaction in flight at once
  /// — an ordinary `ReceiveTransactionCommand` and a `proof_response` for the
  /// same txid, say — could take each other's. This id pairs a verdict with
  /// the request that asked for it instead.
  ///
  /// Optional and opaque: the wallet never interprets it, and a receive
  /// without one behaves exactly as it always did.
  final String? requestId;

  ReceiveTransactionMessage({
    required this.transactionId,
    required this.beef,
    required this.fromCounterparty,
    this.targetWalletId,
    this.invoiceId,
    this.requestId,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  @override
  String get correlationId => 'receive-tx-${transactionId}-${fromCounterparty}';
  @override
  Map<String, dynamic> get metadata => {
    'counterparty': fromCounterparty,
    'walletId': targetWalletId,
    'invoiceId': invoiceId,
  };
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => receivedAt;
}


/// A transaction a received BEEF carried with a BUMP that verifies against
/// our active header chain (bead libspiffy-fggl).
///
/// A verified BUMP proves that transaction is mined, whatever position it
/// holds in the BEEF: the subject a counterparty is paying us with, or an
/// ancestor of it. When the wallet recorded the transaction itself (our own
/// outgoing payment, handed back to us inside a counterparty's BEEF) this is
/// the first hard evidence we get that it was mined, and it outranks any
/// status string a broadcaster reports.
class ProvenTransaction {
  /// Display-order txid.
  final String txid;

  /// Hex of the BRC-74 BUMP that proves it.
  final String bumpHex;

  /// The height of the block the BUMP names.
  final int blockHeight;

  /// The hash of the header at [blockHeight] on our active chain, whose
  /// merkle root the BUMP reproduces.
  final String blockHash;

  const ProvenTransaction({
    required this.txid,
    required this.bumpHex,
    required this.blockHeight,
    required this.blockHash,
  });

  @override
  String toString() => 'ProvenTransaction($txid at $blockHeight)';
}

/// SPV validation result after processing received transaction
class SPVValidationResult implements Message {
  final String txid;
  final bool isValid;
  final String? validationError;
  final List<Map<String, dynamic>> spendableUTXOs; // UTXOs we can now spend
  final List<Map<String, dynamic>> spentUTXOs; // UTXOs that were spent
  final String? targetWalletId;
  final BigInt? transactionFee; // Total transaction fee (only when spentUTXOs is not empty)
  final Map<String, dynamic>? transactionData; // Full transaction data for recording history

  /// Outputs of the transaction whose locking script could not be read (a
  /// script template or a plugin threw), so nobody could tell whether they
  /// are the wallet's (bead libspiffy-rp6x). One map per output: 'vout',
  /// 'satoshis', 'script' (hex), 'scriptType' (when something recognised
  /// the script before failing) and 'reason'. They are not credited; the
  /// transaction is still recorded whole, so they can be read again later.
  final List<Map<String, dynamic>> unreadableOutputs;

  /// Every transaction of the BEEF whose BUMP verifies against our active
  /// header chain, subject and ancestors alike (bead libspiffy-fggl). The
  /// ones the wallet recorded itself are confirmed from these proofs; a
  /// member whose block header we have not synced is not listed (its BUMP is
  /// still retained, stored as a pendingHeader proof).
  final List<ProvenTransaction> provenTransactions;

  /// The app's opaque marker for the counterparty that handed us this
  /// transaction (bead libspiffy-cq16), carried from
  /// [ReceiveTransactionMessage.fromCounterparty] so the wallet can journal
  /// it with the payment. Null when the app supplied none; never
  /// interpreted, validated or parsed.
  final String? counterpartyMarker;

  /// The [ReceiveTransactionMessage.requestId] of the receive this is the
  /// verdict on, echoed back unchanged (bead libspiffy-l8uf).
  ///
  /// It pairs a verdict with the request that asked for it, so a caller
  /// waiting for one does not have to match on the txid and take another
  /// receive's answer for the same transaction. Null for a receive that
  /// carried none, and for a verdict on a receive replayed from storage
  /// (a parked receive is stored with its BEEF, not with a caller's id).
  final String? requestId;

  SPVValidationResult({
    required this.txid,
    required this.isValid,
    this.validationError,
    this.spendableUTXOs = const [],
    this.spentUTXOs = const [],
    this.targetWalletId,
    this.transactionFee,
    this.transactionData,
    this.unreadableOutputs = const [],
    this.provenTransactions = const [],
    this.counterpartyMarker,
    this.requestId,
  });

  /// This result with [marker] as its [counterpartyMarker] (a blank marker
  /// is no marker) and [requestId] as its [requestId]. Applied in one place,
  /// where the receive answers, so every branch that builds a result carries
  /// both (beads libspiffy-cq16, libspiffy-l8uf).
  SPVValidationResult withCounterpartyMarker(String? marker, {String? requestId}) => SPVValidationResult(
        txid: txid,
        isValid: isValid,
        validationError: validationError,
        spendableUTXOs: spendableUTXOs,
        spentUTXOs: spentUTXOs,
        targetWalletId: targetWalletId,
        transactionFee: transactionFee,
        transactionData: transactionData,
        unreadableOutputs: unreadableOutputs,
        provenTransactions: provenTransactions,
        counterpartyMarker: (marker == null || marker.isEmpty) ? null : marker,
        requestId: requestId ?? this.requestId,
      );

  @override
  String get correlationId => 'spv-validation-$txid';
  @override
  Map<String, dynamic> get metadata => {
    'valid': isValid,
    'walletId': targetWalletId,
  };
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Asks a wallet which of [addresses] and [outpoints] are its own (bead
/// libspiffy-29t). Sent by SPVActor to WalletManagerActor, which hands it
/// to the wallet aggregate; the aggregate answers from its event-sourced
/// state with a [WalletOwnershipResponse].
///
/// The read model cannot answer this: the wallet projection lags the
/// wallet's journal, so a payment to a freshly created wallet or a receive
/// address generated moments earlier looked like nobody's. The aggregate
/// handles the query in its mailbox after every command it has already
/// acknowledged, so an address a caller was handed is always known.
class WalletOwnershipQuery implements Message {
  final String walletId;

  /// Candidate addresses (output addresses, multisig key addresses, plugin
  /// owner addresses).
  final Set<String> addresses;

  /// Candidate outpoints, as 'txid:vout' (the inputs of a transaction).
  final Set<String> outpoints;

  WalletOwnershipQuery({
    required this.walletId,
    required this.addresses,
    required this.outpoints,
  });

  @override
  String get correlationId => 'wallet-ownership-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// The answer to a [WalletOwnershipQuery].
class WalletOwnershipResponse extends LocalMessage {
  final String walletId;

  /// False when no such wallet exists (never created, or deleted); the
  /// owned sets are then empty and [error] says why.
  final bool walletFound;

  /// The queried addresses that are the wallet's: addresses it created,
  /// generated or discovered, and addresses it holds a UTXO at (the same
  /// addresses the read model's address rows are written from).
  final Set<String> ownedAddresses;

  /// The queried outpoints that are unspent UTXOs of the wallet (reserved
  /// or held ones included).
  final Set<String> unspentOutpoints;

  final String? error;

  WalletOwnershipResponse({
    required this.walletId,
    required this.walletFound,
    this.ownedAddresses = const {},
    this.unspentOutpoints = const {},
    this.error,
  }) : super(payload: null, metadata: {'walletId': walletId, 'walletFound': walletFound});

  /// This object, for dactor's ask().
  @override
  dynamic get payload => this;
}

/// Asks a wallet for its type and the UTXOs it can spend now (bead
/// libspiffy-ypp). Sent by BenfordCoordinatorActor to WalletManagerActor,
/// which hands it to the wallet aggregate; the aggregate answers from its
/// event-sourced state with a [WalletSpendableUtxosResponse], after every
/// command it has already acknowledged (the read model lags the journal, so
/// a wallet created or funded moments earlier looked unknown or empty).
class WalletSpendableUtxosQuery implements Message {
  final String walletId;

  WalletSpendableUtxosQuery({required this.walletId});

  @override
  String get correlationId => 'wallet-spendable-utxos-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// The answer to a [WalletSpendableUtxosQuery].
class WalletSpendableUtxosResponse extends LocalMessage {
  final String walletId;

  /// False when no such wallet exists (never created, or deleted); [error]
  /// says why.
  final bool walletFound;

  /// The wallet's type; null when [walletFound] is false.
  final WalletType? walletType;

  /// The wallet's available UTXOs it can sign for: not reserved, held,
  /// pending or spent, not plugin-managed, not watch-only (the UTXOs the
  /// aggregate itself would select), in state order.
  final List<BitcoinUtxo> spendable;

  /// Available UTXOs left out because they sit at watch addresses.
  final List<BitcoinUtxo> watchOnly;

  final String? error;

  WalletSpendableUtxosResponse({
    required this.walletId,
    required this.walletFound,
    this.walletType,
    this.spendable = const [],
    this.watchOnly = const [],
    this.error,
  }) : super(payload: null, metadata: {'walletId': walletId, 'walletFound': walletFound});

  /// This object, for dactor's ask().
  @override
  dynamic get payload => this;
}

/// Reply of the wallet aggregate to AddWatchAddressCommand (bead
/// libspiffy-p4kv).
class WatchAddressAddedResponse extends ActorResponse {
  final String walletId;
  final String address;
  @override
  final bool success;

  /// False when the address needed no event: already a watch address, or
  /// an address the wallet derived.
  final bool journaled;
  @override
  final String? error;

  WatchAddressAddedResponse({
    required this.walletId,
    required this.address,
    required this.success,
    this.journaled = false,
    this.error,
  }) : super(metadata: {'walletId': walletId, 'address': address, 'success': success});
}

/// Block header update from SpiffyNode
class BlockHeaderUpdateMessage implements Message {
  final dynamic blockHeader; // Will be SpiffyNode's BlockHeader type
  final int height;
  final bool isReorganization;
  final List<dynamic>? orphanedHeaders; // If reorg occurred

  BlockHeaderUpdateMessage({
    required this.blockHeader,
    required this.height,
    this.isReorganization = false,
    this.orphanedHeaders,
  });

  @override
  String get correlationId => 'block-header-update-$height';
  @override
  Map<String, dynamic> get metadata => {
    'height': height,
    'reorg': isReorganization,
  };
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Ask SPVActor to judge a transaction a counterparty handed us WITHOUT
/// receiving it (bead libspiffy-6e5).
///
/// Same checks as [ReceiveTransactionMessage] — every merkle proof in the
/// BEEF against our header chain, every input covered back to a proven
/// transaction, the input scripts — but nothing is credited to any wallet
/// and the WalletManager is never told: the verdict goes to the sender only,
/// as an [SPVValidationResult] with no target wallet.
///
/// This is what a validation that is not a receive needs: the server judging
/// the funding transaction of a channel a client asks it to open owns none
/// of its outputs, so a receive of it names no wallet, credits nobody, and
/// made the WalletManager log a rejected result on every channel open.
///
/// The evidence the BEEF carries is still retained exactly as a receive
/// retains it (transactions and proofs are filed), because nothing can hand
/// them to us again. What is not done is the receive: no wallet bookkeeping,
/// and no parked retry — a caller that asked a question gets an answer now.
class ValidateCounterpartyTransactionMessage implements Message {
  /// The transaction the verdict is about, in display (big-endian) form.
  final String transactionId;

  /// The BEEF carrying it and the ancestry its proofs rest on.
  final BEEF beef;

  /// Who handed it to us, for the log and for the result's marker.
  final String fromCounterparty;

  /// Caller's own id, echoed on the [SPVValidationResult].
  final String? requestId;

  final DateTime receivedAt;

  ValidateCounterpartyTransactionMessage({
    required this.transactionId,
    required this.beef,
    required this.fromCounterparty,
    this.requestId,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  @override
  String get correlationId => 'validate-tx-$transactionId-$fromCounterparty';
  @override
  Map<String, dynamic> get metadata => {
        'counterparty': fromCounterparty,
        'txid': transactionId,
      };
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => receivedAt;
}

/// Request BEEF validation (enhanced transaction format)
class ValidateBEEFMessage implements Message {
  final String beefData;
  final String? targetWalletId;

  /// Caller-chosen id echoed on the [BEEFValidationResult], so a caller with
  /// several validations in flight (for one wallet or many) can match each
  /// result to its request.
  final String? requestId;

  ValidateBEEFMessage(this.beefData, {this.targetWalletId, this.requestId});

  @override
  String get correlationId => 'validate-beef-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'walletId': targetWalletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// BEEF validation result
class BEEFValidationResult implements Message {
  final bool isValid;
  final String? merkleRoot;
  final String? error;
  final String? targetWalletId;
  final List<Map<String, dynamic>>? extractedTransactions;

  /// The [ValidateBEEFMessage.requestId] this result answers, if one was set.
  final String? requestId;

  BEEFValidationResult({
    required this.isValid,
    this.merkleRoot,
    this.error,
    this.targetWalletId,
    this.extractedTransactions,
    this.requestId,
  });

  @override
  String get correlationId => 'beef-result-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'walletId': targetWalletId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

// ==========================================================================
// ARC ACTOR MESSAGES - ENHANCED WITH PROOF RETRIEVAL
// ==========================================================================

/// Request to broadcast a transaction
class BroadcastTransactionMessage implements Message {
  final String walletId;
  final String txHex;
  final String txid;

  BroadcastTransactionMessage(this.walletId, this.txHex, this.txid);

  @override
  String get correlationId => 'broadcast-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Request to broadcast BEEF data
class BroadcastBEEFMessage implements Message {
  final String walletId;
  final String beefHex;
  final String txid;

  BroadcastBEEFMessage(this.walletId, this.beefHex, this.txid);

  @override
  String get correlationId => 'broadcast-beef-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Request merkle proof retrieval from ARC (NEW)
class RetrieveMerkleProofMessage implements Message {
  final String txid;
  final int? knownBlockHeight;
  final String walletId;

  RetrieveMerkleProofMessage({
    required this.txid,
    this.knownBlockHeight,
    required this.walletId,
  });

  @override
  String get correlationId => 'retrieve-proof-$txid';
  @override
  Map<String, dynamic> get metadata => {
    'txid': txid,
    'walletId': walletId,
    'blockHeight': knownBlockHeight,
  };
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Merkle proof retrieved from ARC (NEW)
class MerkleProofMessage extends ActorResponse {
  final String txid;
  final dynamic merkleProof; // Will be MerkleProof type
  @override
  final bool success;
  @override
  final String? error;

  MerkleProofMessage({
    required this.txid,
    this.merkleProof,
    required this.success,
    this.error,
  });

  @override
  String get correlationId => 'merkle-proof-$txid';
  @override
  Map<String, dynamic> get metadata => {'txid': txid, 'success': success};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Check transaction status
class CheckTransactionStatusMessage implements Message {
  final String txid;

  CheckTransactionStatusMessage(this.txid);

  @override
  String get correlationId => 'check-status-$txid';
  @override
  Map<String, dynamic> get metadata => {'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Transaction status response (ENHANCED)
class TransactionStatusMessage implements Message {
  final String txid;
  final String status; // 'pending', 'confirmed', 'failed'
  final int? confirmations;
  final int? blockHeight;
  final bool proofAvailable; // NEW: Can we get merkle proof now?

  TransactionStatusMessage({
    required this.txid,
    required this.status,
    this.confirmations,
    this.blockHeight,
    this.proofAvailable = false,
  });

  @override
  String get correlationId => 'tx-status-$txid';
  @override
  Map<String, dynamic> get metadata => {'txid': txid, 'status': status};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Request fee quote
class GetFeeQuoteMessage implements Message {
  @override
  String get correlationId => 'fee-quote-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Fee quote response
class FeeQuoteMessage implements Message {
  final Map<String, dynamic> feeData;

  FeeQuoteMessage(this.feeData);

  @override
  String get correlationId => 'fee-quote-response-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Estimate fee for transaction
class EstimateFeeMessage implements Message {
  final int inputCount;
  final int outputCount;

  EstimateFeeMessage(this.inputCount, this.outputCount);

  @override
  String get correlationId => 'estimate-fee-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Fee estimate response
class FeeEstimateMessage implements Message {
  final BigInt estimatedFee;

  FeeEstimateMessage(this.estimatedFee);

  @override
  String get correlationId => 'fee-estimate-response-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Broadcast success notification
class BroadcastSuccessMessage implements Message {
  final String txid;
  final String? networkTxid;

  BroadcastSuccessMessage(this.txid, this.networkTxid);

  @override
  String get correlationId => 'broadcast-success-$txid';
  @override
  Map<String, dynamic> get metadata => {'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Broadcast failure notification
class BroadcastFailedMessage implements Message {
  final String txid;
  final String error;

  BroadcastFailedMessage(this.txid, this.error);

  @override
  String get correlationId => 'broadcast-failed-$txid';
  @override
  Map<String, dynamic> get metadata => {'txid': txid};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Notification about blockchain reorganization
class BlockchainReorganizationNotification implements Message {
  final int orphanedHeaderCount;
  final int newHeight;

  BlockchainReorganizationNotification({
    required this.orphanedHeaderCount,
    required this.newHeight,
  });

  @override
  String get correlationId => 'blockchain-reorg-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {
    'orphanedHeaderCount': orphanedHeaderCount,
    'newHeight': newHeight,
  };
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
} 

/// Message to trigger checking all pending UTXOs from storage against Arc
/// 
/// Sent when new block headers are received to check if any pending UTXOs
/// have been mined and need merkle proofs fetched from Arc.
class CheckStoragePendingUTXOsMessage implements Message {
  /// Block height that triggered this check (informational)
  final int triggerBlockHeight;
  
  CheckStoragePendingUTXOsMessage({required this.triggerBlockHeight});

  @override
  String get correlationId => 'check-pending-utxos-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'triggerBlockHeight': triggerBlockHeight};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

// ==========================================================================
// HEADER CHAIN REORGANIZATION (3b0)
// ==========================================================================

/// Sent by HeaderSyncActor to SPVActor when accepting a batch of headers
/// moved the active chain to another branch.
///
/// SPVActor re-checks every confirmation that may rest on a block that
/// left the active chain and reverts those that no longer verify
/// (RevertTransactionConfirmationCommand), then tells ARCActor
/// ([TransactionConfirmationsRevertedMessage]) so the transactions are
/// polled again.
class HeaderChainReorganizedMessage implements Message {
  /// Height of the common ancestor (the lowest fork point of the batch).
  /// Blocks above it may have changed.
  final int forkHeight;

  /// Display hashes of the headers that left the active chain.
  final List<String> orphanedBlockHashes;

  /// Height of the active tip after the batch.
  final int newTipHeight;

  final DateTime _timestamp = DateTime.now();

  HeaderChainReorganizedMessage({
    required this.forkHeight,
    required this.orphanedBlockHashes,
    required this.newTipHeight,
  });

  @override
  String get correlationId => 'header-chain-reorg-$forkHeight-$newTipHeight';
  @override
  Map<String, dynamic> get metadata => {
        'forkHeight': forkHeight,
        'orphanedBlockHashes': orphanedBlockHashes,
        'newTipHeight': newTipHeight,
      };
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => _timestamp;
}

/// Sent by SPVActor to ARCActor after it reverted the confirmation of
/// [txids] (a reorganization orphaned their block, or a proof imported
/// before its header was known turned out not to match it).
///
/// ARCActor forgets any recent confirmation or held proof of these
/// transactions and schedules a status scan, so they are confirmed again
/// once ARC reports them mined on the active chain.
class TransactionConfirmationsRevertedMessage implements Message {
  final List<String> txids;

  final DateTime _timestamp = DateTime.now();

  TransactionConfirmationsRevertedMessage(this.txids);

  @override
  String get correlationId => 'confirmations-reverted-${_timestamp.microsecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'txids': txids};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => _timestamp;
}

// ==========================================================================
// DEFERRED PAYMENTS (bead libspiffy-7p2)
// ==========================================================================

/// Reply of the wallet aggregate to [CancelDeferredSpendCommand].
class DeferredSpendCancelledResponse extends ActorResponse {
  final String walletId;
  final String txid;
  @override
  final bool success;
  @override
  final String? error;

  /// The inputs returned to their pre-reservation status.
  final List<String> releasedUtxoKeys;

  DeferredSpendCancelledResponse({
    required this.walletId,
    required this.txid,
    required this.success,
    this.error,
    this.releasedUtxoKeys = const [],
  }) : super(metadata: {'walletId': walletId, 'txid': txid, 'success': success});

  @override
  String toString() => 'DeferredSpendCancelledResponse($walletId, $txid, success: $success'
      '${error != null ? ', error: $error' : ''})';
}

/// Asks ARCActor to query the network status of the deferred payment [txid]
/// now, instead of waiting for the periodic scan. The wallet is updated as
/// for a scan result (spend applied on SEEN_ON_NETWORK / MINED, a MINED
/// merkle proof checked against the local headers before confirming, the
/// payment failed on REJECTED; DOUBLE_SPEND_ATTEMPTED keeps it outstanding),
/// and the status is journaled. Replied with [DeferredPaymentNetworkResult].
class CheckDeferredPaymentStatusMessage implements Message {
  final String walletId;
  final String txid;
  final DeferredPaymentNetworkSource via;

  CheckDeferredPaymentStatusMessage({
    required this.walletId,
    required this.txid,
    this.via = DeferredPaymentNetworkSource.arc,
  });

  @override
  String get correlationId => 'check-deferred-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid, 'via': via.name};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Asks ARCActor to broadcast the deferred payment [txid] itself: the
/// unproven transactions of [beefHex] (its unconfirmed ancestors) first,
/// then [rawTxHex]. Idempotent. Replied with [DeferredPaymentNetworkResult].
class BroadcastDeferredPaymentMessage implements Message {
  final String walletId;
  final String txid;
  final String rawTxHex;
  final String? beefHex;
  final DeferredPaymentNetworkSource via;

  BroadcastDeferredPaymentMessage({
    required this.walletId,
    required this.txid,
    required this.rawTxHex,
    this.beefHex,
    this.via = DeferredPaymentNetworkSource.arc,
  });

  @override
  String get correlationId => 'broadcast-deferred-$txid';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'txid': txid, 'via': via.name};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// What ARCActor learned from a [CheckDeferredPaymentStatusMessage] or a
/// [BroadcastDeferredPaymentMessage].
class DeferredPaymentNetworkResult extends ActorResponse {
  final String walletId;
  final String txid;

  /// A source answered (a status, or a definitive "not found"). False when
  /// every source failed ([error]).
  @override
  final bool success;

  /// ARC's wire status, `NOT_FOUND`, or null when no source answered.
  final String? networkStatus;

  /// `arc` or `dataSource`.
  final String? source;
  final int? blockHeight;

  /// Result of checking a MINED merkle proof against the local headers:
  /// `verified`, `headerUnknown`, `rootMismatch`, `malformed`, or null when
  /// there was no proof to check.
  final String? proofStatus;

  /// A confirmation was issued: the proof walked to the stored header.
  final bool confirmed;

  /// The failed broadcast was queued for a durable retry.
  final bool willRetry;
  @override
  final String? error;

  /// The competing transactions ARC named with [networkStatus]
  /// (DOUBLE_SPEND_ATTEMPTED; bead libspiffy-pkum).
  final List<String> competingTxids;

  DeferredPaymentNetworkResult({
    required this.walletId,
    required this.txid,
    required this.success,
    this.networkStatus,
    this.source,
    this.blockHeight,
    this.proofStatus,
    this.confirmed = false,
    this.willRetry = false,
    this.error,
    this.competingTxids = const [],
  }) : super(metadata: {'walletId': walletId, 'txid': txid, 'success': success});

  @override
  String toString() => 'DeferredPaymentNetworkResult($txid, success: $success, status: $networkStatus, '
      'source: $source, proof: $proofStatus, confirmed: $confirmed${error != null ? ', error: $error' : ''})';
}

/// Reply to a `ReclaimDeferredSpendCommand` (bead libspiffy-87a): the
/// wallet journaled the self-spend, moved the hold on the reclaimed
/// payment's inputs to it, and journaled the reclaim.
///
/// The reclaimed payment is not resolved yet; it becomes
/// `DeferredPaymentState.reclaimed` once the network has the self-spend.
class DeferredSpendReclaimedResponse extends ActorResponse {
  final String walletId;

  /// The deferred payment being reclaimed.
  final String txid;

  /// The wallet's self-spend of its held inputs.
  final String reclaimTxid;
  @override
  final bool success;
  @override
  final String? error;

  /// The inputs the self-spend took over and spends.
  final List<String> reclaimedUtxoKeys;

  DeferredSpendReclaimedResponse({
    required this.walletId,
    required this.txid,
    required this.reclaimTxid,
    required this.success,
    this.error,
    this.reclaimedUtxoKeys = const [],
  }) : super(metadata: {'walletId': walletId, 'txid': txid, 'reclaimTxid': reclaimTxid, 'success': success});

  @override
  String toString() => 'DeferredSpendReclaimedResponse($walletId, $txid -> $reclaimTxid, success: $success'
      '${error != null ? ', error: $error' : ''})';
}

/// Asks ARCActor for the standard policy fee of a transaction with
/// [inputCount] P2PKH inputs and [outputCount] P2PKH outputs, from ARC's
/// published policy (`GET /v1/policy`, its `miningFee`). Replied with
/// [PolicyFeeQuote].
///
/// The one fee a transaction the wallet builds pays. This is Bitcoin SV:
/// there is no replace-by-fee, so paying above the policy buys nothing —
/// of two spends of one input the one that reached the network first is the
/// one that is mined. Unlike [EstimateFeeMessage] it does not fall back to a
/// guessed rate: a policy ARC could not be asked for is an error, and the
/// caller decides what to do rather than building a transaction at a fee
/// nobody quoted.
class EstimatePolicyFeeMessage implements Message {
  final int inputCount;
  final int outputCount;

  /// Extra bytes beyond the P2PKH inputs and outputs (OP_RETURN data, ...).
  final int dataSize;

  EstimatePolicyFeeMessage({required this.inputCount, required this.outputCount, this.dataSize = 0});

  @override
  String get correlationId => 'policy-fee-$inputCount-$outputCount-${DateTime.now().microsecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'inputCount': inputCount, 'outputCount': outputCount};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Reply to [EstimatePolicyFeeMessage]: ARC's policy fee for the transaction
/// size asked about.
class PolicyFeeQuote extends ActorResponse {
  /// The fee in satoshis, rounded up; zero when [success] is false.
  final BigInt fee;

  /// The size the fee was quoted for.
  final int sizeBytes;

  /// ARC's published `miningFee`: [feeSatoshis] per [feeBytes].
  final int feeSatoshis;
  final int feeBytes;
  @override
  final bool success;
  @override
  final String? error;

  PolicyFeeQuote({
    required this.fee,
    required this.sizeBytes,
    required this.success,
    this.feeSatoshis = 0,
    this.feeBytes = 0,
    this.error,
  }) : super(metadata: {'fee': fee.toString(), 'sizeBytes': sizeBytes, 'success': success});

  @override
  String toString() => 'PolicyFeeQuote($fee sat for $sizeBytes bytes at $feeSatoshis/$feeBytes, '
      'success: $success${error != null ? ', error: $error' : ''})';
}
