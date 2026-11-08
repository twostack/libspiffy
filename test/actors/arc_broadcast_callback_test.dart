/// Status callbacks through the broadcast-bridge, in ARCActor: submissions
/// carry a token while callbacks are on, and a delivered status is applied
/// as a polled answer would be, its proof checked against our own headers.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/arc_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/services/broadcast_callback.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';

const _wallet = 'callbacks';
const _wait = Duration(seconds: 10);

void main() {
  late LocalActorSystem system;
  late InMemoryWalletStorage storage;
  late _RecordingArc arc;
  late _RecordingWalletManager wallet;
  late ActorRef arcActor;

  setUp(() async {
    system = LocalActorSystem(ActorSystemConfig());
    storage = InMemoryWalletStorage();
    arc = _RecordingArc();
    wallet = _RecordingWalletManager();
    final walletManager = await system.spawn('wallet-manager', () => wallet);
    arcActor = await system.spawn(
      'arc',
      () => ARCActor(
        walletManager: walletManager,
        storage: storage,
        arcService: arc,
        statusCheckInterval: const Duration(minutes: 10),
        inFlightFollowDelays: const [Duration(milliseconds: 10)],
      ),
    );
  });

  tearDown(() => system.shutdown());

  Future<void> storeTx(TransactionStatus status) => storage.storeTransaction(
        _wallet,
        BitcoinTransaction(
          walletId: _wallet,
          txid: kFixtureTxid,
          rawHex: kFixtureTxHex,
          status: status,
          inputValue: BigInt.zero,
          outputValue: BigInt.zero,
          fee: BigInt.zero,
          receivingAddresses: const [],
          sendingAddresses: const [],
          netAmount: BigInt.zero,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          lockTime: 0,
          version: 1,
        ),
      );

  Future<void> broadcast() =>
      arcActor.ask<dynamic>(BroadcastTransactionMessage(_wallet, kFixtureTxHex, kFixtureTxid), _wait);

  group('submitting', () {
    test('with callbacks off, a submission carries no callback headers', () async {
      await broadcast();
      expect(arc.submissions.single, (null, null));
    });

    test('with callbacks on, it carries the bridge URL and a token', () async {
      arcActor.tell(SetBroadcastCallbacksMessage(
          config: BroadcastCallbackConfig.bridgeTestnet(), signer: await _Signer.create()));
      await broadcast();
      final (url, token) = arc.submissions.single;
      expect(url, 'https://bridge-us-west.overnode.net/v1/callback/bsva');
      expect(token, startsWith('bb1.'));
    });

    test('a signer that fails never holds a submission back', () async {
      arcActor.tell(SetBroadcastCallbacksMessage(
          config: BroadcastCallbackConfig.bridgeTestnet(), signer: await _Signer.create(fails: true)));
      await broadcast();
      expect(arc.submissions.single, (null, null), reason: 'submitted without headers, followed by polling');
    });

    test('turning callbacks off again stops the headers', () async {
      arcActor.tell(SetBroadcastCallbacksMessage(
          config: BroadcastCallbackConfig.bridgeTestnet(), signer: await _Signer.create()));
      arcActor.tell(SetBroadcastCallbacksMessage());
      await broadcast();
      expect(arc.submissions.single, (null, null));
    });
  });

  group('a delivered status', () {
    List<int> envelope(Map<String, dynamic> item, {String net = 'test'}) =>
        utf8.encode(jsonEncode({'v': 1, 'type': 'bsv.tx-status', 'net': net, 'items': [item]}));
    Map<String, dynamic> mined({String? bump}) => {
          'txid': kFixtureTxid,
          'txStatus': 'MINED',
          'status': 200,
          'timestamp': '2026-11-08T14:03:11Z',
          'blockHash': kFixtureBlockHash,
          'blockHeight': kFixtureHeight,
          'merklePath': bump ?? fixtureBumpHex(),
          'extraInfo': '',
          'competingTxs': <String>[],
          'source': 'https://arcade-v2-testnet-us-1.bsvblockchain.tech',
        };
    Future<BroadcastStatusAppliedMessage> apply(List<int> payload, {String net = 'test'}) =>
        arcActor.ask<BroadcastStatusAppliedMessage>(ApplyBroadcastStatusMessage(payload, net: net), _wait);
    List<ConfirmTransactionCommand> confirms() => wallet.commands.whereType<ConfirmTransactionCommand>().toList();
    // The wallet manager hears ARCActor's commands after the answer: let
    // them land before saying what was (or was not) sent.
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 300));

    test('MINED with a proof that checks against our header confirms the transaction', () async {
      await storeTx(TransactionStatus.seenOnNetwork);
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      final answer = await apply(envelope(mined()));
      await settle();
      expect((answer.accepted, answer.applied, answer.unknown), (true, 1, 0));
      expect(confirms().single.txid, kFixtureTxid);
      expect(confirms().single.blockHash, kFixtureBlockHash);
    });

    test('a forged MINED, whose proof does not match our header, confirms nothing', () async {
      await storeTx(TransactionStatus.seenOnNetwork);
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await apply(envelope(mined(bump: fixtureBumpHex(tamperLevel: 1))));
      await settle();
      expect(confirms(), isEmpty);
    });

    test('MINED before we hold its header confirms nothing yet', () async {
      await storeTx(TransactionStatus.seenOnNetwork);
      await apply(envelope(mined()));
      await settle();
      expect(confirms(), isEmpty, reason: 'held until the header arrives, never trusted');
    });

    test('the same MINED delivered twice confirms once', () async {
      await storeTx(TransactionStatus.seenOnNetwork);
      await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
      await apply(envelope(mined()));
      await apply(envelope(mined()));
      await settle();
      expect(confirms(), hasLength(1));
    });

    test('REJECTED is applied as a polled REJECTED', () async {
      await storeTx(TransactionStatus.broadcast);
      await apply(envelope({
        'txid': kFixtureTxid,
        'txStatus': 'REJECTED',
        'status': 466,
        'timestamp': '2026-11-08T14:03:11Z',
        'extraInfo': 'inputs already spent',
        'competingTxs': ['ab' * 32],
      }));
      List<TransactionStatus> updates() =>
          [for (final c in wallet.commands.whereType<UpdateTransactionStatusCommand>()) c.newStatus];
      final deadline = DateTime.now().add(_wait);
      while (updates().isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(updates(), [TransactionStatus.failed]);
      expect(wallet.commands.whereType<VoidRejectedTransactionCommand>(), hasLength(1));
    });

    test('a txid this wallet does not hold, or an envelope for another network, is ignored', () async {
      final unknown = await apply(envelope(mined()));
      expect((unknown.accepted, unknown.applied, unknown.unknown), (true, 0, 1));

      await storeTx(TransactionStatus.seenOnNetwork);
      final otherNet = await apply(envelope(mined(), net: 'main'));
      expect(otherNet.accepted, isFalse);
      expect(wallet.commands, isEmpty);
    });
  });
}

class _Signer implements CallbackTokenSigner {
  final SimpleKeyPair _keyPair;
  final bool fails;
  @override
  final Uint8List peerIdBytes;
  _Signer(this._keyPair, this.peerIdBytes, this.fails);

  static Future<_Signer> create({bool fails = false}) async {
    final kp = await Ed25519().newKeyPairFromSeed(List.filled(32, 3));
    final pub = (await kp.extractPublicKey()).bytes;
    return _Signer(kp, Uint8List.fromList([0x00, 0x24, 0x08, 0x01, 0x12, 0x20, ...pub]), fails);
  }

  @override
  Future<Uint8List> sign(Uint8List message) async {
    if (fails) throw StateError('the key is locked');
    return Uint8List.fromList((await Ed25519().sign(message, keyPair: _keyPair)).bytes);
  }
}

/// Records the callback headers of every submission; ARC has it on the network.
class _RecordingArc extends ArcService {
  _RecordingArc() : super(baseUrl: 'fake://arc');

  final List<(String?, String?)> submissions = [];

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl, String? callbackToken}) async {
    submissions.add((callbackUrl, callbackToken));
    return ArcSubmitResponse.fromJson({'txid': kFixtureTxid, 'txStatus': 'SEEN_ON_NETWORK'});
  }

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async =>
      ArcTransactionResponse.fromJson({'txid': txid, 'txStatus': 'SEEN_ON_NETWORK'});
}

/// Records the wallet commands ARCActor sends; answers nothing.
class _RecordingWalletManager extends Actor {
  final List<WalletCommand> commands = [];

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletCommandMessage) commands.add(message.command);
  }
}
