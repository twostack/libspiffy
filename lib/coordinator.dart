/// LibSpiffy Coordinator API - The canonical public interface for third-party apps.
///
/// Import this library to interact with LibSpiffy through the unified coordinator:
///
/// ```dart
/// import 'package:libspiffy/coordinator.dart';
///
/// // Send commands
/// libspiffy.coordinator.tell(CreateWalletCommand(walletId: 'my-wallet', name: 'My Wallet'));
///
/// // Subscribe to events
/// libspiffy.coordinatorEvents?.listen((event) {
///   if (event is WalletCreatedEvent) { ... }
///   if (event is PaymentReadyEvent) { ... }
/// });
/// ```
///
/// This provides clean command/event names without collisions with internal domain types.
/// For access to internal actors and domain types, use `package:libspiffy/libspiffy.dart`.
library coordinator;

export 'src/actors/coordinator_messages.dart';
export 'src/actors/wallet_coordinator_actor.dart';
export 'src/actors/channel_p2p_adapter.dart';
