/// Payment Channel Service
///
/// Coordinates the full lifecycle of payment channels including:
/// - Opening channels with funding transaction and ancestry collection
/// - Creating payment updates with extended BEEF
/// - Closing channels cooperatively or via refund timeout

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:uuid/uuid.dart';

import '../models/bitcoin_transaction.dart';
import '../models/bitcoin_utxo.dart';
import '../models/payment_channel.dart';
import '../storage/read_model_storage.dart';
import '../storage/secure_storage.dart';
import 'ancestor_chain_service.dart';
import 'crypto_service.dart';
import 'payment_channel_builder.dart';

/// Service for managing payment channel lifecycle
class PaymentChannelService {
  final ReadModelStorage _storage;
  final SecureStorage _secureStorage;
  final PaymentChannelBuilder _channelBuilder;
  final AncestorChainService _ancestorService;
  final dartsv.NetworkType _networkType;
  final Uuid _uuid = const Uuid();

  PaymentChannelService({
    required ReadModelStorage storage,
    required SecureStorage secureStorage,
    required CryptoService cryptoService,
    dartsv.NetworkType networkType = dartsv.NetworkType.TEST,
  })  : _storage = storage,
        _secureStorage = secureStorage,
        _networkType = networkType,
        _channelBuilder = PaymentChannelBuilder(
          cryptoService: cryptoService,
          networkType: networkType,
        ),
        _ancestorService = AncestorChainService(storage: storage);

  /// Open a new payment channel as the client (funder)
  ///
  /// Steps:
  /// 1. Select UTXOs for funding
  /// 2. Collect ancestor chain for BEEF
  /// 3. Build funding transaction (T1)
  /// 4. Build refund transaction (T2) - needs server signature
  /// 5. Store channel in opening state
  ///
  /// Returns the channel and unsigned refund transaction.
  /// The refund must be signed by the server before broadcasting T1.
  Future<PaymentChannelResult> openChannel({
    required String walletId,
    required String clientPeerId,
    required String serverPeerId,
    required String serverPubKeyHex,
    required BigInt fundingAmountSats,
    required int lockTimeUnix,
    String? context,
  }) async {
    try {
      print('📖 Opening payment channel');
      print('  Wallet: $walletId');
      print('  Server: $serverPeerId');
      print('  Amount: $fundingAmountSats sats');
      print('  Locktime: $lockTimeUnix');

      // 1. Get wallet keys
      final clientPrivateKey = await _getWalletPrivateKey(walletId);
      final clientPubKey = clientPrivateKey.publicKey;
      final clientAddress =
          dartsv.Address.fromPublicKey(clientPubKey, _networkType);

      final serverPubKey = dartsv.SVPublicKey.fromHex(serverPubKeyHex);
      final serverAddress =
          dartsv.Address.fromPublicKey(serverPubKey, _networkType);

      // 2. Select UTXOs
      final availableUtxos = await _storage.getAvailableUTXOs(walletId);
      final selectedUtxos =
          _selectUTXOs(availableUtxos, fundingAmountSats + BigInt.from(10000));
      if (selectedUtxos == null) {
        return PaymentChannelResult.failure('Insufficient funds');
      }

      print('  Selected ${selectedUtxos.length} UTXOs');

      // 3. Collect ancestor chain
      print('  Collecting ancestor chain...');
      final ancestorResult = await _ancestorService.collectAncestorChainForUtxos(
        selectedUtxos.map((u) => u.txid).toList(),
      );

      if (!ancestorResult.isValid) {
        return PaymentChannelResult.failure(
          'Failed to collect ancestors: ${ancestorResult.error}',
        );
      }

      print('  ✓ Collected ${ancestorResult.ancestorTransactions.length} ancestors');
      print('  ✓ Found ${ancestorResult.merkleProofs.length} merkle proofs');

      // 4. Build funding transaction (T1)
      print('  Building funding transaction...');
      final fundingResult = await _channelBuilder.buildFundingTransaction(
        clientPubKey: clientPubKey,
        serverPubKey: serverPubKey,
        fundingAmountSats: fundingAmountSats,
        clientUtxos: selectedUtxos,
        changeAddress: clientAddress,
        clientPrivateKey: clientPrivateKey,
      );

      print('  ✓ Funding TX: ${fundingResult.txid}');

      // 5. Build refund transaction (T2)
      print('  Building refund transaction...');
      final refundResult = await _channelBuilder.buildRefundTransaction(
        fundingTxId: fundingResult.txid,
        fundingOutputIndex: 0, // Multisig output is first
        fundingAmountSats: fundingAmountSats,
        clientPubKey: clientPubKey,
        serverPubKey: serverPubKey,
        clientAddress: clientAddress,
        lockTimeUnix: lockTimeUnix,
      );

      print('  ✓ Refund TX: ${refundResult.txid}');

      // 6. Sign refund transaction (client side)
      final clientRefundSig = await _channelBuilder.signMultisigInput(
        transaction: refundResult.transaction,
        inputIndex: 0,
        privateKey: clientPrivateKey,
        clientPubKey: clientPubKey,
        serverPubKey: serverPubKey,
        inputAmountSats: fundingAmountSats,
      );

      print('  ✓ Client signed refund');

      // 7. Create channel record
      final channelId = _uuid.v4();
      final channel = PaymentChannel(
        channelId: channelId,
        walletId: walletId,
        role: PaymentChannelRole.client,
        clientPeerId: clientPeerId,
        serverPeerId: serverPeerId,
        fundingTxId: fundingResult.txid,
        fundingTxHex: fundingResult.transactionHex,
        fundingOutputIndex: 0,
        fundingAmountSats: fundingAmountSats,
        clientPubKeyHex: clientPubKey.toHex(),
        serverPubKeyHex: serverPubKeyHex,
        clientAddressB58: clientAddress.toString(),
        serverAddressB58: serverAddress.toString(),
        lockTimeUnix: lockTimeUnix,
        state: PaymentChannelState.opening,
        clientBalanceSats: fundingAmountSats,
        serverBalanceSats: BigInt.zero,
        latestSequenceNumber: 0,
        refundTxHex: refundResult.transactionHex,
        refundClientSigHex: clientRefundSig.signatureHex,
        fundingAncestorTxids:
            ancestorResult.ancestorTransactions.map((tx) => tx.txid).toList(),
        context: context,
        createdAt: DateTime.now(),
      );

      // 8. Store channel
      await _storage.storePaymentChannel(channel);

      print('✓ Channel created: $channelId');

      return PaymentChannelResult.success(
        channel: channel,
        transactionHex: fundingResult.transactionHex,
      );
    } catch (e, stackTrace) {
      print('❌ Error opening channel: $e');
      print('Stack trace: $stackTrace');
      return PaymentChannelResult.failure('Failed to open channel: $e');
    }
  }

  /// Create a payment update (T3) with extended BEEF
  ///
  /// This creates a new payment transaction that updates the channel balance.
  /// If the funding transaction is unconfirmed, the BEEF will include the
  /// full ancestor chain.
  Future<PaymentChannelResult> createPayment({
    required String channelId,
    required BigInt amountSats,
  }) async {
    try {
      print('💸 Creating payment update');
      print('  Channel: $channelId');
      print('  Amount: $amountSats sats');

      // 1. Get channel
      final channel = await _storage.getPaymentChannel(channelId);
      if (channel == null) {
        return PaymentChannelResult.failure('Channel not found');
      }

      if (channel.state != PaymentChannelState.open) {
        return PaymentChannelResult.failure(
          'Channel is not open (state: ${channel.state})',
        );
      }

      // 2. Check balance
      if (channel.isClient && channel.clientBalanceSats < amountSats) {
        return PaymentChannelResult.failure('Insufficient channel balance');
      }

      // 3. Calculate new balances
      final newClientBalance = channel.clientBalanceSats - amountSats;
      final newServerBalance = channel.serverBalanceSats + amountSats;
      final newSequence = channel.latestSequenceNumber + 1;

      print('  New balances: client=$newClientBalance, server=$newServerBalance');

      // 4. Build payment transaction
      final clientPubKey = dartsv.SVPublicKey.fromHex(channel.clientPubKeyHex);
      final serverPubKey = dartsv.SVPublicKey.fromHex(channel.serverPubKeyHex);
      final clientAddress = dartsv.Address.fromBase58(channel.clientAddressB58);
      final serverAddress = dartsv.Address.fromBase58(channel.serverAddressB58);

      final paymentResult = await _channelBuilder.buildPaymentTransaction(
        fundingTxId: channel.fundingTxId,
        fundingOutputIndex: channel.fundingOutputIndex,
        fundingAmountSats: channel.fundingAmountSats,
        clientPubKey: clientPubKey,
        serverPubKey: serverPubKey,
        clientAddress: clientAddress,
        serverAddress: serverAddress,
        serverAmountSats: newServerBalance,
        sequenceNumber: newSequence,
      );

      print('  ✓ Payment TX: ${paymentResult.txid}');

      // 5. Check if we need extended BEEF (funding tx unconfirmed)
      final fundingProof = await _storage.getMerkleProof(channel.fundingTxId);
      String? beefHex;

      if (fundingProof == null && channel.fundingAncestorTxids.isNotEmpty) {
        print('  Funding TX unconfirmed, creating extended BEEF...');

        // Get ancestor transactions
        final ancestors = <BitcoinTransaction>[];
        final proofs = <MerkleProof>[];

        for (final txid in channel.fundingAncestorTxids) {
          final tx = await _storage.getTransaction(txid);
          if (tx != null) {
            ancestors.add(tx);
            final proof = await _storage.getMerkleProof(txid);
            if (proof != null) {
              proofs.add(proof);
            }
          }
        }

        // Get funding transaction
        final fundingTx = await _storage.getTransaction(channel.fundingTxId);
        if (fundingTx == null) {
          // Create from stored hex
          final fundingTx = BitcoinTransaction(
            txid: channel.fundingTxId,
            rawHex: channel.fundingTxHex,
            status: TransactionStatus.pending,
            inputValue: BigInt.zero,
            outputValue: channel.fundingAmountSats,
            fee: BigInt.zero,
            receivingAddresses: [],
            sendingAddresses: [],
            netAmount: BigInt.zero,
            createdAt: channel.createdAt,
            updatedAt: channel.createdAt,
            lockTime: 0,
            version: 1,
          );

          // Build BEEF with ancestry
          final beefResult = await _channelBuilder.buildPaymentWithAncestry(
            paymentTx: paymentResult,
            fundingTransaction: fundingTx,
            fundingAncestors: ancestors,
            ancestorProofs: proofs,
          );

          beefHex = beefResult.beefHex;
          print('  ✓ Extended BEEF created: ${beefHex.length} chars');
        }
      }

      // 6. Update channel
      channel.clientBalanceSats = newClientBalance;
      channel.serverBalanceSats = newServerBalance;
      channel.latestSequenceNumber = newSequence;
      channel.latestPaymentTxHex = paymentResult.transactionHex;

      await _storage.storePaymentChannel(channel);

      print('✓ Payment created');

      return PaymentChannelResult.success(
        channel: channel,
        transactionHex: paymentResult.transactionHex,
        beefHex: beefHex,
      );
    } catch (e, stackTrace) {
      print('❌ Error creating payment: $e');
      print('Stack trace: $stackTrace');
      return PaymentChannelResult.failure('Failed to create payment: $e');
    }
  }

  /// Close channel cooperatively by broadcasting the latest state
  Future<PaymentChannelResult> closeChannelCooperative(String channelId) async {
    try {
      final channel = await _storage.getPaymentChannel(channelId);
      if (channel == null) {
        return PaymentChannelResult.failure('Channel not found');
      }

      if (channel.latestPaymentTxHex == null) {
        return PaymentChannelResult.failure('No payment transaction to broadcast');
      }

      channel.state = PaymentChannelState.closing;
      channel.closedAt = DateTime.now();
      await _storage.storePaymentChannel(channel);

      return PaymentChannelResult.success(
        channel: channel,
        transactionHex: channel.latestPaymentTxHex,
      );
    } catch (e) {
      return PaymentChannelResult.failure('Failed to close channel: $e');
    }
  }

  /// Close channel via refund after timeout
  Future<PaymentChannelResult> closeChannelRefund(String channelId) async {
    try {
      final channel = await _storage.getPaymentChannel(channelId);
      if (channel == null) {
        return PaymentChannelResult.failure('Channel not found');
      }

      if (!channel.isExpired) {
        return PaymentChannelResult.failure(
          'Refund not yet valid (${channel.secondsUntilRefundValid}s remaining)',
        );
      }

      if (channel.refundTxHex == null) {
        return PaymentChannelResult.failure('No refund transaction available');
      }

      channel.state = PaymentChannelState.expired;
      channel.closedAt = DateTime.now();
      await _storage.storePaymentChannel(channel);

      return PaymentChannelResult.success(
        channel: channel,
        transactionHex: channel.refundTxHex,
      );
    } catch (e) {
      return PaymentChannelResult.failure('Failed to refund channel: $e');
    }
  }

  /// Get wallet's private key
  Future<dartsv.SVPrivateKey> _getWalletPrivateKey(String walletId) async {
    final xpriv = await _secureStorage.getXPriv(walletId);
    if (xpriv != null) {
      final hdPrivateKey = dartsv.HDPrivateKey.fromXpriv(xpriv);
      return hdPrivateKey.privateKey;
    }

    final mnemonic = await _secureStorage.getMnemonic(walletId);
    if (mnemonic == null) {
      throw Exception('Wallet keys not found');
    }

    final hdPrivateKey = dartsv.HDPrivateKey.fromSeed(
      dartsv.Mnemonic().toSeedHex(mnemonic, ''),
      _networkType,
    );
    return hdPrivateKey.privateKey;
  }

  /// Select UTXOs for funding (greedy largest-first)
  List<BitcoinUtxo>? _selectUTXOs(
    List<BitcoinUtxo> utxos,
    BigInt targetAmount,
  ) {
    final sortedUtxos = List<BitcoinUtxo>.from(utxos)
      ..sort((a, b) => b.satoshis.compareTo(a.satoshis));

    final selected = <BitcoinUtxo>[];
    var total = BigInt.zero;

    for (final utxo in sortedUtxos) {
      selected.add(utxo);
      total += utxo.satoshis;

      if (total >= targetAmount) {
        return selected;
      }
    }

    return null; // Insufficient funds
  }
}

