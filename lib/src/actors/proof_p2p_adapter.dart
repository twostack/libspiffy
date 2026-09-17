import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:logging/logging.dart';

import '../services/ancestor_chain_service.dart';
import '../storage/read_model_storage.dart';
import '../utils/beef.dart';
import '../utils/unique_id.dart';
import 'coordinator_messages.dart';
import 'wallet_messages.dart' as wm;

final _log = Logger('ProofP2PAdapter');

/// Asks a counterparty for a fresh merkle proof, and answers when one asks us
/// (bead libspiffy-a2v3).
///
/// ## Why
///
/// A reorganization can take an ancestor's block off the active chain. The
/// proof row is kept (a reorganization can put the block back) but no longer
/// counts, so the walk back from a received transaction runs off the end of
/// what we store: the outputs it gave us cannot go into a BEEF and cannot be
/// spent. [ReadModelStorage.getOutputsAwaitingAncestorProof] lists them.
///
/// There are exactly two recoveries and neither is a lookup service. The
/// block comes back, or **the counterparty who handed us the payment supplies
/// a fresh BEEF with a fresh BUMP**. This adapter is the second. There is no
/// block scanning and no address monitoring (spv-understanding.md, Critical
/// Implementation Note 2), and ARC is not asked: an ARC instance answers for
/// what was submitted through it and nothing else, so it has no standing to
/// prove a counterparty's transaction and a NOT_FOUND from it means nothing.
///
/// ## Who is asked
///
/// The counterparty of the transaction *we received*, named by
/// `BitcoinTransaction.counterpartyMarker` on its row (bead libspiffy-cq16) —
/// **not** the orphaned ancestor's counterparty, who is almost always a
/// stranger we never dealt with and have no marker for. The sender of a
/// payment owes us the proofs its ancestry needs; they handed us a BEEF that
/// has since become incomplete, and they are the ones who can complete it.
///
/// ## Transport
///
/// libspiffy owns no transport, exactly as with payment channels
/// ([ChannelP2PAdapter]). Outbound messages are emitted as
/// [P2PMessageToSendEvent]s for the app to deliver; inbound ones arrive as
/// [P2PMessageReceived] (or [ChannelP2PReceived], its channel-named
/// equivalent) and the coordinator routes them here by message type. No
/// socket, no HTTP client, no peer address book.
///
/// ## Identity
///
/// `fromPeerId` and the counterparty marker are both opaque strings the app
/// chooses; this adapter compares them with `==` and gives them no meaning of
/// its own. An app whose peer ids and markers come from the same identity
/// scheme (an Ed25519 key, an account id, a peer id) gets an enforced check
/// out of it; an app that mixes schemes gets a refusal, which is the safe
/// direction.
class ProofP2PAdapter {
  /// Message type of a request for a fresh proof.
  static const String proofRequestType = 'proof_request';

  /// Message type of the answer to one.
  static const String proofResponseType = 'proof_response';

  /// Whether [messageType] belongs to this protocol.
  static bool handles(String messageType) =>
      messageType == proofRequestType || messageType == proofResponseType;

  /// What a refused request says on the wire.
  ///
  /// One sentence for every refusal — unknown transaction, no marker, wrong
  /// requester, nothing we can prove — so a peer cannot learn which
  /// transactions we know by asking. The real reason is emitted locally as
  /// [AncestorProofRequestReceivedEvent.reason].
  static const String refusalOnTheWire = 'no proof available for this transaction';

  final ReadModelStorage _storage;
  final ActorRef _spvActor;
  final void Function(CoordinatorEvent) _emitEvent;
  final AncestorChainService _chains;

  /// How long to wait for the receive path's verdict on a response.
  final Duration _receiveTimeout;

  /// Requests we sent and have not had an answer to, by request id.
  final Map<String, _PendingProofRequest> _pending = {};

  /// Where SPVActor is told to send its verdict: the coordinator, which hands
  /// it back through [handleReceiveResult]. SPVActor's reply is not a dactor
  /// `LocalMessage`, so it cannot be `ask`ed for.
  ActorRef? _replyTo;

  /// Response BEEFs handed to the receive path whose verdict has not come
  /// back yet, FIFO per txid.
  final Map<String, List<Completer<wm.SPVValidationResult>>> _awaitingVerdict = {};

  ProofP2PAdapter({
    required ReadModelStorage storage,
    required ActorRef spvActor,
    required void Function(CoordinatorEvent) emitEvent,
    Duration receiveTimeout = const Duration(seconds: 60),
  })  : _storage = storage,
        _spvActor = spvActor,
        _emitEvent = emitEvent,
        _receiveTimeout = receiveTimeout,
        _chains = AncestorChainService(storage: storage);

  /// The actor SPVActor should reply to (the coordinator). Set once the
  /// coordinator has a context; the adapter is built in its constructor.
  void updateReplyTo(ActorRef replyTo) => _replyTo = replyTo;

  /// Take the receive path's verdict on a BEEF this adapter delivered.
  ///
  /// Returns true when it answered one of ours. The coordinator passes every
  /// [wm.SPVValidationResult] through here; results for receives this adapter
  /// did not start are left alone.
  bool handleReceiveResult(wm.SPVValidationResult result) {
    final queue = _awaitingVerdict[result.txid];
    if (queue == null || queue.isEmpty) return false;
    final waiter = queue.removeAt(0);
    if (queue.isEmpty) _awaitingVerdict.remove(result.txid);
    if (!waiter.isCompleted) waiter.complete(result);
    return true;
  }

  /// Put [message] through the ordinary receive path and wait for its verdict.
  Future<wm.SPVValidationResult> _receive(wm.ReceiveTransactionMessage message) {
    final waiter = Completer<wm.SPVValidationResult>();
    (_awaitingVerdict[message.transactionId] ??= []).add(waiter);
    _spvActor.tell(message, sender: _replyTo);
    return waiter.future.timeout(_receiveTimeout, onTimeout: () {
      _awaitingVerdict[message.transactionId]?.remove(waiter);
      throw TimeoutException(
          'the receive path did not answer for ${message.transactionId}', _receiveTimeout);
    });
  }

  // ==========================================================================
  // Requester
  // ==========================================================================

  /// Ask [RequestAncestorProofCommand.txid]'s counterparty for a fresh proof.
  ///
  /// App-triggered, one request per call: nothing here retries or polls, so a
  /// peer is never pestered by the library.
  Future<void> handleRequestProof(RequestAncestorProofCommand cmd) async {
    final requestId = cmd.requestId ?? uniqueId('proof-req');
    try {
      final tx = await _storage.getTransaction(cmd.txid, walletId: cmd.walletId);
      if (tx == null) {
        _emitEvent(AncestorProofRequestedEvent(
          walletId: cmd.walletId,
          txid: cmd.txid,
          requestId: requestId,
          success: false,
          error: 'no transaction ${cmd.txid} is stored for wallet ${cmd.walletId}',
        ));
        return;
      }

      // Who handed us this payment. Null on rows written before markers
      // existed, and on payments an app recorded without one: then there is
      // nobody to ask, and only the block returning can restore the output.
      final marker = tx.counterpartyMarker;
      if (marker == null || marker.isEmpty) {
        _emitEvent(AncestorProofRequestedEvent(
          walletId: cmd.walletId,
          txid: cmd.txid,
          requestId: requestId,
          success: false,
          error: 'no counterparty marker is recorded for ${cmd.txid}, so there is nobody to ask for a '
              'fresh proof: this output is unrecoverable by request and can only be restored by its '
              "ancestor's block returning to the active chain",
        ));
        return;
      }

      final ancestors = cmd.ancestorTxids.isNotEmpty
          ? cmd.ancestorTxids
          : await _awaitedAncestorsOf(cmd.walletId, cmd.txid);

      _pending[requestId] = _PendingProofRequest(
        walletId: cmd.walletId,
        txid: cmd.txid,
        peerId: marker,
      );

      _emitEvent(P2PMessageToSendEvent(
        toPeerId: marker,
        messageType: proofRequestType,
        payload: {
          'requestId': requestId,
          'txid': cmd.txid,
          'ancestors': ancestors,
        },
      ));
      _emitEvent(AncestorProofRequestedEvent(
        walletId: cmd.walletId,
        txid: cmd.txid,
        requestId: requestId,
        toPeerId: marker,
        ancestorTxids: ancestors,
        success: true,
      ));
    } catch (e, st) {
      _log.warning('Proof request for ${cmd.txid} failed: $e', e, st);
      _pending.remove(requestId);
      _emitEvent(AncestorProofRequestedEvent(
        walletId: cmd.walletId,
        txid: cmd.txid,
        requestId: requestId,
        success: false,
        error: e.toString(),
      ));
    }
  }

  /// The ancestors [txid]'s unspent outputs are waiting on, for the request's
  /// payload. Informational: the responder rebuilds the whole BEEF anyway.
  Future<List<String>> _awaitedAncestorsOf(String walletId, String txid) async {
    final awaiting = await _storage.getOutputsAwaitingAncestorProof(walletId);
    final ancestors = <String>[];
    for (final output in awaiting) {
      if (output.txid != txid) continue;
      for (final ancestor in output.ancestors) {
        if (!ancestors.contains(ancestor.txid)) ancestors.add(ancestor.txid);
      }
    }
    return ancestors;
  }

  // ==========================================================================
  // Inbound
  // ==========================================================================

  /// Handle a `proof_request` or `proof_response` the app delivered.
  Future<void> handleP2PMessage(
      String fromPeerId, String messageType, Map<String, dynamic> payload) async {
    switch (messageType) {
      case proofRequestType:
        await _handleProofRequest(fromPeerId, payload);
      case proofResponseType:
        await _handleProofResponse(fromPeerId, payload);
      default:
        _log.warning('Not a proof protocol message: $messageType');
    }
  }

  // ==========================================================================
  // Responder
  // ==========================================================================

  /// Answer a peer asking for a fresh proof of a transaction we sent them.
  ///
  /// Only the counterparty recorded on that transaction is answered. A
  /// responder that answered anyone would tell any peer that asks which
  /// transactions it knows.
  Future<void> _handleProofRequest(String fromPeerId, Map<String, dynamic> payload) async {
    final requestId = payload['requestId'] as String?;
    final txid = payload['txid'];
    if (txid is! String || txid.isEmpty) {
      _log.warning('proof_request from $fromPeerId names no transaction');
      return;
    }
    if (fromPeerId.isEmpty) {
      _log.warning('proof_request for $txid from an unnamed peer: nothing can be matched to a marker');
      return;
    }

    String? refuse;
    String? beefHex;
    try {
      // Every wallet's row for the transaction, not the first-stored one: a
      // transaction two of our wallets hold has a counterparty per wallet,
      // and any of them naming the requester entitles them to the answer.
      final rows = await _storage.getTransactionsByTxids([txid]);
      // Only rows that actually name a counterparty can match. An absent
      // marker is not an identity: without this, a peer sending no identity
      // would match a row that records none, and two absences are not a
      // match. The unnamed-peer guard above already refuses that case; this
      // keeps the rule true here too, where the disclosure decision is made.
      final markers = [
        for (final row in rows)
          if ((row.counterpartyMarker ?? '').isNotEmpty) row.counterpartyMarker!
      ];
      if (rows.isEmpty) {
        refuse = 'no transaction $txid is stored';
      } else if (markers.isEmpty) {
        refuse = 'transaction $txid records no counterparty marker, so there is no one it may be '
            'disclosed to';
      } else if (!markers.contains(fromPeerId)) {
        // Opaque string equality: the marker is the app's own identity
        // scheme and libspiffy gives it no meaning beyond this comparison.
        refuse = 'the requester is not the counterparty recorded for $txid';
      } else {
        // A BEEF built from our *current* proofs and headers: the ancestor
        // walk skips an orphaned or rejected row, so what goes back carries
        // whatever proves the ancestry on the chain we are on now.
        final chain = await _chains.collectAncestorChainForUtxos([txid]);
        if (!chain.isValid) {
          refuse = 'we cannot prove $txid ourselves either: ${chain.error}';
        } else {
          beefHex = hex.encode(AncestorChainService.buildBeef(
            chain.ancestorTransactions,
            const [],
            chain.merkleProofs,
          ).serialize());
        }
      }
    } catch (e, st) {
      _log.warning('Answering a proof_request for $txid failed: $e', e, st);
      refuse = 'building a fresh BEEF for $txid failed: $e';
    }

    _emitEvent(P2PMessageToSendEvent(
      toPeerId: fromPeerId,
      messageType: proofResponseType,
      payload: {
        if (requestId != null) 'requestId': requestId,
        'txid': txid,
        if (refuse == null) 'beefHex': beefHex! else 'error': refusalOnTheWire,
      },
    ));
    _emitEvent(AncestorProofRequestReceivedEvent(
      fromPeerId: fromPeerId,
      txid: txid,
      requestId: requestId,
      answered: refuse == null,
      reason: refuse,
    ));
  }

  // ==========================================================================
  // Requester, second half
  // ==========================================================================

  /// Take in a counterparty's answer.
  ///
  /// The BEEF goes through the ordinary receive path (SPVActor), so it is
  /// verified against our own header chain like every other incoming proof,
  /// a verified proof supersedes the orphaned row through
  /// `planMerkleProofStore`, and a proof that does not verify is rejected —
  /// the output stays awaiting — while the BEEF is still retained as
  /// evidence of what a counterparty handed us (bead libspiffy-b81q).
  /// Nothing here writes a proof of its own and nothing is deleted.
  Future<void> _handleProofResponse(String fromPeerId, Map<String, dynamic> payload) async {
    final requestId = payload['requestId'] as String?;
    final txid = payload['txid'];
    if (txid is! String || txid.isEmpty) {
      _log.warning('proof_response from $fromPeerId names no transaction');
      return;
    }
    final pending = requestId == null ? null : _pending.remove(requestId);

    void fail(String error, {String? walletId}) => _emitEvent(AncestorProofResponseEvent(
          walletId: walletId ?? pending?.walletId,
          txid: txid,
          fromPeerId: fromPeerId,
          requestId: requestId,
          success: false,
          error: error,
        ));

    final refused = payload['error'];
    if (refused is String) {
      fail('the counterparty refused: $refused');
      return;
    }

    try {
      // We take a proof for a transaction only from the counterparty we
      // recorded for it — the same rule as the responder's, from the other
      // side, so an unsolicited BEEF from a stranger never reaches the
      // receive path on the strength of having been asked for. The wallet
      // the proof is credited to is the one whose row names the sender, not
      // whichever wallet happens to have stored the txid first.
      final rows = await _storage.getTransactionsByTxids([txid]);
      if (rows.isEmpty) {
        fail('no transaction $txid is stored, so nobody was asked for a proof of it');
        return;
      }
      final mine = [
        for (final row in rows)
          if (fromPeerId.isNotEmpty && row.counterpartyMarker == fromPeerId) row
      ];
      if (mine.isEmpty) {
        fail('$fromPeerId is not the counterparty recorded for $txid', walletId: rows.first.walletId);
        return;
      }
      final walletId = mine.first.walletId ?? pending?.walletId;

      final beefHex = payload['beefHex'];
      if (beefHex is! String || beefHex.isEmpty) {
        fail('the response carries no BEEF', walletId: walletId);
        return;
      }
      final BEEF beef;
      try {
        beef = BEEF.parse(Uint8List.fromList(hex.decode(beefHex)));
      } catch (e) {
        fail('the response BEEF does not parse: $e', walletId: walletId);
        return;
      }

      final result = await _receive(wm.ReceiveTransactionMessage(
        transactionId: txid,
        beef: beef,
        fromCounterparty: fromPeerId,
        targetWalletId: walletId,
        receivedAt: DateTime.now(),
      ));
      _emitEvent(AncestorProofResponseEvent(
        walletId: walletId,
        txid: txid,
        fromPeerId: fromPeerId,
        requestId: requestId,
        success: result.isValid,
        error: result.isValid ? null : result.validationError,
      ));
    } catch (e, st) {
      _log.warning('Taking in a proof_response for $txid failed: $e', e, st);
      fail(e.toString());
    }
  }

  /// Forget in-flight requests (the coordinator is stopping).
  void dispose() {
    _pending.clear();
    for (final queue in _awaitingVerdict.values) {
      for (final waiter in queue) {
        if (!waiter.isCompleted) {
          waiter.completeError(StateError('the coordinator stopped before the receive path answered'));
        }
      }
    }
    _awaitingVerdict.clear();
  }
}

/// A request we sent and have not had an answer to.
class _PendingProofRequest {
  final String walletId;
  final String txid;
  final String peerId;

  const _PendingProofRequest({
    required this.walletId,
    required this.txid,
    required this.peerId,
  });
}
