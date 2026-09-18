/// Bead libspiffy-8oaq: a caller-supplied confirmation count or block height
/// must not change a UTXO's spendability.
///
/// `UpdateUTXOConfirmationsCommand` takes a confirmation count and a block
/// height straight from its caller and validates neither. A count is a claim,
/// not evidence (V-60): nothing in it has been checked against our own header
/// chain, so it cannot be allowed to promote a [UTXOStatus.pending] output to
/// [UTXOStatus.available], and it certainly cannot un-void an output that
/// bead libspiffy-3arz (V-73) designed to be revived only by a merkle proof
/// that outranks the resolution which voided it.
///
/// Availability comes from `MarkUTXOAvailableCommand` (driven by ARC/SPV) or
/// from `ConfirmTransactionCommand`, whose senders all derive the height from
/// a BUMP verified against our headers. Never from this command.
///
/// Also pinned here: an absent height is journaled as absent, not as height
/// 0 — the genesis block.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

const _w = 'confirmation-claim-wallet';
final _input = '${'a1' * 32}:0';

final _ourKey = dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST);
final _ourAddress = _ourKey.publicKey.toAddress(dartsv.NetworkType.TEST);
final _ourScript = dartsv.P2PKHLockBuilder.fromAddress(_ourAddress).getScriptPubkey().toHex();

final _theirKey = dartsv.SVPrivateKey.fromHex('33' * 32, dartsv.NetworkType.TEST);
final _theirAddress = _theirKey.publicKey.toAddress(dartsv.NetworkType.TEST);
final _theirScript = dartsv.P2PKHLockBuilder.fromAddress(_theirAddress).getScriptPubkey().toHex();

class _NoStore implements EventStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

BitcoinWalletAggregate _aggregate() => BitcoinWalletAggregate(
      aggregateId: _w,
      aggregateType: 'BitcoinWallet',
      eventStore: _NoStore(),
      cryptoService: DartSVCryptoService(),
      secureStorage: InMemorySecureStorage(),
    );

String _paymentHex(List<String> inputs, {required int sats, required int change}) {
  final tx = dartsv.Transaction();
  for (final key in inputs) {
    final parts = key.split(':');
    tx.addInput(dartsv.TransactionInput(parts[0], int.parse(parts[1]), dartsv.TransactionInput.MAX_SEQ_NUMBER));
  }
  tx.addOutput(dartsv.TransactionOutput(BigInt.from(sats), dartsv.SVScript.fromHex(_theirScript)));
  if (change > 0) {
    tx.addOutput(dartsv.TransactionOutput(BigInt.from(change), dartsv.SVScript.fromHex(_ourScript)));
  }
  return tx.serialize();
}

class _Wallet {
  final BitcoinWalletAggregate aggregate = _aggregate();
  final List<Event> journal = [];

  _Wallet() {
    apply([
      WalletCreatedEvent(
        walletId: _w,
        walletName: 'w',
        rootAddress: _ourAddress.toBase58(),
        walletType: WalletType.hd,
        walletMetadata: {'network': 'testnet'},
        version: 1,
        timestamp: DateTime.utc(2026),
      ),
    ]);
  }

  void apply(List<Event> events) {
    for (final e in events) {
      aggregate.eventHandler(e);
      journal.add(e);
    }
  }

  void receive(String key, int sats, {UTXOStatus status = UTXOStatus.pending}) {
    final parts = key.split(':');
    apply([
      UTXOReceivedEvent(
        walletId: _w,
        txid: parts[0],
        vout: int.parse(parts[1]),
        satoshis: sats,
        scriptPubKey: _ourScript,
        address: _ourAddress.toBase58(),
        initialStatus: status,
        version: aggregate.currentState.version + 1,
        timestamp: DateTime.utc(2026),
      ),
    ]);
  }

  Future<List<Event>> handle(WalletCommand command) async {
    final events = await aggregate.handleCommand(aggregate.currentState, command);
    apply(events);
    return events;
  }

  BitcoinUtxo utxo(String key) => aggregate.currentState.utxos[key]!;

  BitcoinWalletAggregate replay() {
    final fresh = _aggregate();
    for (final e in journal) {
      fresh.eventHandler(e);
    }
    return fresh;
  }

  /// Records a deferred payment out of [inputs] with [change] back to us,
  /// so that cancelling it leaves a [UTXOStatus.voided] change output.
  Future<String> pay(List<String> inputs, {int sats = 1000, int change = 18900}) async {
    final rawHex = _paymentHex(inputs, sats: sats, change: change);
    final txid = dartsv.Transaction.fromHex(rawHex).id;
    await handle(RecordOutgoingTransactionCommand(
      walletId: _w,
      txid: txid,
      rawHex: rawHex,
      totalInputSats: 20000,
      totalOutputSats: sats + change,
      fee: 100,
      numInputs: inputs.length,
      numOutputs: change > 0 ? 2 : 1,
      txVersion: 1,
      txLockTime: 0,
      spentUtxoKeys: inputs,
      recipientAddresses: [_theirAddress.toBase58()],
      paymentAmount: BigInt.from(sats),
      changeAddress: _ourAddress.toBase58(),
      changeAmount: BigInt.from(change),
      deferSpend: true,
      invoiceId: 'inv-$sats',
      purpose: 'invoice-payment',
    ));
    return txid;
  }
}

void main() {
  group('8oaq: a caller-supplied confirmation count does not conjure spendable funds', () {
    test('a pending UTXO is not promoted to available by UpdateUTXOConfirmationsCommand', () async {
      final wallet = _Wallet();
      wallet.receive(_input, 20000);
      expect(wallet.utxo(_input).status, UTXOStatus.pending);

      // No proof anywhere: just a caller asserting a height and a count.
      await wallet.handle(UpdateUTXOConfirmationsCommand(
        walletId: _w,
        utxoKey: _input,
        confirmations: 6,
        blockHeight: 900000,
      ));

      for (final state in [wallet.aggregate.currentState, wallet.replay().currentState]) {
        expect(state.utxos[_input]!.status, UTXOStatus.pending,
            reason: 'a claim is not evidence: only a proof or MarkUTXOAvailableCommand promotes');
        expect(state.availableBalance, BigInt.zero,
            reason: 'the command must not make one satoshi spendable');
      }
    });

    test('MarkUTXOAvailableCommand is the path that does promote it', () async {
      final wallet = _Wallet();
      wallet.receive(_input, 20000);
      final parts = _input.split(':');

      await wallet.handle(
          MarkUTXOAvailableCommand(walletId: _w, txid: parts[0], vout: int.parse(parts[1])));

      expect(wallet.utxo(_input).status, UTXOStatus.available);
      expect(wallet.aggregate.currentState.availableBalance, BigInt.from(20000));
    });

    test('a voided output is not un-voided by UpdateUTXOConfirmationsCommand', () async {
      final wallet = _Wallet();
      wallet.receive(_input, 20000, status: UTXOStatus.available);
      final txid = await wallet.pay([_input]);
      final changeKey = '$txid:1';
      await wallet.handle(CancelDeferredSpendCommand(walletId: _w, txid: txid, reason: 'gone'));
      expect(wallet.utxo(changeKey).status, UTXOStatus.voided);

      await wallet.handle(UpdateUTXOConfirmationsCommand(
        walletId: _w,
        utxoKey: changeKey,
        confirmations: 3,
        blockHeight: 900002,
      ));

      for (final state in [wallet.aggregate.currentState, wallet.replay().currentState]) {
        expect(state.utxos[changeKey]!.status, UTXOStatus.voided,
            reason: 'only a proof outranks the resolution that voided it (libspiffy-3arz)');
      }
      expect(wallet.aggregate.currentState.availableBalance, BigInt.from(20000),
          reason: 'the released input only; the voided change stays out');
    });

    test('a pending UTXO reserved and then given a confirmation count is still pending on release',
        () async {
      final wallet = _Wallet();
      wallet.receive(_input, 20000);
      await wallet.handle(ReserveUTXOCommand(walletId: _w, utxoKey: _input, reservedByTxId: 'payment'));

      await wallet.handle(UpdateUTXOConfirmationsCommand(
        walletId: _w,
        utxoKey: _input,
        confirmations: 4,
        blockHeight: 900003,
      ));
      expect(wallet.utxo(_input).status, UTXOStatus.reserved);

      await wallet.handle(ReleaseUTXOCommand(walletId: _w, utxoKey: _input));

      for (final state in [wallet.aggregate.currentState, wallet.replay().currentState]) {
        expect(state.utxos[_input]!.status, UTXOStatus.pending,
            reason: 'releasing must restore pending: the count never made it spendable');
        expect(state.availableBalance, BigInt.zero);
      }
    });

    test('the claim is still recorded on the row; only the status is left alone', () async {
      final wallet = _Wallet();
      wallet.receive(_input, 20000);

      await wallet.handle(UpdateUTXOConfirmationsCommand(
        walletId: _w,
        utxoKey: _input,
        confirmations: 2,
        blockHeight: 800500,
      ));

      // RETENTION: what we were told is kept; it just carries no authority.
      expect(wallet.utxo(_input).confirmations, 2);
      expect(wallet.utxo(_input).blockHeight, 800500);
      expect(wallet.utxo(_input).status, UTXOStatus.pending);
    });
  });

  group('8oaq: an absent block height is not the genesis block', () {
    test('a command with no height journals no height, and leaves the row without one', () async {
      final wallet = _Wallet();
      wallet.receive(_input, 20000);

      final events = await wallet.handle(UpdateUTXOConfirmationsCommand(
        walletId: _w,
        utxoKey: _input,
        confirmations: 1,
      ));

      final event = events.single as UTXOConfirmationUpdatedEvent;
      expect(event.blockHeight, isNull,
          reason: 'height 0 is the genesis block, not "no height given"');
      expect(event.getWalletEventData()['blockHeight'], isNull);
      expect(wallet.utxo(_input).blockHeight, isNull);
      expect(wallet.utxo(_input).isConfirmed, isFalse,
          reason: 'an absent height must not read back as mined in the genesis block');
    });

    test('an absent height survives the event-data round trip as absent', () {
      final event = UTXOConfirmationUpdatedEvent(
        walletId: _w,
        txid: 'a1' * 32,
        vout: 0,
        confirmations: 1,
        version: 2,
        timestamp: DateTime.utc(2026),
      );
      final restored = UTXOConfirmationUpdatedEvent.fromMap({
        ...event.getEventData(),
        'eventId': event.eventId,
        'timestamp': event.timestamp.toIso8601String(),
        'version': event.version,
      });
      expect(restored.blockHeight, isNull);
      expect(restored.confirmations, 1);

      final withHeight = UTXOConfirmationUpdatedEvent.fromMap({
        ...event.getEventData(),
        'blockHeight': 800500,
        'eventId': event.eventId,
        'timestamp': event.timestamp.toIso8601String(),
        'version': event.version,
      });
      expect(withHeight.blockHeight, 800500);
    });

    test('a command with no height does not erase a height a proof established', () async {
      final wallet = _Wallet();
      wallet.receive(_input, 20000, status: UTXOStatus.available);
      final txid = await wallet.pay([_input]);
      final changeKey = '$txid:1';

      // A merkle proof on our own header chain: this height is evidence.
      await wallet.handle(
          ConfirmTransactionCommand(walletId: _w, txid: txid, blockHeight: 910000, blockHash: 'h'));
      expect(wallet.utxo(changeKey).blockHeight, 910000);

      await wallet.handle(UpdateUTXOConfirmationsCommand(
        walletId: _w,
        utxoKey: changeKey,
        confirmations: 1,
      ));

      expect(wallet.utxo(changeKey).blockHeight, 910000,
          reason: 'an absent height says nothing; it must not overwrite a proven one with 0');
    });
  });
}
