import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/header_sync_actor.dart';
import 'package:libspiffy/src/actors/spv_messages.dart';
import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/spv/network_params.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

/// HeaderSyncActor's catch-all error reply names the operation of the message
/// that failed (libspiffy-r1l). It used to switch on `message.runtimeType`
/// with `case BlockHeadersReceivedMessage _:` patterns, which test a Type
/// object against the message class and never match, so every escaped
/// failure was reported as operation 'unknown'.
void main() {
  late ActorSystem system;
  late ActorRef headerSync;
  late ActorRef probe;
  late _Probe probeActor;

  setUp(() async {
    system = LocalActorSystem();
    final chain = BlockHeaderChain(InMemoryWalletStorage(),
        params: NetworkParams.regtest,
        clock: () => NetworkParams.regtest.genesisHeader.timestamp
            .add(const Duration(days: 365)));
    await chain.initialize();
    probeActor = _Probe();
    probe = await system.spawn('probe', () => probeActor);
    headerSync = await system.spawn(
        'header-sync', () => HeaderSyncActor(headerChain: chain));
  });

  tearDown(() async {
    await system.shutdown();
  });

  Future<SPVErrorMessage> errorReplyFor(Message message) async {
    headerSync.tell(message, sender: probe);
    return (await probeActor.next.timeout(const Duration(seconds: 5)))
        as SPVErrorMessage;
  }

  test('a failure escaping the headers handler is reported as process_headers',
      () async {
    final reply = await errorReplyFor(_ThrowingHeadersMessage());
    expect(reply.operation, equals('process_headers'));
    expect(reply.error, contains('headers unavailable'));
  });

  test('a failure escaping the sync request handler is reported as header_sync_request',
      () async {
    final reply = await errorReplyFor(_ThrowingSyncRequest());
    expect(reply.operation, equals('header_sync_request'));
    expect(reply.error, contains('stop hash unavailable'));
  });
}

class _Probe extends Actor {
  final _messages = StreamController<dynamic>.broadcast();
  Future<dynamic> get next => _messages.stream.first;

  @override
  Future<void> onMessage(dynamic message) async => _messages.add(message);
}

/// A headers batch whose header list cannot be read. The handler reads it
/// before its own try block, so the failure reaches onMessage's catch.
class _ThrowingHeadersMessage extends BlockHeadersReceivedMessage {
  _ThrowingHeadersMessage()
      : super(peerId: 'p', headers: const <BlockHeader>[], startHeight: 1);

  @override
  List<BlockHeader> get headers => throw StateError('headers unavailable');
}

/// A sync request whose `fromHeight` cannot be read. The handler logs it
/// before its own try block, so the failure reaches onMessage's catch.
class _ThrowingSyncRequest extends RequestHeaderSyncMessage {
  @override
  int? get fromHeight => throw StateError('stop hash unavailable');
}
