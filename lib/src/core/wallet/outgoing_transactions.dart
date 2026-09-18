/// The wallet's transaction records: imported transactions, outgoing
/// transactions and the wallet outputs they create, confirmations and their
/// reversal (bead libspiffy-dp4; part of `BitcoinWalletAggregate`).
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';

import '../../models/bitcoin_utxo.dart';
import '../../models/deferred_payment.dart' show DeferredPaymentState;
import '../../models/persistent_map.dart';
import '../../models/wallet_state.dart';
import '../../plugin/plugin_registry.dart';
import '../../services/script_type_registry.dart';
import '../../utils/network_name.dart';
import '../wallet_commands.dart';
import '../wallet_events.dart';
import '../wallet_output_ownership.dart';
import 'deferred_payments.dart';
import 'state_records.dart';

final _log = Logger('BitcoinWalletAggregate');

/// Transaction record commands and events of one wallet aggregate.
class OutgoingTransactions {
  static const String _importedTransactionsKey = WalletMetadataKeys.importedTransactions;
  static const String _outgoingTransactionsKey = WalletMetadataKeys.outgoingTransactions;

  final DeferredPayments deferred;

  OutgoingTransactions(this.deferred);

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  /// Whether [state] holds the outgoing-transaction record of [txid]
  /// ([applyRecorded]; a list-shaped record from older state included).
  static bool isRecorded(WalletState state, String txid) => outgoingRecord(state, txid) != null;

  /// The outgoing-transaction record of [txid] in [state], or null when the
  /// wallet did not record it ([applyRecorded]; a list-shaped record from
  /// older state included).
  static Map<dynamic, dynamic>? outgoingRecord(WalletState state, String txid) =>
      _recordOf(state, _outgoingTransactionsKey, txid);

  /// The imported-transaction record of [txid] in [state], or null when the
  /// wallet did not receive it ([applyImported]; a list-shaped record from
  /// older state included).
  ///
  /// A received transaction is one the wallet recorded, in the other
  /// direction: it creates wallet outputs and spends none of ours. Bead
  /// libspiffy-73bj — a merkle proof confirms it exactly as it confirms a
  /// payment we sent.
  static Map<dynamic, dynamic>? importedRecord(WalletState state, String txid) =>
      _recordOf(state, _importedTransactionsKey, txid);

  /// The record of [txid] under metadata[[key]] in [state], or null.
  static Map<dynamic, dynamic>? _recordOf(WalletState state, String key, String txid) {
    final records = state.metadata[key];
    if (records is Map) {
      final record = records[txid];
      return record is Map ? record : (records.containsKey(txid) ? const {} : null);
    }
    if (records is List) {
      for (final record in records) {
        if (record is Map && record['txid']?.toString() == txid) return record;
      }
    }
    return null;
  }

  /// Whether the outgoing transaction [txid] this wallet recorded lists
  /// [utxoKey] among the UTXOs it spends.
  static bool recordedTransactionSpends(WalletState state, String txid, String utxoKey) =>
      _recordedSpentKeys(state, txid).contains(utxoKey);

  /// The UTXO keys the outgoing transaction [txid] this wallet recorded
  /// spends; empty when it recorded none.
  static List<String> _recordedSpentKeys(WalletState state, String txid) {
    final records = state.metadata[_outgoingTransactionsKey];
    final record = records is Map
        ? records[txid]
        : records is List
            ? records.firstWhere((r) => r is Map && r['txid']?.toString() == txid, orElse: () => null)
            : null;
    if (record is! Map) return const [];
    final keys = record['spentUtxoKeys'];
    return keys is List ? [for (final k in keys) k.toString()] : const [];
  }

  // ---------------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------------

  static List<Event> recordImported(WalletState currentState, RecordImportedTransactionCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot record transaction for non-existent wallet');
    }

    // Emit TransactionImportedEvent with all the pre-calculated data from ImportActor
    final event = TransactionImportedEvent(
      walletId: command.walletId,
      txid: command.txid,
      rawHex: command.rawHex,
      blockHeight: command.blockHeight,
      bumpProof: command.bumpProofHex,
      totalOutputSats: command.totalOutputSats,
      numInputs: command.numInputs,
      numOutputs: command.numOutputs,
      txVersion: command.txVersion,
      txLockTime: command.txLockTime,
      walletReceivingAddresses: command.walletReceivingAddresses,
      walletReceivedSats: command.walletReceivedSats,
      totalInputSats: command.totalInputSats,
      sendingAddresses: command.sendingAddresses,
      ancestors: command.ancestors,
      // Who handed us the transaction, as the app names them (cq16).
      counterpartyMarker: command.counterpartyMarker,
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  /// Handle recording an outgoing transaction (payment created by this wallet)
  ///
  /// [supersedesDeferred] is the one deferred payment whose hold on these
  /// inputs this recording takes over: the payment a reclaim's self-spend
  /// reclaims (bead libspiffy-87a). Everywhere else an input another
  /// deferred payment holds is left to it.
  List<Event> recordOutgoing(WalletState currentState, RecordOutgoingTransactionCommand command,
      {String? supersedesDeferred}) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot record outgoing transaction for non-existent wallet');
    }

    // Business rule: a transaction is recorded once (bead libspiffy-viy).
    // The command is re-sent for a txid the wallet already recorded, e.g. by
    // a channel funding broadcast resumed after a restart. Recording it
    // again journaled a second TransactionRecordedEvent (the read model's
    // history row went back to pending) and spent the inputs again. Only an
    // input spend the earlier record deferred and this one asks for is
    // still applied.
    if (isRecorded(currentState, command.txid)) {
      return _spendsStillOwed(currentState, command);
    }

    final events = <Event>[];

    // Phase 4: when the TX was signed externally (plugin's
    // CallbackTransactionSigner or similar), emit a TransactionSignedEvent
    // here to fill the audit-trail gap. Wallet-internal flows that came
    // through SignTransactionCommand already emitted this event; plugin
    // flows had no canonical signing record until now.
    if (command.preSigned) {
      events.add(TransactionSignedEvent(
        walletId: command.walletId,
        txid: command.txid,
        signedRawHex: command.rawHex,
        version: currentState.version + events.length + 1,
        timestamp: DateTime.now(),
        metadata: command.signerMetadata,
      ));
    }

    // Emit TransactionRecordedEvent
    final transactionEvent = TransactionRecordedEvent(
      walletId: command.walletId,
      txid: command.txid,
      rawHex: command.rawHex,
      totalInputSats: command.totalInputSats,
      totalOutputSats: command.totalOutputSats,
      fee: command.fee,
      numInputs: command.numInputs,
      numOutputs: command.numOutputs,
      txVersion: command.txVersion,
      txLockTime: command.txLockTime,
      spentUtxoKeys: command.spentUtxoKeys,
      recipientAddresses: command.recipientAddresses,
      paymentAmount: command.paymentAmount.toString(),
      changeAddress: command.changeAddress,
      changeAmount: command.changeAmount?.toString(),
      // Who we paid, as the app names them (cq16).
      counterpartyMarker: command.counterpartyMarker,
      version: currentState.version + events.length + 1,
      timestamp: DateTime.now(),
    );
    events.add(transactionEvent);

    // Mark spent UTXOs — unless deferSpend is true: then the wallet holds
    // the inputs (no expiry) until the network settles the transaction,
    // ARC reports it failed, or it is cancelled (bead libspiffy-7p2);
    // ARCActor issues SpendUTXOCommand when it reaches SEEN_ON_NETWORK.
    if (command.deferSpend) {
      final hold = deferred.holdEvent(currentState, command,
          version: currentState.version + events.length + 1, supersedes: supersedesDeferred);
      events.add(hold);
      _log.fine('Deferred spend for ${command.txid}: ${hold.heldInputs.length} input(s) held');
    }
    for (final utxoKey in command.deferSpend ? <String>[] : command.spentUtxoKeys) {
      final parts = utxoKey.split(':');
      if (parts.length != 2) {
        continue;
      }
      final utxoTxid = parts[0];
      final utxoVout = int.tryParse(parts[1]);
      if (utxoVout == null) {
        continue;
      }

      final spentEvent = UTXOSpentEvent(
        walletId: command.walletId,
        txid: utxoTxid,
        vout: utxoVout,
        spentInTxId: command.txid,
        version: currentState.version + events.length + 1,
        timestamp: DateTime.now(),
      );
      events.add(spentEvent);
    }

    _addWalletOutputs(currentState, command, events);
    return events;
  }

  /// SCAN ALL OUTPUTS: adds a [UTXOReceivedEvent] to [events] for each output
  /// of [command]'s transaction that belongs to a wallet address and that
  /// the wallet does not hold yet. This handles change outputs, settlement
  /// outputs, self-transfers, and any other scenario where transaction
  /// outputs belong to this wallet. A transaction that does not parse is
  /// still recorded; its outputs are not scanned.
  static void _addWalletOutputs(WalletState currentState, RecordOutgoingTransactionCommand command, List<Event> events) {
    try {
      final tx = dartsv.Transaction.fromHex(command.rawHex);
      final walletAddresses = currentState.addresses.keys.toSet();
      final network = NetworkName.toDartsv(currentState.networkType);

      // Use ScriptTypeRegistry to identify output types and extract addresses
      final scriptRegistry = ScriptTypeRegistry(networkType: network);

      for (int i = 0; i < tx.outputs.length; i++) {
        final output = tx.outputs[i];
        final satoshis = output.satoshis.toInt();

        if (satoshis <= 0) {
          continue;
        }

        // Identify script type
        final scriptType = scriptRegistry.identifyScriptType(output.script)?.toLowerCase() ?? 'unknown';

        String? outputAddress;
        bool belongsToWallet = false;
        Map<String, dynamic>? outputPluginMetadata;

        // Extract address based on script type
        switch (scriptType) {
          case 'p2pkh':
            try {
              final locker = dartsv.P2PKHLockBuilder.fromScript(output.script, networkType: network);
              outputAddress = locker.address?.toBase58();
              if (outputAddress != null && walletAddresses.contains(outputAddress)) {
                belongsToWallet = true;
              }
            } catch (e) {
              _log.warning('Failed to extract P2PKH address from output: $e');
            }
            break;

          case 'p2pk':
            try {
              final scriptInfo = scriptRegistry.extractScriptMetadata(output.script);
              final pubkeyHex = scriptInfo?['pubKey'] ?? scriptInfo?['publicKey'];
              if (pubkeyHex != null) {
                final pubKeyObj = dartsv.SVPublicKey.fromHex(pubkeyHex);
                outputAddress = dartsv.Address.fromPublicKey(pubKeyObj, network).toBase58();
                if (walletAddresses.contains(outputAddress)) {
                  belongsToWallet = true;
                }
              }
            } catch (e) {
              _log.warning('Failed to extract P2PK address from output: $e');
            }
            break;

          case 'p2ms':
            // A bare multisig output is the wallet's only when the wallet
            // holds as many of its keys as it requires: a payment channel's
            // 2-of-2 funding output also needs the other party's signature
            // and is not spendable balance (bead libspiffy-viy). The
            // transaction itself is recorded whole either way.
            outputAddress = BareMultisigScript.parse(output.script)?.spendableAloneBy(walletAddresses.contains, network);
            belongsToWallet = outputAddress != null;
            break;

          case 'opreturn':
          case 'op_return':
            // OP_RETURN outputs don't belong to anyone
            continue;

          default:
            // Plugin-aware fallback: ScriptTypeRegistry.identifyScriptType
            // already consulted PluginRegistry for unknown templates and
            // returned `pluginId:scriptType` when a plugin claimed the script.
            // Mirror the SPV inbound path (spv_actor.dart:504-525) so the
            // aggregate that *built* a plugin-locked output represents it
            // immediately, without waiting for SPV rediscovery.
            if (scriptType.contains(':')) {
              final pluginId = scriptType.split(':').first;
              // Guarded: a plugin that throws must not fail the recording of
              // our own outgoing transaction (bead libspiffy-u150).
              final metadata = PluginRegistry().extractMetadata(pluginId, output.script);
              final ownerAddress = metadata?['ownerAddress'] as String?;
              if (ownerAddress != null && walletAddresses.contains(ownerAddress)) {
                outputAddress = ownerAddress;
                belongsToWallet = true;
                outputPluginMetadata = metadata;
              }
            }
            break;
        }

        // An output the wallet already holds (the transaction was recorded
        // before, or the UTXO arrived another way) keeps its current state:
        // re-emitting UTXOReceivedEvent reset its status (audit M9).
        if (belongsToWallet && currentState.utxos.containsKey('${command.txid}:$i')) {
          continue;
        }

        // If output belongs to wallet, create a UTXO for it
        if (belongsToWallet && outputAddress != null) {
          final utxoEvent = UTXOReceivedEvent(
            walletId: command.walletId,
            txid: command.txid,
            vout: i,
            satoshis: satoshis,
            scriptPubKey: output.script.toHex(),
            address: outputAddress,
            blockHeight: null, // Not confirmed yet
            confirmations: 0,
            initialStatus: UTXOStatus.pending, // Starts as pending until confirmed
            pluginMetadata: outputPluginMetadata,
            version: currentState.version + events.length + 1,
            timestamp: DateTime.now(),
          );
          events.add(utxoEvent);
        }
      }
    } catch (e, stackTrace) {
      // The transaction is still recorded; its outputs are not scanned.
      _log.warning('Could not scan the outputs of ${command.txid}: $e', e, stackTrace);
    }
  }

  /// For a [command] recording a transaction already recorded: a
  /// [UTXOSpentEvent] for each of its spent UTXOs the wallet holds unspent,
  /// unless the spend is deferred. Nothing else is journaled again.
  List<Event> _spendsStillOwed(WalletState currentState, RecordOutgoingTransactionCommand command) {
    final events = <Event>[];
    final record = command.deferSpend ? DeferredPayments.record(currentState, command.txid) : null;
    if (command.deferSpend && record == null) {
      // Recorded before its hold was journaled (a journal older than bead
      // libspiffy-7p2): hold what it still has unspent now.
      events.add(deferred.holdEvent(currentState, command, version: currentState.version + 1));
    } else if (record?['state'] == DeferredPaymentState.cancelled.name) {
      // The same payment handed out again after it was cancelled (the same
      // inputs signed deterministically give the same transaction, bead
      // libspiffy-4r0): outstanding again, its inputs held again. Every
      // input must still be the wallet's to hold, or the transaction could
      // not settle.
      for (final key in command.spentUtxoKeys) {
        final utxo = currentState.utxos[key];
        final holder = deferred.holderOf(currentState, key);
        if ((utxo != null && utxo.status == UTXOStatus.spent) || (holder != null && holder != command.txid)) {
          throw StateError('Deferred payment ${command.txid} was cancelled and cannot be re-activated: '
              'its input $key is ${holder != null ? 'held by deferred payment $holder' : 'spent'}');
        }
      }
      events.add(deferred.holdEvent(currentState, command, version: currentState.version + 1, reactivated: true));
    } else if (record?['state'] == DeferredPaymentState.failed.name) {
      throw StateError('Deferred payment ${command.txid} failed '
          '(${record?['lastNetworkStatus'] ?? 'rejected by the network'}); '
          'the same transaction is not recorded as a payment again');
    }
    if (!command.deferSpend) {
      for (final utxoKey in command.spentUtxoKeys) {
        final utxo = currentState.utxos[utxoKey];
        if (utxo == null || utxo.status == UTXOStatus.spent) continue;
        events.add(UTXOSpentEvent(
          walletId: command.walletId,
          txid: utxo.txid,
          vout: utxo.vout,
          spentInTxId: command.txid,
          version: currentState.version + events.length + 1,
          timestamp: DateTime.now(),
        ));
      }
    }
    _log.info('Outgoing transaction ${command.txid} is already recorded; '
        '${events.length} spend(s) still applied, nothing else journaled');
    return events;
  }

  /// Confirm a transaction: its merkle proof verified against the active
  /// header chain, so it is mined, whatever the network reported before.
  ///
  /// A confirmation is authoritative (bead hccp): an outgoing transaction
  /// this wallet recorded spends its inputs, so each of them the wallet still
  /// holds unspent is spent by it (UTXOSpentEvent before the
  /// TransactionConfirmedEvent). That applies the spend of a deferred payment
  /// ARC reported REJECTED, or the user cancelled, whose inputs were
  /// released; a payment whose spend already applied spends nothing again.
  /// An input recorded as spent by another transaction is a double spend
  /// with that one: logged severe and left as recorded (that spend is not
  /// rewritten). An input another deferred payment holds is spent by this
  /// transaction (that payment can no longer settle), logged severe; an
  /// input under another reservation is spent too, logged as a warning.
  ///
  /// The transaction's own outputs this wallet holds pending become
  /// available (bead libspiffy-fggl): a proof on the active chain says they
  /// are in a block, so the change of a payment we deferred is spendable
  /// from the moment the proof reaches us. A UTXO that is already available
  /// or spent is left alone. A **voided** output becomes available too (bead
  /// libspiffy-3arz): a cancelled or failed payment the recipient got mined
  /// after all is confirmed like any other, and the proof outranks the
  /// resolution that voided its change.
  ///
  /// A transaction the wallet RECEIVED is confirmed the same way (bead
  /// libspiffy-73bj), and only the second half applies: it creates wallet
  /// outputs and spends nothing of ours, so no input is spent (an imported
  /// record lists no spent UTXO keys) and its pending outputs become
  /// spendable. A proof is a proof wherever it reaches us — in the BEEF that
  /// paid us, re-delivered once the payment is mined, or as an ancestor of a
  /// later transaction that spends it.
  ///
  /// With [ConfirmTransactionCommand.onlyIfRecorded] nothing is journaled
  /// unless the wallet recorded the transaction itself — sent or received —
  /// and has not confirmed it yet: the confirmation then comes from a proof
  /// nobody asked for (a BUMP in a received BEEF), which mostly proves other
  /// people's transactions, and the same BEEF may arrive twice.
  static List<Event> confirm(WalletState currentState, ConfirmTransactionCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot confirm transaction for non-existent wallet');
    }

    if (command.onlyIfRecorded) {
      // What the wallet sent, else what it received: a transaction that is
      // both keeps the outgoing record's verdict, since that one also spends
      // inputs.
      final record = outgoingRecord(currentState, command.txid) ?? importedRecord(currentState, command.txid);
      if (record == null || record['status'] == 'confirmed') {
        _log.fine('Proof for ${command.txid} offered to wallet ${command.walletId}: '
            '${record == null ? 'not a transaction this wallet recorded' : 'already confirmed'}; nothing journaled');
        return const [];
      }
    }

    final events = <Event>[];
    for (final key in _recordedSpentKeys(currentState, command.txid).toSet()) {
      final utxo = currentState.utxos[key];
      if (utxo == null) continue;
      if (utxo.status == UTXOStatus.spent) {
        final spender = utxo.spentInTxId;
        if (spender != null && spender != command.txid) {
          _log.severe('Double spend in wallet ${command.walletId}: transaction ${command.txid} is confirmed by a '
              'merkle proof on the active header chain, but its input $key is recorded as spent by $spender. '
              'The confirmation stands; the spend by $spender is left as recorded');
        }
        continue;
      }
      final holder = DeferredPayments.explicitHolder(currentState, key);
      final reservedBy = utxo.status == UTXOStatus.reserved ? utxo.reservedByTxId : null;
      if (holder != null && holder != command.txid) {
        _log.severe('Double spend in wallet ${command.walletId}: transaction ${command.txid} is confirmed by a '
            'merkle proof on the active header chain and spends input $key, which deferred payment $holder holds; '
            '$holder can no longer settle');
      } else if (reservedBy != null && reservedBy != command.txid) {
        // A reservation (the payment coordinator reserves under a payment id
        // before the txid exists, so this may be the transaction's own).
        _log.warning('Transaction ${command.txid} is confirmed in wallet ${command.walletId} and spends input '
            '$key, reserved by $reservedBy');
      }
      final sep = key.lastIndexOf(':');
      final vout = sep > 0 ? int.tryParse(key.substring(sep + 1)) : null;
      if (vout == null) continue;
      events.add(UTXOSpentEvent(
        walletId: command.walletId,
        txid: key.substring(0, sep),
        vout: vout,
        spentInTxId: command.txid,
        version: currentState.version + events.length + 1,
        timestamp: DateTime.now(),
      ));
    }
    if (events.isNotEmpty) {
      _log.info('Transaction ${command.txid} confirmed in wallet ${command.walletId}: '
          '${events.length} input(s) it spends were still unspent and are spent now');
    }

    // Its outputs are in a block: a pending one of this wallet's becomes
    // spendable (bead libspiffy-fggl). A pending UTXO under a reservation
    // keeps the reservation and is available once it is released, as
    // MarkUTXOAvailableCommand does it (UTXOLedger.markAvailable).
    for (final entry in currentState.utxos.entries) {
      final utxo = entry.value;
      if (utxo.txid != command.txid) continue;
      final pendingUnderReservation =
          utxo.status == UTXOStatus.reserved && utxo.statusBeforeReservation == UTXOStatus.pending;
      // A voided output of this transaction (its change, after the payment
      // was cancelled, failed or reclaimed) is promoted too: the proof says
      // the transaction is mined after all (bead libspiffy-3arz).
      if (utxo.status != UTXOStatus.pending && utxo.status != UTXOStatus.voided && !pendingUnderReservation) {
        continue;
      }
      events.add(UTXOMarkedAvailableEvent(
        walletId: command.walletId,
        txid: utxo.txid,
        vout: utxo.vout,
        version: currentState.version + events.length + 1,
        timestamp: DateTime.now(),
      ));
    }

    events.add(TransactionConfirmedEvent(
      walletId: command.walletId,
      txid: command.txid,
      blockHeight: command.blockHeight,
      blockHash: command.blockHash,
      bumpHex: command.bumpHex,
      version: currentState.version + events.length + 1,
      timestamp: DateTime.now(),
    ));
    return events;
  }

  /// Take back a confirmation whose block left the active chain or whose
  /// proof does not match its block header (audit 3b0).
  static List<Event> revertConfirmation(WalletState currentState, RevertTransactionConfirmationCommand command) {
    if (!currentState.isCreated) {
      throw StateError('Cannot revert a confirmation for non-existent wallet');
    }
    return [
      TransactionConfirmationRevertedEvent(
        walletId: command.walletId,
        txid: command.txid,
        blockHeight: command.blockHeight,
        blockHash: command.blockHash,
        merkleProof: command.merkleProof,
        reason: command.reason,
        version: currentState.version + 1,
        timestamp: DateTime.now(),
      )
    ];
  }

  static List<Event> updateStatus(WalletState currentState, UpdateTransactionStatusCommand command) {
    if (!currentState.isCreated) {
      throw StateError('Cannot update transaction status for non-existent wallet');
    }

    return [
      TransactionStatusUpdatedEvent(
        walletId: command.walletId,
        txid: command.txid,
        newStatus: command.newStatus,
        version: currentState.version + 1,
        timestamp: DateTime.now(),
      )
    ];
  }

  static List<Event> broadcast(WalletState currentState, BroadcastTransactionCommand command) {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot broadcast transaction for non-existent wallet');
    }

    final event = TransactionBroadcastEvent(
      walletId: command.walletId,
      txid: command.transactionId,
      broadcastResponse: 'broadcast_success', // Placeholder - will be set by ARC service
      version: currentState.version + 1,
      timestamp: DateTime.now(),
    );

    return [event];
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  /// The transaction records under metadata[[key]] in [state], keyed by
  /// txid (audit 2026-09-14 M7: they were lists appended on every event and
  /// searched linearly). A list-shaped value (state built before the change)
  /// is converted, and the converted records are stored in [state].
  static PersistentMap<String, dynamic> _transactionRecords(WalletStateBuilder state, String key) {
    final existing = state.metadata[key];
    if (existing is PersistentMap<String, dynamic>) return existing;
    var records = PersistentMap<String, dynamic>.empty();
    if (existing is Map) {
      existing.forEach((txid, record) => records = records.put(txid.toString(), freezeDeep(record)));
    } else if (existing is List) {
      for (final record in existing) {
        if (record is Map && record['txid'] != null) {
          records = records.put(record['txid'].toString(), freezeDeep(record));
        }
      }
    }
    state.metadata = state.metadata.put(key, records);
    return records;
  }

  static void applyImported(WalletStateBuilder state, TransactionImportedEvent event) {
    // Store imported transaction in metadata (for audit/history). Records
    // keep first-import order. A repeated import of the same txid keeps the
    // first import time and takes the latest block height — unless a merkle
    // proof already confirmed it (bead libspiffy-73bj), or the re-delivery
    // carries no proof at all (bead libspiffy-nys0): a delivery with no
    // proof says nothing about which block the transaction is in, so it may
    // not take away a height an earlier proof established, the same rule
    // bead libspiffy-7dj gives the read model's row. Records written before
    // 73bj carry no 'status', so older journals keep taking the latest
    // height as they always did.
    //
    // No height is written at all when none is known: 'blockHeight' absent
    // is how a transaction nothing proves is recorded, and it is the shape
    // [applyConfirmationReverted] leaves behind (bead libspiffy-nys0 —
    // height 0 is the genesis block, not an absence).
    final records = _transactionRecords(state, _importedTransactionsKey);
    final existing = records[event.txid];
    final PersistentMap<String, dynamic> record;
    if (existing is Map) {
      final confirmed = existing['status'] == 'confirmed';
      final height =
          confirmed || event.blockHeight == null ? existing['blockHeight'] : event.blockHeight;
      final withTime = frozenRecord(existing).put('lastImportedAt', event.timestamp.toIso8601String());
      record = height == null ? withTime.without('blockHeight') : withTime.put('blockHeight', height);
    } else {
      record = freezeMap(<String, dynamic>{
        'txid': event.txid,
        if (event.blockHeight != null) 'blockHeight': event.blockHeight,
        'importedAt': event.timestamp.toIso8601String(),
      });
    }
    state.metadata = state.metadata.put(_importedTransactionsKey, records.put(event.txid, record));

    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  static void applyRecorded(WalletStateBuilder state, TransactionRecordedEvent event) {
    // Store outgoing transaction in metadata (for audit/history)
    // Status starts as PENDING - will be updated to CONFIRMED when recipient accepts
    final records = _transactionRecords(state, _outgoingTransactionsKey);
    final details = freezeMap(<String, dynamic>{
      'txid': event.txid,
      'recipientAddresses': event.recipientAddresses,
      'paymentAmount': event.paymentAmount,
      'fee': event.fee,
      'spentUtxoKeys': List<String>.from(event.spentUtxoKeys),
      'recordedAt': event.timestamp.toIso8601String(),
    });
    final existing = records[event.txid];
    final PersistentMap<String, dynamic> record;
    if (existing is Map) {
      // Recorded again: refresh the details; keep the first record time and
      // any confirmation.
      record = frozenRecord(existing).putAll(details).put('recordedAt', existing['recordedAt'] ?? details['recordedAt']);
    } else {
      record = details.put('status', 'pending');
    }
    state.metadata = state.metadata.put(_outgoingTransactionsKey, records.put(event.txid, record));

    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  /// The transaction is no longer confirmed: back to pending in the
  /// transaction metadata, and its UTXOs lose their confirmations. A UTXO
  /// that was spendable because of the proof becomes pending (a reserved one
  /// returns to pending on release); spent UTXOs are left alone.
  static void applyConfirmationReverted(WalletStateBuilder state, TransactionConfirmationRevertedEvent event) {
    DeferredPayments.applyConfirmationReverted(state, event.txid);
    // Both records, so a received transaction whose block left the chain can
    // be confirmed again when a proof puts it back (bead libspiffy-73bj). A
    // record that never reached 'confirmed' is left exactly as it is, so
    // older journals revert nothing they did not revert before.
    for (final key in const [_outgoingTransactionsKey, _importedTransactionsKey]) {
      if (state.metadata[key] == null) continue; // no records of that kind to revert
      final records = _transactionRecords(state, key);
      final record = records[event.txid];
      if (record is! Map || record['status'] != 'confirmed') continue;
      final reverted =
          frozenRecord(record).put('status', 'pending').without('blockHeight').without('blockHash').without('confirmedAt');
      state.metadata = state.metadata.put(key, records.put(event.txid, reverted));
    }

    for (final entry in state.utxos.entries.toList()) {
      final utxo = entry.value;
      if (utxo.txid != event.txid || utxo.status == UTXOStatus.spent) continue;
      state.putUtxo(
          entry.key,
          BitcoinUtxo(
            txid: utxo.txid,
            vout: utxo.vout,
            value: utxo.value,
            scriptPubKey: utxo.scriptPubKey,
            address: utxo.address,
            status: utxo.status == UTXOStatus.available ? UTXOStatus.pending : utxo.status,
            blockHeight: null,
            confirmations: 0,
            createdAt: utxo.createdAt,
            updatedAt: event.timestamp,
            reservedByTxId: utxo.reservedByTxId,
            reservationExpiresAt: utxo.reservationExpiresAt,
            reservationPriority: utxo.reservationPriority,
            reservationReason: utxo.reservationReason,
            derivationIndex: utxo.derivationIndex,
            pluginMetadata: utxo.pluginMetadata,
            statusBeforeReservation:
                utxo.statusBeforeReservation == UTXOStatus.available ? UTXOStatus.pending : utxo.statusBeforeReservation,
            spentInTxId: utxo.spentInTxId,
          ));
    }

    state.version = event.version;
    state.lastModified = event.timestamp;
  }

  /// The transaction is mined: its record takes the confirmation, and every
  /// output of it the wallet holds takes the block the proof puts it in
  /// (bead libspiffy-4dja — the transaction row said height N while its own
  /// output said null).
  ///
  /// A height on a UTXO means a verified proof backs it (bead
  /// libspiffy-5ry), so this is the only way one reaches an output after it
  /// was received: [TransactionConfirmedEvent.blockHeight] is journaled from
  /// [ConfirmTransactionCommand], whose senders all derive it from a BUMP
  /// checked against our own header chain. Being spendable is a separate
  /// question with its own path — `UTXOMarkedAvailableEvent` carries no
  /// height — so an output ARC reports only as seen on the network becomes
  /// available with no block, which is exactly right.
  ///
  /// No count of confirmations is stored: it would be stale at the next
  /// block and nothing journals an event per block. The count is
  /// `tip height - blockHeight + 1` wherever it is wanted.
  ///
  /// The inverse of [applyConfirmationReverted], which takes the height off
  /// again, and spent UTXOs are skipped here for the same reason they are
  /// skipped there: a spent row is history.
  static void applyConfirmed(WalletStateBuilder state, TransactionConfirmedEvent event) {
    DeferredPayments.applyConfirmed(state, event.txid, event.timestamp);
    final provenHeight = event.blockHeight;
    if (provenHeight != null) {
      for (final entry in state.utxos.entries.toList()) {
        final utxo = entry.value;
        if (utxo.txid != event.txid || utxo.status == UTXOStatus.spent) continue;
        if (utxo.blockHeight == provenHeight) continue;
        state.putUtxo(entry.key, utxo.copyWith(blockHeight: provenHeight, updatedAt: event.timestamp));
      }
    }
    // Update transaction status from PENDING to CONFIRMED, in whichever
    // record the wallet keeps of the transaction: the one it sent, the one
    // it received, or both (bead libspiffy-73bj). A record written before
    // that bead carries no 'status', so replaying an older journal reaches
    // the same decisions it always did; the imported record simply gains the
    // confirmation the write model used to drop.
    for (final key in const [_outgoingTransactionsKey, _importedTransactionsKey]) {
      if (state.metadata[key] == null) continue; // no records of that kind to update
      final records = _transactionRecords(state, key);
      final record = records[event.txid];
      if (record is! Map) continue;
      final confirmed = frozenRecord(record)
          .put('status', 'confirmed')
          .put('blockHeight', event.blockHeight)
          .put('blockHash', event.blockHash)
          .put('confirmedAt', event.timestamp.toIso8601String());
      state.metadata = state.metadata.put(key, records.put(event.txid, confirmed));
    }

    state.version = event.version;
    state.lastModified = event.timestamp;
  }
}
