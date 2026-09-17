/// A `proof_request` carrying no identity must be refused (bead libspiffy-a2v3).
///
/// The responder matches the requester against the counterparty markers on
/// every one of our rows for the transaction. A wallet that holds a row with
/// no marker — a payment recorded before libspiffy-cq16, or one the app gave
/// no identity — must not make that transaction answerable to a peer who
/// sends no identity either: two absences are not a match.
library;

import 'package:dactor/dactor.dart';
import 'package:libspiffy/coordinator.dart' as coord;
import 'package:libspiffy/libspiffy.dart';
import 'package:libspiffy/src/actors/proof_p2p_adapter.dart';
import 'package:test/test.dart';

class _SilentActor implements ActorRef {
  @override
  void tell(dynamic message, {ActorRef? sender}) {}
  @override
  Future<T> ask<T>(dynamic message, [Duration? timeout]) async => throw UnimplementedError();
  @override
  String get path => 'silent';
  @override
  String get id => 'silent';
  @override
  noSuchMethod(Invocation invocation) => null;
}

BitcoinTransaction _row(String walletId, String txid, String? marker) => BitcoinTransaction(
      walletId: walletId,
      txid: txid,
      rawHex: '0100000000',
      status: TransactionStatus.confirmed,
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

void main() {
  test('a proof request with no identity is refused, even when another wallet\'s row has no marker',
      () async {
    final storage = InMemoryWalletStorage();
    final txid = 'aa' * 32;
    // Two of our wallets hold the same transaction: one recorded who it was
    // with, the other did not.
    await storage.storeTransaction('wallet-with', _row('wallet-with', txid, 'peer-b'));
    await storage.storeTransaction('wallet-without', _row('wallet-without', txid, null));

    final sent = <coord.CoordinatorEvent>[];
    final adapter = ProofP2PAdapter(
      storage: storage,
      spvActor: _SilentActor(),
      emitEvent: sent.add,
    );

    // An anonymous peer asks for the proof.
    adapter.handleP2PMessage('', 'proof_request', {'requestId': 'r1', 'txid': txid});
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // Two protections must each hold on their own: the unnamed-peer guard
    // refuses the request outright, and the marker comparison treats an
    // absent marker as no identity rather than something an empty peer id
    // can match. Removing either one alone must fail this test, so neither
    // is left resting on the other.
    expect(sent, isEmpty,
        reason: 'a request from a peer that names no identity must not be processed at all');
    final handedOut = [
      for (final e in sent.whereType<coord.P2PMessageToSendEvent>())
        if (e.payload.containsKey('beefHex')) e
    ];
    expect(handedOut, isEmpty,
        reason: 'an anonymous requester must not be handed a BEEF: an empty peer id matching an '
            'empty marker is two absences, not a match');
  });

  test('a request naming a peer no row records is refused, and the refusal tells them nothing',
      () async {
    final storage = InMemoryWalletStorage();
    final txid = 'bb' * 32;
    await storage.storeTransaction('wallet-with', _row('wallet-with', txid, 'peer-b'));
    await storage.storeTransaction('wallet-without', _row('wallet-without', txid, null));

    final sent = <coord.CoordinatorEvent>[];
    final adapter = ProofP2PAdapter(
      storage: storage,
      spvActor: _SilentActor(),
      emitEvent: sent.add,
    );

    adapter.handleP2PMessage('peer-stranger', 'proof_request', {'requestId': 'r2', 'txid': txid});
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final replies = sent.whereType<coord.P2PMessageToSendEvent>().toList();
    expect(replies, hasLength(1), reason: 'a named peer gets an answer');
    expect(replies.single.payload.containsKey('beefHex'), isFalse,
        reason: 'a stranger must not be handed a BEEF');
    expect(replies.single.payload['error'], ProofP2PAdapter.refusalOnTheWire,
        reason: 'every refusal reads the same on the wire, so a peer cannot map out which '
            'transactions this wallet knows');
  });
}
