/// Bead libspiffy-l8uf: a proof response's verdict is paired with the request
/// that asked for it, not with the txid.
///
/// SPVActor's reply is not a dactor `LocalMessage`, so `ActorRef.ask` cannot
/// be used for it: [ProofP2PAdapter] tells the receive with the coordinator as
/// sender and the coordinator hands every [SPVValidationResult] back through
/// `handleReceiveResult`. That used to be matched FIFO per txid, so an
/// ordinary receive and a `proof_response` for the SAME
/// transaction in flight at the same moment could take each other's verdict.
/// A correlation id on the receive, echoed on the result, makes the pairing
/// structural.
library;

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/coordinator.dart' as coord;
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/proof_p2p_adapter.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart' as wm;
import 'package:libspiffy/src/utils/beef.dart';
import 'package:test/test.dart';

/// Records the receives told to it; answers nothing by itself, so the test
/// decides which verdict comes back when.
class _RecordingSpvActor implements ActorRef {
  final List<wm.ReceiveTransactionMessage> received = [];

  @override
  void tell(dynamic message, {ActorRef? sender}) {
    if (message is wm.ReceiveTransactionMessage) received.add(message);
  }

  @override
  Future<T> ask<T>(dynamic message, [Duration? timeout]) async => throw UnimplementedError();
  @override
  String get path => 'recording-spv';
  @override
  String get id => 'recording-spv';
  @override
  noSuchMethod(Invocation invocation) => null;
}

BitcoinTransaction _row(String walletId, String txid, String marker) => BitcoinTransaction(
      walletId: walletId,
      txid: txid,
      rawHex: '0100000000',
      status: TransactionStatus.pending,
      inputValue: BigInt.from(2000),
      outputValue: BigInt.from(1000),
      fee: BigInt.from(1000),
      receivingAddresses: const [],
      sendingAddresses: const [],
      netAmount: BigInt.from(1000),
      createdAt: DateTime.utc(2026, 9, 17),
      updatedAt: DateTime.utc(2026, 9, 17),
      lockTime: 0,
      version: 1,
      counterpartyMarker: marker,
    );

/// A BEEF carrying one unproven transaction: enough to reach the receive path.
String _beefHex() {
  final tx = dartsv.Transaction()
    ..addInput(dartsv.TransactionInput('11' * 32, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER))
    ..addOutput(dartsv.TransactionOutput(
        BigInt.from(1000), dartsv.SVScript.fromHex('76a914${'00' * 20}88ac')));
  final beef = BEEF.create(
    bumps: const [],
    txs: [Uint8List.fromList(hex.decode(tx.serialize()))],
    hasMerkle: const [false],
    bumpIndex: const [],
  );
  return hex.encode(beef.serialize());
}

/// The verdict SPVActor would answer [msg] with: the correlation id echoed
/// back, exactly as `SPVActor._runReceive` does it.
wm.SPVValidationResult _verdictFor(wm.ReceiveTransactionMessage msg,
        {required bool valid, String? error}) =>
    wm.SPVValidationResult(txid: msg.transactionId, isValid: valid, validationError: error)
        .answering(msg.fromCounterparty, requestId: msg.requestId);

void main() {
  test('l8uf: a receive and a proof response for the same txid in flight together each get their own '
      'verdict', () async {
    final storage = InMemoryWalletStorage();
    final txid = 'aa' * 32;
    await storage.storeTransaction('w1', _row('w1', txid, 'bob'));

    final spv = _RecordingSpvActor();
    final emitted = <coord.CoordinatorEvent>[];
    final adapter = ProofP2PAdapter(
      storage: storage,
      spvActor: spv,
      emitEvent: emitted.add,
      receiveTimeout: const Duration(seconds: 5),
    );

    // Bob answers our request for a fresh proof; the adapter puts the BEEF
    // through the ordinary receive path and waits for the verdict on it.
    final handled = adapter.handleP2PMessage('bob', ProofP2PAdapter.proofResponseType, {
      'requestId': 'req-1',
      'txid': txid,
      'beefHex': _beefHex(),
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(spv.received, hasLength(1), reason: 'the response BEEF went through the receive path');
    final ours = spv.received.single;
    expect(ours.requestId, isNotNull, reason: 'the receive carries our own correlation id');

    // An ordinary receive of the SAME transaction answers
    // first, with a different verdict. It is not ours, and taking it would
    // report somebody else's outcome as the counterparty's answer.
    final somebodyElses = wm.SPVValidationResult(
      txid: txid,
      isValid: false,
      validationError: 'another receive of the same transaction failed',
    );
    expect(adapter.handleReceiveResult(somebodyElses), isFalse,
        reason: 'a verdict this adapter did not ask for is left to whoever did');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(emitted.whereType<coord.AncestorProofResponseEvent>(), isEmpty,
        reason: 'our request has not been answered yet');

    // Now our own verdict comes back.
    expect(adapter.handleReceiveResult(_verdictFor(ours, valid: true)), isTrue);
    await handled;

    final answer = emitted.whereType<coord.AncestorProofResponseEvent>().single;
    expect((answer.txid, answer.requestId, answer.success, answer.error), (txid, 'req-1', true, null),
        reason: "the adapter reports its own verdict, not the other receive's");
  });

  test('l8uf: the adapter reports its own failed verdict, not one that arrived for the same txid',
      () async {
    final storage = InMemoryWalletStorage();
    final txid = 'bb' * 32;
    await storage.storeTransaction('w1', _row('w1', txid, 'bob'));

    final spv = _RecordingSpvActor();
    final emitted = <coord.CoordinatorEvent>[];
    final adapter = ProofP2PAdapter(
      storage: storage,
      spvActor: spv,
      emitEvent: emitted.add,
      receiveTimeout: const Duration(seconds: 5),
    );

    final handled = adapter.handleP2PMessage('bob', ProofP2PAdapter.proofResponseType, {
      'requestId': 'req-2',
      'txid': txid,
      'beefHex': _beefHex(),
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final ours = spv.received.single;

    // Somebody else's receive of the same transaction succeeded; ours did not.
    expect(adapter.handleReceiveResult(wm.SPVValidationResult(txid: txid, isValid: true)), isFalse);
    expect(
        adapter.handleReceiveResult(
            _verdictFor(ours, valid: false, error: "the counterparty's BUMP does not verify")),
        isTrue);
    await handled;

    final answer = emitted.whereType<coord.AncestorProofResponseEvent>().single;
    expect((answer.success, answer.error), (false, "the counterparty's BUMP does not verify"),
        reason: 'the output stays awaiting a proof; a stranger verdict must not clear it');
  });
}
