/// Read-model keying contract shared by the three [ReadModelStorage]
/// backends (audit 2026-09-14 S-05, S-12, S-13, S-17, S-18 and the
/// header re-activation bead libspiffy-0v3).
///
/// [defineReadModelKeyingContract] registers the same tests for every
/// backend; each backend's test file supplies a fresh storage per test.
library;

import 'package:crypto/crypto.dart' show sha256;
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:spiffynode/spiffy_node.dart';
import 'package:test/test.dart';

import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/transaction_address_link.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

/// A 64-hex id derived from [tag] (unique per tag).
String contractHex64(String tag) =>
    sha256.convert(tag.codeUnits).toString();

/// A header unique per [seed], chained to [prev].
BlockHeader contractHeader(int seed, {String? prev}) => BlockHeader(
      version: 1,
      prevBlock: Hash.fromHex(prev ?? contractHex64('prev-$seed')),
      merkleRoot: Hash.fromHex(contractHex64('merkle-$seed')),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (1231469665 + seed) * 1000,
        isUtc: true,
      ),
      bits: 0x1d00ffff,
      nonce: seed,
    );

BitcoinTransaction _tx(String txid, BigInt netAmount,
        {TransactionStatus status = TransactionStatus.pending}) =>
    BitcoinTransaction(
      txid: txid,
      rawHex: '0100000000000000000000',
      status: status,
      blockHeight: null,
      confirmations: 0,
      inputValue: BigInt.from(2000),
      outputValue: BigInt.from(1800),
      fee: BigInt.from(200),
      receivingAddresses: const ['mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt'],
      sendingAddresses: const [],
      netAmount: netAmount,
      createdAt: DateTime.utc(2026, 9, 14, 12),
      updatedAt: DateTime.utc(2026, 9, 14, 12),
      lockTime: 0,
      version: 1,
    );

BitcoinUtxo _utxo(String txid, int vout, int sats,
        {UTXOStatus status = UTXOStatus.available,
        Map<String, dynamic>? pluginMetadata}) =>
    BitcoinUtxo(
      txid: txid,
      vout: vout,
      value: dartsv.Coin.ofSat(BigInt.from(sats)),
      scriptPubKey: '76a914000000000000000000000000000000000000000088ac',
      address: 'mkHS9ne12qx9pS9VojpwU5xtRd4T7X7ZUt',
      status: status,
      createdAt: DateTime.utc(2026, 9, 14, 12),
      updatedAt: DateTime.utc(2026, 9, 14, 12),
      pluginMetadata: pluginMetadata,
    );

AddressMetadata _address(String address,
        {int index = 0, bool isChange = false, String? label}) =>
    AddressMetadata(
      address: address,
      scriptType: 'p2pkh',
      derivationPath: "m/0/${isChange ? 1 : 0}/$index",
      derivationIndex: index,
      isChange: isChange,
      label: label,
      purpose: isChange ? 'change' : 'receive',
      usageCount: 0,
      balance: BigInt.zero,
      createdAt: DateTime.utc(2026, 9, 14, 12, 0, index),
      isWatched: true,
    );

/// Registers the keying contract tests.
///
/// [storage] returns the storage for the running test. [unique] returns a
/// string unique per test run (the Postgres database outlives a run).
/// [baseHeight] keeps header heights clear of other tests; [beforeHeaders]
/// runs before each header test (Postgres clears its header table).
void defineReadModelKeyingContract(
  ReadModelStorage Function() storage, {
  required String Function() unique,
  int baseHeight = 1000,
  Future<void> Function()? beforeHeaders,
}) {
  group('read-model keying contract', () {
    // ------------------------------------------------------------------
    // S-05: transactions and UTXOs are per wallet
    // ------------------------------------------------------------------

    test('S-05: two wallets record the same txid with their own amounts and directions',
        () async {
      final s = storage();
      final u = unique();
      final walletA = 'kc-a-$u';
      final walletB = 'kc-b-$u';
      final txid = contractHex64('shared-tx-$u');
      await s.storeWallet(walletA, 'A');
      await s.storeWallet(walletB, 'B');

      // A pays B: outgoing for A, incoming for B.
      await s.storeTransaction(walletA, _tx(txid, BigInt.from(-1200)));
      await s.storeTransaction(walletB, _tx(txid, BigInt.from(1000)));

      final historyA = await s.getTransactionHistory(walletA);
      final historyB = await s.getTransactionHistory(walletB);
      expect(historyB.map((t) => t.txid), [txid],
          reason: "wallet B's copy of the shared txid must be stored");
      expect(historyB.single.netAmount, BigInt.from(1000));
      expect(historyA.map((t) => t.txid), [txid]);
      expect(historyA.single.netAmount, BigInt.from(-1200),
          reason: "wallet B's store must not overwrite wallet A's row");

      // Wallet-scoped lookup; without a wallet id the first-stored row.
      expect((await s.getTransaction(txid, walletId: walletA))?.netAmount,
          BigInt.from(-1200));
      expect((await s.getTransaction(txid, walletId: walletB))?.netAmount,
          BigInt.from(1000));
      expect(await s.getTransaction(txid, walletId: 'kc-none-$u'), isNull);
      expect((await s.getTransaction(txid))?.netAmount, BigInt.from(-1200));
      expect((await s.getTransactionsBatch([txid]))[txid]?.netAmount,
          BigInt.from(-1200));

      // A status update by B touches only B's row.
      await s.storeTransaction(walletB,
          _tx(txid, BigInt.from(1000), status: TransactionStatus.confirmed));
      expect((await s.getTransactionHistory(walletA)).single.status,
          TransactionStatus.pending);
      expect((await s.getTransactionHistory(walletB)).single.status,
          TransactionStatus.confirmed);
      expect(
          (await s.getTransactionsByStatus(TransactionStatus.confirmed,
                  walletId: walletA))
              .map((t) => t.txid),
          isNot(contains(txid)));
    });

    test('S-05: a UTXO of wallet B at an outpoint wallet A already holds is stored',
        () async {
      final s = storage();
      final u = unique();
      final walletA = 'kc-ua-$u';
      final walletB = 'kc-ub-$u';
      final txid = contractHex64('shared-utxo-$u');
      await s.storeWallet(walletA, 'A');
      await s.storeWallet(walletB, 'B');

      await s.upsertUTXO(walletA, _utxo(txid, 0, 5000));
      await s.upsertUTXO(walletB, _utxo(txid, 0, 5000));

      expect((await s.getUTXOs(walletB)).map((x) => '${x.txid}:${x.vout}'),
          ['$txid:0']);
      expect((await s.getUTXOs(walletA)).map((x) => '${x.txid}:${x.vout}'),
          ['$txid:0']);

      // B spending its copy leaves A's untouched.
      await s.upsertUTXO(walletB, _utxo(txid, 0, 5000, status: UTXOStatus.spent));
      expect(await s.getBalance(walletA), BigInt.from(5000));
      expect(await s.getBalance(walletB), BigInt.zero);
      await s.deleteUTXO(walletB, txid, 0);
      expect(await s.getUTXOs(walletA, includeSpent: true), hasLength(1));
    });

    // ------------------------------------------------------------------
    // libspiffy-0v3 / S-12: block headers
    // ------------------------------------------------------------------

    test('0v3: a header orphaned earlier becomes active again when re-stored',
        () async {
      await beforeHeaders?.call();
      final s = storage();
      final h1 = contractHeader(baseHeight + 1);
      final h2 = contractHeader(baseHeight + 2, prev: h1.blockHash().toString());
      final h3 = contractHeader(baseHeight + 3, prev: h2.blockHash().toString());
      final h3b = contractHeader(baseHeight + 33, prev: h2.blockHash().toString());
      final hash3 = h3.blockHash().toString();
      final hash3b = h3b.blockHash().toString();
      final height3 = baseHeight + 3;

      await s.storeBlockHeader(h1, baseHeight + 1);
      await s.storeBlockHeader(h2, baseHeight + 2);
      await s.storeBlockHeader(h3, height3);

      // Reorg to h3b ...
      await s.markHeaderAsOrphaned(hash3);
      await s.storeBlockHeader(h3b, height3);
      expect((await s.getChainTip())!.blockHash().toString(), hash3b);

      // ... and back to h3, in the order BlockHeaderChain uses.
      await s.markHeaderAsOrphaned(hash3b);
      await s.storeBlockHeader(h3, height3);

      expect((await s.getBlockHeaderByHeight(height3))?.blockHash().toString(),
          hash3,
          reason: 'the re-stored header must no longer be orphaned');
      expect((await s.getChainTip())?.blockHash().toString(), hash3);
      expect(await s.getBestHeight(), height3);
      expect(await s.getHeightByBlockHash(hash3), height3);
      expect(await s.getBlockHeaderByHash(hash3), isNotNull);
      expect(await s.getBlockHeaderByHash(hash3b), isNull);
      expect(await s.getBlockHeaderRange(height3, height3), hasLength(1));
    });

    test('S-12: re-storing a header (single and bulk) is idempotent', () async {
      await beforeHeaders?.call();
      final s = storage();
      final h1 = contractHeader(baseHeight + 51);
      final h2 = contractHeader(baseHeight + 52, prev: h1.blockHash().toString());

      await s.storeBlockHeader(h1, baseHeight + 51);
      await s.storeBlockHeader(h1, baseHeight + 51);
      await s.storeBlockHeadersBulk([(h1, baseHeight + 51), (h2, baseHeight + 52)]);
      await s.storeBlockHeadersBulk([(h1, baseHeight + 51), (h2, baseHeight + 52)]);

      final range = await s.getBlockHeaderRange(baseHeight + 51, baseHeight + 52);
      expect(range.map((h) => h.blockHash().toString()),
          [h1.blockHash().toString(), h2.blockHash().toString()]);
      expect(await s.getBestHeight(), baseHeight + 52);
    });

    // ------------------------------------------------------------------
    // S-12 / S-18: addresses
    // ------------------------------------------------------------------

    test('S-12: the same address in two wallets is stored for both', () async {
      final s = storage();
      final u = unique();
      final walletA = 'kc-aa-$u';
      final walletB = 'kc-ab-$u';
      final address = 'addr-shared-$u';

      await s.upsertAddress(walletA, _address(address, label: 'a'));
      await s.upsertAddress(walletB, _address(address, label: 'b'));

      expect(await s.isWalletAddress(walletA, address), isTrue);
      expect(await s.isWalletAddress(walletB, address), isTrue);
      expect(await s.getAddressCount(walletA), 1);
      expect(await s.getAddressCount(walletB), 1);
      expect((await s.getAddressMetadata(walletA, address))?.label, 'a');
      expect((await s.getAddressMetadata(walletB, address))?.label, 'b');

      // Updating one wallet's row leaves the other's alone.
      await s.upsertAddress(walletA, _address(address, label: 'a2'));
      expect((await s.getAddressMetadata(walletA, address))?.label, 'a2');
      expect((await s.getAddressMetadata(walletB, address))?.label, 'b');
      expect(await s.getAddressCount(walletA), 1);
    });

    test('S-18: address API stores, queries and tracks usage', () async {
      final s = storage();
      final u = unique();
      final wallet = 'kc-addr-$u';
      final other = 'kc-addr-other-$u';
      final r0 = 'addr-r0-$u';
      final r1 = 'addr-r1-$u';
      final c0 = 'addr-c0-$u';

      await s.upsertAddress(wallet, _address(r0, index: 0));
      await s.upsertAddress(wallet, _address(r1, index: 1));
      await s.upsertAddress(wallet, _address(c0, index: 0, isChange: true));

      expect(await s.getAddressCount(wallet), 3);
      expect(await s.isWalletAddress(wallet, r1), isTrue);
      expect(await s.isWalletAddress(other, r1), isFalse);
      expect(await s.checkAddresses(wallet, [r0, 'nope-$u']),
          {r0: true, 'nope-$u': false});

      final meta = await s.getAddressMetadata(wallet, c0);
      expect(meta, isNotNull);
      expect(meta!.isChange, isTrue);
      expect(meta.derivationIndex, 0);
      expect(meta.purpose, 'change');

      expect((await s.getAddressesWithMetadata(wallet, isChange: false))
          .map((a) => a.address)
          .toSet(), {r0, r1});
      expect((await s.getAddressRange(wallet, startIndex: 0, count: 2))
          .map((a) => a.address)
          .toList(), [r0, r1]);
      expect((await s.getAddressRange(wallet, startIndex: 1, count: 5))
          .map((a) => a.address)
          .toList(), [r1]);

      // Receipt: usage and balance go up.
      final usedAt = DateTime.utc(2026, 9, 14, 13);
      await s.updateAddressUsage(wallet, r1,
          usedAt: usedAt, balanceDelta: BigInt.from(1000));
      var r1meta = await s.getAddressMetadata(wallet, r1);
      expect(r1meta!.usageCount, 1);
      expect(r1meta.balance, BigInt.from(1000));
      expect(r1meta.firstUsedAt, isNotNull);
      expect((await s.getAddressesWithMetadata(wallet, includeUnused: false))
          .map((a) => a.address), [r1]);

      // Spend (the projection passes only a balance delta): balance goes
      // down, the usage count does not.
      await s.updateAddressUsage(wallet, r1, balanceDelta: BigInt.from(-1000));
      r1meta = await s.getAddressMetadata(wallet, r1);
      expect(r1meta!.usageCount, 1);
      expect(r1meta.balance, BigInt.zero);

      // Upsert keeps one row per (wallet, address).
      await s.upsertAddress(wallet, _address(r0, index: 0, label: 'relabelled'));
      expect(await s.getAddressCount(wallet), 3);
      expect((await s.getAddressMetadata(wallet, r0))!.label, 'relabelled');
    });

    test('p4kv: getAddressesByPurpose returns only that wallet\'s rows with that purpose', () async {
      final s = storage();
      final u = unique();
      final wallet = 'kc-purpose-$u';
      final other = 'kc-purpose-other-$u';
      final registered = DateTime.utc(2025, 6, 1, 8, 30);
      AddressMetadata watch(String address, {String? label}) => AddressMetadata(
            address: address,
            scriptType: 'p2pk',
            isChange: false,
            label: label,
            purpose: 'watch',
            usageCount: 2,
            balance: BigInt.from(1500),
            createdAt: registered,
            isWatched: true,
          );

      await s.upsertAddress(wallet, _address('addr-r0-$u', index: 0));
      await s.upsertAddress(wallet, _address('addr-c0-$u', index: 0, isChange: true));
      await s.upsertAddress(wallet, watch('addr-w1-$u', label: 'cold'));
      await s.upsertAddress(wallet, watch('addr-w2-$u'));
      await s.upsertAddress(other, watch('addr-w3-$u'));

      final rows = await s.getAddressesByPurpose(wallet, 'watch');
      expect(rows.map((a) => a.address).toSet(), {'addr-w1-$u', 'addr-w2-$u'});
      final w1 = rows.firstWhere((a) => a.address == 'addr-w1-$u');
      expect((w1.scriptType, w1.label, w1.purpose, w1.isChange, w1.usageCount, w1.balance),
          ('p2pk', 'cold', 'watch', false, 2, BigInt.from(1500)));
      expect(w1.createdAt.isAtSameMomentAs(registered), isTrue);
      expect(w1.derivationIndex, isNull);

      expect((await s.getAddressesByPurpose(wallet, 'change')).map((a) => a.address), ['addr-c0-$u']);
      expect(await s.getAddressesByPurpose('kc-purpose-none-$u', 'watch'), isEmpty);
    });

    // ------------------------------------------------------------------
    // S-13: merkle proofs
    // ------------------------------------------------------------------

    // Since bead mny the first proof is kept as orphaned
    // (merkle_proof_retention_contract.dart); it is no longer current.
    test('S-13: a second proof for a txid replaces the first as the current proof', () async {
      final s = storage();
      final u = unique();
      final txid = contractHex64('proof-tx-$u');
      final blockA = contractHex64('proof-block-a-$u');
      final blockB = contractHex64('proof-block-b-$u');
      final bumpA = 'fe${contractHex64('bump-a-$u')}';
      final bumpB = 'fe${contractHex64('bump-b-$u')}';

      await s.storeMerkleProof(txid, MerkleProof(
          blockHash: blockA, txid: txid, merkleProof: [bumpA], position: 1, blockHeight: 10));
      // Reorg: the transaction is mined again in block B.
      await s.storeMerkleProof(txid, MerkleProof(
          blockHash: blockB, txid: txid, merkleProof: [bumpB], position: 2, blockHeight: 11));
      await s.storeMerkleProof(txid, MerkleProof(
          blockHash: blockB, txid: txid, merkleProof: [bumpB], position: 2, blockHeight: 11));

      final proof = await s.getMerkleProof(txid);
      expect(proof, isNotNull);
      expect(proof!.blockHash, blockB, reason: 'the second proof must win');
      expect(proof.merkleProof, [bumpB]);
      expect(proof.blockHeight, 11);
      expect((await s.getMerkleProofsBatch([txid]))[txid]!.blockHash, blockB);
      expect(await s.getMerkleProofsForBlock(blockA), isEmpty,
          reason: 'the replaced proof is no longer current');
      expect(await s.getMerkleProofsForBlock(blockB), hasLength(1),
          reason: 'exactly one row per (txid, block)');
    });

    test('S-13: a proof with no segments reads back with no segments', () async {
      final s = storage();
      final u = unique();
      final txid = contractHex64('proof-empty-$u');
      final block = contractHex64('proof-empty-block-$u');
      await s.storeMerkleProof(txid, MerkleProof(
          blockHash: block, txid: txid, merkleProof: const [], position: 0, blockHeight: 12));
      expect((await s.getMerkleProof(txid))!.merkleProof, isEmpty);
    });

    // ------------------------------------------------------------------
    // S-17 / S-18: transaction-address junction
    // ------------------------------------------------------------------

    test('S-17: storing the junction rows twice leaves one set', () async {
      final s = storage();
      final u = unique();
      final wallet = 'kc-junction-$u';
      final txid = contractHex64('junction-tx-$u');
      final addrIn = 'addr-in-$u';
      final addrOut = 'addr-out-$u';
      final addrChange = 'addr-change-$u';
      final links = [
        TransactionAddressLink(
            address: addrIn, direction: 'input', amount: BigInt.from(3000), vin: 0),
        TransactionAddressLink(
            address: addrOut, direction: 'output', amount: BigInt.from(2000), vout: 0),
        TransactionAddressLink(
            address: addrChange, direction: 'output', amount: BigInt.from(800), vout: 1),
      ];

      await s.storeTransactionAddresses(wallet, txid, links);
      await s.storeTransactionAddresses(wallet, txid, links); // replay

      final stored = await s.getTransactionAddresses(wallet, txid);
      expect(stored.inputs.map((l) => l.address), [addrIn]);
      expect(stored.inputs.single.vin, 0);
      expect(stored.outputs.map((l) => '${l.address}:${l.vout}:${l.amount}').toSet(),
          {'$addrOut:0:2000', '$addrChange:1:800'});
      expect(stored.outputs, hasLength(2));
      expect(await s.getTransactionsByAddress(wallet, addrOut), [txid]);
      expect(await s.getTransactionsByAddress(wallet, addrOut, direction: 'input'),
          isEmpty);
      expect(await s.getAddressTransactionCount(wallet, addrIn), 1);
      expect(await s.getTransactionAddresses('kc-junction-other-$u', txid),
          isA<TransactionAddresses>().having((t) => t.allAddresses, 'all', isEmpty));

      // A replay with a different link set replaces the old one.
      await s.storeTransactionAddresses(wallet, txid, links.sublist(1, 2));
      final replaced = await s.getTransactionAddresses(wallet, txid);
      expect(replaced.inputs, isEmpty);
      expect(replaced.outputs.map((l) => l.address), [addrOut]);
    });

    // ------------------------------------------------------------------
    // S-18: payment UTXO rule
    // ------------------------------------------------------------------

    test('S-18: only UTXOs with a pluginId are excluded from payment UTXOs', () async {
      final s = storage();
      final u = unique();
      final wallet = 'kc-pay-$u';
      final txid = contractHex64('pay-$u');
      await s.storeWallet(wallet, 'pay');

      await s.upsertUTXO(wallet, _utxo(txid, 0, 1000));
      // Script-analysis metadata only: still a plain payment output.
      await s.upsertUTXO(wallet,
          _utxo(txid, 1, 2000, pluginMetadata: {'scriptType': 'p2pkh'}));
      await s.upsertUTXO(wallet, _utxo(txid, 2, 1,
          pluginMetadata: {'pluginId': 'tstoken', 'scriptType': 'pp1_nft'}));

      expect((await s.getPaymentUTXOs(wallet)).map((x) => x.vout).toSet(), {0, 1});
      expect(await s.getBalance(wallet), BigInt.from(3000));
      expect((await s.getUTXOsByPlugin(wallet, 'tstoken')).map((x) => x.vout), [2]);
    });

    test(
        'vsap / 0k8: getBalance leaves out watch-only UTXOs and bare multisig UTXOs the wallet cannot '
        'spend alone; getWatchOnlyBalance reports the watch-only ones', () async {
      final s = storage();
      final u = unique();
      final wallet = 'kc-bal-$u';
      await s.storeWallet(wallet, 'balance', networkType: 'testnet');

      dartsv.SVPublicKey key(String byte) => dartsv.SVPrivateKey.fromHex(byte * 32, dartsv.NetworkType.TEST).publicKey;
      String addressOf(dartsv.SVPublicKey k) => k.toAddress(dartsv.NetworkType.TEST).toBase58();
      String p2pkh(String a) =>
          dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(a)).getScriptPubkey().toHex();
      String multisig(List<dartsv.SVPublicKey> keys, int m) =>
          dartsv.P2MSLockBuilder(keys, m, sorting: false).getScriptPubkey().toHex();
      final walletKey = key('31');
      final serverKey = key('11');
      final watchKey = key('22');
      final own = addressOf(walletKey);
      final watched = addressOf(watchKey);
      await s.upsertAddress(wallet, _address(own));
      await s.upsertAddress(
          wallet,
          AddressMetadata(
            address: watched,
            scriptType: 'p2pkh',
            isChange: false,
            purpose: 'watch',
            usageCount: 0,
            balance: BigInt.zero,
            createdAt: DateTime.utc(2026, 9, 14),
            isWatched: true,
          ));

      final txid = contractHex64('bal-$u');
      Future<void> put(int vout, int sats, String script, String address,
              {UTXOStatus status = UTXOStatus.available}) =>
          s.upsertUTXO(
              wallet,
              _utxo(txid, vout, sats, status: status)
                  .copyWith(scriptPubKey: script, address: address));
      await put(0, 1000, p2pkh(own), own); // spendable
      await put(1, 20000, p2pkh(watched), watched); // watch-only
      await put(2, 300000, multisig([walletKey, serverKey], 2), own); // cannot spend alone (a journal before viy)
      await put(3, 4000, multisig([serverKey, walletKey], 1), own); // 1-of-2 with a wallet key: spendable
      await put(4, 50000, multisig([watchKey, walletKey], 2), watched); // needs the watch key: watch-only
      await put(5, 7, p2pkh(own), own, status: UTXOStatus.pending); // not available

      expect(await s.getBalance(wallet), BigInt.from(5000));
      expect(await s.getWatchOnlyBalance(wallet), BigInt.from(70000));
      expect((await s.getPaymentUTXOs(wallet)).length, 5, reason: 'the rows are kept and listed');
    });

    // Bead libspiffy-kfvv. A P2PK output locked to a key the wallet does not
    // hold can be attributed to a wallet (no command or replay path checks a
    // P2PK script's key), and channel funding refused to spend it while both
    // balances went on counting it — the two layers disagreeing about the
    // same output. `unlocksAlone` is now the one predicate both ask.
    test('kfvv: getBalance leaves out a P2PK UTXO locked to a key the wallet does not hold', () async {
      final s = storage();
      final u = unique();
      final wallet = 'kc-p2pk-$u';
      await s.storeWallet(wallet, 'p2pk', networkType: 'testnet');

      dartsv.SVPublicKey key(String byte) => dartsv.SVPrivateKey.fromHex(byte * 32, dartsv.NetworkType.TEST).publicKey;
      final walletKey = key('31');
      final foreignKey = key('11');
      final own = walletKey.toAddress(dartsv.NetworkType.TEST).toBase58();
      await s.upsertAddress(wallet, _address(own));

      final txid = contractHex64('p2pk-$u');
      Future<void> put(int vout, int sats, String script) => s.upsertUTXO(
          wallet,
          _utxo(txid, vout, sats)
              .copyWith(scriptPubKey: script, address: own));
      await put(0, 1000, dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(own)).getScriptPubkey().toHex());
      // The wallet's own key: a P2PK output is its money and stays spendable.
      await put(1, 800, dartsv.P2PKLockBuilder(walletKey).getScriptPubkey().toHex());
      // Someone else's key: the wallet can never sign it.
      await put(2, 90000, dartsv.P2PKLockBuilder(foreignKey).getScriptPubkey().toHex());

      expect(await s.getBalance(wallet), BigInt.from(1800));
      expect(await s.getWatchOnlyBalance(wallet), BigInt.zero,
          reason: 'no watch address is involved: it is not watch-only funds');
      expect((await s.getPaymentUTXOs(wallet)).length, 3, reason: 'the row is kept and listed');
    });
  });
}
