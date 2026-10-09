/// LibSpiffy Coordinator API - The canonical public interface for third-party apps.
///
/// Import this library to interact with LibSpiffy through the unified coordinator:
///
/// ```dart
/// import 'package:libspiffy/coordinator.dart';
///
/// // Send a request and get its own reply; a failure throws CoordinatorFailure
/// final wallet = await libspiffy.coordinator
///     .ask(CreateWalletCommand(walletId: 'my-wallet', name: 'My Wallet', mnemonic: mnemonic));
///
/// // Follow what happens without a request
/// libspiffy.coordinator.on<BalanceUpdatedEvent>(walletId: 'my-wallet').listen(render);
/// ```
///
/// `example/coordinator_example.dart` runs this offline.
///
/// This provides clean command/event names without collisions with internal domain types.
/// For access to internal actors and domain types, use `package:libspiffy/libspiffy.dart`.
library coordinator;

export 'src/actors/coordinator_messages.dart';
export 'src/models/foreign_spend.dart';
export 'src/actors/wallet_coordinator.dart';
export 'src/actors/wallet_coordinator_actor.dart';
export 'src/actors/channel_p2p_adapter.dart';
export 'src/actors/proof_p2p_adapter.dart';
