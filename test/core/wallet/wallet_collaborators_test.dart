/// libspiffy-dp4: the wallet aggregate's collaborators (lib/src/core/wallet/)
/// tested on their own, on states built directly, with no actor system,
/// event store or aggregate.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/core/wallet/address_book.dart';
import 'package:libspiffy/src/core/wallet/channel_funding.dart';
import 'package:libspiffy/src/core/wallet/deferred_payments.dart';
import 'package:libspiffy/src/core/wallet/outgoing_transactions.dart';
import 'package:libspiffy/src/core/wallet/transaction_signer.dart';
import 'package:libspiffy/src/core/wallet/utxo_ledger.dart';
import 'package:libspiffy/src/core/wallet/utxo_reservations.dart';
import 'package:libspiffy/src/core/wallet/wallet_keys.dart';
import 'package:libspiffy/src/core/wallet/wallet_lifecycle.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/persistent_map.dart';
import 'package:libspiffy/src/models/wallet_balances.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

const _w = 'collaborators';
final _t0 = DateTime.utc(2026, 1, 1);
final _root = dartsv.SVPrivateKey.fromHex('11' * 32, dartsv.NetworkType.TEST).publicKey;
final _rootAddress = _root.toAddress(dartsv.NetworkType.TEST).toBase58();
final _watchAddress =
    dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST).publicKey.toAddress(dartsv.NetworkType.TEST).toBase58();

String _txid(int n) => n.toRadixString(16).padLeft(64, '0');
String _key(int n) => '${_txid(n)}:0';
String _p2pkh(String address) =>
    dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey().toHex();

/// [state] with [apply] applied to a draft of it.
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

/// [provenHeight] is the block a verified merkle proof puts the UTXO in —
/// what the confirmed bucket counts (bead libspiffy-jc3h) — and
/// [confirmations] a count someone reported, which counts towards nothing.
BitcoinUtxo _utxo(int n, int sats,
        {UTXOStatus status = UTXOStatus.available,
        int? provenHeight = 900000,
        int? confirmations,
        String? address,
        String? script,
        Map<String, dynamic>? pluginMetadata}) =>
    BitcoinUtxo.create(
      txid: _txid(n),
      vout: 0,
      satoshis: BigInt.from(sats),
      scriptPubKey: script ?? _p2pkh(address ?? _rootAddress),
      address: address ?? _rootAddress,
      blockHeight: provenHeight,
      confirmations: confirmations,
      status: status,
      pluginMetadata: pluginMetadata,
      createdAt: _t0,
    );

WalletState _withUtxos(WalletState state, List<BitcoinUtxo> utxos) =>
    _with(state, (b) => [for (final u in utxos) b.putUtxo(u.key, u)]);

TransactionRecordedEvent _recorded(String txid, List<String> inputs, int version, DateTime at) =>
    TransactionRecordedEvent(
      walletId: _w,
      txid: txid,
      rawHex: '',
      totalInputSats: 0,
      totalOutputSats: 0,
      fee: 10,
      numInputs: inputs.length,
      numOutputs: 1,
      txVersion: 1,
      txLockTime: 0,
      spentUtxoKeys: inputs,
      recipientAddresses: const ['x'],
      paymentAmount: '5',
      version: version,
      timestamp: at,
    );

void main() {
  group('WalletBalances and WalletStateBuilder.putUtxo', () {
    // Bead libspiffy-jc3h: this pinned a six-confirmation boundary, which no
    // longer exists anywhere. Confirmed is the proven block height, at depth
    // one as at depth six, and a reported count decides nothing.
    test('the bucket of each status, and the proven-height boundary', () {
      expect(WalletBalances.bucketOf(_utxo(1, 1, status: UTXOStatus.spent)), isNull);
      expect(WalletBalances.bucketOf(_utxo(1, 1, status: UTXOStatus.voided)), isNull);
      expect(WalletBalances.bucketOf(_utxo(1, 1, status: UTXOStatus.reserved)), BalanceBucket.reserved);
      expect(WalletBalances.bucketOf(_utxo(1, 1)), BalanceBucket.confirmed);
      expect(WalletBalances.bucketOf(_utxo(1, 1, provenHeight: null, confirmations: 9)),
          BalanceBucket.unconfirmed,
          reason: 'a reported count is not evidence of any block');
      expect(WalletBalances.bucketOf(_utxo(1, 1, status: UTXOStatus.pending)), BalanceBucket.confirmed);
    });

    test('putUtxo moves a replaced UTXO\'s amount between balances; recomputeBalances and totals agree', () {
      var state = _withUtxos(_created(), [_utxo(1, 100), _utxo(2, 20, provenHeight: null), _utxo(3, 3)]);
      state = _with(state, (b) {
        b.putUtxo(_key(1), b.utxos[_key(1)]!.copyWith(status: UTXOStatus.reserved));
        b.putUtxo(_key(3), b.utxos[_key(3)]!.markSpent(timestamp: _t0, spentInTxId: 's'));
      });
      expect([state.confirmedBalance.getValue(), state.unconfirmedBalance.getValue(), state.reservedBalance.getValue()],
          [BigInt.zero, BigInt.from(20), BigInt.from(100)]);
      final totals = WalletBalances.totals(state.utxos.values);
      expect([totals.confirmed, totals.unconfirmed, totals.reserved], [BigInt.zero, BigInt.from(20), BigInt.from(100)]);
      final recomputed = _with(
          state.copyWithWallet(confirmedBalance: dartsv.Coin.ofSat(BigInt.from(999))), (b) => b.recomputeBalances());
      expect(recomputed.confirmedBalance.getValue(), BigInt.zero);
      expect(recomputed.reservedBalance.getValue(), BigInt.from(100));
    });
  });

  group('AddressBook', () {
    test('derivation records: typed from an untyped snapshot map, chain defaults to receive', () {
      final state = _with(_created(), (b) {
        b.metadata = b.metadata
            .put(AddressBook.addressIndicesKey, freezeMap({'a': 3, 'bad': 'x'}))
            .put(AddressBook.addressChainsKey, freezeMap({'a': true}));
        AddressBook.typeRestoredDerivationRecords(b);
      });
      expect(state.metadata[AddressBook.addressIndicesKey], isA<PersistentMap<String, int>>());
      expect(AddressBook.addressIndices(state.metadata), {'a': 3});
      expect(AddressBook.isChangeAddress(state, 'a'), isTrue);
      expect(AddressBook.isChangeAddress(state, _rootAddress), isFalse);
      expect(AddressBook.addressIndices(state.metadata).containsKey(_rootAddress), isFalse,
          reason: 'the restore typing replaces the records it is given');
    });

    test('watch addresses: an owned or repeated address journals nothing', () {
      final state = _created();
      final events = AddressBook.reconcileWatchAddresses(
        state,
        ReconcileWatchAddressesCommand(walletId: _w, addresses: [
          LegacyWatchAddress(address: _rootAddress, scriptType: 'p2pkh', registeredAt: _t0),
          LegacyWatchAddress(address: _watchAddress, scriptType: 'p2pkh', registeredAt: _t0),
          LegacyWatchAddress(address: _watchAddress, scriptType: 'p2pkh', registeredAt: _t0),
        ]),
      );
      expect([for (final e in events.cast<WatchAddressAddedEvent>()) (e.address, e.reconciled, e.version)],
          [(_watchAddress, true, 2)]);
      final watched = _with(state, (b) => AddressBook.applyWatchAddressAdded(b, events.single as WatchAddressAddedEvent));
      expect(AddressBook.addWatchAddress(watched, AddWatchAddressCommand(walletId: _w, address: _watchAddress, scriptType: 'p2pkh')),
          isEmpty);
    });
  });

  group('WalletKeys', () {
    const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
    WalletKeys keys(InMemorySecureStorage storage) =>
        WalletKeys(cryptoService: DartSVCryptoService(), secureStorage: storage);

    test('walletRoot refuses a WIF for another network and writes nothing', () async {
      final storage = InMemorySecureStorage();
      final mainnetWif = dartsv.SVPrivateKey.fromHex('33' * 32, dartsv.NetworkType.MAIN).toWIF();
      await expectLater(
        keys(storage).walletRoot(CreateWalletCommand(walletId: _w, walletName: 'w', wif: mainnetWif)),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message', 'WIF network type does not match wallet network type')),
      );
      expect(await storage.getWIF(_w), isNull);
    });

    test('a generated change address is signed for with the change-chain key its record names', () async {
      final storage = InMemorySecureStorage();
      final k = keys(storage);
      final command = CreateWalletCommand(walletId: _w, walletName: 'w', mnemonic: mnemonic);
      final root = await k.walletRoot(command);
      expect((root.walletType, root.networkName), (WalletType.hd, 'testnet'));
      await k.storeKeyMaterial(command, root.hdPublicKeyXpub);
      var state = _with(WalletState.empty(_w),
          (b) => WalletLifecycle.applyWalletCreated(b, WalletLifecycle.created(WalletState.empty(_w), command, root)));
      final generated = (await k.generateAddress(
        state,
        GenerateAddressCommand(walletId: _w, purpose: AddressBook.changePurpose, includePublicKey: true),
      ))
          .single as AddressGeneratedEvent;
      state = _with(state, (b) => AddressBook.applyAddressGenerated(b, generated));

      final key = await k.privateKeyForAddress(generated.address, _w, state);
      expect(key.publicKey.toHex(), generated.publicKeyHex);
      final receiveKey = await k.privateKeyAtIndex(_w, generated.derivationIndex, state);
      expect(receiveKey.publicKey.toHex(), isNot(generated.publicKeyHex));

      await k.removeKeyMaterial(_w, cause: 'test');
      for (final key in WalletKeys.keyMaterialKeys(_w)) {
        expect(await storage.getString(key), isNull, reason: key);
      }
    });
  });

  group('UtxoLedger', () {
    test('available, selection and watch-only exclusion', () {
      final state = _withUtxos(
        _with(_created(), (b) => b.watchAddresses = b.watchAddresses.put(_watchAddress, 'p2pkh')),
        [_utxo(1, 5), _utxo(2, 50, status: UTXOStatus.pending), _utxo(3, 30), _utxo(4, 90, address: _watchAddress)],
      );
      expect(UtxoLedger.isWatchOnly(state, state.utxos[_key(4)]!), isTrue);
      expect(UtxoLedger.available(state).map((u) => u.key), [_key(1), _key(3)]);
      expect(UtxoLedger.selectForAmount(state, BigInt.from(31)).map((u) => u.key), [_key(3), _key(1)]);
      expect(() => UtxoLedger.selectForAmount(state, BigInt.from(36)),
          throwsA(isA<StateError>().having((e) => e.message, 'message', 'Insufficient funds: need 36 satoshis, have 35 available')));
    });

    test('a pending input is spendable by the wallet\'s own recorded transaction only', () {
      var state = _withUtxos(_created(), [_utxo(1, 5, status: UTXOStatus.pending)]);
      SpendUTXOCommand spend(String txid) =>
          SpendUTXOCommand(walletId: _w, utxoKey: _key(1), spendingTxId: txid, fee: BigInt.zero);
      expect(() => UtxoLedger.spend(state, spend('t1')), throwsA(isA<StateError>()));
      state = _with(state, (b) => OutgoingTransactions.applyRecorded(b, _recorded('t1', [_key(1)], 2, _t0)));
      expect((UtxoLedger.spend(state, spend('t1')).single as UTXOSpentEvent).spentInTxId, 't1');
      expect(OutgoingTransactions.recordedTransactionSpends(state, 't1', _key(1)), isTrue);
    });
  });

  group('UtxoReservations and DeferredPayments', () {
    test('a live reservation is taken only at a higher priority; a held input at none', () {
      final deferred = DeferredPayments();
      final reservations = UtxoReservations(deferred);
      var state = _withUtxos(_created(), [_utxo(1, 5), _utxo(2, 6)]);
      state = _with(state, (b) {
        UtxoReservations.applyReserved(
            b,
            UTXOReservedEvent(
                walletId: _w, txid: _txid(1), vout: 0, reservedByTxId: 'low', priority: 3,
                expiresAt: DateTime.now().add(const Duration(hours: 1)), version: 2, timestamp: _t0));
        DeferredPayments.applySpendDeferred(
            b,
            TransactionSpendDeferredEvent(
                walletId: _w, txid: 'held', heldInputs: [{'utxoKey': _key(2), 'satoshis': '6'}], recipientAddresses: const [],
                paymentAmount: '1', fee: 1, recordedAt: _t0, version: 3, timestamp: _t0));
      });
      ReserveUTXOCommand reserve(String key, int priority) =>
          ReserveUTXOCommand(walletId: _w, utxoKey: key, reservedByTxId: 'x', priority: priority);

      expect(() => reservations.reserve(state, reserve(_key(1), 3)),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('higher or equal priority'))));
      expect(reservations.reserve(state, reserve(_key(1), 4)), hasLength(1));
      expect(() => reservations.reserve(state, reserve(_key(2), 1 << 31)),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('held by deferred payment held'))));
      expect(state.utxos[_key(2)]!.reservationPriority, DeferredPayments.holdPriority);
      expect(reservations.releaseMany(state, ReleaseUTXOsCommand(walletId: _w, reservationId: 'held')), isEmpty);
    });

    test('the "no legacy payment" finding carries over events that cannot create one, and not over those that can',
        () {
      final deferred = DeferredPayments();
      final before = _withUtxos(_created(), [_utxo(1, 5)]);
      expect(deferred.legacySpends(before), isEmpty); // inferred once for `before`

      // States that do hold an un-journaled deferred payment, reached (as far
      // as the finding knows) from `before`: across an event that cannot
      // create one the finding carries over and the inference does not run
      // again; across one that can, it runs.
      WalletState withLegacy() =>
          _with(before, (b) => OutgoingTransactions.applyRecorded(b, _recorded('old', [_key(1)], 2, _t0)));
      final noOp = WatchAddressAddedEvent(
          walletId: _w, address: _watchAddress, scriptType: 'p2pkh', registeredAt: _t0, version: 2, timestamp: _t0);
      final carried = withLegacy();
      deferred.stateApplied(before, carried, noOp);
      expect(deferred.legacySpends(carried), isEmpty);
      expect(carried.legacyDeferredHeldKeys, isEmpty, reason: 'the spendable rule reads the same finding');

      final inferred = withLegacy();
      deferred.stateApplied(before, inferred, _recorded('old', [_key(1)], 2, _t0));
      final legacy = deferred.legacySpends(inferred).single;
      expect(legacy.txid, 'old');
      expect(legacy.heldKeys, [_key(1)]);
      expect(deferred.holderOf(inferred, _key(1)), 'old');
      expect(inferred.legacyDeferredHeldKeys, {_key(1)});
      expect(WalletBalances.isSpendable(inferred, inferred.utxos[_key(1)]!), isFalse);

      // A state never told about `before` infers for itself.
      expect(DeferredPayments().legacySpends(withLegacy()).single.txid, 'old');
    });
  });

  group('OutgoingTransactions', () {
    test('records in the list shape of older states are found and converted on the next record', () {
      final listShaped = _with(_created(), (b) {
        b.metadata = b.metadata.put('outgoingTransactions', freezeDeep([
          {'txid': 'a', 'spentUtxoKeys': [_key(1)], 'recordedAt': '2020-01-01T00:00:00.000'},
        ]));
      });
      expect(OutgoingTransactions.isRecorded(listShaped, 'a'), isTrue);
      expect(OutgoingTransactions.recordedTransactionSpends(listShaped, 'a', _key(1)), isTrue);
      final next = _with(listShaped, (b) => OutgoingTransactions.applyRecorded(b, _recorded('a', [_key(2)], 2, _t0)));
      final records = next.metadata['outgoingTransactions'] as Map;
      expect(records.keys, ['a']);
      expect((records['a'] as Map)['recordedAt'], '2020-01-01T00:00:00.000', reason: 'the first record time is kept');
      expect((records['a'] as Map)['spentUtxoKeys'], [_key(2)]);
    });
  });

  group('WalletTransactionSigner and ChannelFunding', () {
    test('a P2PKH key check names the UTXO; the P2PK unlocking script is the signature alone', () {
      final other = dartsv.SVPrivateKey.fromHex('44' * 32, dartsv.NetworkType.TEST).publicKey;
      final script = dartsv.SVScript.fromHex(_p2pkh(_rootAddress));
      expect(() => WalletTransactionSigner.requireKeyForP2pkh('k', _rootAddress, script, _root), returnsNormally);
      expect(
          () => WalletTransactionSigner.requireKeyForP2pkh('k', _rootAddress, script, other),
          throwsA(isA<StateError>().having(
              (e) => e.message, 'message', startsWith('Cannot sign UTXO k at $_rootAddress: the wallet holds no key for it'))));
      expect(SignatureOnlyUnlockBuilder().getScriptSig().chunks, isEmpty);
    });

    test(
        'funding candidates leave out held, watch-only and un-unlockable UTXOs, largest first, and name why none is left',
        () {
      final deferred = DeferredPayments();
      final funding = ChannelFunding(
          WalletKeys(cryptoService: DartSVCryptoService(), secureStorage: InMemorySecureStorage()), deferred);
      // A P2PK output to a wallet key and a 1-of-2 multisig the wallet's key
      // meets are the wallet's own money: they fund a channel (bead
      // libspiffy-8egy). A 2-of-2 the counterparty must co-sign, and a P2PK
      // to someone else's key, do not.
      final p2pk = dartsv.P2PKLockBuilder(_root).getScriptPubkey().toHex();
      final other = dartsv.SVPrivateKey.fromHex('33' * 32, dartsv.NetworkType.TEST).publicKey;
      final foreignP2pk = dartsv.P2PKLockBuilder(other).getScriptPubkey().toHex();
      final oneOfTwo = dartsv.P2MSLockBuilder([_root, other], 1, sorting: false).getScriptPubkey().toHex();
      final twoOfTwo = dartsv.P2MSLockBuilder([_root, other], 2, sorting: false).getScriptPubkey().toHex();
      final base = _with(_created(), (b) => b.watchAddresses = b.watchAddresses.put(_watchAddress, 'p2pkh'));
      final state = _withUtxos(base, [
        _utxo(1, 10),
        _utxo(2, 70, script: p2pk),
        _utxo(3, 80, address: _watchAddress),
        _utxo(4, 40),
        _utxo(5, 90, status: UTXOStatus.reserved),
        _utxo(6, 60, script: oneOfTwo),
        _utxo(7, 100, script: twoOfTwo),
        _utxo(8, 110, script: foreignP2pk),
      ]);
      expect(funding.fundingCandidates(state).map((u) => u.key), [_key(2), _key(6), _key(4), _key(1)]);

      expect(() => funding.fundingCandidates(_withUtxos(base, [_utxo(3, 80, address: _watchAddress)])),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('are at watch addresses'))));
      expect(() => funding.fundingCandidates(_withUtxos(base, [_utxo(7, 100, script: twoOfTwo)])),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('cannot unlock on its own'))));
      expect(() => funding.fundingCandidates(_withUtxos(base, [_utxo(8, 110, script: foreignP2pk)])),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('cannot unlock on its own'))));
      expect(() => funding.fundingCandidates(base),
          throwsA(isA<StateError>().having((e) => e.message, 'message', 'No available UTXOs for funding')));
    });

    // A token output or a funding earmark is its plugin's to spend (bead
    // libspiffy-ecy8): `WalletBalances.isSpendable` leaves it out of every
    // other selection the wallet makes, and channel funding now selects by
    // that same rule (bead libspiffy-qfmb). Spending one as plain satoshis
    // consumes the output the plugin's state stands on.
    final token = _utxo(9, 500, pluginMetadata: {'pluginId': 'token-protocol', 'tokenId': 't1'});

    test('a wallet whose only funds are plugin-managed cannot fund a channel, and the error says why', () {
      final funding = ChannelFunding(
          WalletKeys(cryptoService: DartSVCryptoService(), secureStorage: InMemorySecureStorage()), DeferredPayments());
      final onlyToken = _withUtxos(_created(), [token]);
      expect(WalletBalances.isSpendable(onlyToken, token), isFalse, reason: 'the shared rule already excludes it');
      expect(() => funding.fundingCandidates(onlyToken),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('plugin-managed'))));
    });

    test('a wallet holding a plugin-managed and an ordinary UTXO funds from the ordinary one only', () {
      final funding = ChannelFunding(
          WalletKeys(cryptoService: DartSVCryptoService(), secureStorage: InMemorySecureStorage()), DeferredPayments());
      final mixed = _withUtxos(_created(), [token, _utxo(10, 100)]);
      expect(funding.fundingCandidates(mixed).map((u) => u.key), [_key(10)],
          reason: 'the larger plugin-managed output is not the wallet\'s to spend, however it is sorted');
    });
  });

  test('WalletLifecycle: a deleted wallet is not deleted twice', () {
    final deleted = _with(
        _created(), (b) => WalletLifecycle.applyWalletDeleted(b, WalletDeletedEvent(walletId: _w, version: 2, timestamp: _t0)));
    expect(() => WalletLifecycle.delete(deleted, DeleteWalletCommand(walletId: _w)),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'Wallet $_w is already deleted')));
  });
}
