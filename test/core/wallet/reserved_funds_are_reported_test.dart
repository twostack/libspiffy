/// Bead libspiffy-a5h8: money a reservation or a deferred payment's hold has
/// committed is the wallet's own, and it was reported nowhere.
///
/// Two halves, both of them a silence rather than a wrong number:
///
/// * `BalanceResponse` carried confirmed, unconfirmed, total and watch-only
///   balances and no reserved one, and `_handleGetBalance` read
///   `getPaymentUTXOs`, whose contract is `isAvailable && !isPluginManaged`,
///   so a reserved row was filtered out before the handler could see it.
///   Through the supported coordinator API the money simply vanished.
/// * `WalletBalances.noneSelectableReason` built its candidate list from the
///   available UTXOs alone, so a reserved one was dropped before any reason
///   was computed and the caller got the bare headline — including the
///   wallet frozen by a journaled deferred hold, the one case the "inputs of
///   a deferred payment" branch was written for. That branch read
///   `legacyDeferredHeldKeys`, which a journaled hold does not enter, and
///   `ChannelFunding` passed a `held` predicate to narrow a diagnosis the
///   status filter had already thrown away.
library;

import 'dart:async';

import 'package:dactor/dactor.dart';
import 'package:dactor_test/dactor_test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/core/wallet/channel_funding.dart';
import 'package:libspiffy/src/core/wallet/deferred_payments.dart';
import 'package:libspiffy/src/core/wallet/utxo_reservations.dart';
import 'package:libspiffy/src/core/wallet/wallet_keys.dart';
import 'package:libspiffy/src/core/wallet/wallet_lifecycle.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_balances.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

const _w = 'a5h8';
final _t0 = DateTime.utc(2026, 1, 1);
final _root = dartsv.SVPrivateKey.fromHex('11' * 32, dartsv.NetworkType.TEST).publicKey;
final _rootAddress = _root.toAddress(dartsv.NetworkType.TEST).toBase58();
final _other = dartsv.SVPrivateKey.fromHex('33' * 32, dartsv.NetworkType.TEST).publicKey;

String _txid(int n) => n.toRadixString(16).padLeft(64, '0');
String _key(int n) => '${_txid(n)}:0';
String _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();

BitcoinUtxo _utxo(
  int n,
  int sats, {
  UTXOStatus status = UTXOStatus.available,
  int? provenHeight = 900000,
  String? script,
  Map<String, dynamic>? pluginMetadata,
}) =>
    BitcoinUtxo.create(
      txid: _txid(n),
      vout: 0,
      satoshis: BigInt.from(sats),
      scriptPubKey: script ?? _p2pkh(_rootAddress),
      address: _rootAddress,
      blockHeight: provenHeight,
      status: status,
      pluginMetadata: pluginMetadata,
      createdAt: _t0,
    );

WalletState _with(WalletState state, void Function(WalletStateBuilder b) apply) {
  final b = state.toBuilder();
  apply(b);
  return b.build();
}

WalletState _created() => _with(
      WalletState.empty(_w),
      (b) => WalletLifecycle.applyWalletCreated(
        b,
        WalletCreatedEvent(
          walletId: _w,
          walletName: 'w',
          rootAddress: _rootAddress,
          walletType: WalletType.hd,
          walletMetadata: {'network': 'testnet'},
          version: 1,
          timestamp: _t0,
        ),
      ),
    );

WalletState _withUtxos(WalletState state, List<BitcoinUtxo> utxos) =>
    _with(state, (b) => [for (final u in utxos) b.putUtxo(u.key, u)]);

/// [state] after a deferred payment [txid] takes hold of [keys], journaled
/// the way `RecordOutgoingTransactionCommand` with `deferSpend` journals it:
/// the real event through the real apply, so the UTXO ends up reserved with
/// the hold's own `reservationReason` rather than one this test invented.
WalletState _heldByDeferredPayment(WalletState state, String txid, List<String> keys) => _with(
      state,
      (b) => DeferredPayments.applySpendDeferred(
        b,
        TransactionSpendDeferredEvent(
          walletId: _w,
          txid: txid,
          heldInputs: [
            for (final key in keys) {'utxoKey': key, 'satoshis': state.utxos[key]!.satoshis.toString()},
          ],
          recipientAddresses: const ['recipient'],
          purpose: 'channel-funding',
          recordedAt: _t0,
          version: state.version + 1,
          timestamp: _t0,
        ),
      ),
    );

/// [state] after an ordinary reservation of [key] — an in-flight payment's
/// input, which expires and which cleanup can release, unlike a hold.
WalletState _reserved(WalletState state, String key) => _with(
      state,
      (b) => UtxoReservations.applyReserved(
        b,
        UTXOReservedEvent(
          walletId: _w,
          txid: key.split(':')[0],
          vout: 0,
          reservedByTxId: 'in-flight',
          reservationReason: 'Reservation r1',
          expiresAt: _t0.add(const Duration(minutes: 30)),
          priority: 0,
          version: state.version + 1,
          timestamp: _t0,
        ),
      ),
    );

ChannelFunding _funding() => ChannelFunding(
    WalletKeys(cryptoService: DartSVCryptoService(), secureStorage: InMemorySecureStorage()), DeferredPayments());

String _fundingRefusal(WalletState state) {
  try {
    _funding().fundingCandidates(state);
  } on StateError catch (e) {
    return e.message;
  }
  fail('funding was not refused');
}

void main() {
  group('a5h8: the balance API reports reserved money', () {
    late TestActorSystem system;
    late InMemoryWalletStorage storage;
    late WalletCoordinatorActor coordinator;
    late ActorRef ref;
    late List<coord.CoordinatorEvent> events;

    setUp(() async {
      system = TestActorSystem();
      storage = InMemoryWalletStorage();
      await storage.storeWallet(_w, 'w', rootAddress: _rootAddress, networkType: 'testnet');
      final noop = await system.spawn('noop', () => _Noop());
      coordinator = WalletCoordinatorActor(
        walletManager: noop,
        invoiceCoordinator: noop,
        paymentCoordinator: noop,
        spvActor: noop,
        arcActor: noop,
        headerSyncActor: noop,
        benfordCoordinator: noop,
        channelManager: noop,
        walletProjection: noop,
        storage: storage,
      );
      events = [];
      final sub = coordinator.events.listen(events.add);
      addTearDown(sub.cancel);
      ref = await system.spawn('coordinator', () => coordinator);
    });

    tearDown(() async {
      await system.shutdown();
    });

    Future<coord.BalanceResponse> balance() async {
      ref.tell(coord.GetBalanceQuery(walletId: _w, queryId: 'q1'));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        final answered = events.whereType<coord.BalanceResponse>().where((e) => e.queryId == 'q1');
        if (answered.isNotEmpty) return answered.first;
        final failed = events.whereType<coord.ErrorEvent>();
        if (failed.isNotEmpty) fail('the balance query failed: ${failed.first.message}');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('no BalanceResponse within 5s; received: $events');
    }

    // The bead's own test: a stuck channel funding holds every input the
    // wallet has. Old code: every number came back zero, so an application
    // asking why could only conclude the money was gone.
    test('a wallet whose only funds are a deferred payment\'s held inputs reports them as reserved', () async {
      final held = _utxo(1, 90000, status: UTXOStatus.reserved)
          .reserve('funding-tx', priority: DeferredPayments.holdPriority, reason: DeferredPayments.holdReason);
      await storage.upsertUTXO(_w, held);

      final reported = await balance();

      expect(reported.reservedBalance, BigInt.from(90000), reason: 'the money is the wallet\'s, and committed');
      expect(reported.totalBalance, BigInt.zero, reason: 'committed is not spendable');
      expect(reported.confirmedBalance, BigInt.zero);
      expect(reported.unconfirmedBalance, BigInt.zero);
    });

    test('reserved money is reported apart from the spendable balance, and a pending UTXO still counts nowhere',
        () async {
      await storage.upsertUTXO(_w, _utxo(1, 10000));
      await storage.upsertUTXO(
          _w, _utxo(2, 20000).reserve('in-flight', reason: 'Reservation r1', timestamp: _t0));
      await storage.upsertUTXO(_w, _utxo(3, 40000, status: UTXOStatus.pending, provenHeight: null));

      final reported = await balance();

      expect(reported.confirmedBalance, BigInt.from(10000));
      expect(reported.unconfirmedBalance, BigInt.zero);
      expect(reported.reservedBalance, BigInt.from(20000),
          reason: 'an ordinary reservation is the wallet\'s money too');
      expect(reported.totalBalance, BigInt.from(10000),
          reason: 'reserved money is reported apart, exactly as watch-only money is');
    });

    test('a wallet holding nothing reserved reports zero, not null', () async {
      await storage.upsertUTXO(_w, _utxo(1, 10000));

      expect((await balance()).reservedBalance, BigInt.zero);
    });
  });

  group('a5h8: the refusal names the reservation that emptied the wallet', () {
    final funded = _withUtxos(_created(), [_utxo(1, 90000)]);

    // Old code: 'No available UTXOs for funding', full stop. The branch that
    // exists to say this read legacyDeferredHeldKeys, which a journaled hold
    // does not enter, so it could fire only for a payment recorded before
    // holds were journaled.
    test('a wallet frozen by a journaled deferred hold is told its inputs are held, not that it has none', () {
      final held = _heldByDeferredPayment(funded, 'funding-tx', [_key(1)]);
      expect(held.utxos[_key(1)]!.status, UTXOStatus.reserved, reason: 'a journaled hold reserves the input');
      expect(WalletBalances.isDeferredHeld(held, held.utxos[_key(1)]!), isTrue);

      expect(_fundingRefusal(held), contains('inputs of a deferred payment, held until it settles or is reclaimed'));
    });

    // A hold and a reservation are both `reserved`, and they are different
    // answers: a reservation expires and cleanup releases it, while a hold
    // ends only with the payment.
    test('an ordinary reservation is named as a payment in flight, not as a deferred hold', () {
      final reserved = _reserved(funded, _key(1));
      expect(reserved.utxos[_key(1)]!.status, UTXOStatus.reserved);
      expect(WalletBalances.isDeferredHeld(reserved, reserved.utxos[_key(1)]!), isFalse);

      final refusal = _fundingRefusal(reserved);
      expect(refusal, contains('reserved for a payment in flight'));
      expect(refusal, isNot(contains('deferred payment')));
    });

    test('a legacy inferred hold is still named, and names the same reason as a journaled one', () {
      final legacy = _with(
        funded,
        (b) => b.metadata = b.metadata.put('outgoingTransactions', {
          'old': {
            'txid': 'old',
            'spentUtxoKeys': [_key(1)],
            'deferSpend': true,
            'recordedAt': _t0.toIso8601String(),
          }
        }),
      );
      expect(legacy.legacyDeferredHeldKeys, {_key(1)}, reason: 'inferred, and the UTXO stays available');
      expect(legacy.utxos[_key(1)]!.status, UTXOStatus.available);

      expect(_fundingRefusal(legacy), contains('inputs of a deferred payment'));
    });

    test('a wallet holding nothing at all still gets the bare headline', () {
      expect(_fundingRefusal(_created()), 'No available UTXOs for funding');
    });

    group('the order the reasons are walked in', () {
      // The walk narrows: it names the exclusion that emptied the wallet,
      // not the first kind of output it saw. A wallet holding one token and
      // one reserved UTXO still has an ordinary output after the token is
      // put aside, so what it is told about is the reservation.
      test('a wallet holding a token and a reserved output is told about the reservation', () {
        final mixed = _reserved(
          _withUtxos(_created(), [
            _utxo(1, 90000),
            _utxo(2, 500, pluginMetadata: {'pluginId': 'token-protocol', 'tokenId': 't1'}),
          ]),
          _key(1),
        );

        expect(_fundingRefusal(mixed), contains('reserved for a payment in flight'));
      });

      // Precedence shows on one output carrying two exclusions at once.
      // From "not yours to spend at all" to "yours, but not on its own":
      // plugin-managed, watch-only, held by a deferred payment, reserved,
      // cannot be unlocked alone. A reserved output is money committed, so
      // it sits next to the hold it is a cousin of.
      test('an output that is both plugin-managed and reserved is named as its plugin\'s', () {
        final both = _reserved(
          _withUtxos(_created(), [_utxo(1, 500, pluginMetadata: {'pluginId': 'token-protocol', 'tokenId': 't1'})]),
          _key(1),
        );

        expect(_fundingRefusal(both), contains('plugin-managed'));
      });

      // Every journaled hold carries both exclusions: it *is* a reservation,
      // marked with the hold's own reason. The more specific answer wins,
      // which is the whole point of telling the two apart.
      test('a held input, which is reserved too, is named as held rather than as in flight', () {
        final held = _heldByDeferredPayment(_withUtxos(_created(), [_utxo(1, 90000)]), 'funding-tx', [_key(1)]);

        final refusal = _fundingRefusal(held);
        expect(refusal, contains('inputs of a deferred payment'));
        expect(refusal, isNot(contains('in flight')));
      });

      test('an output that is both reserved and unspendable alone is named as reserved', () {
        final twoOfTwo = dartsv.P2MSLockBuilder([_root, _other], 2, sorting: false).getScriptPubkey().toHex();
        final both = _reserved(_withUtxos(_created(), [_utxo(1, 500, script: twoOfTwo)]), _key(1));

        final refusal = _fundingRefusal(both);
        expect(refusal, contains('reserved for a payment in flight'));
        expect(refusal, isNot(contains('cannot unlock on its own')));
      });
    });
  });
}

class _Noop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}
