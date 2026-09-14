/// Hand-built wallet events with fixed timestamps, for tests that apply
/// events to a [BitcoinWalletAggregate] directly (replay, snapshots) rather
/// than through commands, whose events carry the wall-clock time.
library;

import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_event.dart';
import 'package:libspiffy/src/models/wallet_type.dart';

/// Builds a journal for one wallet: every event gets the next version and a
/// timestamp one minute after the previous event's, starting at [start].
class WalletJournalBuilder {
  final String walletId;
  final List<WalletEvent> events = [];
  final int firstVersion;
  DateTime _clock;

  /// [firstVersion] is the version of the first event added (a builder for
  /// the tail of a journal starts after the events already written).
  WalletJournalBuilder(this.walletId, {DateTime? start, this.firstVersion = 1})
      : _clock = start ?? DateTime.utc(2021, 3, 4, 5, 6, 7, 8, 9);

  int get _nextVersion => firstVersion + events.length;

  DateTime _tick() => _clock = _clock.add(const Duration(minutes: 1));

  /// The timestamp of the last event added.
  DateTime get lastTimestamp => events.last.timestamp;

  T _add<T extends WalletEvent>(T event) {
    events.add(event);
    return event;
  }

  static String txid(int n) => n.toRadixString(16).padLeft(64, '0');

  static const scriptPubKey = '76a91489abcdefabbaabbaabbaabbaabbaabbaabbaabba88ac';

  WalletCreatedEvent created({String rootAddress = 'mrootaddress0000000000000000000000'}) =>
      _add(WalletCreatedEvent(
        walletId: walletId,
        walletName: 'Journal wallet',
        rootAddress: rootAddress,
        walletType: WalletType.hd,
        walletMetadata: {'network': 'testnet'},
        version: _nextVersion,
        timestamp: _tick(),
      ));

  AddressGeneratedEvent address(String address, int index, {bool change = false, String? label}) =>
      _add(AddressGeneratedEvent(
        walletId: walletId,
        address: address,
        derivationIndex: index,
        label: label,
        purpose: change ? 'change' : 'receive',
        version: _nextVersion,
        timestamp: _tick(),
      ));

  UTXOReceivedEvent received(
    int tx,
    int vout, {
    int sats = 1000,
    UTXOStatus status = UTXOStatus.pending,
    int confirmations = 0,
    String address = 'mutxoaddress00000000000000000000000',
    Map<String, dynamic>? pluginMetadata,
  }) =>
      _add(UTXOReceivedEvent(
        walletId: walletId,
        txid: txid(tx),
        vout: vout,
        satoshis: sats,
        scriptPubKey: scriptPubKey,
        address: address,
        initialStatus: status,
        confirmations: confirmations,
        blockHeight: confirmations > 0 ? 100 : null,
        derivationIndex: 1,
        pluginMetadata: pluginMetadata,
        version: _nextVersion,
        timestamp: _tick(),
      ));

  UTXOConfirmationUpdatedEvent confirmed(int tx, int vout, int confirmations) =>
      _add(UTXOConfirmationUpdatedEvent(
        walletId: walletId,
        txid: txid(tx),
        vout: vout,
        confirmations: confirmations,
        blockHeight: 200,
        version: _nextVersion,
        timestamp: _tick(),
      ));

  UTXOMarkedAvailableEvent markedAvailable(int tx, int vout) => _add(UTXOMarkedAvailableEvent(
        walletId: walletId,
        txid: txid(tx),
        vout: vout,
        version: _nextVersion,
        timestamp: _tick(),
      ));

  UTXOReservedEvent reserved(int tx, int vout,
      {String by = 'payment-1', int priority = 0, DateTime? expiresAt}) {
    final at = _tick();
    return _add(UTXOReservedEvent(
      walletId: walletId,
      txid: txid(tx),
      vout: vout,
      reservedByTxId: by,
      reservationReason: 'reason $by',
      expiresAt: expiresAt ?? at.add(const Duration(minutes: 30)),
      priority: priority,
      version: _nextVersion,
      timestamp: at,
    ));
  }

  UTXOReservationRenewedEvent renewed(int tx, int vout, DateTime oldExpiresAt, Duration by) =>
      _add(UTXOReservationRenewedEvent(
        walletId: walletId,
        txid: txid(tx),
        vout: vout,
        oldExpiresAt: oldExpiresAt,
        newExpiresAt: oldExpiresAt.add(by),
        renewalReason: 'renewed',
        version: _nextVersion,
        timestamp: _tick(),
      ));

  UTXOReleasedEvent released(int tx, int vout, {UTXOStatus? restored}) => _add(UTXOReleasedEvent(
        walletId: walletId,
        txid: txid(tx),
        vout: vout,
        releaseReason: 'released',
        restoredStatus: restored,
        version: _nextVersion,
        timestamp: _tick(),
      ));

  UTXOSpentEvent spent(int tx, int vout, {int inTx = 9999}) => _add(UTXOSpentEvent(
        walletId: walletId,
        txid: txid(tx),
        vout: vout,
        spentInTxId: txid(inTx),
        version: _nextVersion,
        timestamp: _tick(),
      ));

  TransactionImportedEvent imported(int tx, {int blockHeight = 150}) =>
      _add(TransactionImportedEvent(
        walletId: walletId,
        txid: txid(tx),
        rawHex: '00',
        blockHeight: blockHeight,
        bumpProof: '',
        totalOutputSats: 1000,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        walletReceivingAddresses: const ['mutxoaddress00000000000000000000000'],
        walletReceivedSats: 1000,
        totalInputSats: 1100,
        sendingAddresses: const [],
        version: _nextVersion,
        timestamp: _tick(),
      ));

  TransactionRecordedEvent recorded(int tx, {int fee = 50}) => _add(TransactionRecordedEvent(
        walletId: walletId,
        txid: txid(tx),
        rawHex: '00',
        totalInputSats: 2000,
        totalOutputSats: 1950,
        fee: fee,
        numInputs: 1,
        numOutputs: 2,
        txVersion: 1,
        txLockTime: 0,
        spentUtxoKeys: const [],
        recipientAddresses: const ['mrecipient000000000000000000000000'],
        paymentAmount: '1000',
        version: _nextVersion,
        timestamp: _tick(),
      ));

  TransactionConfirmedEvent txConfirmed(int tx) => _add(TransactionConfirmedEvent(
        walletId: walletId,
        txid: txid(tx),
        blockHeight: 300,
        blockHash: 'ab' * 32,
        version: _nextVersion,
        timestamp: _tick(),
      ));
}
