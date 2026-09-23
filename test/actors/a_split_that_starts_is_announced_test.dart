/// Bead libspiffy-7ye4: an application heard a UTXO split finish and never
/// heard one start.
///
/// `UTXOSplitCompleteEvent` was emitted; `UTXOSplitStartedEvent` was exported
/// beside it and nothing in the library ever constructed it. The asymmetry is
/// not cosmetic: a Benford split builds, signs and broadcasts one transaction
/// per source UTXO and waits for ARC's answer to each, so between the command
/// and the completion an app had nothing to show but a spinner it started on
/// faith.
///
/// The numbers it announces are the split's own. How many UTXOs a split takes
/// is not in the command — `maxUtxosToSplit` bounds it and what the wallet
/// actually holds decides it — so only `BenfordCoordinatorActor` can state
/// it, and it states it at the point where nothing can refuse the split any
/// more. A split that cannot start announces no start.
library;

// The stand-in wallet manager answers its sender through dactor's @internal
// `Actor.context`.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/actors/arc_actor.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/actors/benford_coordinator_actor.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/services/arc_service.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:test/test.dart';

import 'in_memory_event_store.dart';
import '../mocks/offline_arc.dart';

const _xpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';
const _walletId = 'benford-7ye4';
final _sourceTxid = 'c7' * 32;
const _wait = Duration(seconds: 10);
const _splitWait = Duration(seconds: 40);

void main() {
  late LocalActorSystem system;
  late InMemoryWalletStorage readModel;
  late ActorRef walletManager;
  late ActorRef benford;
  late List<coord.CoordinatorEvent> announced;
  late StreamSubscription<coord.CoordinatorEvent> sub;
  late ActorRef coordinatorRef;

  setUp(() async {
    system = LocalActorSystem(ActorSystemConfig());
    readModel = InMemoryWalletStorage();
    walletManager = await system.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: InMemoryEventStore(),
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
        aggregateIdleTimeout: null,
        readModelStorage: readModel,
      ),
    );
    final arcActor = await system.spawn(
      'arc',
      () => ARCActor(
        walletManager: walletManager,
        storage: readModel,
        arcService: _SilentArc(),
        statusCheckInterval: const Duration(minutes: 10),
      ),
    );
    benford = await system.spawn(
      'benford',
      () => BenfordCoordinatorActor(
        walletManager: walletManager,
        arcActor: arcActor,
        storage: readModel,
      ),
    );
    walletManager.tell(SetBenfordCoordinatorMessage(benford));

    final noop = await system.spawn('noop', () => _Noop());
    final coordinator = WalletCoordinatorActor(
      walletManager: walletManager,
      invoiceCoordinator: noop,
      paymentCoordinator: noop,
      spvActor: noop,
      arcActor: noop,
      headerSyncActor: noop,
      benfordCoordinator: benford,
      channelManager: noop,
      walletProjection: noop,
      storage: readModel,
    );
    announced = [];
    sub = coordinator.events.listen(announced.add);
    coordinatorRef = await system.spawn('coordinator', () => coordinator);
  });

  tearDown(() async {
    await sub.cancel();
    await system.shutdown();
  });

  /// Creates the wallet and gives it one available UTXO per entry of
  /// [amounts], at one generated address, known to the aggregate and to the
  /// read model as a caught-up projection would have it.
  Future<void> walletWithUtxos(List<int> amounts) async {
    final created = await walletManager.ask<WalletCreatedMessage>(
      CreateWalletMessage(_walletId, 'Benford', xpriv: _xpriv),
      _wait,
    );
    expect(created.success, isTrue, reason: created.error);
    final generated = await walletManager.ask<AddressGeneratedResponse>(
      WalletCommandMessage(_walletId, GenerateAddressCommand(walletId: _walletId)),
      _wait,
    );
    expect(generated.success, isTrue, reason: generated.error);
    final address = generated.address;
    final script = dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(address))
        .getScriptPubkey()
        .toHex();
    await readModel.storeWallet(_walletId, 'Benford',
        networkType: 'testnet', metadata: {'walletType': 'hd'});

    for (var vout = 0; vout < amounts.length; vout++) {
      final satoshis = BigInt.from(amounts[vout]);
      final received = await walletManager.ask<UTXOReceivedResponse>(
        WalletCommandMessage(
          _walletId,
          ReceiveUTXOCommand(
            walletId: _walletId,
            txid: _sourceTxid,
            vout: vout,
            satoshis: satoshis,
            scriptPubKey: script,
            address: address,
            blockHeight: 100,
            confirmations: 6,
            initialStatus: UTXOStatus.available,
          ),
        ),
        _wait,
      );
      expect(received.success, isTrue, reason: received.error);
      await readModel.upsertUTXO(
        _walletId,
        BitcoinUtxo.create(
          txid: _sourceTxid,
          vout: vout,
          satoshis: satoshis,
          scriptPubKey: script,
          address: address,
          status: UTXOStatus.available,
        ),
      );
    }
  }

  /// Runs a split to completion and returns what the coordinator announced.
  Future<coord.UTXOSplitCompleteEvent> splitAndSettle(
      {int targetUtxoCount = 3, int? maxUtxosToSplit}) async {
    final done = _first<coord.UTXOSplitCompleteEvent>(announced);
    coordinatorRef.tell(coord.SplitUTXOsCommand(
      walletId: _walletId,
      targetUtxoCount: targetUtxoCount,
      maxUtxosToSplit: maxUtxosToSplit,
    ));
    return await done.timeout(_splitWait);
  }

  test('a split that starts is announced before it finishes', () async {
    await walletWithUtxos([100000, 90000]);

    final complete = await splitAndSettle();
    expect(complete.success, isTrue, reason: complete.error);

    final started = announced.whereType<coord.UTXOSplitStartedEvent>().single;
    expect(started.walletId, _walletId);
    expect(started.utxoCount, 2,
        reason: 'both of the wallet\'s spendable outputs are being split');
    expect(started.targetOutputsPerUtxo, 3);

    final kinds = announced
        .where((e) =>
            e is coord.UTXOSplitStartedEvent || e is coord.UTXOSplitCompleteEvent)
        .map((e) => e.runtimeType.toString());
    expect(kinds, ['UTXOSplitStartedEvent', 'UTXOSplitCompleteEvent'],
        reason: 'an app hears the split start and then hears it finish');
  });

  test('the count announced is what the split takes, not what the wallet holds',
      () async {
    await walletWithUtxos([100000, 90000, 80000]);

    final complete = await splitAndSettle(maxUtxosToSplit: 2);
    expect(complete.success, isTrue, reason: complete.error);

    expect(announced.whereType<coord.UTXOSplitStartedEvent>().single.utxoCount, 2,
        reason: 'the wallet holds three; maxUtxosToSplit bounds the split to '
            'two, and the announcement states the split, not the wallet');
    expect(complete.transactionCount, 2);
  });

  test('a split with nothing to split announces no start', () async {
    await walletWithUtxos([]);

    final complete = await splitAndSettle();
    expect(complete.success, isFalse);
    expect(complete.error, contains('No available UTXOs'));
    expect(announced.whereType<coord.UTXOSplitStartedEvent>(), isEmpty,
        reason: 'nothing was started, so nothing may say it was');
  });

  test('the split command is still answered with its reply and nothing else',
      () async {
    // The start is announced to the coordinator, never to the command's
    // sender. A caller that used `ask` holds a one-shot reply reference, and
    // a second message told to it resolves the ask with the wrong answer -
    // dactor fails it outright ("Ask response must be a LocalMessage").
    await walletWithUtxos([100000]);
    final started = _first<coord.UTXOSplitStartedEvent>(announced);

    final response = await benford.ask<SplitUTXOsResponse>(
      SplitUTXOsToBenfordCommand(walletId: _walletId, targetUtxoCount: 3),
      _splitWait,
    );

    expect(response.success, isTrue, reason: response.error);
    expect(response.splitCount, 3);
    expect((await started).utxoCount, 1,
        reason: 'the start still reaches the application');
  });

  test('a watch-only wallet announces no start', () async {
    final xpub = dartsv.HDPrivateKey.fromXpriv(_xpriv).hdPublicKey.xpubkey;
    final created = await walletManager.ask<WalletCreatedMessage>(
      CreateWalletMessage(_walletId, 'Benford', xpub: xpub),
      _wait,
    );
    expect(created.success, isTrue, reason: created.error);

    final complete = await splitAndSettle();
    expect(complete.success, isFalse);
    expect(announced.whereType<coord.UTXOSplitStartedEvent>(), isEmpty,
        reason: 'a wallet that holds no key to sign a split never starts one');
  });
}

/// The next [T] the coordinator announces, watched from before the command
/// that causes it is sent.
Future<T> _first<T extends coord.CoordinatorEvent>(
    List<coord.CoordinatorEvent> announced) async {
  final from = announced.length;
  final deadline = DateTime.now().add(_splitWait);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final found = announced.skip(from).whereType<T>();
    if (found.isNotEmpty) return found.first;
  }
  throw TimeoutException('no $T was announced', _splitWait);
}

class _Noop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

/// ARC without a network: accepts every broadcast as SEEN_ON_NETWORK.
class _SilentArc extends OfflineArc {
  _SilentArc() : super(baseUrl: 'fake://arc');

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async {
    final txid = dartsv.Transaction.fromHex(rawTx).id;
    return ArcSubmitResponse.fromJson({'txid': txid, 'txStatus': 'SEEN_ON_NETWORK'});
  }

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async =>
      throw ArcException('Failed to get transaction: {"status":404}', statusCode: 404);
}
