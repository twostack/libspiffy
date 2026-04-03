import 'package:test/test.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

/// Phase 2 tests: Token-aware UTXO management.
///
/// Verifies that plugin-managed UTXOs (tokens) are correctly excluded from
/// payment UTXO selection, balance calculations, and aggregate-level queries.
void main() {
  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Create a regular (non-token) UTXO.
  BitcoinUtxo createRegularUtxo(
    String txid,
    int vout,
    int sats, {
    UTXOStatus status = UTXOStatus.available,
  }) {
    return BitcoinUtxo.create(
      txid: txid,
      vout: vout,
      satoshis: BigInt.from(sats),
      scriptPubKey: '76a914abcd123456789012345678901234567890abcdef88ac',
      address: '1Regular${txid}Address',
      blockHeight: 750000,
      confirmations: 6,
      status: status,
    );
  }

  /// Create a token UTXO (PP1) with plugin metadata.
  BitcoinUtxo createTokenUtxo(
    String txid,
    int vout,
    int sats, {
    String scriptType = 'pp1_nft',
    String tokenId = 'deadbeef01234567890abcdef01234567890abcdef01234567890abcdef0123',
    UTXOStatus status = UTXOStatus.available,
    int? amount,
  }) {
    return BitcoinUtxo.create(
      txid: txid,
      vout: vout,
      satoshis: BigInt.from(sats),
      scriptPubKey: '76a914token123456789012345678901234567890abcdef88ac',
      address: '1Token${txid}Address',
      blockHeight: 750000,
      confirmations: 6,
      status: status,
      pluginMetadata: {
        'pluginId': 'tstoken',
        'scriptType': scriptType,
        'tokenId': tokenId,
        'ownerAddress': '1Token${txid}Address',
        if (amount != null) 'amount': amount,
      },
    );
  }

  // ---------------------------------------------------------------------------
  // BitcoinUtxo.hasPluginMetadata
  // ---------------------------------------------------------------------------

  group('BitcoinUtxo.hasPluginMetadata', () {
    test('returns false for regular UTXO', () {
      final utxo = createRegularUtxo('tx1', 0, 50000);
      expect(utxo.hasPluginMetadata, isFalse);
    });

    test('returns true for token UTXO', () {
      final utxo = createTokenUtxo('tx2', 1, 1);
      expect(utxo.hasPluginMetadata, isTrue);
    });

    test('returns true for empty plugin metadata map', () {
      final utxo = BitcoinUtxo.create(
        txid: 'tx3',
        vout: 0,
        satoshis: BigInt.from(1000),
        scriptPubKey: '76a914abcd88ac',
        address: '1Addr',
        pluginMetadata: {},
      );
      expect(utxo.hasPluginMetadata, isTrue);
    });

    test('preserved through copyWith', () {
      final original = createTokenUtxo('tx4', 0, 1);
      final copied = original.copyWith(txid: 'tx4_copy');
      expect(copied.hasPluginMetadata, isTrue);
      expect(copied.pluginMetadata!['pluginId'], equals('tstoken'));
    });

    test('preserved through reserve and release', () {
      final utxo = createTokenUtxo('tx5', 0, 1);

      final reserved = utxo.reserve('reservation_1');
      expect(reserved.hasPluginMetadata, isTrue);
      expect(reserved.status, equals(UTXOStatus.reserved));

      final released = reserved.releaseReservation();
      expect(released.hasPluginMetadata, isTrue);
      expect(released.status, equals(UTXOStatus.available));
    });

    test('preserved through updateConfirmations', () {
      final utxo = createTokenUtxo('tx6', 0, 1,
          status: UTXOStatus.pending);
      final confirmed = utxo.updateConfirmations(
        blockHeight: 800000,
        confirmations: 3,
      );
      expect(confirmed.hasPluginMetadata, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // InMemoryWalletStorage.getPaymentUTXOs
  // ---------------------------------------------------------------------------

  group('InMemoryWalletStorage.getPaymentUTXOs', () {
    late InMemoryWalletStorage storage;
    const walletId = 'test-wallet';

    setUp(() async {
      storage = InMemoryWalletStorage();
      await storage.storeWallet(walletId, 'Test Wallet');
    });

    test('returns empty list for empty wallet', () async {
      final utxos = await storage.getPaymentUTXOs(walletId);
      expect(utxos, isEmpty);
    });

    test('returns regular UTXOs only', () async {
      await storage.upsertUTXO(walletId, createRegularUtxo('tx1', 0, 50000));
      await storage.upsertUTXO(walletId, createRegularUtxo('tx2', 0, 30000));

      final utxos = await storage.getPaymentUTXOs(walletId);
      expect(utxos.length, equals(2));
      expect(utxos.every((u) => !u.hasPluginMetadata), isTrue);
    });

    test('excludes token UTXOs', () async {
      await storage.upsertUTXO(walletId, createRegularUtxo('tx1', 0, 50000));
      await storage.upsertUTXO(walletId, createTokenUtxo('tx2', 1, 1));
      await storage.upsertUTXO(walletId, createTokenUtxo('tx2', 2, 1));
      await storage.upsertUTXO(walletId, createTokenUtxo('tx2', 3, 1));

      final paymentUtxos = await storage.getPaymentUTXOs(walletId);
      expect(paymentUtxos.length, equals(1));
      expect(paymentUtxos.first.txid, equals('tx1'));
    });

    test('getAvailableUTXOs still returns all including tokens', () async {
      await storage.upsertUTXO(walletId, createRegularUtxo('tx1', 0, 50000));
      await storage.upsertUTXO(walletId, createTokenUtxo('tx2', 1, 1));

      final allUtxos = await storage.getAvailableUTXOs(walletId);
      expect(allUtxos.length, equals(2));

      final paymentUtxos = await storage.getPaymentUTXOs(walletId);
      expect(paymentUtxos.length, equals(1));
    });

    test('excludes non-available UTXOs', () async {
      await storage.upsertUTXO(
          walletId, createRegularUtxo('tx1', 0, 50000, status: UTXOStatus.spent));
      await storage.upsertUTXO(
          walletId, createRegularUtxo('tx2', 0, 30000, status: UTXOStatus.pending));
      await storage.upsertUTXO(
          walletId, createRegularUtxo('tx3', 0, 20000, status: UTXOStatus.available));

      final utxos = await storage.getPaymentUTXOs(walletId);
      expect(utxos.length, equals(1));
      expect(utxos.first.txid, equals('tx3'));
    });

    test('returns empty when all UTXOs are tokens', () async {
      await storage.upsertUTXO(
          walletId, createTokenUtxo('tx1', 1, 1, scriptType: 'pp1_nft'));
      await storage.upsertUTXO(
          walletId, createTokenUtxo('tx1', 2, 1, scriptType: 'pp2'));
      await storage.upsertUTXO(
          walletId, createTokenUtxo('tx1', 3, 1, scriptType: 'pp1_ft'));

      final utxos = await storage.getPaymentUTXOs(walletId);
      expect(utxos, isEmpty);
    });

    test('handles mixed available and token UTXOs correctly', () async {
      // Regular: 50k + 30k + 20k = 100k sats
      await storage.upsertUTXO(walletId, createRegularUtxo('reg1', 0, 50000));
      await storage.upsertUTXO(walletId, createRegularUtxo('reg2', 0, 30000));
      await storage.upsertUTXO(walletId, createRegularUtxo('reg3', 0, 20000));
      // Tokens: 1 + 1 + 1 = 3 sats
      await storage.upsertUTXO(walletId, createTokenUtxo('tok1', 1, 1));
      await storage.upsertUTXO(walletId, createTokenUtxo('tok2', 1, 1));
      await storage.upsertUTXO(walletId, createTokenUtxo('tok3', 1, 1));
      // Spent regular: should not appear
      await storage.upsertUTXO(
          walletId, createRegularUtxo('spent1', 0, 99999, status: UTXOStatus.spent));

      final paymentUtxos = await storage.getPaymentUTXOs(walletId);
      expect(paymentUtxos.length, equals(3));

      final txids = paymentUtxos.map((u) => u.txid).toSet();
      expect(txids, containsAll(['reg1', 'reg2', 'reg3']));
    });

    test('throws StorageException for non-existent wallet', () async {
      expect(
        () => storage.getPaymentUTXOs('nonexistent'),
        throwsA(isA<StorageException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // InMemoryWalletStorage.getBalance (excludes tokens)
  // ---------------------------------------------------------------------------

  group('InMemoryWalletStorage.getBalance (token exclusion)', () {
    late InMemoryWalletStorage storage;
    const walletId = 'test-wallet';

    setUp(() async {
      storage = InMemoryWalletStorage();
      await storage.storeWallet(walletId, 'Test Wallet');
    });

    test('returns zero for empty wallet', () async {
      final balance = await storage.getBalance(walletId);
      expect(balance, equals(BigInt.zero));
    });

    test('sums only regular UTXOs', () async {
      await storage.upsertUTXO(walletId, createRegularUtxo('tx1', 0, 50000));
      await storage.upsertUTXO(walletId, createRegularUtxo('tx2', 0, 30000));

      final balance = await storage.getBalance(walletId);
      expect(balance, equals(BigInt.from(80000)));
    });

    test('excludes token UTXOs from balance', () async {
      await storage.upsertUTXO(walletId, createRegularUtxo('tx1', 0, 50000));
      await storage.upsertUTXO(walletId, createTokenUtxo('tx2', 1, 1));
      await storage.upsertUTXO(walletId, createTokenUtxo('tx3', 1, 1));

      final balance = await storage.getBalance(walletId);
      // Should be 50000, NOT 50002
      expect(balance, equals(BigInt.from(50000)));
    });

    test('returns zero when all UTXOs are tokens', () async {
      await storage.upsertUTXO(walletId, createTokenUtxo('tx1', 1, 1));
      await storage.upsertUTXO(walletId, createTokenUtxo('tx2', 1, 1));

      final balance = await storage.getBalance(walletId);
      expect(balance, equals(BigInt.zero));
    });

    test('balance matches getPaymentUTXOs sum', () async {
      await storage.upsertUTXO(walletId, createRegularUtxo('tx1', 0, 50000));
      await storage.upsertUTXO(walletId, createRegularUtxo('tx2', 0, 25000));
      await storage.upsertUTXO(walletId, createTokenUtxo('tok1', 1, 1));

      final balance = await storage.getBalance(walletId);
      final paymentUtxos = await storage.getPaymentUTXOs(walletId);
      final utxoSum = paymentUtxos.fold<BigInt>(
          BigInt.zero, (sum, u) => sum + u.satoshis);

      expect(balance, equals(utxoSum));
      expect(balance, equals(BigInt.from(75000)));
    });
  });

  // ---------------------------------------------------------------------------
  // WalletState UTXO filtering (mirrors aggregate getAvailableUTXOs logic)
  // ---------------------------------------------------------------------------

  group('WalletState UTXO filtering', () {
    WalletState createStateWithUtxos(Map<String, BitcoinUtxo> utxos) {
      final now = DateTime.now();
      return WalletState(
        walletId: 'test-wallet',
        name: 'Test',
        isCreated: true,
        isDeleted: false,
        networkType: 'test',
        walletType: WalletType.hd,
        timestamp: now,
        utxos: utxos,
        addresses: {},
        nextDerivationIndex: 0,
        metadata: {},
        confirmedBalance: dartsv.Coin.ofSat(BigInt.zero),
        unconfirmedBalance: dartsv.Coin.ofSat(BigInt.zero),
        reservedBalance: dartsv.Coin.ofSat(BigInt.zero),
        version: 1,
        lastModified: now,
      );
    }

    /// Replicate the aggregate's getAvailableUTXOs logic for testing.
    List<BitcoinUtxo> getPaymentUtxosFromState(WalletState state) {
      return state.utxos.values
          .where((utxo) =>
              utxo.status == UTXOStatus.available && !utxo.hasPluginMetadata)
          .toList();
    }

    test('filters out token UTXOs from available set', () {
      final regular = createRegularUtxo('reg1', 0, 50000);
      final token = createTokenUtxo('tok1', 1, 1);

      final state = createStateWithUtxos({
        regular.key: regular,
        token.key: token,
      });

      final available = getPaymentUtxosFromState(state);
      expect(available.length, equals(1));
      expect(available.first.txid, equals('reg1'));
    });

    test('filters out both non-available and token UTXOs', () {
      final regular = createRegularUtxo('reg1', 0, 50000);
      final spent =
          createRegularUtxo('spent1', 0, 30000, status: UTXOStatus.spent);
      final reserved =
          createRegularUtxo('res1', 0, 20000, status: UTXOStatus.reserved);
      final token = createTokenUtxo('tok1', 1, 1);

      final state = createStateWithUtxos({
        regular.key: regular,
        spent.key: spent,
        reserved.key: reserved,
        token.key: token,
      });

      final available = getPaymentUtxosFromState(state);
      expect(available.length, equals(1));
      expect(available.first.txid, equals('reg1'));
    });

    test('returns empty when all UTXOs are tokens', () {
      final token1 = createTokenUtxo('tok1', 1, 1, scriptType: 'pp1_nft');
      final token2 = createTokenUtxo('tok2', 1, 1, scriptType: 'pp1_ft');

      final state = createStateWithUtxos({
        token1.key: token1,
        token2.key: token2,
      });

      final available = getPaymentUtxosFromState(state);
      expect(available, isEmpty);
    });

    test('UTXO selection for payment skips large token UTXOs', () {
      // Regular: 50k + 30k = 80k total
      final reg1 = createRegularUtxo('reg1', 0, 50000);
      final reg2 = createRegularUtxo('reg2', 0, 30000);
      // Token: 100k sats (large, but should be skipped in selection)
      final token = createTokenUtxo('tok1', 1, 100000);

      final state = createStateWithUtxos({
        reg1.key: reg1,
        reg2.key: reg2,
        token.key: token,
      });

      final payable = getPaymentUtxosFromState(state);
      expect(payable.length, equals(2));
      expect(payable.every((u) => !u.hasPluginMetadata), isTrue);

      final totalPayable =
          payable.fold<BigInt>(BigInt.zero, (sum, u) => sum + u.satoshis);
      expect(totalPayable, equals(BigInt.from(80000)));
    });

    test('mixed archetypes: all token types excluded from payment set', () {
      final regular = createRegularUtxo('reg1', 0, 100000);
      final nft = createTokenUtxo('nft1', 1, 1, scriptType: 'pp1_nft');
      final ft = createTokenUtxo('ft1', 1, 1, scriptType: 'pp1_ft', amount: 500);
      final at = createTokenUtxo('at1', 1, 1, scriptType: 'pp1_at');
      final rnft = createTokenUtxo('rnft1', 1, 1, scriptType: 'pp1_rnft');
      final pp2 = createTokenUtxo('pp2_1', 2, 1, scriptType: 'pp2');

      final state = createStateWithUtxos({
        regular.key: regular,
        nft.key: nft,
        ft.key: ft,
        at.key: at,
        rnft.key: rnft,
        pp2.key: pp2,
      });

      final payable = getPaymentUtxosFromState(state);
      expect(payable.length, equals(1));
      expect(payable.first.txid, equals('reg1'));
    });
  });

  // ---------------------------------------------------------------------------
  // getUTXOsByPlugin (existing method, verify it still works)
  // ---------------------------------------------------------------------------

  group('InMemoryWalletStorage.getUTXOsByPlugin', () {
    late InMemoryWalletStorage storage;
    const walletId = 'test-wallet';

    setUp(() async {
      storage = InMemoryWalletStorage();
      await storage.storeWallet(walletId, 'Test Wallet');
    });

    test('returns only UTXOs matching plugin ID', () async {
      await storage.upsertUTXO(walletId, createRegularUtxo('reg1', 0, 50000));
      await storage.upsertUTXO(walletId, createTokenUtxo('tok1', 1, 1));
      await storage.upsertUTXO(walletId, createTokenUtxo('tok2', 1, 1));

      final tokenUtxos =
          await storage.getUTXOsByPlugin(walletId, 'tstoken');
      expect(tokenUtxos.length, equals(2));
      expect(tokenUtxos.every((u) => u.hasPluginMetadata), isTrue);
    });

    test('returns empty for non-matching plugin ID', () async {
      await storage.upsertUTXO(walletId, createTokenUtxo('tok1', 1, 1));

      final utxos = await storage.getUTXOsByPlugin(walletId, 'ordinals');
      expect(utxos, isEmpty);
    });

    test('filters by metadata when provided', () async {
      await storage.upsertUTXO(walletId,
          createTokenUtxo('tok1', 1, 1, scriptType: 'pp1_nft'));
      await storage.upsertUTXO(walletId,
          createTokenUtxo('tok2', 1, 1, scriptType: 'pp1_ft'));

      final nftOnly = await storage.getUTXOsByPlugin(
        walletId,
        'tstoken',
        metadataFilter: {'scriptType': 'pp1_nft'},
      );
      expect(nftOnly.length, equals(1));
      expect(nftOnly.first.pluginMetadata!['scriptType'], equals('pp1_nft'));
    });

    test('includes spent token UTXOs', () async {
      await storage.upsertUTXO(walletId,
          createTokenUtxo('tok1', 1, 1, status: UTXOStatus.spent));
      await storage.upsertUTXO(walletId,
          createTokenUtxo('tok2', 1, 1, status: UTXOStatus.available));

      final utxos = await storage.getUTXOsByPlugin(walletId, 'tstoken');
      expect(utxos.length, equals(2));
    });
  });

  // ---------------------------------------------------------------------------
  // Edge cases: UTXO lifecycle with plugin metadata
  // ---------------------------------------------------------------------------

  group('UTXO lifecycle with plugin metadata', () {
    late InMemoryWalletStorage storage;
    const walletId = 'test-wallet';

    setUp(() async {
      storage = InMemoryWalletStorage();
      await storage.storeWallet(walletId, 'Test Wallet');
    });

    test('token UTXO that becomes spent disappears from both queries', () async {
      final token = createTokenUtxo('tok1', 1, 1);
      await storage.upsertUTXO(walletId, token);

      // Available in getAvailableUTXOs, not in getPaymentUTXOs
      expect((await storage.getAvailableUTXOs(walletId)).length, equals(1));
      expect((await storage.getPaymentUTXOs(walletId)).length, equals(0));

      // Mark spent
      final spent = token.copyWith(
        status: UTXOStatus.spent,
      );
      await storage.upsertUTXO(walletId, spent);

      // Gone from both
      expect((await storage.getAvailableUTXOs(walletId)).length, equals(0));
      expect((await storage.getPaymentUTXOs(walletId)).length, equals(0));
    });

    test('upsert preserves plugin metadata', () async {
      final token = createTokenUtxo('tok1', 1, 1);
      await storage.upsertUTXO(walletId, token);

      // Update confirmations
      final updated = token.updateConfirmations(
        blockHeight: 800000,
        confirmations: 10,
      );
      await storage.upsertUTXO(walletId, updated);

      final utxos = await storage.getUTXOsByPlugin(walletId, 'tstoken');
      expect(utxos.length, equals(1));
      expect(utxos.first.pluginMetadata!['scriptType'], equals('pp1_nft'));
      expect(utxos.first.confirmations, equals(10));
    });

    test('multiple archetype tokens coexist correctly', () async {
      await storage.upsertUTXO(walletId,
          createTokenUtxo('nft1', 1, 1, scriptType: 'pp1_nft'));
      await storage.upsertUTXO(walletId,
          createTokenUtxo('ft1', 1, 1, scriptType: 'pp1_ft', amount: 1000));
      await storage.upsertUTXO(walletId,
          createTokenUtxo('at1', 1, 1, scriptType: 'pp1_at'));
      await storage.upsertUTXO(walletId,
          createTokenUtxo('rnft1', 1, 1, scriptType: 'pp1_rnft'));
      await storage.upsertUTXO(walletId, createRegularUtxo('reg1', 0, 100000));

      // All 5 available
      expect((await storage.getAvailableUTXOs(walletId)).length, equals(5));
      // Only 1 regular for payments
      expect((await storage.getPaymentUTXOs(walletId)).length, equals(1));
      // 4 tokens
      expect(
          (await storage.getUTXOsByPlugin(walletId, 'tstoken')).length, equals(4));
      // Balance is only the regular UTXO
      expect(await storage.getBalance(walletId), equals(BigInt.from(100000)));
    });
  });
}
