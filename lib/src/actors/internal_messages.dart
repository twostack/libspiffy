/// Actor-internal messages of LibSpiffy (libspiffy-pgt).
///
/// One home for the messages actors exchange among themselves that are not
/// part of any aggregate's journal:
///
/// * [ActorResponse], the common base of actor replies. A reply extends
///   [LocalMessage] and returns itself as its payload, so it can answer both
///   a `tell` from another actor and an `ask` (dactor completes an ask with
///   the reply's payload). Every reply says whether the request succeeded and,
///   when it did not, why.
/// * The wiring messages the actor system sends after spawning actors, to
///   hand one actor a reference to another (`Set*Message`) or to start work
///   that needs that wiring ([InitiateHeaderSyncMessage]).
///
/// Commands and events are not here: they belong to the journal and stay
/// with their aggregates in lib/src/core/.
///
/// These classes used to live in wallet_messages.dart,
/// libspiffy_actor_system.dart and header_sync_actor.dart; those libraries
/// re-export them, so existing imports keep working.
library;

import 'package:dactor/dactor.dart';

// ==========================================================================
// REPLIES
// ==========================================================================

/// Base class of actor replies.
///
/// Subclasses keep their own fields and constructors; they only have to
/// provide [success] and [error] (usually as `final` fields). [payload]
/// returns the reply itself, which is what dactor's `ask<T>()` hands back.
abstract class ActorResponse extends LocalMessage {
  ActorResponse({
    super.sender,
    super.correlationId,
    super.replyTo,
    super.timestamp,
    super.metadata,
  }) : super(payload: null);

  /// Whether the request this reply answers succeeded.
  bool get success;

  /// Why the request failed; null when [success] is true.
  String? get error;

  /// The reply itself, so `ask<ConcreteResponse>()` completes with it.
  @override
  dynamic get payload => this;
}

// ==========================================================================
// WIRING MESSAGES (actor references handed over after spawn)
// ==========================================================================

/// Internal message to set InvoiceManager reference in WalletManager
class SetInvoiceManagerMessage implements Message {
  final ActorRef invoiceManager;
  
  SetInvoiceManagerMessage(this.invoiceManager);

  @override
  String get correlationId => 'set-invoice-manager-${DateTime.now().millisecondsSinceEpoch}';
  
  @override
  Map<String, dynamic> get metadata => {};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => DateTime.now();
}

/// Internal message to set ARC actor reference in WalletManager
class SetArcActorMessage implements Message {
  final ActorRef arcActor;
  
  SetArcActorMessage(this.arcActor);

  @override
  String get correlationId => 'set-arc-actor-${DateTime.now().millisecondsSinceEpoch}';
  
  @override
  Map<String, dynamic> get metadata => {};
  
  @override
  ActorRef? get replyTo => null;
  
  @override
  DateTime get timestamp => DateTime.now();
}

/// Message to set the Benford coordinator reference in WalletManager
class SetBenfordCoordinatorMessage implements Message {
  final ActorRef benfordCoordinator;

  SetBenfordCoordinatorMessage(this.benfordCoordinator);

  @override
  String get correlationId => 'set-benford-coordinator-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'actorRef': benfordCoordinator.toString()};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Message to set the ARC actor reference in SPVActor
/// 
/// Used to wire up the ARCActor reference after actor system initialization,
/// enabling SPVActor to trigger pending UTXO checks when block headers arrive.
class SetArcActorForSPVMessage implements Message {
  final ActorRef arcActor;

  SetArcActorForSPVMessage(this.arcActor);

  @override
  String get correlationId => 'set-arc-actor-spv-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'arcActorRef': arcActor.toString()};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Tells SPVActor which actor speaks for the app (bead libspiffy-4gy8).
///
/// A receive parked for a block header is replayed by whichever process
/// holds the header when it arrives, and that is usually not the process
/// that took the delivery: the caller's `ActorRef` died with it. So a
/// replayed receive had nobody to answer, and an app restarted between the
/// park and the header saw its wallet credited with no event on the public
/// stream -- it could learn of the funds only by polling the read model.
///
/// The coordinator registers itself here, and SPVActor answers it whenever
/// no live caller is waiting. Registering is also what triggers the replay
/// of receives whose headers arrived while the node was down, so the credit
/// and the announcement happen together rather than the credit happening
/// first, in `preStart`, with nobody yet able to hear it.
class SetCoordinatorForSPVMessage implements Message {
  final ActorRef coordinator;

  SetCoordinatorForSPVMessage(this.coordinator);

  @override
  String get correlationId => 'set-coordinator-spv-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'coordinatorRef': coordinator.toString()};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Message to set HeaderSyncActor reference in SPVActor
class SetHeaderSyncActorMessage implements Message {
  final ActorRef headerSyncActor;

  SetHeaderSyncActorMessage(this.headerSyncActor);

  @override
  String get correlationId => 'set-header-sync-actor-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {'headerSyncActorRef': headerSyncActor.toString()};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Message to set the SpiffyNode bridge reference after P2P initialization
class SetSpiffyNodeBridgeMessage implements Message {
  final dynamic bridge;

  SetSpiffyNodeBridgeMessage(this.bridge);

  @override
  String get correlationId => 'set-bridge-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Message to set the PeerManager reference after P2P initialization
class SetPeerManagerMessage implements Message {
  final dynamic peerManager;

  SetPeerManagerMessage(this.peerManager);

  @override
  String get correlationId => 'set-peer-manager-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Message to initiate header sync after P2P setup is complete
class InitiateHeaderSyncMessage implements Message {
  final int? startHeight;

  InitiateHeaderSyncMessage({this.startHeight});

  @override
  String get correlationId => 'initiate-sync-${DateTime.now().millisecondsSinceEpoch}';
  @override
  Map<String, dynamic> get metadata => {};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}
