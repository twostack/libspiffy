/// LibSpiffy Internals - Domain event-sourcing types for advanced use.
///
/// Most applications should use `package:libspiffy/coordinator.dart` instead.
/// This library exposes the aggregate commands, domain events, and actor-level
/// messages used internally by the coordinator. Import this only if you are
/// building custom actors, extending aggregates, or writing integration tests
/// that need direct access to the event-sourcing layer.
library internals;

// Wallet aggregate (event-sourced write model)
export 'src/core/wallet_commands.dart';
export 'src/core/wallet_events.dart';
export 'src/core/bitcoin_wallet_aggregate.dart';

// Invoice aggregate (event-sourced write model)
export 'src/core/invoice_commands.dart';
export 'src/core/invoice_events.dart';
export 'src/core/invoice_aggregate.dart';

// Payment channel aggregate (event-sourced write model)
export 'src/core/channel_commands.dart';
export 'src/core/channel_events.dart';
export 'src/core/channel_state.dart';
export 'src/core/payment_channel_aggregate.dart';

// Actor-level messages (internal routing between actors)
export 'src/actors/payment_channel_messages.dart';
export 'src/actors/payment_channel_manager_actor.dart';
