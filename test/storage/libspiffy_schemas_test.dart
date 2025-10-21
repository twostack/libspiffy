import 'package:test/test.dart';
import 'package:spiffynode/spiffy_node.dart';
import 'package:libspiffy/src/storage/libspiffy_schemas.dart';
import 'package:libspiffy/src/storage/wallet_storage.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/bitcoin_transaction.dart';

/// Tests for LibSpiffy schema entity conversions
void main() {
  group('BlockHeaderEntity Conversion', () {
    test('should convert BlockHeader to entity and back', () {
      // Create a test BlockHeader
      final originalHeader = BlockHeader(
        version: 1,
        prevBlock: Hash.fromHex('0' * 64),
        merkleRoot: Hash.fromHex('a' * 64),
        timestamp: DateTime(2024, 1, 1, 12, 0, 0),
        bits: 0x1d00ffff,
        nonce: 12345,
      );

      // Convert to entity
      final entity = BlockHeaderEntity.fromBlockHeader(originalHeader, 100);

      // Verify entity fields
      expect(entity.height, equals(100));
      expect(entity.version, equals(1));
      expect(entity.bits, equals(0x1d00ffff));
      expect(entity.nonce, equals(12345));
      expect(entity.isOrphaned, isFalse);
      expect(entity.hash, equals(originalHeader.blockHash().toString()));

      // Convert back to BlockHeader
      final reconstructed = entity.toBlockHeader();

      // Verify all fields match
      expect(reconstructed.version, equals(originalHeader.version));
      expect(reconstructed.prevBlock.toString(), equals(originalHeader.prevBlock.toString()));
      expect(reconstructed.merkleRoot.toString(), equals(originalHeader.merkleRoot.toString()));
      expect(reconstructed.timestamp, equals(originalHeader.timestamp));
      expect(reconstructed.bits, equals(originalHeader.bits));
      expect(reconstructed.nonce, equals(originalHeader.nonce));
    });

    test('should handle real Bitcoin block header', () {
      // Block 1 from Bitcoin mainnet
      final block1Header = BlockHeader(
        version: 1,
        prevBlock: Hash.fromHex('000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f'),
        merkleRoot: Hash.fromHex('0e3e2357e806b6cdb1f70b54c3a3a17b6714ee1f0e68bebb44a74b1efd512098'),
        timestamp: DateTime.fromMillisecondsSinceEpoch(1231469665000),
        bits: 0x1d00ffff,
        nonce: 2573394689,
      );

      // Convert to entity and back
      final entity = BlockHeaderEntity.fromBlockHeader(block1Header, 1);
      final reconstructed = entity.toBlockHeader();

      // Verify reconstruction
      expect(reconstructed.version, equals(block1Header.version));
      expect(reconstructed.bits, equals(block1Header.bits));
      expect(reconstructed.nonce, equals(block1Header.nonce));
      expect(reconstructed.timestamp, equals(block1Header.timestamp));
    });
  });

  group('MerkleProofEntity Conversion', () {
    test('should convert MerkleProof to entity and back', () {
      final originalProof = MerkleProof(
        blockHash: 'block_hash_123',
        txid: 'tx_id_456',
        merkleProof: ['proof1', 'proof2', 'proof3'],
        position: 5,
        blockHeight: 100,
      );

      // Convert to entity
      final entity = MerkleProofEntity.fromMerkleProof(originalProof);

      // Verify entity fields
      expect(entity.txid, equals('tx_id_456'));
      expect(entity.blockHash, equals('block_hash_123'));
      expect(entity.blockHeight, equals(100));
      expect(entity.position, equals(5));

      // Convert back to MerkleProof
      final reconstructed = entity.toMerkleProof();

      // Verify all fields match
      expect(reconstructed.blockHash, equals(originalProof.blockHash));
      expect(reconstructed.txid, equals(originalProof.txid));
      expect(reconstructed.merkleProof, equals(originalProof.merkleProof));
      expect(reconstructed.position, equals(originalProof.position));
      expect(reconstructed.blockHeight, equals(originalProof.blockHeight));
    });
  });

  group('BitcoinUtxoEntity Conversion', () {
    test('should convert BitcoinUtxo to entity', () {
      final utxo = BitcoinUtxo.create(
        txid: 'test_txid',
        vout: 0,
        satoshis: BigInt.from(100000),
        scriptPubKey: '76a914...',
        address: '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa',
        blockHeight: 100,
        confirmations: 6,
      );

      final entity = BitcoinUtxoEntity.fromDomain(utxo);

      expect(entity.txid, equals('test_txid'));
      expect(entity.vout, equals(0));
      expect(entity.satoshis, equals('100000'));
      expect(entity.scriptPubKey, equals('76a914...'));
      expect(entity.address, equals('1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa'));
      expect(entity.blockHeight, equals(100));
      expect(entity.confirmations, equals(6));
      expect(entity.status, equals('available'));
      expect(entity.isSpendable, isTrue);
    });

    test('should convert entity back to domain model', () {
      final entity = BitcoinUtxoEntity()
        ..walletId = 'wallet_123'
        ..txid = 'tx_456'
        ..vout = 1
        ..utxoKey = 'tx_456:1'
        ..satoshis = '50000'
        ..scriptPubKey = '76a914...'
        ..address = 'test_address'
        ..blockHeight = 200
        ..confirmations = 3
        ..status = 'available'
        ..createdAt = DateTime.now()
        ..scriptType = 'p2pkh'
        ..isSpendable = true
        ..category = 'funding';

      final utxo = entity.toDomain();

      expect(utxo.txid, equals('tx_456'));
      expect(utxo.vout, equals(1));
      expect(utxo.satoshis, equals(BigInt.from(50000)));
      expect(utxo.scriptPubKey, equals('76a914...'));
      expect(utxo.address, equals('test_address'));
      expect(utxo.blockHeight, equals(200));
      expect(utxo.confirmations, equals(3));
    });
  });

  group('BitcoinTransactionEntity Conversion', () {
    test('should convert BitcoinTransaction to entity', () {
      final tx = BitcoinTransaction(
        txid: 'test_tx',
        rawHex: '0100000001...',
        status: TransactionStatus.confirmed,
        blockHeight: 100,
        confirmations: 6,
        inputValue: BigInt.from(200000),
        outputValue: BigInt.from(190000),
        fee: BigInt.from(10000),
        receivingAddresses: ['addr1', 'addr2'],
        sendingAddresses: ['addr3'],
        netAmount: BigInt.from(-10000),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        memo: 'Test transaction',
        lockTime: 0,
        version: 1,
      );

      final entity = BitcoinTransactionEntity.fromDomain(tx);

      expect(entity.txid, equals('test_tx'));
      expect(entity.rawHex, equals('0100000001...'));
      expect(entity.status, equals('confirmed'));
      expect(entity.blockHeight, equals(100));
      expect(entity.confirmations, equals(6));
      expect(entity.totalInput, equals('200000'));
      expect(entity.totalOutput, equals('190000'));
      expect(entity.fee, equals('10000'));
      expect(entity.isOutgoing, isTrue); // netAmount is negative
      expect(entity.notes, equals('Test transaction'));
    });

    test('should convert entity back to domain model', () {
      final entity = BitcoinTransactionEntity()
        ..walletId = 'wallet_123'
        ..txid = 'tx_789'
        ..rawHex = '0200000002...'
        ..blockHeight = 150
        ..blockHash = 'block_hash'
        ..confirmations = 10
        ..totalInput = '500000'
        ..totalOutput = '480000'
        ..fee = '20000'
        ..isIncoming = true
        ..isOutgoing = false
        ..status = 'confirmed'
        ..createdAt = DateTime.now()
        ..notes = 'Incoming payment';

      final tx = entity.toDomain();

      expect(tx.txid, equals('tx_789'));
      expect(tx.rawHex, equals('0200000002...'));
      expect(tx.status, equals(TransactionStatus.confirmed));
      expect(tx.blockHeight, equals(150));
      expect(tx.confirmations, equals(10));
      expect(tx.inputValue, equals(BigInt.from(500000)));
      expect(tx.outputValue, equals(BigInt.from(480000)));
      expect(tx.fee, equals(BigInt.from(20000)));
      expect(tx.memo, equals('Incoming payment'));
    });
  });
}

