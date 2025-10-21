import 'package:eventador/eventador.dart';
import '../core/wallet_events.dart';
import '../models/wallet_event.dart';
import '../models/wallet_read_model.dart';
import '../models/bitcoin_utxo.dart';
import '../storage/read_model_storage.dart';

/// Wallet projection that builds read models from wallet events
/// 
/// This projection subscribes to wallet events from the EventStore and
/// maintains denormalized read models in Isar for fast queries.
/// Separates write concerns (aggregate) from read concerns (queries).
class WalletProjection extends Projection<WalletReadModel> {
  final ReadModelStorage _storage;
  final String _projectionId;
  late WalletReadModel _readModel;
  int _checkpoint = 0;
  
  // Track UTXO statistics for the read model
  final Map<String, BitcoinUtxo> _utxos = {};
  final Set<String> _addresses = {};
  
  WalletProjection({
    required String projectionId,
    required EventStore eventStore,
    required ReadModelStorage storage,
  })  : _storage = storage,
        _projectionId = projectionId,
        super() {
    _readModel = WalletReadModel.empty(projectionId);
  }
  
  @override
  String get projectionId => _projectionId;
  
  @override
  WalletReadModel get readModel => _readModel;
  
  @override
  List<Type> get interestedEventTypes => [
        WalletCreatedEvent,
        WalletConfigurationUpdatedEvent,
        AddressGeneratedEvent,
        AddressLabelUpdatedEvent,
        UTXOReceivedEvent,
        UTXOSpentEvent,
        UTXOConfirmationUpdatedEvent,
        UTXOReservedEvent,
        UTXOReleasedEvent,
        UTXOReservationRenewedEvent,
      ];
  
  @override
  Future<int> getCheckpoint() async {
    return _checkpoint;
  }
  
  @override
  Future<void> updateCheckpoint(int checkpoint) async {
    _checkpoint = checkpoint;
  }
  
  @override
  Future<void> rebuild() async {
    await reset();
    // Projection manager will replay events after rebuild
  }
  
  @override
  Future<bool> handle(Event event) async {
    if (event is! WalletEvent) return false;
    
    try {
      switch (event.runtimeType) {
        case WalletCreatedEvent:
          await _handleWalletCreated(event as WalletCreatedEvent);
          return true;
        case WalletConfigurationUpdatedEvent:
          await _handleWalletConfigurationUpdated(event as WalletConfigurationUpdatedEvent);
          return true;
        case AddressGeneratedEvent:
          await _handleAddressGenerated(event as AddressGeneratedEvent);
          return true;
        case AddressLabelUpdatedEvent:
          // Label updates don't affect read model statistics
          return true;
        case UTXOReceivedEvent:
          await _handleUTXOReceived(event as UTXOReceivedEvent);
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
          // Renewal doesn't change statistics
          return true;
        default:
          return false;
      }
    } catch (e) {
      print('Error handling event ${event.runtimeType} in WalletProjection: $e');
      rethrow;
    }
  }
  
  Future<void> _handleWalletCreated(WalletCreatedEvent event) async {
    _readModel = WalletReadModel(
      walletId: event.walletId,
      name: event.walletName,
      rootAddress: event.rootAddress,
      networkType: event.walletMetadata?['network'] as String? ?? 'mainnet',
      createdAt: event.timestamp,
      lastUpdated: event.timestamp,
      confirmedBalance: BigInt.zero,
      unconfirmedBalance: BigInt.zero,
      reservedBalance: BigInt.zero,
      totalBalance: BigInt.zero,
      addressCount: 0,
      utxoCount: 0,
      availableUtxoCount: 0,
      reservedUtxoCount: 0,
      spentUtxoCount: 0,
      metadata: event.walletMetadata ?? {},
    );
    
    // Persist to storage
    await _persistReadModel();
  }
  
  Future<void> _handleWalletConfigurationUpdated(WalletConfigurationUpdatedEvent event) async {
    _readModel = _readModel.copyWith(
      name: event.newName,
      metadata: event.newMetadata != null
          ? {..._readModel.metadata, ...event.newMetadata!}
          : _readModel.metadata,
      lastUpdated: event.timestamp,
    );
    
    await _persistReadModel();
  }
  
  Future<void> _handleAddressGenerated(AddressGeneratedEvent event) async {
    _addresses.add(event.address);
    
    _readModel = _readModel.copyWith(
      addressCount: _addresses.length,
      lastUpdated: event.timestamp,
    );
    
    await _persistReadModel();
  }
  
  Future<void> _handleUTXOReceived(UTXOReceivedEvent event) async {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = BitcoinUtxo.create(
      txid: event.txid,
      vout: event.vout,
      satoshis: BigInt.from(event.satoshis),
      scriptPubKey: event.scriptPubKey,
      address: event.address,
      blockHeight: event.blockHeight,
      confirmations: event.confirmations ?? 0,
    );
    
    _utxos[utxoKey] = utxo;
    await _recalculateAndPersist(event.timestamp);
  }
  
  Future<void> _handleUTXOSpent(UTXOSpentEvent event) async {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = _utxos[utxoKey];
    
    if (utxo != null) {
      _utxos[utxoKey] = utxo.markSpent();
      await _recalculateAndPersist(event.timestamp);
    }
  }
  
  Future<void> _handleUTXOConfirmationUpdated(UTXOConfirmationUpdatedEvent event) async {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = _utxos[utxoKey];
    
    if (utxo != null) {
      _utxos[utxoKey] = utxo.updateConfirmations(
        blockHeight: event.blockHeight,
        confirmations: event.confirmations,
      );
      await _recalculateAndPersist(event.timestamp);
    }
  }
  
  Future<void> _handleUTXOReserved(UTXOReservedEvent event) async {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = _utxos[utxoKey];
    
    if (utxo != null) {
      _utxos[utxoKey] = utxo.copyWith(
        status: UTXOStatus.reserved,
        reservedByTxId: event.reservedByTxId,
        reservationExpiresAt: event.expiresAt,
        reservationPriority: event.priority,
        reservationReason: event.reservationReason,
        updatedAt: event.timestamp,
      );
      await _recalculateAndPersist(event.timestamp);
    }
  }
  
  Future<void> _handleUTXOReleased(UTXOReleasedEvent event) async {
    final utxoKey = '${event.txid}:${event.vout}';
    final utxo = _utxos[utxoKey];
    
    if (utxo != null && utxo.status == UTXOStatus.reserved) {
      _utxos[utxoKey] = utxo.releaseReservation();
      await _recalculateAndPersist(event.timestamp);
    }
  }
  
  /// Recalculate statistics and persist
  Future<void> _recalculateAndPersist(DateTime timestamp) async {
    BigInt confirmed = BigInt.zero;
    BigInt unconfirmed = BigInt.zero;
    BigInt reserved = BigInt.zero;
    int available = 0;
    int reservedCount = 0;
    int spentCount = 0;
    
    for (final utxo in _utxos.values) {
      if (utxo.status == UTXOStatus.spent) {
        spentCount++;
        continue;
      }
      
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
    
    _readModel = _readModel.copyWith(
      confirmedBalance: confirmed,
      unconfirmedBalance: unconfirmed,
      reservedBalance: reserved,
      totalBalance: total,
      utxoCount: _utxos.length,
      availableUtxoCount: available,
      reservedUtxoCount: reservedCount,
      spentUtxoCount: spentCount,
      lastUpdated: timestamp,
    );
    
    await _persistReadModel();
  }
  
  /// Persist read model to storage (Isar)
  Future<void> _persistReadModel() async {
    try {
      // Store wallet in read model storage
      await _storage.storeWallet(
        _readModel.walletId,
        _readModel.name,
        rootAddress: _readModel.rootAddress,
        networkType: _readModel.networkType,
        metadata: _readModel.metadata,
      );
    } catch (e) {
      print('Error persisting wallet read model: $e');
      rethrow;
    }
  }
  
  @override
  Future<void> reset() async {
    _readModel = WalletReadModel.empty(projectionId);
    _utxos.clear();
    _addresses.clear();
  }
}

