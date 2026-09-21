/// PaymentChannelManagerActor: pending signature cleanup and QueryChannelState.
///
/// Covers the remainder of audit finding A-M6 (libspiffy-y23,
/// doc/audit-2026-09-14.md):
/// - A signing request the WalletManager refuses, or which is never
///   answered, used to leave its entry in the pending signature map forever
///   and the caller without a reply. (The refusal was a bare error map until
///   libspiffy-kl4i typed it as WalletManagerFailure.)
/// - QueryChannelState was an unconditional UnimplementedError (the caller
///   got no reply at all).
///
/// The WalletManager is a stub: it answers address generation with a real
/// key and answers (or ignores) the multisig signing command as each test
/// needs. The channel aggregate is real, over an in-memory journal.

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' show NetworkType;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/payment_channel_manager_actor.dart';
import 'package:libspiffy/src/actors/payment_channel_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';

import 'channel_test_fixtures.dart';
import 'in_memory_event_store.dart';
import '../mocks/policy_rate_arc.dart';

const _walletId = 'server-wallet';
const _channelId = 'chan-sign';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

enum _SignBehaviour { refuses, silent }

void main() {
  late TestActorSystem actorSystem;
  late DartSVCryptoService cryptoService;
  late PaymentChannelManagerActor manager;
  late ActorRef managerRef;
  late _StubWalletManager walletStub;
  late InMemoryEventStore eventStore;

  late String clientPubKeyHex;
  late String clientAddressB58;
  late String serverPubKeyHex;
  late String serverAddressB58;

  setUp(() async {
    actorSystem = TestActorSystem();
    cryptoService = DartSVCryptoService();
    final hd = await cryptoService.mnemonicToHDPrivateKey(_mnemonic);
    final client = hd.deriveChildKey('m/0/1').privateKey.publicKey;
    final server = hd.deriveChildKey('m/0/2').privateKey.publicKey;
    clientPubKeyHex = client.toString();
    clientAddressB58 = client.toAddress(NetworkType.TEST).toString();
    serverPubKeyHex = server.toString();
    serverAddressB58 = server.toAddress(NetworkType.TEST).toString();
  });

  tearDown(() async {
    await actorSystem.shutdown();
  });

  Future<void> spawn(_SignBehaviour behaviour, {bool asClient = false}) async {
    walletStub = _StubWalletManager(
      behaviour: behaviour,
      pubKeyHex: asClient ? clientPubKeyHex : serverPubKeyHex,
      addressB58: asClient ? clientAddressB58 : serverAddressB58,
    );
    final policyArc1 = await actorSystem.spawn('policy-arc-${DateTime.now().microsecondsSinceEpoch}', () => PolicyRateArc());
    final walletRef = await actorSystem.spawn('wallet-manager', () => walletStub);
    manager = PaymentChannelManagerActor(
            arcActor: policyArc1,
      walletManager: walletRef,
      eventStore: eventStore = InMemoryEventStore(),
      cryptoService: cryptoService,
      networkType: NetworkType.TEST,
      signingTimeout: const Duration(milliseconds: 300),
    );
    managerRef = await actorSystem.spawn('channel-manager', () => manager);
  }

  Future<ChannelAcceptedResponse> acceptChannel() =>
      managerRef.ask<ChannelAcceptedResponse>(
        AcceptChannelMessage(
          channelId: _channelId,
          walletId: _walletId,
          clientPeerId: 'client-peer',
          clientPubKeyHex: clientPubKeyHex,
          clientAddressB58: clientAddressB58,
          fundingAmountSats: BigInt.from(100000),
          lockTimeUnix:
              DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
                  1000,
        ),
        const Duration(seconds: 10),
      );

  Future<RefundTransactionSignedResponse> signRefund() async {
    final built = await managerRef.ask<RefundTransactionBuiltResponse>(
      BuildRefundTransactionMessage(
        channelId: _channelId,
        walletId: _walletId,
        fundingTxId: 'b' * 64,
        fundingOutputIndex: 0,
        fundingAmountSats: BigInt.from(100000),
        clientPubKeyHex: clientPubKeyHex,
        clientAddressB58: clientAddressB58,
        serverPubKeyHex: serverPubKeyHex,
        serverAddressB58: serverAddressB58,
        lockTimeUnix:
            DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
                1000,
      ),
      const Duration(seconds: 10),
    );
    expect(built.success, isTrue, reason: built.error);

    return managerRef.ask<RefundTransactionSignedResponse>(
      SignRefundTransactionMessage(
        channelId: _channelId,
        walletId: _walletId,
        refundTxHex: built.refundTxHex,
        clientPubKeyHex: clientPubKeyHex,
        serverPubKeyHex: serverPubKeyHex,
        serverAddressB58: serverAddressB58,
        derivationIndex: 2,
        fundingAmountSats: BigInt.from(100000),
        lockTimeUnix:
            DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
                1000,
      ),
      const Duration(seconds: 3),
    );
  }

  group('A-M6: pending signature maps are cleared on failure', () {
    test('a refused signing command fails the caller and '
        'leaves no pending entry', () async {
      await spawn(_SignBehaviour.refuses);
      final accepted = await acceptChannel();
      expect(accepted.success, isTrue, reason: accepted.error);

      final signed = await signRefund();

      expect(walletStub.signRequests, equals(1));
      expect(signed.success, isFalse);
      expect(signed.error, contains('Wallet not found'));
      expect(manager.pendingSignatureCount, equals(0));
    });

    test('an unanswered signing command times out, fails the caller and '
        'leaves no pending entry', () async {
      await spawn(_SignBehaviour.silent);
      final accepted = await acceptChannel();
      expect(accepted.success, isTrue, reason: accepted.error);

      final signed = await signRefund();

      expect(walletStub.signRequests, equals(1));
      expect(signed.success, isFalse);
      expect(signed.error, contains('timed out'));
      expect(manager.pendingSignatureCount, equals(0));
    });

    test('a failed payment signature fails RecordPayment and leaves no '
        'pending entry', () async {
      await spawn(_SignBehaviour.refuses, asClient: true);
      const timeout = Duration(seconds: 10);

      // Client side of an open channel, as the client flow journals it
      // (verified refund, funding broadcast; libspiffy-b83, 9f7).
      final fixture = await ChannelRefundFixture.create(channelId: _channelId);
      await eventStore.persistEvents('PaymentChannel_$_channelId',
          fixture.openClientJournal(walletId: _walletId), 0);
      final state = await managerRef.ask<ChannelStateResponse>(
          QueryChannelStateMessage(channelId: _channelId), timeout);
      expect(state.status, 'open', reason: state.error);

      final paid = await managerRef.ask<PaymentRecordedResponse>(
        RecordPaymentMessage(
          channelId: _channelId,
          walletId: _walletId,
          amountSats: BigInt.from(1000),
        ),
        const Duration(seconds: 3),
      );

      expect(walletStub.signRequests, equals(1));
      expect(paid.success, isFalse);
      expect(paid.error, contains('Wallet not found'));
      expect(manager.pendingSignatureCount, equals(0));
    });
  });

  group('A-M6: QueryChannelState', () {
    test('returns the channel state from the aggregate', () async {
      await spawn(_SignBehaviour.refuses);
      final accepted = await acceptChannel();
      expect(accepted.success, isTrue, reason: accepted.error);

      final state = await managerRef.ask<ChannelStateResponse>(
        QueryChannelStateMessage(channelId: _channelId),
        const Duration(seconds: 3),
      );

      expect(state.success, isTrue, reason: state.error);
      expect(state.channelId, equals(_channelId));
      expect(state.status, equals('accepted'));
      expect(state.latestSequenceNumber, equals(0));
      expect(state.clientBalanceSats, equals(BigInt.from(100000)));
      expect(state.serverBalanceSats, equals(BigInt.zero));
    });

    test('answers an unknown channel with success:false', () async {
      await spawn(_SignBehaviour.refuses);

      final state = await managerRef.ask<ChannelStateResponse>(
        QueryChannelStateMessage(channelId: 'no-such-channel'),
        const Duration(seconds: 3),
      );

      expect(state.success, isFalse);
      expect(state.error, contains('not found'));
    });
  });
}

/// Answers address generation with a fixed key; answers the multisig signing
/// command with WalletManager's "Wallet not found" map, or not at all.
class _StubWalletManager extends Actor {
  final _SignBehaviour behaviour;
  final String pubKeyHex;
  final String addressB58;
  int signRequests = 0;

  _StubWalletManager({
    required this.behaviour,
    required this.pubKeyHex,
    required this.addressB58,
  });

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! WalletCommandMessage) return;
    final command = message.command;
    if (command is GenerateAddressCommand) {
      context.sender?.tell(AddressGeneratedResponse(
        walletId: command.walletId,
        address: addressB58,
        derivationIndex: 2,
        success: true,
        publicKeyHex: pubKeyHex,
      ));
    } else if (command is SignMultisigTransactionCommand) {
      signRequests++;
      if (behaviour == _SignBehaviour.refuses) {
        context.sender?.tell(WalletManagerFailure(
          error: 'Wallet not found',
          request: 'WalletCommandMessage',
          walletId: command.walletId,
        ));
      }
    }
  }
}
