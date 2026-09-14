import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:eventador/eventador.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/services/script_type_registry.dart';
import 'package:logging/logging.dart';
import '../core/wallet_events.dart';
import '../models/wallet_event.dart';
import '../models/wallet_type.dart';
import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../models/address_metadata.dart';
import '../models/transaction_address_link.dart';
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

    switch (event.runtimeType) {
      case WalletCreatedEvent:
        await _handleWalletCreated(event as WalletCreatedEvent);
        return true;
      case WalletDeletedEvent:
        await _handleWalletDeleted(event as WalletDeletedEvent);
        return true;
      case WalletConfigurationUpdatedEvent:
        await _handleWalletConfigurationUpdated(event as WalletConfigurationUpdatedEvent);
        return true;
      case AddressGeneratedEvent:
        await _handleAddressGenerated(event as AddressGeneratedEvent);
        return true;
      case AddressDiscoveredEvent:
        await _handleAddressDiscovered(event as AddressDiscoveredEvent);
        return true;
      case AddressLabelUpdatedEvent:
        // Label updates don't affect read model statistics
        return true;
      case UTXOReceivedEvent:
        await _handleUTXOReceived(event as UTXOReceivedEvent);
        return true;
      case UTXOMarkedAvailableEvent:
        await _handleUTXOMarkedAvailable(event as UTXOMarkedAvailableEvent);
        return true;
      case UTXOSpentEvent:
        await _handleUTXOSpent(event as UTXOSpentEvent);
        return true;
      case UTXOConfirmationUpdatedEvent:
        await _handleUTXOConfirmationUpdated(event as UTXOConfirmationUpdatedEvent);
        return true;
      case UTXOReservedEvent:
        await _handleUTXOReserved(event as UTXOReservedEvent);
        return true;
      case UTXOReleasedEvent:
        await _handleUTXOReleased(event as UTXOReleasedEvent);
        return true;
      case UTXOReservationRenewedEvent:
        await _handleUTXOReservationRenewed(event as UTXOReservationRenewedEvent);
        return true;
      case TransactionImportedEvent:
        await _handleTransactionImported(event as TransactionImportedEvent);
        return true;
      case TransactionRecordedEvent:
        await _handleTransactionRecorded(event as TransactionRecordedEvent);
        return true;
      case TransactionConfirmedEvent:
        await _handleTransactionConfirmed(event as TransactionConfirmedEvent);
        return true;
      case TransactionStatusUpdatedEvent:
        await _handleTransactionStatusUpdated(event as TransactionStatusUpdatedEvent);
        return true;
      case TransactionConfirmationRevertedEvent:
        await _handleTransactionConfirmationReverted(event as TransactionConfirmationRevertedEvent);
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
        ...event.walletMetadata ?? {},
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
        if (event.newMetadata != null) ...event.newMetadata!,
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
    await _updateWalletAddressCount(event.walletId, event.timestamp);
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
    await _updateWalletAddressCount(event.walletId, event.timestamp);
  }
  
  /// Helper: Update wallet address count by reading current count from storage
  Future<void> _updateWalletAddressCount(String walletId, DateTime timestamp) async {
    final existingWallet = await _storage.getWallet(walletId);
    if (existingWallet == null) {
      _log.warning('No wallet row for $walletId; address count not updated');
      return;
    }
    
    // Get actual address count from storage
    final addresses = await _storage.getWalletAddresses(walletId);
    final addressCount = addresses.length;
    
    // Update wallet metadata
    final existingMetadata = existingWallet['metadata'] as Map<String, dynamic>? ?? {};
    await _storage.storeWallet(
      walletId,
      existingWallet['name'] as String,
      rootAddress: existingWallet['rootAddress'] as String?,
      networkType: (existingWallet['network'] ?? existingWallet['networkType']) as String?,
      metadata: {
        ...existingMetadata,
        'addressCount': addressCount,
        'lastUpdated': timestamp.toIso8601String(),
      },
    );
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
        pluginMetadata: scriptMetadata,
        createdAt: event.timestamp,
      );
      await _storage.upsertUTXO(event.walletId, utxo);
      rows.put(utxo);
    }

    await _syncAddress(event.walletId, event.address, rows.all,
        newUseAt: existing == null ? event.timestamp : null);
    await _recalculateAndPersistForWallet(event.walletId, event.timestamp, rows.all);
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

    if (utxo.status == UTXOStatus.pending) {
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

  /// Recalculate statistics and persist for a specific wallet
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
    
    for (final utxo in walletUtxos) {
      if (utxo.status == UTXOStatus.spent) {
        spentCount++;
        continue;
      }
      // Skip plugin-managed UTXOs (e.g. tokens) from balance calculation.
      // Only exclude UTXOs with an explicit pluginId — standard P2PKH outputs
      // have script-analysis metadata (scriptType, address) but no pluginId.
      if (utxo.pluginMetadata?['pluginId'] != null) continue;

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
    final bumpHex = event.bumpHex;
    if (bumpHex != null && bumpHex.isNotEmpty) {
      await _storeMerkleProofFromBump(event.txid, bumpHex);
    }

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

  /// A confirmation was taken back (audit 3b0): the transaction row returns
  /// to pending with no block, the transaction's UTXO rows lose their
  /// confirmations (available ones become pending), and the stored proof is
  /// marked orphaned (never deleted, bead mny) if it is still the current one
  /// the event names. A newer proof (the transaction re-mined on the active
  /// chain, journaled by a later TransactionConfirmedEvent) differs and stays
  /// current. Idempotent: a
  /// replay finds nothing left to mark.
  Future<void> _handleTransactionConfirmationReverted(TransactionConfirmationRevertedEvent event) async {
    final existingTx = await _storage.getTransaction(event.txid, walletId: event.walletId);
    if (existingTx == null) {
      _log.warning('TransactionConfirmationReverted for ${event.txid}: no transaction row in '
          '${event.walletId}; UTXOs and proof still updated');
    } else if (existingTx.status == TransactionStatus.confirmed ||
        existingTx.blockHeight != null ||
        (existingTx.confirmations ?? 0) > 0) {
      await _storage.storeTransaction(event.walletId, BitcoinTransaction(
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
