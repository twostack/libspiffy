import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:eventador/eventador.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/services/script_type_registry.dart';
import 'package:logging/logging.dart';
import '../core/wallet/state_records.dart';
import '../core/wallet_events.dart';
import '../models/wallet_event.dart';
import '../models/wallet_type.dart';
import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../models/address_metadata.dart';
import '../models/transaction_address_link.dart';
import '../models/deferred_payment.dart';
import '../services/watch_only_funds.dart' show splitBalanceUtxos;
import '../storage/read_model_storage.dart';
import '../spv/merkle_proof_header_check.dart';
import '../utils/bump.dart';
import '../utils/network_name.dart';

/// Wallet projection that builds read models from wallet events
/// 
/// This projection subscribes to wallet events from the EventStore and
/// maintains denormalized read models in Isar for fast queries.
/// Separates write concerns (aggregate) from read concerns (queries).
/// 
/// STATELESS DESIGN: This projection does NOT cache state in memory.
/// Storage (Isar) is the source of truth. Checkpoints track which events
/// have been processed, but all state is read from/written to storage.
/// This design survives app restarts correctly - no checkpoint/state mismatch.
class WalletProjection extends Projection<void> {
  final _log = Logger('WalletProjection');
  final ReadModelStorage _storage;
  final String _projectionId;
  int _checkpoint = 0;
  
  // NOTE: No in-memory state caching. Storage IS the read model.
  // This prevents checkpoint/state mismatch bugs on restart.
  
  WalletProjection({
    required String projectionId,
    required EventStore eventStore,
    required ReadModelStorage storage,
  })  : _storage = storage,
        _projectionId = projectionId,
        super();
  
  @override
  String get projectionId => _projectionId;
  
  @override
  void get readModel => null; // Storage is the read model, query it directly
  
  @override
  List<Type> get interestedEventTypes => [
        WalletCreatedEvent,
        WalletDeletedEvent,
        WalletConfigurationUpdatedEvent,
        AddressGeneratedEvent,
        AddressDiscoveredEvent,
        AddressLabelUpdatedEvent,
        WatchAddressAddedEvent,
        UTXOReceivedEvent,
        UTXOMarkedAvailableEvent,
        UTXOSpentEvent,
        UTXOConfirmationUpdatedEvent,
        UTXOReservedEvent,
        UTXOReleasedEvent,
        UTXOReservationRenewedEvent,
        TransactionImportedEvent,
        TransactionRecordedEvent,
        TransactionConfirmedEvent,
        TransactionStatusUpdatedEvent,
        TransactionConfirmationRevertedEvent,
        TransactionSpendDeferredEvent,
        TransactionNetworkStatusCheckedEvent,
        DeferredTransactionFailedEvent,
        DeferredTransactionCancelledEvent,
        DeferredSpendReclaimedEvent,
      ];
  
  @override
  Future<int> getCheckpoint() async {
    // Checkpoint persistence is now handled automatically by ProjectionManager
    // This is only used as a fallback if ProjectionManager doesn't have Isar
    return _checkpoint;
  }
  
  @override
  Future<void> updateCheckpoint(int checkpoint) async {
    // Checkpoint persistence is now handled automatically by ProjectionManager
    // We just maintain an in-memory checkpoint for backward compatibility
    _checkpoint = checkpoint;
  }
  
  @override
  Future<void> rebuild() async {
    await reset();
    // Projection manager will replay events after rebuild
  }
  
  /// Applies [event] to the read model.
  ///
  /// Contract (audit M2):
  /// - **Tolerant.** Under eventador's ProjectionActor a handler that throws
  ///   has its event skipped for good (the checkpoint later moves past it and
  ///   awaiters never resolve), so a missing read-model row must never throw.
  ///   Where the event carries the data, the missing row is rebuilt from it;
  ///   otherwise the gap is logged at WARNING and the event is acknowledged.
  ///   Storage failures (the backend itself throwing) still propagate.
  /// - **Idempotent.** Applying the same event again (replay after a lagging
  ///   checkpoint, rebuild over existing rows) leaves the read model as one
  ///   application did. Every derived value is written as an absolute value
  ///   recomputed from the UTXO rows, never as a delta; see [_syncAddress].
  @override
  Future<bool> handle(Event event) async {
    if (event is! WalletEvent) {
      return false;
    }

    switch (event) {
      case final WalletCreatedEvent evt:
        await _handleWalletCreated(evt);
        return true;
      case final WalletDeletedEvent evt:
        await _handleWalletDeleted(evt);
        return true;
      case final WalletConfigurationUpdatedEvent evt:
        await _handleWalletConfigurationUpdated(evt);
        return true;
      case final AddressGeneratedEvent evt:
        await _handleAddressGenerated(evt);
        return true;
      case final AddressDiscoveredEvent evt:
        await _handleAddressDiscovered(evt);
        return true;
      case AddressLabelUpdatedEvent():
        // Label updates don't affect read model statistics
        return true;
      case final WatchAddressAddedEvent evt:
        await _handleWatchAddressAdded(evt);
        return true;
      case final UTXOReceivedEvent evt:
        await _handleUTXOReceived(evt);
        return true;
      case final UTXOMarkedAvailableEvent evt:
        await _handleUTXOMarkedAvailable(evt);
        return true;
      case final UTXOSpentEvent evt:
        await _handleUTXOSpent(evt);
        return true;
      case final UTXOConfirmationUpdatedEvent evt:
        await _handleUTXOConfirmationUpdated(evt);
        return true;
      case final UTXOReservedEvent evt:
        await _handleUTXOReserved(evt);
        return true;
      case final UTXOReleasedEvent evt:
        await _handleUTXOReleased(evt);
        return true;
      case final UTXOReservationRenewedEvent evt:
        await _handleUTXOReservationRenewed(evt);
        return true;
      case final TransactionImportedEvent evt:
        await _handleTransactionImported(evt);
        return true;
      case final TransactionRecordedEvent evt:
        await _handleTransactionRecorded(evt);
        return true;
      case final TransactionConfirmedEvent evt:
        await _handleTransactionConfirmed(evt);
        return true;
      case final TransactionStatusUpdatedEvent evt:
        await _handleTransactionStatusUpdated(evt);
        return true;
      case final TransactionConfirmationRevertedEvent evt:
        await _handleTransactionConfirmationReverted(evt);
        return true;
      case final TransactionSpendDeferredEvent evt:
        await _handleTransactionSpendDeferred(evt);
        return true;
      case final TransactionNetworkStatusCheckedEvent evt:
        await _handleNetworkStatusChecked(evt);
        return true;
      case final DeferredTransactionFailedEvent failed:
        await _handleDeferredResolution(failed, failed.txid, DeferredPaymentState.failed,
            failed.releasedInputs, failed.reason ?? failed.networkStatus);
        return true;
      case final DeferredTransactionCancelledEvent cancelled:
        await _handleDeferredResolution(cancelled, cancelled.txid, DeferredPaymentState.cancelled,
            cancelled.releasedInputs, cancelled.reason);
        return true;
      case final DeferredSpendReclaimedEvent reclaimed:
        await _handleDeferredSpendReclaimed(reclaimed);
        return true;
      default:
        return false;
    }
  }
  
  Future<void> _handleWalletCreated(WalletCreatedEvent event) async {
    // Root address first, with a single lookup: SPVActor.isWalletAddress
    // reads it as soon as the coordinator reports the wallet created, and
    // that report does not wait for this projection. An existing row means
    // a replay; it is left as is so its usage and balance survive.
    final existingRoot = await _storage.getAddressMetadata(event.walletId, event.rootAddress);
    if (existingRoot == null) {
      await _storage.upsertAddress(event.walletId, AddressMetadata(
        address: event.rootAddress,
        scriptType: 'p2pkh',
        derivationPath: 'm/0/0', // First receiving address
        derivationIndex: 0,
        isChange: false,
        label: 'Root address (m/0/0)',
        purpose: 'receive',
        firstUsedAt: null,
        lastUsedAt: null,
        usageCount: 0,
        balance: BigInt.zero,
        createdAt: event.timestamp,
        isWatched: true,
      ));
    }
    final replay = existingRoot != null || await _storage.getWallet(event.walletId) != null;

    // Store wallet metadata directly to storage (no in-memory caching)
    await _storage.storeWallet(
      event.walletId,
      event.walletName,
      rootAddress: event.rootAddress,
      networkType: NetworkName.canonical(event.walletMetadata?['network'] as String?),
      metadata: {
        // Reserved keys in a creation journaled before they were rejected
        // are not written (bead libspiffy-hfai).
        ...WalletMetadataKeys.hostEntries(event.walletMetadata ?? const {}, creation: true),
        'walletType': event.walletType.toStorageString(),
        'confirmedBalance': '0',
        'unconfirmedBalance': '0',
        'totalBalance': '0',
        'addressCount': 1,
        'utxoCount': 0,
        'availableUtxoCount': 0,
        'lastUpdated': event.timestamp.toIso8601String(),
      },
    );

    // A replayed creation must not zero the balances and counts that later
    // events already derived: recompute them from the rows.
    if (replay) {
      await _updateWalletAddressCount(event.walletId, event.timestamp);
      await _recalculateAndPersistForWallet(event.walletId, event.timestamp);
    }
  }

  Future<void> _handleWalletDeleted(WalletDeletedEvent event) async {
    await _storage.deleteWallet(event.walletId);
  }

  Future<void> _handleWalletConfigurationUpdated(WalletConfigurationUpdatedEvent event) async {
    // Read current wallet from storage
    final existingWallet = await _storage.getWallet(event.walletId);
    if (existingWallet == null) {
      _log.warning('WalletConfigurationUpdated for ${event.walletId}: no wallet row; skipped');
      return;
    }

    // Update wallet metadata in storage
    final existingMetadata = existingWallet['metadata'] as Map<String, dynamic>? ?? {};
    await _storage.storeWallet(
      event.walletId,
      event.newName ?? existingWallet['name'] as String,
      rootAddress: existingWallet['rootAddress'] as String?,
      networkType: (existingWallet['network'] ?? existingWallet['networkType']) as String?,
      metadata: {
        ...existingMetadata,
        // Reserved keys in an update journaled before they were rejected
        // do not overwrite derived values (bead libspiffy-hfai).
        if (event.newMetadata != null) ...WalletMetadataKeys.hostEntries(event.newMetadata!),
        'lastUpdated': event.timestamp.toIso8601String(),
      },
    );
  }
  
  Future<void> _handleAddressGenerated(AddressGeneratedEvent event) async {
    
    // Store address in AddressEntity
    final metadata = await _preservingUsage(event.walletId, AddressMetadata(
      address: event.address,
      scriptType: 'p2pkh', // Standard HD wallet addresses are P2PKH
      derivationPath: null, // AddressGeneratedEvent doesn't include derivation path
      derivationIndex: event.derivationIndex,
      isChange: event.purpose == 'change',
      label: event.label,
      purpose: event.purpose ?? 'receive',
      firstUsedAt: null,
      lastUsedAt: null,
      usageCount: 0,
      balance: BigInt.zero,
      createdAt: event.timestamp,
      isWatched: true,
    ));
    await _storage.upsertAddress(event.walletId, metadata);
    
    // Update wallet metadata with new address count (read from storage, update, write back)
    final row = await _updateWalletAddressCount(event.walletId, event.timestamp);
    await _recalculateForNewKey(event.walletId, row, event.timestamp);
  }
  
  Future<void> _handleAddressDiscovered(AddressDiscoveredEvent event) async {
    
    // Store discovered address in AddressEntity
    final metadata = await _preservingUsage(event.walletId, AddressMetadata(
      address: event.address,
      scriptType: 'p2pkh', // Discovered addresses are typically P2PKH
      derivationPath: null,
      derivationIndex: event.derivationIndex,
      isChange: event.isChange,
      label: 'Imported (${event.isChange ? 'change' : 'receive'} #${event.derivationIndex})',
      purpose: event.isChange ? 'change' : 'receive',
      firstUsedAt: null,
      lastUsedAt: null,
      usageCount: event.transactionCount,
      balance: BigInt.zero,
      createdAt: event.timestamp,
      isWatched: true,
    ));
    await _storage.upsertAddress(event.walletId, metadata);
    
    // Update wallet metadata with new address count (read from storage, update, write back)
    final row = await _updateWalletAddressCount(event.walletId, event.timestamp);
    await _recalculateForNewKey(event.walletId, row, event.timestamp);
  }

  /// Wallet row metadata key: the number of unspent bare multisig UTXOs the
  /// wallet's keys cannot spend alone ([_recalculateAndPersistForWallet]).
  static const String _notSpendableAloneUtxoCount = 'notSpendableAloneUtxoCount';

  /// Recomputes the wallet row's balances after the wallet gained the key of
  /// a new address (row metadata [row]) when that can change them (bead
  /// libspiffy-hccp): a bare multisig UTXO the wallet could not spend alone
  /// may be spendable with the new key, as it is at once for the aggregate
  /// and `getBalance`. Only a wallet whose row counts such a UTXO is
  /// recomputed; a row written before the count was stored is recomputed
  /// once when it has UTXOs, which stores the count. Other wallets' address
  /// events load no UTXO rows.
  Future<void> _recalculateForNewKey(String walletId, Map<String, dynamic>? row, DateTime timestamp) async {
    if (row == null) return;
    final count = row[_notSpendableAloneUtxoCount];
    if (count == null ? (row['utxoCount'] ?? 0) == 0 : count == 0) return;
    await _recalculateAndPersistForWallet(walletId, timestamp);
  }

  /// The watch address row (bead libspiffy-p4kv). An existing row (a replay,
  /// or the row a reconciled legacy registration was read from) keeps its
  /// usage, balance and creation time.
  Future<void> _handleWatchAddressAdded(WatchAddressAddedEvent event) async {
    final metadata = await _preservingUsage(event.walletId, AddressMetadata(
      address: event.address,
      scriptType: event.scriptType,
      isChange: false,
      label: event.label,
      purpose: 'watch',
      usageCount: 0,
      balance: BigInt.zero,
      createdAt: event.registeredAt,
      isWatched: true,
    ));
    await _storage.upsertAddress(event.walletId, metadata);
    await _updateWalletAddressCount(event.walletId, event.timestamp);
    // UTXO rows at the address may exist already (a legacy registration
    // journaled on load): they are watch-only from now on (bead
    // libspiffy-vsap).
    await _recalculateAndPersistForWallet(event.walletId, event.timestamp);
  }

  /// Helper: Update wallet address count by reading current count from storage.
  /// Returns the metadata written, null when there is no wallet row.
  Future<Map<String, dynamic>?> _updateWalletAddressCount(String walletId, DateTime timestamp) async {
    final existingWallet = await _storage.getWallet(walletId);
    if (existingWallet == null) {
      _log.warning('No wallet row for $walletId; address count not updated');
      return null;
    }
    
    // Get actual address count from storage
    final addresses = await _storage.getWalletAddresses(walletId);
    final addressCount = addresses.length;
    
    // Update wallet metadata
    final existingMetadata = existingWallet['metadata'] as Map<String, dynamic>? ?? {};
    final metadata = {
      ...existingMetadata,
      'addressCount': addressCount,
      'lastUpdated': timestamp.toIso8601String(),
    };
    await _storage.storeWallet(
      walletId,
      existingWallet['name'] as String,
      rootAddress: existingWallet['rootAddress'] as String?,
      networkType: (existingWallet['network'] ?? existingWallet['networkType']) as String?,
      metadata: metadata,
    );
    return metadata;
  }
  
  Future<void> _handleUTXOReceived(UTXOReceivedEvent event) async {
    
    // Look up derivation index from address metadata
    int? derivationIndex;
    Map<String, dynamic>? scriptMetadata;

    // Extract script metadata for all received UTXOs (needed for plugin UTXO storage)
    if (event.scriptPubKey.isNotEmpty) {
      try {
        final walletMeta = await _storage.getWallet(event.walletId);
        // Backends return the network under 'network' (Isar, Postgres) or
        // 'networkType' (in-memory); 'network_type' was never a key.
        final networkType = NetworkName.toDartsv(
            (walletMeta?['network'] ?? walletMeta?['networkType']) as String?);

        final script = dartsv.SVScript.fromHex(event.scriptPubKey);
        final scriptRegistry = ScriptTypeRegistry(networkType: networkType);
        scriptMetadata = scriptRegistry.extractScriptMetadata(script);
      } catch (_) {}
    }

    if (event.address.isNotEmpty) {
      final addressMeta = await _storage.getAddressMetadata(event.walletId, event.address);
      if (addressMeta != null) {
        derivationIndex = addressMeta.derivationIndex;
      } else {
        // Address doesn't exist yet - create it!
        // This can happen for payment channel addresses or other externally generated addresses
        String scriptType = scriptMetadata?['scriptType'] as String? ?? 'unknown';

        // Created empty: _syncAddress below records the first use and the
        // balance exactly once (audit H5).
        final newAddressMeta = AddressMetadata(
          address: event.address,
          scriptType: scriptType,
          derivationPath: null,
          derivationIndex: null,
          isChange: false,
          label: 'Received UTXO ($scriptType)',
          purpose: 'receive',
          firstUsedAt: null,
          lastUsedAt: null,
          usageCount: 0,
          balance: BigInt.zero,
          createdAt: event.timestamp,
          isWatched: true,
        );
        await _storage.upsertAddress(event.walletId, newAddressMeta);

        // Update wallet address count since we just added a new address
        await _updateWalletAddressCount(event.walletId, event.timestamp);
      }
    }

    // A row that already exists means this receipt was applied before (the
    // aggregate rejects duplicate UTXOs): leave the row alone so a replay
    // does not regress a later spent/reserved/confirmed state, and do not
    // count the address use again.
    final rows = await _loadUtxoRows(event.walletId);
    final existing = rows.find(event.txid, event.vout);
    if (existing == null) {
      final utxo = BitcoinUtxo.create(
        txid: event.txid,
        vout: event.vout,
        satoshis: BigInt.from(event.satoshis),
        scriptPubKey: event.scriptPubKey,
        address: event.address,
        blockHeight: event.blockHeight,
        confirmations: event.confirmations ?? 0,
        status: event.initialStatus,
        derivationIndex: derivationIndex,
        // The script analysis, and over it the metadata the UTXO was
        // received with: a plugin id the event names (a funding earmark on
        // a P2PKH output) makes the row plugin-managed, as on the wallet
        // aggregate (bead libspiffy-ecy8). The analysis alone dropped it.
        pluginMetadata: event.pluginMetadata == null ? scriptMetadata : {...?scriptMetadata, ...event.pluginMetadata!},
        createdAt: event.timestamp,
      );
      await _storage.upsertUTXO(event.walletId, utxo);
      rows.put(utxo);
    }

    await _stampCounterpartyMarker(event.walletId, event.txid, event.counterpartyMarker);

    await _syncAddress(event.walletId, event.address, rows.all,
        newUseAt: existing == null ? event.timestamp : null);
    await _recalculateAndPersistForWallet(event.walletId, event.timestamp, rows.all);
  }

  /// Records [marker] on the transaction row of [txid] (bead libspiffy-cq16).
  ///
  /// A receive names its counterparty on the UTXO event; the payment's own
  /// row is written by the sibling TransactionImportedEvent, which carries
  /// the same marker, so this only has to cover the order in which the row
  /// already exists without one (a transaction of ours whose output a
  /// counterparty later pays back to us, a receive replayed after the row
  /// was written). Nothing is created here: a receive with no row yet leaves
  /// none. The marker is set once and never replaced
  /// ([TransactionRowRules.counterpartyMarkerAfter]), so a replay converges
  /// and a second receipt naming somebody else cannot overwrite it.
  Future<void> _stampCounterpartyMarker(String walletId, String txid, String? marker) async {
    if (marker == null || marker.isEmpty) return;
    final existing = await _storage.getTransaction(txid, walletId: walletId);
    if (existing == null || (existing.counterpartyMarker ?? '').isNotEmpty) return;
    await _storage.storeTransaction(walletId, existing.copyWith(counterpartyMarker: marker));
  }

  /// The wallet's UTXO rows (spent included), loaded once per event.
  ///
  /// Each UTXO handler used to load every row twice: once to find the row
  /// the event is about and again to recompute the balances (audit
  /// 2026-09-14 M7). Handlers now load once, find the row in memory, and
  /// apply their own write to the loaded rows ([_UtxoRows.put]) instead of
  /// reading them back. ReadModelStorage has no single-outpoint lookup, so
  /// one full load per event remains.
  Future<_UtxoRows> _loadUtxoRows(String walletId) async =>
      _UtxoRows(await _storage.getUTXOs(walletId, includeSpent: true));

  /// Logs a UTXO event whose row the read model does not have. None of the
  /// UTXO status events carries amount, script or address, so the row cannot
  /// be rebuilt from them; the event is acknowledged rather than thrown.
  void _warnMissingUtxo(WalletEvent event, String txid, int vout) {
    _log.warning('${event.runtimeType} for ${event.walletId} $txid:$vout: '
        'UTXO not in the read model; event acknowledged without changes');
  }

  /// Sets [address]'s balance to the sum of its unspent UTXO rows in [utxos]
  /// and, when [newUseAt] is given, records one more use.
  ///
  /// Idempotency design (audit M2): the balance is recomputed from the UTXO
  /// rows (absolute, so replaying any event converges), and the usage count
  /// moves only when a UTXO row is created, which happens once per outpoint.
  /// Rows are written through upsertAddress, not updateAddressUsage, so the
  /// result does not depend on a backend's increment semantics.
  Future<void> _syncAddress(
    String walletId,
    String address,
    List<BitcoinUtxo> utxos, {
    DateTime? newUseAt,
  }) async {
    if (address.isEmpty) return;
    final meta = await _storage.getAddressMetadata(walletId, address);
    if (meta == null) {
      _log.warning('No address row for $walletId $address; balance not updated');
      return;
    }
    var balance = BigInt.zero;
    for (final u in utxos) {
      if (u.address == address && u.status != UTXOStatus.spent) {
        balance += u.satoshis;
      }
    }
    if (balance == meta.balance && newUseAt == null) return;

    final lastUsedAt = newUseAt != null &&
            (meta.lastUsedAt == null || newUseAt.isAfter(meta.lastUsedAt!))
        ? newUseAt
        : meta.lastUsedAt;
    await _storage.upsertAddress(
      walletId,
      _copyAddress(
        meta,
        balance: balance,
        usageCount: meta.usageCount + (newUseAt != null ? 1 : 0),
        firstUsedAt: meta.firstUsedAt ?? newUseAt,
        lastUsedAt: lastUsedAt,
      ),
    );
  }

  /// [fresh] with the usage statistics of the address row that already
  /// exists, so a replayed address/wallet creation does not zero them.
  Future<AddressMetadata> _preservingUsage(String walletId, AddressMetadata fresh) async {
    final existing = await _storage.getAddressMetadata(walletId, fresh.address);
    if (existing == null) return fresh;
    return _copyAddress(
      fresh,
      derivationPath: fresh.derivationPath ?? existing.derivationPath,
      derivationIndex: fresh.derivationIndex ?? existing.derivationIndex,
      usageCount: fresh.usageCount > existing.usageCount ? fresh.usageCount : existing.usageCount,
      balance: existing.balance,
      firstUsedAt: existing.firstUsedAt,
      lastUsedAt: existing.lastUsedAt,
      createdAt: existing.createdAt,
    );
  }

  static AddressMetadata _copyAddress(
    AddressMetadata m, {
    String? derivationPath,
    int? derivationIndex,
    int? usageCount,
    BigInt? balance,
    DateTime? firstUsedAt,
    DateTime? lastUsedAt,
    DateTime? createdAt,
  }) =>
      AddressMetadata(
        address: m.address,
        scriptType: m.scriptType,
        derivationPath: derivationPath ?? m.derivationPath,
        derivationIndex: derivationIndex ?? m.derivationIndex,
        isChange: m.isChange,
        label: m.label,
        purpose: m.purpose,
        firstUsedAt: firstUsedAt ?? m.firstUsedAt,
        lastUsedAt: lastUsedAt ?? m.lastUsedAt,
        usageCount: usageCount ?? m.usageCount,
        balance: balance ?? m.balance,
        createdAt: createdAt ?? m.createdAt,
        isWatched: m.isWatched,
      );

  Future<void> _handleUTXOMarkedAvailable(UTXOMarkedAvailableEvent event) async {
    final rows = await _loadUtxoRows(event.walletId);
    final utxo = rows.find(event.txid, event.vout);
    if (utxo == null) {
      _warnMissingUtxo(event, event.txid, event.vout);
      return;
    }

    // A voided output is promoted too (bead libspiffy-3arz): its transaction
    // turned out to be mined after all, and a proof outranks the resolution
    // that voided it.
    if (utxo.status == UTXOStatus.pending || utxo.status == UTXOStatus.voided) {
      final updatedUtxo = utxo.markAvailable(timestamp: event.timestamp);
      await _storage.upsertUTXO(event.walletId, updatedUtxo);
      rows.put(updatedUtxo);
      await _recalculateAndPersistForWallet(event.walletId, event.timestamp, rows.all);
    }
  }

  Future<void> _handleUTXOSpent(UTXOSpentEvent event) async {
    final rows = await _loadUtxoRows(event.walletId);
    final utxo = rows.find(event.txid, event.vout);
    if (utxo == null) {
      _warnMissingUtxo(event, event.txid, event.vout);
      return;
    }

    if (utxo.status != UTXOStatus.spent) {
      final spent = utxo.markSpent(timestamp: event.timestamp, spentInTxId: event.spentInTxId);
      await _storage.upsertUTXO(event.walletId, spent);
      rows.put(spent);
    }

    // Address balance and wallet totals are recomputed from the rows, so a
    // replayed spend cannot debit twice.
    await _syncAddress(event.walletId, utxo.address, rows.all);
    await _recalculateAndPersistForWallet(event.walletId, event.timestamp, rows.all);
    await _markDeferredSeen(event.walletId, event.spentInTxId, event.timestamp);
    // The row says who held it: a reclaim's self-spend whose input something
    // else spent lost the race and is failed now (bead libspiffy-wfvi).
    if (utxo.reservationReason == _deferredHoldReason &&
        utxo.reservedByTxId != null &&
        utxo.reservedByTxId != event.spentInTxId) {
      await _failLostReclaim(event.walletId, utxo.reservedByTxId!, utxo.key, event.spentInTxId, event.timestamp);
    }
  }

  /// A reclaim's self-spend [reclaimTxid] held [utxoKey] and [spentInTxId] —
  /// in practice the recipient's copy of the payment being reclaimed — spent
  /// it. The self-spend can never be mined now, so the reclaim is failed with
  /// the reason (bead libspiffy-wfvi), as the wallet aggregate does it
  /// (`DeferredPayments._failLostReclaim`).
  ///
  /// This is Bitcoin SV: first seen wins and there is no replace-by-fee, so
  /// nothing here looks at or raises a fee and nothing is retried — the race
  /// is over and only the record is left to put right, without waiting for
  /// ARC to report the same thing. Only a reclaim's self-spend resolves this
  /// way; any other deferred payment stays outstanding (bead libspiffy-ey2).
  Future<void> _failLostReclaim(
      String walletId, String reclaimTxid, String utxoKey, String spentInTxId, DateTime at) async {
    final selfSpend = await _storage.getDeferredPayment(walletId, reclaimTxid);
    if (selfSpend == null) return;
    final reclaims = DeferredPaymentPurpose.reclaimedTxid(selfSpend.purpose);
    if (reclaims == null) return; // not a reclaim's self-spend
    if (selfSpend.state != DeferredPaymentState.outstanding) return;
    await _storage.storeDeferredPayment(selfSpend.copyWith(
      state: DeferredPaymentState.failed,
      updatedAt: at,
      resolvedAt: at,
      resolutionReason: DeferredPayment.reclaimLostRace(utxoKey, spentInTxId),
    ));
    final rows = await _loadUtxoRows(walletId);
    if (await _voidOwnOutputs(walletId, reclaimTxid, at, rows)) {
      await _recalculateAndPersistForWallet(walletId, at, rows.all);
    }
    _log.warning('The reclaim $reclaimTxid of deferred payment $reclaims failed in $walletId: its input '
        '$utxoKey was spent by $spentInTxId. First seen wins on this network, so the self-spend can no '
        'longer be mined; no fee would have changed that');
  }

  Future<void> _handleUTXOConfirmationUpdated(UTXOConfirmationUpdatedEvent event) async {
    final rows = await _loadUtxoRows(event.walletId);
    final utxo = rows.find(event.txid, event.vout);
    if (utxo == null) {
      _warnMissingUtxo(event, event.txid, event.vout);
      return;
    }

    // Confirmations and height only; the status moves solely from pending to
    // available (BitcoinUtxo.updateConfirmations, the aggregate's rule).
    // Forcing `available` resurrected spent and reserved UTXOs (audit M1).
    final updatedUtxo = utxo.updateConfirmations(
      blockHeight: event.blockHeight,
      confirmations: event.confirmations,
      timestamp: event.timestamp,
    );

    await _storage.upsertUTXO(event.walletId, updatedUtxo);
    rows.put(updatedUtxo);
    await _recalculateAndPersistForWallet(event.walletId, event.timestamp, rows.all);
  }

  Future<void> _handleUTXOReserved(UTXOReservedEvent event) async {
    final rows = await _loadUtxoRows(event.walletId);
    final utxo = rows.find(event.txid, event.vout);
    if (utxo == null) {
      _warnMissingUtxo(event, event.txid, event.vout);
      return;
    }
    if (utxo.status == UTXOStatus.spent) {
      // Only reachable on replay (the aggregate never reserves a spent UTXO);
      // the later spend wins.
      _log.warning('UTXOReservedEvent for spent UTXO ${event.txid}:${event.vout}; ignored');
      return;
    }

    final updatedUtxo = utxo.copyWith(
      status: UTXOStatus.reserved,
      statusBeforeReservation: utxo.statusToRestoreOnRelease,
      reservedByTxId: event.reservedByTxId,
      reservationExpiresAt: event.expiresAt,
      reservationPriority: event.priority,
      reservationReason: event.reservationReason,
      updatedAt: event.timestamp,
    );
    await _storage.upsertUTXO(event.walletId, updatedUtxo);
    rows.put(updatedUtxo);
    await _recalculateAndPersistForWallet(event.walletId, event.timestamp, rows.all);
  }

  Future<void> _handleUTXOReleased(UTXOReleasedEvent event) async {
    final rows = await _loadUtxoRows(event.walletId);
    final utxo = rows.find(event.txid, event.vout);
    if (utxo == null) {
      _warnMissingUtxo(event, event.txid, event.vout);
      return;
    }

    if (utxo.status == UTXOStatus.reserved) {
      // The aggregate records the restored status on the event (audit M4).
      // Older events carry none and release to available, as they did when
      // journaled (the aggregate replays them the same way).
      final updatedUtxo = utxo.releaseReservation(
        restoreStatus: event.restoredStatus ?? UTXOStatus.available,
        timestamp: event.timestamp,
      );
      await _storage.upsertUTXO(event.walletId, updatedUtxo);
      rows.put(updatedUtxo);
      await _recalculateAndPersistForWallet(event.walletId, event.timestamp, rows.all);
    }
  }

  /// A renewed reservation: the new expiry (and reason) on the reserved
  /// row, as the aggregate applies it. Balances do not change.
  Future<void> _handleUTXOReservationRenewed(UTXOReservationRenewedEvent event) async {
    final rows = await _loadUtxoRows(event.walletId);
    final utxo = rows.find(event.txid, event.vout);
    if (utxo == null) {
      _warnMissingUtxo(event, event.txid, event.vout);
      return;
    }
    if (utxo.status != UTXOStatus.reserved) return;
    await _storage.upsertUTXO(
      event.walletId,
      utxo.copyWith(
        reservationExpiresAt: event.newExpiresAt,
        reservationReason: event.renewalReason ?? utxo.reservationReason,
        updatedAt: event.timestamp,
      ),
    );
  }


  // ==========================================================================
  // DEFERRED PAYMENTS (bead libspiffy-7p2)
  // ==========================================================================
  //
  // Mirrors the wallet aggregate: a hold makes each held input reserved by
  // the transaction with no expiry, and a deferred-payment row outstanding;
  // a spend by the transaction or an on-network status makes it seen, a
  // verified confirmation mined, a failure or cancellation releases the
  // inputs still reserved by it. Every handler is idempotent: a row already
  // in a later state is not taken back.

  Future<void> _handleTransactionSpendDeferred(TransactionSpendDeferredEvent event) async {
    final existing = await _storage.getDeferredPayment(event.walletId, event.txid);
    if (existing == null) {
      await _storage.storeDeferredPayment(DeferredPayment(
        walletId: event.walletId,
        txid: event.txid,
        invoiceId: event.invoiceId,
        purpose: event.purpose,
        recipientAddresses: event.recipientAddresses,
        amount: BigInt.tryParse(event.paymentAmount) ?? BigInt.zero,
        fee: BigInt.from(event.fee),
        heldInputs: [
          for (final input in event.heldInputs)
            DeferredPaymentInput.fromMap(input),
        ],
        createdAt: event.recordedAt,
        updatedAt: event.timestamp,
        inferred: event.inferred,
      ));
    } else if (event.reactivated && existing.state == DeferredPaymentState.cancelled) {
      // A cancelled payment recorded again is outstanding again (bead
      // libspiffy-4r0). On a replay over a later state (seen, mined, or
      // cancelled again) the events after this one bring the row back there.
      await _storage.storeDeferredPayment(existing.copyWith(
        state: DeferredPaymentState.outstanding,
        heldInputs: [
          for (final input in event.heldInputs)
            DeferredPaymentInput.fromMap(input),
        ],
        updatedAt: event.timestamp,
        resolvedAt: null,
        resolutionReason: null,
      ));
    }
    // A replay re-applies the hold even to a resolved payment: the event that
    // resolved it follows in the journal and releases the inputs again.

    final rows = await _loadUtxoRows(event.walletId);
    // Outstanding again means it can settle again, so its own change is
    // pending again rather than voided (beads libspiffy-4r0, libspiffy-3arz).
    var changed = event.reactivated && await _unvoidOwnOutputs(event.walletId, event.txid, event.timestamp, rows);
    for (final key in event.heldUtxoKeys) {
      final sep = key.lastIndexOf(':');
      final vout = sep > 0 ? int.tryParse(key.substring(sep + 1)) : null;
      if (vout == null) continue;
      final utxo = rows.find(key.substring(0, sep), vout);
      if (utxo == null) {
        _warnMissingUtxo(event, key.substring(0, sep), vout);
        continue;
      }
      if (utxo.status == UTXOStatus.spent) continue;
      if (utxo.status == UTXOStatus.reserved &&
          utxo.reservedByTxId == event.txid &&
          utxo.reservationExpiresAt == null) {
        continue; // replayed
      }
      final held = utxo.copyWith(
        status: UTXOStatus.reserved,
        statusBeforeReservation: utxo.statusToRestoreOnRelease,
        reservedByTxId: event.txid,
        reservationExpiresAt: null,
        reservationPriority: _deferredHoldPriority,
        reservationReason: _deferredHoldReason,
        updatedAt: event.timestamp,
      );
      await _storage.upsertUTXO(event.walletId, held);
      rows.put(held);
      changed = true;
    }
    if (changed) {
      await _recalculateAndPersistForWallet(event.walletId, event.timestamp, rows.all);
    }
  }

  /// Same values as BitcoinWalletAggregate.deferredHoldPriority / Reason.
  static const int _deferredHoldPriority = 1 << 30;
  static const String _deferredHoldReason = 'deferred-spend';

  Future<void> _markDeferredSeen(String walletId, String txid, DateTime at) async {
    final deferred = await _storage.getDeferredPayment(walletId, txid);
    if (deferred == null) return;
    if (deferred.state == DeferredPaymentState.outstanding ||
        deferred.state == DeferredPaymentState.failed ||
        deferred.state == DeferredPaymentState.cancelled) {
      await _storage.storeDeferredPayment(deferred.copyWith(
        state: DeferredPaymentState.seen,
        updatedAt: at,
        resolvedAt: at,
      ));
    }
    await _resolveReclaimedBy(walletId, deferred, at);
  }

  /// [selfSpend] is on the network: if it is a reclaim's self-spend (bead
  /// libspiffy-87a), the deferred payment its purpose names is reclaimed
  /// now. That is the moment the signed transaction the recipient holds can
  /// no longer be mined, and the one place the payment resolves — never at
  /// broadcast time. Terminal and idempotent: a payment already resolved
  /// some other way is left as it is.
  Future<void> _resolveReclaimedBy(String walletId, DeferredPayment selfSpend, DateTime at) async {
    final reclaimedTxid = DeferredPaymentPurpose.reclaimedTxid(selfSpend.purpose);
    if (reclaimedTxid == null) return;
    final payment = await _storage.getDeferredPayment(walletId, reclaimedTxid);
    if (payment == null) {
      _log.warning('Reclaim ${selfSpend.txid} in $walletId names $reclaimedTxid, which has no deferred '
          'payment row; nothing resolved');
      return;
    }
    if (payment.state != DeferredPaymentState.outstanding) return;
    await _storage.storeDeferredPayment(payment.copyWith(
      state: DeferredPaymentState.reclaimed,
      updatedAt: at,
      resolvedAt: at,
      resolutionReason: DeferredPayment.reclaimedBy(selfSpend.txid),
    ));
    // Its own change belongs to a transaction that can no longer be mined
    // (bead libspiffy-3arz).
    final rows = await _loadUtxoRows(walletId);
    if (await _voidOwnOutputs(walletId, reclaimedTxid, at, rows)) {
      await _recalculateAndPersistForWallet(walletId, at, rows.all);
    }
  }

  /// A reclaim was journaled (bead libspiffy-87a). The link between the two
  /// payments is already on the self-spend's row (its purpose), and the hold
  /// moved with the self-spend's own TransactionSpendDeferredEvent, so
  /// nothing is written here — except when this replays after the self-spend
  /// already reached the network, where the payment resolves now.
  Future<void> _handleDeferredSpendReclaimed(DeferredSpendReclaimedEvent event) async {
    final selfSpend = await _storage.getDeferredPayment(event.walletId, event.reclaimTxid);
    if (selfSpend == null) {
      _log.warning('Reclaim of ${event.txid} in ${event.walletId}: no deferred payment row for its '
          'self-spend ${event.reclaimTxid}');
      return;
    }
    if (selfSpend.state == DeferredPaymentState.seen || selfSpend.state == DeferredPaymentState.mined) {
      await _resolveReclaimedBy(event.walletId, selfSpend, event.timestamp);
    }
  }

  Future<void> _handleNetworkStatusChecked(TransactionNetworkStatusCheckedEvent event) async {
    final deferred = await _storage.getDeferredPayment(event.walletId, event.txid);
    if (deferred == null) {
      _log.warning('Network status for ${event.txid} in ${event.walletId}: no deferred payment row; skipped');
      return;
    }
    final lastChecked = deferred.lastCheckedAt;
    if (lastChecked != null && !event.checkedAt.isAfter(lastChecked)) {
      return; // replayed, or older than the observation the row holds
    }
    final seen = DeferredNetworkStatus.isOnNetwork(event.networkStatus) &&
        (deferred.state == DeferredPaymentState.outstanding ||
            deferred.state == DeferredPaymentState.failed ||
            deferred.state == DeferredPaymentState.cancelled);
    await _storage.storeDeferredPayment(deferred.copyWith(
      lastNetworkStatus: event.networkStatus,
      lastNetworkStatusSource: event.source,
      lastCheckedAt: event.checkedAt,
      // Every competing txid ARC named so far (bead libspiffy-pkum).
      competingTxids: DeferredPayment.mergeCompetingTxids(deferred.competingTxids, event.competingTxids),
      updatedAt: event.timestamp,
      state: seen ? DeferredPaymentState.seen : null,
      resolvedAt: seen ? event.timestamp : deferred.resolvedAt,
    ));
    if (seen) await _resolveReclaimedBy(event.walletId, deferred, event.timestamp);
  }

  Future<void> _handleDeferredResolution(WalletEvent event, String txid, DeferredPaymentState state,
      List<ReleasedDeferredInput> released, String? reason) async {
    final deferred = await _storage.getDeferredPayment(event.walletId, txid);
    if (deferred == null) {
      _log.warning('${event.runtimeType} for $txid in ${event.walletId}: no deferred payment row; '
          'inputs still released');
    } else if (deferred.state == DeferredPaymentState.outstanding) {
      await _storage.storeDeferredPayment(deferred.copyWith(
        state: state,
        updatedAt: event.timestamp,
        resolvedAt: event.timestamp,
        resolutionReason: reason,
      ));
    }

    final rows = await _loadUtxoRows(event.walletId);
    var changed = false;
    for (final input in released) {
      final sep = input.utxoKey.lastIndexOf(':');
      final vout = sep > 0 ? int.tryParse(input.utxoKey.substring(sep + 1)) : null;
      if (vout == null) continue;
      final utxo = rows.find(input.utxoKey.substring(0, sep), vout);
      if (utxo == null || utxo.status != UTXOStatus.reserved || utxo.reservedByTxId != txid) continue;
      final restored = utxo.releaseReservation(restoreStatus: input.restoredStatus, timestamp: event.timestamp);
      await _storage.upsertUTXO(event.walletId, restored);
      rows.put(restored);
      changed = true;
    }
    changed = await _voidOwnOutputs(event.walletId, txid, event.timestamp, rows) || changed;
    if (changed) {
      await _recalculateAndPersistForWallet(event.walletId, event.timestamp, rows.all);
    }
  }

  /// The wallet's own pending outputs of [txid] — its change — become
  /// [UTXOStatus.voided] once [txid] is resolved as a payment the network
  /// will not settle (bead libspiffy-3arz), exactly as the wallet aggregate
  /// does it (`DeferredPayments._voidOwnOutputs`).
  ///
  /// Nothing is deleted and no other column is touched: the row, its amount
  /// and its script stay (spv-understanding.md, Data Retention). It only
  /// stops being reported as funds on the way from a transaction that can
  /// never be mined. A later confirmation of [txid] makes it available again
  /// through [UTXOMarkedAvailableEvent].
  ///
  /// Returns whether any row changed.
  Future<bool> _voidOwnOutputs(String walletId, String txid, DateTime at, _UtxoRows rows) async {
    var changed = false;
    for (final utxo in [...rows.all]) {
      if (utxo.txid != txid || utxo.status != UTXOStatus.pending) continue;
      final voided = utxo.markVoided(timestamp: at);
      await _storage.upsertUTXO(walletId, voided);
      rows.put(voided);
      changed = true;
    }
    return changed;
  }

  /// The reverse: a payment that is outstanding again (bead libspiffy-4r0)
  /// can settle again, so its own voided outputs are pending again.
  Future<bool> _unvoidOwnOutputs(String walletId, String txid, DateTime at, _UtxoRows rows) async {
    var changed = false;
    for (final utxo in [...rows.all]) {
      if (utxo.txid != txid || utxo.status != UTXOStatus.voided) continue;
      final pending = utxo.copyWith(status: UTXOStatus.pending, updatedAt: at);
      await _storage.upsertUTXO(walletId, pending);
      rows.put(pending);
      changed = true;
    }
    return changed;
  }

  /// Recalculate statistics and persist for a specific wallet
  ///
  /// The read model's balance rule (spv-understanding.md, "Balances"): the
  /// write model's buckets (`WalletBalances.bucketOf`: reserved when
  /// reserved, confirmed from 6 confirmations, unconfirmed otherwise,
  /// pending UTXOs included) over the wallet's unspent UTXOs the wallet can
  /// spend alone: plugin-managed UTXOs (`BitcoinUtxo.isPluginManaged`),
  /// watch-only UTXOs and bare multisig UTXOs the wallet's keys cannot spend
  /// alone are left out ([splitBalanceUtxos], beads libspiffy-vsap,
  /// libspiffy-0k8). `watchOnlyBalance` is the unspent watch-only UTXOs'
  /// total, whatever their status. `totalBalance` is confirmed +
  /// unconfirmed; it is not a spendable amount.
  ///
  /// [utxos], when given, must be the wallet's rows (includeSpent: true) with
  /// the handler's own writes applied; it saves a second scan.
  Future<void> _recalculateAndPersistForWallet(
    String walletId,
    DateTime timestamp, [
    List<BitcoinUtxo>? utxos,
  ]) async {
    final walletUtxos = utxos ?? await _storage.getUTXOs(walletId, includeSpent: true);
    
    BigInt confirmed = BigInt.zero;
    BigInt unconfirmed = BigInt.zero;
    BigInt reserved = BigInt.zero;
    int available = 0;
    int reservedCount = 0;
    int spentCount = 0;

    // Skip plugin-managed UTXOs (e.g. tokens) from balance calculation.
    // Only UTXOs whose metadata names a pluginId are plugin-managed: standard
    // P2PKH outputs have script-analysis metadata (scriptType, address) but
    // no pluginId.
    final unspent = <BitcoinUtxo>[];
    for (final utxo in walletUtxos) {
      if (utxo.status == UTXOStatus.spent) {
        spentCount++;
      } else if (utxo.status == UTXOStatus.voided) {
        // The output of a transaction the network will not settle (bead
        // libspiffy-3arz): the row is kept, but it counts towards no balance,
        // exactly as `WalletBalances.bucketOf` has it in the write model.
        continue;
      } else if (!utxo.isPluginManaged) {
        unspent.add(utxo);
      }
    }
    final split = await splitBalanceUtxos(_storage, walletId, unspent);

    for (final utxo in split.spendable) {
      if (utxo.status == UTXOStatus.reserved) {
        reserved += utxo.satoshis;
        reservedCount++;
      } else if ((utxo.confirmations ?? 0) >= 6) {
        confirmed += utxo.satoshis;
        available++;
      } else {
        unconfirmed += utxo.satoshis;
        available++;
      }
    }
    
    final total = confirmed + unconfirmed;
    
    // Get existing wallet metadata
    final existingWallet = await _storage.getWallet(walletId);
    if (existingWallet == null) {
      // The wallet row cannot be rebuilt here (no name); the UTXO and address
      // rows are still written, and a later WalletCreated replay recomputes.
      _log.warning('No wallet row for $walletId; balances not updated');
      return;
    }

    // Update wallet metadata with new balances
    await _storage.storeWallet(
      walletId,
      existingWallet['name'] as String,
      rootAddress: existingWallet['rootAddress'] as String?,
      networkType: (existingWallet['network'] ?? existingWallet['networkType']) as String?,
      metadata: {
        ...existingWallet['metadata'] as Map<String, dynamic>? ?? {},
        'confirmedBalance': confirmed.toString(),
        'unconfirmedBalance': unconfirmed.toString(),
        'reservedBalance': reserved.toString(),
        'totalBalance': total.toString(),
        'watchOnlyBalance': split.watchOnlySatoshis.toString(),
        // A new key can make these spendable (_recalculateForNewKey).
        _notSpendableAloneUtxoCount: split.notSpendableAlone.length,
        'utxoCount': walletUtxos.length,
        'availableUtxoCount': available,
        'reservedUtxoCount': reservedCount,
        'spentUtxoCount': spentCount,
        'lastUpdated': timestamp.toIso8601String(),
      },
    );
    
  }
  
  Future<void> _handleTransactionImported(TransactionImportedEvent event) async {
    
    try {
      // Use pre-calculated values from BEEF import (no need to re-parse!)
      final totalOutput = BigInt.from(event.totalOutputSats);
      final totalInput = BigInt.from(event.totalInputSats);
      final walletReceivedSats = BigInt.from(event.walletReceivedSats);
      
      
      // Calculate fee from actual input/output values (if inputs are available)
      final fee = totalInput > BigInt.zero ? totalInput - totalOutput : BigInt.zero;
      
      
      // Net amount: positive for receives, negative for sends
      final netAmount = walletReceivedSats; // For receives this is positive
      
      // CRITICAL: Determine status based on whether we have merkle proof in hand
      // If we have the proof, transaction is confirmed and can be trusted
      // If we don't have the proof yet, transaction is pending until proof is obtained
      final hasMerkleProof = event.bumpProof.isNotEmpty;
      final transactionStatus = hasMerkleProof ? TransactionStatus.confirmed : TransactionStatus.pending;
      
      
      // Create BitcoinTransaction with complete wallet-aware data from BEEF
      final transaction = BitcoinTransaction(
        txid: event.txid,
        rawHex: event.rawHex,
        status: transactionStatus,
        blockHeight: hasMerkleProof ? event.blockHeight : null,
        confirmations: hasMerkleProof ? 6 : 0, // Only confirmed if we have the proof
        inputValue: totalInput,
        outputValue: totalOutput,
        fee: fee,
        receivingAddresses: event.walletReceivingAddresses, // Our addresses that received
        sendingAddresses: event.sendingAddresses, // Addresses from parent tx outputs (BEEF)
        netAmount: netAmount,
        // Event time, not wall-clock: a replay writes the same row.
        createdAt: event.timestamp,
        updatedAt: event.timestamp,
        lockTime: event.txLockTime,
        version: event.txVersion,
        // Who handed the payment to us, as the app names them (bead
        // libspiffy-cq16). The backends set it once and never blank it.
        counterpartyMarker: event.counterpartyMarker,
      );
      
      // The ancestors its BEEF carried, before the transaction that needs
      // them (bead zsh).
      await _storeAncestors(event);

      await _storage.storeTransaction(event.walletId, transaction);

      // Store Merkle proof from BUMP
      if (event.bumpProof.isNotEmpty) {
        await _storeMerkleProofFromBump(event.txid, event.bumpProof);
      }

      // Create junction table records for efficient address-centric queries.
      // A transaction that cannot be parsed for them keeps its stored row;
      // throwing here would drop the event for good (audit M2).
      try {
        await _createTransactionAddressJunctions(
          event.walletId,
          event.txid,
          event.walletReceivingAddresses,
          event.sendingAddresses,
          transaction,
        );
      } catch (e) {
        _log.warning('Address links for ${event.txid} not stored: $e');
      }
    } catch (e) {
      rethrow;
    }
  }
  
  /// Stores the ancestors a received BEEF carried for an unproven transaction
  /// (bead libspiffy-zsh), so that AncestorChainService can build a BEEF
  /// spending its outputs before it is mined, also after a rebuild from the
  /// journal.
  ///
  /// Ancestors are not wallet transactions: their raw transactions go to the
  /// txid-keyed ancestor store (`storeAncestorTransaction`), never to the
  /// wallet's transaction rows, history or balance. A proven ancestor's BUMP
  /// is stored as a merkle proof under the same status rules as the
  /// transaction's own ([_storeMerkleProofFromBump]: verified against the
  /// stored header, else pendingHeader). An ancestor whose raw hex does not
  /// hash to its txid is skipped with a warning. Idempotent: the ancestor
  /// store ignores a txid it holds, and the same proof updates its own row.
  Future<void> _storeAncestors(TransactionImportedEvent event) async {
    for (final ancestor in event.ancestors) {
      final String parsedTxid;
      try {
        parsedTxid = dartsv.Transaction.fromHex(ancestor.rawHex).id;
      } catch (e) {
        _log.warning('Ancestor ${ancestor.txid} of ${event.txid} does not parse; not stored: $e');
        continue;
      }
      if (parsedTxid != ancestor.txid) {
        _log.warning('Ancestor ${ancestor.txid} of ${event.txid} hashes to $parsedTxid; not stored');
        continue;
      }
      await _storage.storeAncestorTransaction(ancestor.txid, ancestor.rawHex);
      if (ancestor.isProven) {
        await _storeMerkleProofFromBump(ancestor.txid, ancestor.bumpHex);
      }
    }
  }

  /// The outgoing transaction's history row, pending. A row that already
  /// exists (a second TransactionRecordedEvent for the txid, which journals
  /// written before bead libspiffy-viy can hold) keeps its status, block,
  /// confirmations and creation time, as the aggregate keeps its record: a
  /// replay must not take a confirmed transaction back to pending.
  Future<void> _handleTransactionRecorded(TransactionRecordedEvent event) async {
    
    try {
      final existing = await _storage.getTransaction(event.txid, walletId: event.walletId);
      // For outgoing transactions, net amount should be:
      // -(payment amount + fee) because we're losing this amount from our wallet
      final paymentAmount = BigInt.parse(event.paymentAmount);
      final fee = BigInt.from(event.fee);
      final netAmount = -(paymentAmount + fee);
      
      // Create transaction record in PENDING state
      final transaction = BitcoinTransaction(
        walletId: event.walletId, // Include wallet ID for proper querying
        txid: event.txid,
        rawHex: event.rawHex,
        status: existing?.status ?? TransactionStatus.pending, // a new row starts pending
        blockHeight: existing?.blockHeight, // none until confirmed
        confirmations: existing?.confirmations ?? 0,
        inputValue: BigInt.from(event.totalInputSats),
        outputValue: BigInt.from(event.totalOutputSats),
        fee: fee,
        receivingAddresses: event.recipientAddresses,
        sendingAddresses: [], // Sender addresses will be from our wallet
        netAmount: netAmount, // Negative for outgoing
        // Event time, not wall-clock: a replay writes the same row.
        createdAt: existing?.createdAt ?? event.timestamp,
        updatedAt: event.timestamp,
        lockTime: event.txLockTime,
        version: event.txVersion,
        // Who we paid, as the app names them (bead libspiffy-cq16). A
        // record without one never blanks the stored marker.
        counterpartyMarker: event.counterpartyMarker ?? existing?.counterpartyMarker,
      );
      
      
      await _storage.storeTransaction(event.walletId, transaction);
    } catch (e) {
      _log.warning('Failed to handle transaction recorded event: $e');
    }
  }

  /// A confirmation, with the proof that backs it (bead libspiffy-9ek).
  ///
  /// The proof is stored from the event's BUMP under the same status rules
  /// as an imported proof ([_storeMerkleProofFromBump]): verified when its
  /// root matches the stored header at its height, else pendingHeader; a
  /// replayed proof that contradicts the active chain never displaces a
  /// different verified current proof. It is stored even without a
  /// transaction row: proofs are keyed by txid, not wallet. Rows journaled
  /// before the BUMP was carried have none and store no proof. Replaying the
  /// event again writes the same row.
  Future<void> _handleTransactionConfirmed(TransactionConfirmedEvent event) async {
    final deferred = await _storage.getDeferredPayment(event.walletId, event.txid);
    if (deferred != null && deferred.state != DeferredPaymentState.mined) {
      await _storage.storeDeferredPayment(deferred.copyWith(
        state: DeferredPaymentState.mined,
        updatedAt: event.timestamp,
        resolvedAt: deferred.resolvedAt ?? event.timestamp,
      ));
    }
    if (deferred != null) await _resolveReclaimedBy(event.walletId, deferred, event.timestamp);
    final bumpHex = event.bumpHex;
    if (bumpHex != null && bumpHex.isNotEmpty) {
      await _storeMerkleProofFromBump(event.txid, bumpHex);
    }
    await _stampProvenHeightOnOutputs(event);

    try {
      // Fetch the existing transaction from storage
      final existingTx = await _storage.getTransaction(event.txid, walletId: event.walletId);
      
      if (existingTx == null) {
        return;
      }
      
      // Update transaction status to confirmed
      final confirmedTx = existingTx.copyWith(
        status: TransactionStatus.confirmed,
        blockHeight: event.blockHeight,
        confirmations: 1, // Assume 1 confirmations when confirmed
        updatedAt: event.timestamp,
      );
      
      
      // Store the updated transaction
      await _storage.storeTransaction(event.walletId, confirmedTx);

    } catch (e) {
      _log.warning('Failed to handle transaction confirmed event: $e');
    }
  }

  /// The block the confirming proof puts [event]'s transaction in, written
  /// onto every unspent UTXO row the transaction created (bead
  /// libspiffy-4dja): the transaction row said height N while its own output
  /// said null, so the same wallet contradicted itself about the same block.
  ///
  /// A height on a UTXO means a verified proof backs it (bead
  /// libspiffy-5ry). [TransactionConfirmedEvent.blockHeight] is the only
  /// height that reaches an output here, and it is journaled from
  /// [ConfirmTransactionCommand], whose senders all derive it from a BUMP
  /// checked against our own header chain; `UTXOMarkedAvailableEvent`
  /// carries none, so an output ARC reports only as seen on the network
  /// stays heightless while becoming spendable.
  ///
  /// No confirmation count is stored: it would be stale at the next block
  /// and no event is journaled per block. The count is
  /// `tip height - blockHeight + 1` wherever it is wanted, which is why this
  /// writes nothing to any balance bucket and does not recompute them.
  ///
  /// The inverse of the UTXO half of
  /// [_handleTransactionConfirmationReverted], and spent rows are skipped
  /// for the same reason: a spent row is history. Idempotent — a replay
  /// finds the height already written and writes nothing.
  Future<void> _stampProvenHeightOnOutputs(TransactionConfirmedEvent event) async {
    final provenHeight = event.blockHeight;
    if (provenHeight == null) return;
    try {
      for (final utxo in await _storage.getUTXOs(event.walletId, includeSpent: false)) {
        if (utxo.txid != event.txid || utxo.blockHeight == provenHeight) continue;
        await _storage.upsertUTXO(
            event.walletId, utxo.copyWith(blockHeight: provenHeight, updatedAt: event.timestamp));
      }
    } catch (e, stackTrace) {
      _log.warning('Failed to write the proven height $provenHeight onto the outputs of ${event.txid}: $e',
          e, stackTrace);
    }
  }

  /// A confirmation was taken back (audit 3b0): the transaction row returns
  /// to pending with no block, the transaction's UTXO rows lose their
  /// confirmations (available ones become pending), and the stored proof is
  /// marked orphaned (never deleted, bead mny) if it is still the current one
  /// the event names. A newer proof (the transaction re-mined on the active
  /// chain, journaled by a later TransactionConfirmedEvent) differs and stays
  /// current. Idempotent: a
  /// replay finds nothing left to mark.
  Future<void> _handleTransactionConfirmationReverted(TransactionConfirmationRevertedEvent event) async {
    final deferred = await _storage.getDeferredPayment(event.walletId, event.txid);
    if (deferred != null && deferred.state == DeferredPaymentState.mined) {
      await _storage.storeDeferredPayment(
          deferred.copyWith(state: DeferredPaymentState.seen, updatedAt: event.timestamp));
    }
    final existingTx = await _storage.getTransaction(event.txid, walletId: event.walletId);
    if (existingTx == null) {
      _log.warning('TransactionConfirmationReverted for ${event.txid}: no transaction row in '
          '${event.walletId}; UTXOs and proof still updated');
    } else if (existingTx.status == TransactionStatus.confirmed ||
        existingTx.blockHeight != null ||
        (existingTx.confirmations ?? 0) > 0) {
      // The one path that lowers a confirmed row (7dj).
      await _storage.storeRevertedTransaction(event.walletId, BitcoinTransaction(
        walletId: existingTx.walletId,
        txid: existingTx.txid,
        rawHex: existingTx.rawHex,
        status: existingTx.status == TransactionStatus.confirmed ? TransactionStatus.pending : existingTx.status,
        blockHeight: null,
        confirmations: 0,
        inputValue: existingTx.inputValue,
        outputValue: existingTx.outputValue,
        fee: existingTx.fee,
        receivingAddresses: existingTx.receivingAddresses,
        sendingAddresses: existingTx.sendingAddresses,
        netAmount: existingTx.netAmount,
        createdAt: existingTx.createdAt,
        updatedAt: event.timestamp,
        memo: existingTx.memo,
        lockTime: existingTx.lockTime,
        version: existingTx.version,
      ));
    }

    var utxosChanged = false;
    for (final utxo in await _storage.getUTXOs(event.walletId, includeSpent: false)) {
      if (utxo.txid != event.txid) continue;
      await _storage.upsertUTXO(event.walletId, BitcoinUtxo(
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
        statusBeforeReservation: utxo.statusBeforeReservation == UTXOStatus.available
            ? UTXOStatus.pending
            : utxo.statusBeforeReservation,
      ));
      utxosChanged = true;
    }
    if (utxosChanged) {
      await _recalculateAndPersistForWallet(event.walletId, event.timestamp);
    }

    final dropped = event.merkleProof;
    if (dropped != null) {
      final marked = await _storage.markMerkleProofOrphaned(
        event.txid,
        blockHash: event.blockHash,
        onlyIfMerkleProof: dropped,
        at: event.timestamp,
      );
      final blockHash = event.blockHash;
      if (!marked && blockHash != null) {
        await _orphanRejectedRevertedProof(event.txid, blockHash, dropped, event.timestamp);
      }
    }
  }

  /// A rebuild from the journal meets a proof that was verified in [blockHash]
  /// and then reverted against today's header chain, where that block is
  /// gone: [_storeContradictedProof] stored it rejected. The revert names the
  /// block the proof was verified in, so the row becomes what the live read
  /// model holds: orphaned, in that block (bead azl). A revert without a block
  /// hash (a pendingHeader proof that never verified) leaves it rejected.
  /// Only a rejected row with no block hash and the same proof is changed,
  /// and only while no row of [txid] names [blockHash].
  Future<void> _orphanRejectedRevertedProof(
      String txid, String blockHash, List<String> merkleProof, DateTime at) async {
    final rows = await _storage.getMerkleProofHistory(txid);
    if (rows.any((r) => r.blockHash == blockHash)) return;
    final rejected = rows
        .where((r) =>
            r.status == MerkleProofStatus.rejected &&
            r.blockHash == null &&
            MerkleProof.sameContent(r.merkleProof, merkleProof))
        .firstOrNull;
    if (rejected == null) return;
    await _storage.storeMerkleProof(txid, MerkleProof(
      txid: txid,
      blockHash: blockHash,
      blockHeight: rejected.blockHeight,
      position: rejected.position,
      merkleProof: rejected.merkleProof,
      createdAt: rejected.createdAt,
      status: MerkleProofStatus.orphaned,
      statusChangedAt: at,
    ));
  }

  Future<void> _handleTransactionStatusUpdated(TransactionStatusUpdatedEvent event) async {
    try {
      final existingTx = await _storage.getTransaction(event.txid, walletId: event.walletId);
      if (existingTx == null) {
        return;
      }

      final updatedTx = existingTx.copyWith(
        status: event.newStatus,
        updatedAt: event.timestamp,
      );

      await _storage.storeTransaction(event.walletId, updatedTx);
    } catch (e) {
      _log.warning('Failed to handle transaction status updated event: $e');
    }
  }

  Future<void> _createTransactionAddressJunctions(
    String walletId,
    String txid,
    List<String> receivingAddresses,
    List<String> sendingAddresses,
    BitcoinTransaction transaction,
  ) async {
    final links = <TransactionAddressLink>[];

    // Create registry once for all outputs. ScriptTypeRegistry is a
    // singleton pinned to the first network it is built with, so it must be
    // built for the wallet's network; the testnet default threw for mainnet
    // wallets (see _handleUTXOReceived for the metadata keys).
    final walletMeta = await _storage.getWallet(walletId);
    final scriptTypeRegistry = ScriptTypeRegistry(
      networkType: NetworkName.toDartsv(
          (walletMeta?['network'] ?? walletMeta?['networkType']) as String?),
    );
    
    // Parse transaction to get exact amounts per address
    final parsedTx = dartsv.Transaction.fromHex(transaction.rawHex);
    
    // Add output links (receiving addresses)
    for (int i = 0; i < parsedTx.outputs.length; i++) {
      final output = parsedTx.outputs[i];
      
      try {
        final script = dartsv.SVScript.fromHex(output.script.toHex());
        
        // Use the registry to extract metadata for ANY script type
        final metadata = scriptTypeRegistry.extractScriptMetadata(script);
        
        if (metadata != null) {
          // Extract identifier and script type
          final destination = _extractPaymentDestination(metadata, script);
          
          if (destination != null) {
            final (outputDestination, scriptType) = destination;
            
            // Check if this destination is in our receiving addresses
            if (receivingAddresses.contains(outputDestination)) {
              links.add(TransactionAddressLink(
                address: outputDestination,
                direction: 'output',
                amount: output.satoshis,
                vout: i,
              ));
            }
          }
        }
      } catch (_) {
        continue;
      }
    }
    
    // Add input links (sending addresses)
    for (int i = 0; i < sendingAddresses.length && i < parsedTx.inputs.length; i++) {
      final sendingAddress = sendingAddresses[i];
      links.add(TransactionAddressLink(
        address: sendingAddress,
        direction: 'input',
        amount: BigInt.zero, // Would need parent tx to get exact amount
        vin: i,
      ));
    }
    
    await _storage.storeTransactionAddresses(walletId, txid, links);
  }
  
  /// Extract a canonical payment destination identifier from script metadata
  /// Returns (identifier, scriptType) tuple or null if not extractable
  (String, String)? _extractPaymentDestination(
    Map<String, dynamic> metadata,
    dartsv.SVScript script,
  ) {
    final scriptType = metadata['scriptType'] as String?;
    
    switch (scriptType?.toLowerCase()) {
      case 'p2pkh':
      case 'p2pk':
        // These have standard addresses
        final address = metadata['address'] as String?;
        return address != null ? (address, scriptType!) : null;

      case 'p2ms':
        // Multisig: concatenate sorted public keys for deterministic identifier
        final publicKeys = metadata['publicKeys'] as List?;
        if (publicKeys != null && publicKeys.isNotEmpty) {
          final sortedKeys = (publicKeys.cast<String>()..sort());
          final identifier = 'multisig:${sortedKeys.join(':')}';
          return (identifier, 'p2ms');
        }
        return null;
        
      case 'p2sh':
        // P2SH: use script hash as identifier
        final scriptHash = metadata['scriptHash'] as String?;
        return scriptHash != null ? ('scripthash:$scriptHash', 'p2sh') : null;
        
      case 'opreturn':
      case 'op_return':
        // OP_RETURN outputs are not spendable, skip
        return null;
        
      default:
        // Unknown/custom script: use script hex hash
        final scriptHex = script.toHex();
        final identifier = 'script:${scriptHex.hashCode.toRadixString(16)}';
        return (identifier, 'custom');
    }
  }
  
  /// Store the hex-encoded BRC-74 BUMP for [txid] as a MerkleProof.
  ///
  /// The raw BUMP is stored verbatim as the single `merkleProof` element
  /// (CryptoUtils.buildBUMPFromMerkleProof
  /// parses it back), so multi-txid BUMPs and duplicate flags survive
  /// storage and outgoing BEEFs carry the proof unchanged. The position is
  /// the offset of the level-0 leaf whose hash is [txid] — a BRC-74 level 0
  /// holds the txid AND its sibling, so "first leaf's offset" is wrong for
  /// every even-positioned transaction (audit SPV-06).
  Future<void> _storeMerkleProofFromBump(
    String txid,
    String bumpHex,
  ) async {
    try {
      final bump = BUMP.fromBytes(Uint8List.fromList(hex.decode(bumpHex)));

      // Leaves are internal byte order; txid is display hex.
      final txidInternal = Uint8List.fromList(hex.decode(txid).reversed.toList());
      final txidLeaf = bump.findTxidLeaf(txidInternal);
      if (txidLeaf == null) {
        throw Exception('BUMP does not contain txid $txid');
      }
      if (!bump.validateMerklePath(txidInternal)) {
        throw Exception('BUMP path for $txid cannot be walked to a root');
      }
      final txPosition = txidLeaf.offset;
      final siblingHashes = <String>[bumpHex];

      // The proof's status comes from the stored headers (beads mny, azl):
      // verified (with that block's hash) when its root matches the active
      // header at its height; pendingHeader (no block hash) when no header
      // is known there, which SPVActor checks when headers arrive (zvj).
      // A proof the header at its height contradicts is not pending: see
      // [_storeContradictedProof]. The projection itself never takes a
      // confirmation back; SPVActor does, for a confirmation whose only proof
      // is rejected.
      final check = await checkBumpAgainstHeaders(
        txid: txid,
        bump: bump,
        headerAt: _storage.getBlockHeaderByHeight,
      );
      if (check.status == ProofHeaderStatus.rootMismatch || check.status == ProofHeaderStatus.malformed) {
        await _storeContradictedProof(txid, bump.blockHeight, txPosition, siblingHashes, check);
        return;
      }
      final status = check.isVerified ? MerkleProofStatus.verified : MerkleProofStatus.pendingHeader;

      // Create MerkleProof object
      final merkleProof = MerkleProof(
        txid: txid,
        blockHash: status == MerkleProofStatus.verified ? check.blockHash : null,
        blockHeight: bump.blockHeight,
        position: txPosition,
        merkleProof: siblingHashes,
        status: status,
      );
      
      // Store to database
      await _storage.storeMerkleProof(txid, merkleProof);

    } catch (e) {
      // Don't rethrow - transaction is still valid without proof stored
      _log.warning('Merkle proof for $txid not stored: $e');
    }
  }
  
  /// A proof the active header at its height contradicts (bead azl). It is
  /// never current, never in a BEEF and never displaces the current proof.
  ///
  /// Live imports, received BEEFs and ARC confirmations check a proof
  /// against the stored headers before journaling it, so this is met on a
  /// replay after the header at that height changed, or when the header
  /// changed between the check and this event:
  /// * no row holds this proof: it is stored rejected (no block hash);
  /// * this proof is the current proof with a block hash (it was verified
  ///   there): that block left the active chain, so it is marked orphaned,
  ///   as SPVActor does on a reorganization;
  /// * this proof is the current proof without a block hash
  ///   (pendingHeader): it becomes rejected;
  /// * it is already orphaned or rejected: nothing changes (replay no-op).
  Future<void> _storeContradictedProof(
    String txid,
    int blockHeight,
    int position,
    List<String> merkleProof,
    ProofHeaderCheck check,
  ) async {
    final same = [
      for (final row in await _storage.getMerkleProofHistory(txid))
        if (MerkleProof.sameContent(row.merkleProof, merkleProof)) row,
    ];
    final current = same.where((r) => r.isCurrent).firstOrNull;
    final String outcome;
    if (same.isEmpty || (current != null && current.blockHash == null)) {
      await _storage.storeMerkleProof(txid, MerkleProof(
        txid: txid,
        blockHash: null,
        blockHeight: blockHeight,
        position: position,
        merkleProof: merkleProof,
        status: MerkleProofStatus.rejected,
      ));
      outcome = 'stored as rejected';
    } else if (current != null) {
      await _storage.markMerkleProofOrphaned(txid, blockHash: current.blockHash, onlyIfMerkleProof: merkleProof);
      outcome = 'its block left the active chain: marked orphaned';
    } else {
      outcome = 'already ${same.last.status.name}';
    }
    _log.warning('Merkle proof for $txid does not match the active header chain ($check); $outcome');
  }

  @override
  Future<void> reset() async {
    // Stateless projection - no in-memory state to clear.
    // Storage is the source of truth and is not cleared here.
    // (If you need to rebuild, clear the storage separately.)
    _checkpoint = 0;
  }

  @override
  Future<void> onError(dynamic error, StackTrace stackTrace) async {
  }
}

/// One load of a wallet's UTXO rows, updated in memory with the writes the
/// handler makes (see [WalletProjection._loadUtxoRows]).
class _UtxoRows {
  final List<BitcoinUtxo> all;
  final Map<String, int> _index = {};

  _UtxoRows(List<BitcoinUtxo> rows) : all = List.of(rows) {
    for (var i = 0; i < all.length; i++) {
      _index[all[i].key] = i;
    }
  }

  /// The row for txid:vout, or null.
  BitcoinUtxo? find(String txid, int vout) {
    final i = _index['$txid:$vout'];
    return i == null ? null : all[i];
  }

  /// Records [utxo] as written: replaces its row or adds it.
  void put(BitcoinUtxo utxo) {
    final i = _index[utxo.key];
    if (i == null) {
      _index[utxo.key] = all.length;
      all.add(utxo);
    } else {
      all[i] = utxo;
    }
  }
}
