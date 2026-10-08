/// Bead libspiffy-5hnt: which coins a Benford split takes, and how many
/// pieces each makes. It took the first coins in storage order, so a
/// wallet's largest coin could stay whole while its small ones were split
/// again and again.
library;

import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/actors/arc_actor.dart';
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
const _walletId = 'benford-5hnt';
const _wait = Duration(seconds: 10);

/// The wallet's coins, by vout of one parent: small, the dominant one, mid.
const _coins = [5000, 100000, 20000, 1500];
final _parent = 'b2' * 32;
String _key(int vout) => '$_parent:$vout';

void main() {
  late LocalActorSystem system;
  late ActorRef walletManager;
  late ActorRef benford;

  setUp(() async {
    system = LocalActorSystem(ActorSystemConfig());
    final eventStore = InMemoryEventStore();
    final readModel = InMemoryWalletStorage();
    walletManager = await system.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: eventStore,
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
        arcService: _SeenArc(),
        statusCheckInterval: const Duration(minutes: 10),
      ),
    );
    benford = await system.spawn(
      'benford',
      () => BenfordCoordinatorActor(walletManager: walletManager, arcActor: arcActor, storage: readModel),
    );

    final created = await walletManager.ask<WalletCreatedMessage>(
      CreateWalletMessage(_walletId, 'Benford', xpriv: _xpriv),
      _wait,
    );
    expect(created.success, isTrue, reason: created.error);
    final generated = await walletManager.ask<AddressGeneratedResponse>(
      WalletCommandMessage(_walletId, GenerateAddressCommand(walletId: _walletId)),
      _wait,
    );
    final address = generated.address;
    for (var vout = 0; vout < _coins.length; vout++) {
      final received = await walletManager.ask<UTXOReceivedResponse>(
        WalletCommandMessage(
          _walletId,
          ReceiveUTXOCommand(
            walletId: _walletId,
            txid: _parent,
            vout: vout,
            satoshis: BigInt.from(_coins[vout]),
            scriptPubKey: dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(address)).getScriptPubkey().toHex(),
            address: address,
            blockHeight: 100,
            confirmations: 6,
            initialStatus: UTXOStatus.available,
          ),
        ),
        _wait,
      );
      expect(received.success, isTrue, reason: received.error);
    }
  });

  tearDown(() => system.shutdown());

  Future<SplitUTXOsResponse> split(SplitUTXOsToBenfordCommand command) =>
      benford.ask<SplitUTXOsResponse>(command, const Duration(seconds: 40));

  test('one coin to split is the largest, not the first stored', () async {
    final response = await split(SplitUTXOsToBenfordCommand(walletId: _walletId, targetUtxoCount: 3, maxUtxosToSplit: 1));

    expect(response.success, isTrue, reason: response.error);
    expect(response.splits!.single.sourceUtxoKey, _key(1));
    expect(response.splitCount, 3);
  });

  test('named coins only, the largest of them first', () async {
    final response = await split(SplitUTXOsToBenfordCommand(
        walletId: _walletId, targetUtxoCount: 2, utxoKeys: [_key(0), _key(2)]));

    expect(response.success, isTrue, reason: response.error);
    expect(response.splits!.map((s) => s.sourceUtxoKey).toList(), [_key(2), _key(0)]);
  });

  test('a piece size sets how many pieces each coin makes, within the target count', () async {
    final response = await split(SplitUTXOsToBenfordCommand(
        walletId: _walletId, targetUtxoCount: 50, utxoKeys: [_key(1), _key(2)], partSats: BigInt.from(10000)));

    expect(response.success, isTrue, reason: response.error);
    // 100,000 → 10 pieces, 20,000 → 2.
    expect(response.splitCount, 12);
  });

  test('no piece under the minimum: fewer pieces, or the coin is left whole', () async {
    final response = await split(SplitUTXOsToBenfordCommand(
        walletId: _walletId, targetUtxoCount: 10, utxoKeys: [_key(0), _key(3)], minPartSats: BigInt.from(1000)));

    // 5,000 less the fee makes 4 pieces of 1,000 or more; 1,500 makes none.
    expect(response.splitCount, 4);
    final whole = response.splits!.singleWhere((s) => s.sourceUtxoKey == _key(3));
    expect(whole.error, contains('too few for two pieces'));
  });

  test('none of the named coins available is refused', () async {
    final response = await split(SplitUTXOsToBenfordCommand(
        walletId: _walletId, targetUtxoCount: 3, utxoKeys: ['${'c3' * 32}:0']));

    expect(response.success, isFalse);
    expect(response.error, contains('None of the named UTXOs'));
  });
}

/// ARC that takes every transaction.
class _SeenArc extends OfflineArc {
  _SeenArc() : super(baseUrl: 'fake://arc');

  @override
  Future<ArcSubmitResponse> submitTransaction(String rawTx, {String? callbackUrl}) async =>
      ArcSubmitResponse.fromJson({'txid': dartsv.Transaction.fromHex(rawTx).id, 'txStatus': 'SEEN_ON_NETWORK'});

  @override
  Future<ArcTransactionResponse> getTransaction(String txid) async =>
      throw ArcException('Failed to get transaction: {"status":404}', statusCode: 404);
}
