import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/transaction_address_link.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/projections/wallet_projection.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

/// Bead libspiffy-o9h6 (sweep D-3): the transaction-address junctions that
/// back [ReadModelStorage.getTransactionAddresses].
///
/// Testnet throughout: ScriptTypeRegistry is a process-wide singleton and
/// defaults to TEST, so this file never pins it to mainnet.
const _walletId = 'junction-projection-wallet';

/// Distinct P2PKH destinations. The registry is testnet, so the addresses
/// these hashes produce are testnet addresses.
const _ourHash = '1111111111111111111111111111111111111111';
const _changeHash = '2222222222222222222222222222222222222222';
const _recipientHash = '3333333333333333333333333333333333333333';
const _senderAHash = '4444444444444444444444444444444444444444';
const _senderBHash = '5555555555555555555555555555555555555555';

String _script(String pubKeyHash) => '76a914${pubKeyHash}88ac';
String _address(String pubKeyHash) =>
    dartsv.Address.fromPubkeyHash(pubKeyHash, dartsv.NetworkType.TEST).toBase58();

dartsv.Transaction _tx({
  required List<(String, int)> inputs,
  required List<(String, int)> outputs,
}) {
  final tx = dartsv.Transaction()
    ..version = 1
    ..nLockTime = 0;
  for (final (prevTxid, prevVout) in inputs) {
    tx.inputs.add(dartsv.TransactionInput(
        prevTxid, prevVout, dartsv.TransactionInput.MAX_SEQ_NUMBER));
  }
  for (final (pubKeyHash, satoshis) in outputs) {
    tx.outputs.add(dartsv.TransactionOutput(
        BigInt.from(satoshis), dartsv.SVScript.fromHex(_script(pubKeyHash))));
  }
  return tx;
}

TransactionAddressLink _atVin(List<TransactionAddressLink> links, int vin) =>
    links.firstWhere((l) => l.vin == vin,
        orElse: () => fail('no input link with vin $vin in '
            '${links.map((l) => '${l.address}/vin=${l.vin}/${l.amount}').toList()}'));

void main() {
  late InMemoryWalletStorage storage;
  late WalletProjection projection;

  setUp(() async {
    storage = InMemoryWalletStorage();
    projection = WalletProjection(
      projectionId: 'junction-projection-test',
      eventStore: _NoopEventStore(),
      storage: storage,
    );
    await projection.handle(WalletCreatedEvent(
      walletId: _walletId,
      walletName: 'Junctions',
      rootAddress: _address(_ourHash),
      walletType: WalletType.hd,
      walletMetadata: const {'network': 'testnet'},
      version: 1,
      timestamp: DateTime.utc(2026, 1, 1),
    ));
  });

  group('outgoing transactions build junctions (D-3 a)', () {
    test('a recorded outgoing transaction links its inputs and outputs', () async {
      // A funding transaction paying us, imported and credited as a UTXO.
      final funding = _tx(inputs: [('a' * 64, 0)], outputs: [(_ourHash, 60000)]);
      await projection.handle(UTXOReceivedEvent(
        walletId: _walletId,
        txid: funding.id,
        vout: 0,
        satoshis: 60000,
        scriptPubKey: _script(_ourHash),
        address: _address(_ourHash),
        confirmations: 0,
        version: 2,
        timestamp: DateTime.utc(2026, 1, 2),
      ));
      await projection.handle(TransactionImportedEvent(
        walletId: _walletId,
        txid: funding.id,
        rawHex: funding.serialize(),
        blockHeight: null,
        bumpProof: '',
        totalOutputSats: 60000,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        walletReceivingAddresses: [_address(_ourHash)],
        walletReceivedSats: 60000,
        totalInputSats: 61000,
        sendingAddresses: const [],
        version: 3,
        timestamp: DateTime.utc(2026, 1, 2),
      ));

      // We spend it: 45000 to the recipient, 14000 back as change.
      final spend = _tx(
        inputs: [(funding.id, 0)],
        outputs: [(_recipientHash, 45000), (_changeHash, 14000)],
      );
      await projection.handle(TransactionRecordedEvent(
        walletId: _walletId,
        txid: spend.id,
        rawHex: spend.serialize(),
        totalInputSats: 60000,
        totalOutputSats: 59000,
        fee: 1000,
        numInputs: 1,
        numOutputs: 2,
        txVersion: 1,
        txLockTime: 0,
        spentUtxoKeys: ['${funding.id}:0'],
        recipientAddresses: [_address(_recipientHash)],
        paymentAmount: '45000',
        changeAddress: _address(_changeHash),
        changeAmount: '14000',
        version: 4,
        timestamp: DateTime.utc(2026, 1, 3),
      ));

      final links = await storage.getTransactionAddresses(_walletId, spend.id);
      expect(links.inputs, hasLength(1),
          reason: 'the outgoing transaction spends one input, from our address');
      final input = _atVin(links.inputs, 0);
      expect(input.address, equals(_address(_ourHash)));
      expect(input.amount, equals(BigInt.from(60000)),
          reason: 'the amount is the funding output it spends, not zero');
      expect(links.outputAddresses,
          containsAll([_address(_recipientHash), _address(_changeHash)]),
          reason: 'the payment and the change are both address-queryable');
    });

    test('an outgoing spend of an outpoint we know only as a UTXO row still links it',
        () async {
      // No transaction row and no ancestor for the parent: the wallet's own
      // UTXO row is the evidence for the address and the amount.
      final parentTxid = 'b' * 64;
      await projection.handle(UTXOReceivedEvent(
        walletId: _walletId,
        txid: parentTxid,
        vout: 3,
        satoshis: 21000,
        scriptPubKey: _script(_ourHash),
        address: _address(_ourHash),
        confirmations: 0,
        version: 2,
        timestamp: DateTime.utc(2026, 1, 2),
      ));

      final spend = _tx(
        inputs: [(parentTxid, 3)],
        outputs: [(_recipientHash, 20000)],
      );
      await projection.handle(TransactionRecordedEvent(
        walletId: _walletId,
        txid: spend.id,
        rawHex: spend.serialize(),
        totalInputSats: 21000,
        totalOutputSats: 20000,
        fee: 1000,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        spentUtxoKeys: ['$parentTxid:3'],
        recipientAddresses: [_address(_recipientHash)],
        paymentAmount: '20000',
        version: 4,
        timestamp: DateTime.utc(2026, 1, 3),
      ));

      final links = await storage.getTransactionAddresses(_walletId, spend.id);
      final input = _atVin(links.inputs, 0);
      expect(input.address, equals(_address(_ourHash)));
      expect(input.amount, equals(BigInt.from(21000)));
    });
  });

  group('input links are keyed to the input they belong to (D-3 b)', () {
    test('a derived sendingAddresses list does not decide vin or amount', () async {
      // One parent, two outputs to two different senders. The child spends
      // BOTH, taking output 1 first and output 0 second, and the event's
      // sendingAddresses carries a single derived entry (the real producers
      // dedupe and skip inputs whose script they cannot read).
      final parent = _tx(
        inputs: [('c' * 64, 0)],
        outputs: [(_senderAHash, 7000), (_senderBHash, 3000)],
      );
      final child = _tx(
        inputs: [(parent.id, 1), (parent.id, 0)],
        outputs: [(_ourHash, 9000)],
      );

      await projection.handle(TransactionImportedEvent(
        walletId: _walletId,
        txid: child.id,
        rawHex: child.serialize(),
        blockHeight: null,
        bumpProof: '',
        totalOutputSats: 9000,
        numInputs: 2,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        walletReceivingAddresses: [_address(_ourHash)],
        walletReceivedSats: 9000,
        totalInputSats: 10000,
        sendingAddresses: [_address(_senderAHash)],
        ancestors: [BeefAncestor(txid: parent.id, rawHex: parent.serialize())],
        version: 2,
        timestamp: DateTime.utc(2026, 1, 3),
      ));

      final links = await storage.getTransactionAddresses(_walletId, child.id);
      expect(links.inputs, hasLength(2),
          reason: 'both inputs are linked, not min(sendingAddresses, inputs)');

      final vin0 = _atVin(links.inputs, 0);
      expect(vin0.address, equals(_address(_senderBHash)),
          reason: 'input 0 spends parent output 1, which pays sender B');
      expect(vin0.amount, equals(BigInt.from(3000)),
          reason: 'the parent output it spends is 3000 sats, not zero');

      final vin1 = _atVin(links.inputs, 1);
      expect(vin1.address, equals(_address(_senderAHash)));
      expect(vin1.amount, equals(BigInt.from(7000)));
    });

    test('an input whose parent we do not hold is not linked to a fabricated amount',
        () async {
      // sendingAddresses names an address, but no ancestor, transaction row
      // or UTXO row evidences which input it belongs to or for how much.
      final orphan = _tx(inputs: [('d' * 64, 0)], outputs: [(_ourHash, 5000)]);
      await projection.handle(TransactionImportedEvent(
        walletId: _walletId,
        txid: orphan.id,
        rawHex: orphan.serialize(),
        blockHeight: null,
        bumpProof: '',
        totalOutputSats: 5000,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        walletReceivingAddresses: [_address(_ourHash)],
        walletReceivedSats: 5000,
        totalInputSats: 6000,
        sendingAddresses: [_address(_senderAHash)],
        version: 2,
        timestamp: DateTime.utc(2026, 1, 3),
      ));

      final links = await storage.getTransactionAddresses(_walletId, orphan.id);
      expect(links.inputs, isEmpty,
          reason: 'no parent output in hand is no evidence: no link rather than '
              'a zero amount on an invented vin');
      expect(links.outputAddresses, contains(_address(_ourHash)));
    });
  });
}

class _NoopEventStore implements EventStore {
  @override
  Future<void> persistEvent(String persistenceId, Event event, int expectedVersion) async {}

  @override
  Future<void> persistEvents(String persistenceId, List<Event> events, int expectedVersion) async {}

  @override
  Future<List<Event>> getEvents(String persistenceId,
          {int fromSequence = 0, int? toSequence}) async =>
      [];

  @override
  Future<int> getHighestSequenceNumber(String persistenceId) async => 0;

  @override
  Future<void> saveSnapshot(String persistenceId, dynamic state, int sequenceNumber) async {}

  @override
  Future<SnapshotData?> loadSnapshot(String persistenceId) async => null;

  @override
  Future<void> deleteOldSnapshots(String persistenceId, int keepCount) async {}

  @override
  Future<void> close() async {}
}
