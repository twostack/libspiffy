import 'dart:typed_data';
import 'dart:async';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';
import 'package:spiffynode/spiffy_node.dart' as spiffy;
import 'package:convert/convert.dart';

import '../models/bitcoin_utxo.dart';
import '../models/bitcoin_transaction.dart';
import '../models/invoice_output_spec.dart';
import '../plugin/plugin_registry.dart';
import '../plugin/plugin_types.dart';
import '../plugin/transaction_builder_plugin.dart';
import '../plugin/provisioned_transaction.dart';
import '../services/callback_transaction_signer.dart';
import '../storage/read_model_storage.dart';
import '../storage/secure_storage.dart';
import '../services/ancestor_chain_service.dart';
import '../utils/beef.dart';
import '../utils/bump.dart';
import '../utils/crypto_utils.dart';
import '../core/wallet_commands.dart';
import '../services/transaction/builder/op_return_lockbuilder.dart';
import 'payment_messages.dart';
import 'wallet_messages.dart';

/// Coordinator actor for payment operations with SPV BEEF construction
/// 
/// Handles PayInvoiceMessage by:
/// 1. Selecting UTXOs to fund payment
/// 2. Recursively collecting ancestor transactions back to first merkle proof
/// 3. Validating complete chain exists
/// 4. Building payment transaction
/// 5. Creating BEEF package with ancestors and proofs
/// 6. Returning BEEF (does NOT broadcast - pure SPV model)
class PaymentCoordinatorActor extends Actor {
  static final _log = Logger('PaymentCoordinatorActor');
  final ReadModelStorage _storage;
  final SecureStorage _secureStorage;
  final ActorRef _walletManager;
  late final AncestorChainService _ancestorService;

  PaymentCoordinatorActor({
    required ActorRef walletManager,
    required ReadModelStorage storage,
    required SecureStorage secureStorage,
  })  : _storage = storage,
        _secureStorage = secureStorage,
        _walletManager = walletManager {
    _ancestorService = AncestorChainService(storage: storage);
  }

  @override
  void preStart() {
  }

  @override
  Future<void> onMessage(dynamic message) async {
    try {
      if (message is PayInvoiceMessage) {
        await _handlePayInvoice(message);
      } else if (message is ProvisionFundingMessage) {
        await _handleProvisionFunding(message);
      } else {
      }
    } catch (e, stackTrace) {

      if (message is PayInvoiceMessage) {
        _sendError(message.invoiceId, 'Internal error: $e');
      }
    }
  }

  /// Handle payment invoice request
  Future<void> _handlePayInvoice(PayInvoiceMessage msg) async {
    final totalSw = Stopwatch()..start();
    // Capture sender before any async gaps to avoid stale references
    final originalSender = context.sender;
    // Calculate effective amount (from outputs or legacy amount)
    final effectiveAmount = msg.effectiveAmount;
    // Fee estimate from message or default
    final feeEstimate = msg.feeEstimateSats ?? BigInt.from(1000);

    _log.info('[pay ${msg.invoiceId}] Starting payment: amount=$effectiveAmount sats');

    // 1. Get available UTXOs
    final utxoSw = Stopwatch()..start();
    final utxos = await _storage.getPaymentUTXOs(msg.walletId);
    _log.info('[pay ${msg.invoiceId}] getUTXOs: ${utxoSw.elapsedMilliseconds}ms, count=${utxos.length}');
    if (utxos.isEmpty) {
      _sendError(msg.invoiceId, 'Insufficient funds', sender: originalSender);
      return;
    }

    // 2. Select UTXOs for payment
    final selectedUtxos = _selectUTXOs(utxos, effectiveAmount);
    if (selectedUtxos == null) {
      final totalBalance = utxos.fold<BigInt>(
        BigInt.zero,
        (sum, utxo) => sum + utxo.satoshis,
      );
      _sendError(
        msg.invoiceId,
        'Insufficient funds: need $effectiveAmount satoshis, have $totalBalance',
        sender: originalSender,
      );
      return;
    }

    // 2a. Reserve selected UTXOs to prevent double-spending
    final reservationId = 'payment-${msg.invoiceId}-${DateTime.now().millisecondsSinceEpoch}';
    final reserved = await _reserveUTXOs(msg.walletId, selectedUtxos, reservationId);
    if (!reserved) {
      _sendError(msg.invoiceId, 'Failed to reserve UTXOs — they may already be in use', sender: originalSender);
      return;
    }

    // Check if this payment will be handled by a TransactionBuilderPlugin.
    // Plugin-built transactions manage their own inputs — ancestor chain
    // validation and BEEF construction are not applicable.
    final isPluginTransaction = msg.outputs != null &&
        msg.outputs!.whereType<PluginOutputSpec>().any((p) {
          final plugin = PluginRegistry().getPlugin(p.pluginId);
          return plugin is TransactionBuilderPlugin &&
              p.params.containsKey('action') &&
              plugin.supportedActions.contains(p.params['action']);
        });

    late final dynamic ancestorResult;
    if (!isPluginTransaction) {
      // 2b. Fast-fail if no block headers synced (can't construct valid BEEF)
      final bestHeight = await _storage.getBestHeight();
      if (bestHeight == 0) {
        _log.warning('[pay ${msg.invoiceId}] No block headers synced yet - cannot construct BEEF payment');
        _releaseReservation(walletId: msg.walletId, reservationId: reservationId);
        _sendError(msg.invoiceId, 'No block headers synced yet - cannot construct BEEF payment', sender: originalSender);
        return;
      }

      // 3. CRITICAL: Validate complete ancestor chain using AncestorChainService
      final ancestorSw = Stopwatch()..start();
      ancestorResult = await _ancestorService.collectAncestorChainForUtxos(
        selectedUtxos.map((u) => u.txid).toList(),
      );
      _log.info('[pay ${msg.invoiceId}] ancestorChain: ${ancestorSw.elapsedMilliseconds}ms, '
          'ancestors=${ancestorResult.isValid ? ancestorResult.ancestorTransactions.length : "N/A"}, '
          'proofs=${ancestorResult.isValid ? ancestorResult.merkleProofs.length : "N/A"}');
      if (!ancestorResult.isValid) {
        _releaseReservation(walletId: msg.walletId, reservationId: reservationId);
        _sendError(
          msg.invoiceId,
          'Incomplete transaction chain: ${ancestorResult.error}',
          sender: originalSender,
        );
        return;
      }
    } else {
      ancestorResult = null;
    }

    final keyInfo = await _getPublicKeysForUTXOs(msg.walletId, selectedUtxos);

    // 4. Build payment transaction (with outputs if provided)
    // Returns (transaction, preSigned, witnessTx) — plugin-built transactions are already signed.
    final buildSw = Stopwatch()..start();
    final (paymentTx, preSigned, witnessTx) = await _buildPaymentTransactionWithOutputs(
      selectedUtxos: selectedUtxos,
      outputs: msg.outputs,
      legacyAddresses: msg.addresses,
      legacyAmount: msg.amount,
      changeAddress: msg.changeAddress,
      walletId: msg.walletId,
      publicKeys: keyInfo.publicKeys,
    );

    _log.info('[pay ${msg.invoiceId}] buildTx: ${buildSw.elapsedMilliseconds}ms, preSigned=$preSigned');
    if (paymentTx == null) {
      _releaseReservation(walletId: msg.walletId, reservationId: reservationId);
      _sendError(msg.invoiceId, 'Failed to build payment transaction', sender: originalSender);
      return;
    }

    late final BitcoinTransaction signedPaymentTx;

    if (preSigned) {
      // TransactionBuilderPlugin already built and signed the transaction
      signedPaymentTx = paymentTx;
    } else {
      // 4b. Sign the transaction
      final signSw = Stopwatch()..start();
      final utxoKeys = selectedUtxos.map((u) => '${u.txid}:${u.vout}').toList();
      final (signedTxHex, signError) = await _signTransaction(
        walletId: msg.walletId,
        txid: paymentTx.txid,
        unsignedTxHex: paymentTx.rawHex,
        utxoKeys: utxoKeys,
        publicKeys: keyInfo.publicKeys,
        addresses: keyInfo.addresses,
        derivationIndices: keyInfo.derivationIndices,
      );

      _log.info('[pay ${msg.invoiceId}] signing: ${signSw.elapsedMilliseconds}ms');
      if (signedTxHex == null) {
        _releaseReservation(walletId: msg.walletId, reservationId: reservationId);
        _sendError(msg.invoiceId, 'Failed to sign transaction: $signError', sender: originalSender);
        return;
      }

      // IMPORTANT: TXID changes after signing because scriptSig changes the raw bytes
      final signedDartsvTx = dartsv.Transaction.fromHex(signedTxHex);
      final signedTxid = signedDartsvTx.id;

      signedPaymentTx = BitcoinTransaction(
        txid: signedTxid,
        rawHex: signedTxHex,
        status: paymentTx.status,
        inputValue: paymentTx.inputValue,
        outputValue: paymentTx.outputValue,
        fee: paymentTx.fee,
        receivingAddresses: paymentTx.receivingAddresses,
        sendingAddresses: paymentTx.sendingAddresses,
        netAmount: paymentTx.netAmount,
        createdAt: paymentTx.createdAt,
        updatedAt: DateTime.now(),
        lockTime: paymentTx.lockTime,
        version: paymentTx.version,
      );
    }

    // 4c. Record the outgoing transaction in PENDING state

    // CRITICAL: Use the actual change address (same logic as _buildPaymentTransaction)
    // If no changeAddress was provided, we use the first UTXO's address as change destination
    final actualChangeAddress = msg.changeAddress ?? selectedUtxos.first.address;

    // Get recipient addresses for recording
    final recipientAddresses = _getRecipientAddresses(msg.outputs, msg.addresses);

    final spentUtxoKeys = selectedUtxos.map((u) => '${u.txid}:${u.vout}').toList();
    await _recordOutgoingTransaction(
      walletId: msg.walletId,
      transaction: signedPaymentTx,
      spentUtxoKeys: spentUtxoKeys,
      recipientAddresses: recipientAddresses,
      paymentAmount: effectiveAmount,
      changeAddress: actualChangeAddress,
      deferSpend: true, // UTXOs stay reserved; ARCActor marks spent on SEEN_ON_NETWORK
    );

    if (preSigned) {
      // Plugin-built transaction — return raw tx bytes as a minimal BEEF.
      // The plugin manages its own inputs; no ancestor chain or merkle proofs.
      try {
        // Record paired witness TX if present
        if (witnessTx != null) {
          // Identify which reserved UTXOs the witness TX spends
          final witnessDartsvTx = dartsv.Transaction.fromHex(witnessTx.rawHex);
          final witnessSpentKeys = <String>[];
          for (final input in witnessDartsvTx.inputs) {
            final key = '${input.prevTxnId}:${input.prevTxnOutputIndex}';
            witnessSpentKeys.add(key);
          }
          await _recordOutgoingTransaction(
            walletId: msg.walletId,
            transaction: witnessTx,
            spentUtxoKeys: witnessSpentKeys,
            recipientAddresses: ['witness'],
            paymentAmount: BigInt.zero,
            changeAddress: actualChangeAddress,
          );
        }

        final txBytes = hex.decode(signedPaymentTx.rawHex);
        final beef = _createMinimalBEEF(Uint8List.fromList(txBytes));

        // Build witness BEEF if present
        Uint8List? witnessBeef;
        String? witnessTxid;
        if (witnessTx != null) {
          final witnessTxBytes = hex.decode(witnessTx.rawHex);
          witnessBeef = _createMinimalBEEF(Uint8List.fromList(witnessTxBytes));
          witnessTxid = witnessTx.txid;
        }

        _log.info('[pay ${msg.invoiceId}] plugin tx TOTAL: ${totalSw.elapsedMilliseconds}ms'
            '${witnessTxid != null ? ', witnessTxid=$witnessTxid' : ''}');

        if (originalSender != null) {
          originalSender.tell(BEEFPaymentResponse(
            invoiceId: msg.invoiceId,
            beefBytes: beef,
            txid: signedPaymentTx.txid,
            amountPaid: effectiveAmount,
            changeAmount: BigInt.zero,
            ancestorCount: 0,
            success: true,
            witnessTxid: witnessTxid,
            witnessBeefBytes: witnessBeef,
            spentUtxoKeys: spentUtxoKeys,
          ));
        }
      } catch (e) {
        _sendError(msg.invoiceId, 'Failed to package plugin transaction: $e', sender: originalSender);
      }
    } else {
      // Standard transaction — full BEEF with ancestor chain and merkle proofs.
      final headerSw = Stopwatch()..start();
      final blockHeaders = await _getBlockHeaders(ancestorResult.blockHeights);
      _log.info('[pay ${msg.invoiceId}] getHeaders: ${headerSw.elapsedMilliseconds}ms');

      try {
        final beefSw = Stopwatch()..start();
        final beef = await _createBEEF(
          paymentTransaction: signedPaymentTx,
          ancestorTransactions: ancestorResult.ancestorTransactions,
          merkleProofs: ancestorResult.merkleProofs,
          blockHeaders: blockHeaders,
        );

        _log.info('[pay ${msg.invoiceId}] createBEEF: ${beefSw.elapsedMilliseconds}ms');

        final totalInput = selectedUtxos.fold<BigInt>(
          BigInt.zero,
          (sum, utxo) => sum + utxo.satoshis,
        );
        final changeAmount = totalInput - effectiveAmount - feeEstimate;

        _log.info('[pay ${msg.invoiceId}] TOTAL: ${totalSw.elapsedMilliseconds}ms');

        if (originalSender != null) {
          originalSender.tell(BEEFPaymentResponse(
            invoiceId: msg.invoiceId,
            beefBytes: beef,
            txid: signedPaymentTx.txid,
            amountPaid: effectiveAmount,
            changeAmount: changeAmount > BigInt.zero ? changeAmount : BigInt.zero,
            ancestorCount: ancestorResult.ancestorTransactions.length,
            success: true,
            spentUtxoKeys: spentUtxoKeys,
          ));
        }
      } catch (e) {
        _sendError(msg.invoiceId, 'Failed to create BEEF: $e', sender: originalSender);
      }
    }
  }

  /// Extract recipient addresses from outputs or legacy addresses
  List<String> _getRecipientAddresses(List<InvoiceOutputSpec>? outputs, List<String> legacyAddresses) {
    if (outputs == null || outputs.isEmpty) {
      return legacyAddresses;
    }
    // For P2PKH outputs, return addresses; for P2MS, return "multisig" placeholder
    return outputs.map((o) {
      if (o is P2PKHOutputSpec) {
        return o.address;
      } else if (o is P2MSOutputSpec) {
        return 'multisig:${o.threshold}-of-${o.totalKeys}';
      } else if (o is OPReturnOutputSpec) {
        return 'op_return';
      }
      return 'unknown';
    }).toList();
  }

  // Ancestor collection methods removed - now using AncestorChainService

  /// Select UTXOs to fund payment (greedy largest-first strategy)
  List<BitcoinUtxo>? _selectUTXOs(List<BitcoinUtxo> utxos, BigInt targetAmount) {
    // Sort by size (largest first) for minimal inputs
    final sortedUtxos = List<BitcoinUtxo>.from(utxos)
      ..sort((a, b) => b.satoshis.compareTo(a.satoshis));

    final selected = <BitcoinUtxo>[];
    var total = BigInt.zero;

    for (final utxo in sortedUtxos) {
      selected.add(utxo);
      total += utxo.satoshis;

      // Add buffer for fees
      if (total >= targetAmount + BigInt.from(1000)) { // Note: fee buffer in UTXO selection
        return selected;
      }
    }

    return null; // Insufficient funds
  }

  /// Build payment transaction with support for multiple output types (P2PKH, P2MS)
  /// Returns (transaction, preSigned) — preSigned is true when a TransactionBuilderPlugin
  /// built and signed the entire transaction.
  Future<(BitcoinTransaction?, bool, BitcoinTransaction?)> _buildPaymentTransactionWithOutputs({
    required List<BitcoinUtxo> selectedUtxos,
    List<InvoiceOutputSpec>? outputs,
    required List<String> legacyAddresses,
    required BigInt legacyAmount,
    String? changeAddress,
    required String walletId,
    required List<dartsv.SVPublicKey> publicKeys,
  }) async {
    try {
      // Calculate total input
      final totalInput = selectedUtxos.fold<BigInt>(
        BigInt.zero,
        (sum, utxo) => sum + utxo.satoshis,
      );

      // Build transaction using TransactionBuilder pattern
      final txBuilder = dartsv.TransactionBuilder();

      // Track receiving addresses for record
      final receivingAddresses = <String>[];
      BigInt totalOutputAmount = BigInt.zero;

      // Add payment outputs based on outputs or legacy addresses
      if (outputs != null && outputs.isNotEmpty) {
        // Check if any PluginOutputSpec belongs to a TransactionBuilderPlugin.
        // If so, delegate the entire transaction build to the plugin.
        final pluginOutput = outputs.whereType<PluginOutputSpec>().firstOrNull;
        if (pluginOutput != null) {
          final pluginInstance = PluginRegistry().getPlugin(pluginOutput.pluginId);
          if (pluginInstance is TransactionBuilderPlugin &&
              pluginOutput.params.containsKey('action') &&
              pluginInstance.supportedActions.contains(pluginOutput.params['action'])) {
            // Retrieve the signing key from secure storage and create a
            // CallbackTransactionSigner. The private key stays inside this
            // closure — the plugin receives a TransactionSigner interface
            // but cannot extract the key.
            final xpriv = await _secureStorage.getXPriv(walletId);
            final wif = await _secureStorage.getWIF(walletId);
            final keyMaterial = xpriv ?? wif;
            if (keyMaterial == null) {
              throw Exception('No signing key available for wallet $walletId');
            }

            // Derive the private key for the funding UTXO's derivation index
            final derivationIndex = selectedUtxos.first.derivationIndex ?? 0;
            late dartsv.SVPrivateKey signingKey;
            if (xpriv != null) {
              final hdKey = dartsv.HDPrivateKey.fromXpriv(xpriv);
              final derived = hdKey.deriveChildNumber(0).deriveChildNumber(derivationIndex);
              signingKey = derived.privateKey;
            } else {
              signingKey = dartsv.SVPrivateKey.fromWIF(wif!);
            }

            final sigHashType = dartsv.SighashType.SIGHASH_ALL.value |
                dartsv.SighashType.SIGHASH_FORKID.value;

            // Create callback signer — key is captured in the closure, never
            // exposed to the plugin through any accessible field or parameter.
            final callbackSigner = CallbackTransactionSigner(
              sigHashType: sigHashType,
              onSign: (Uint8List sighash, int inputIndex) {
                final sig = dartsv.SVSignature.fromPrivateKey(signingKey);
                sig.nhashtype = sigHashType;
                sig.sign(hex.encode(sighash));
                return Uint8List.fromList(sig.toDER());
              },
            );

            final request = PluginTransactionRequest(
              fundingUtxos: selectedUtxos,
              signer: callbackSigner,
              publicKeys: publicKeys,
              params: pluginOutput.params,
              transactionLookup: (txid) async {
                final tx = await _storage.getTransaction(txid);
                return tx?.rawHex;
              },
            );

            final result = await pluginInstance.buildTransaction(request);

            // Validate primary TX structure
            final action = pluginOutput.params['action'] as String;
            if (!pluginInstance.validateTransactionStructure(result.primaryTx, action)) {
              throw Exception('Plugin transaction structure validation failed');
            }

            // Validate witness TX structure if present
            if (result.hasPairedWitness) {
              final witnessAction = pluginOutput.params['witnessAction'] as String? ?? 'witness';
              if (!pluginInstance.validateTransactionStructure(result.witnessTx!, witnessAction)) {
                throw Exception('Plugin witness transaction structure validation failed');
              }
            }

            final primaryBtx = BitcoinTransaction.fromDartSvTransaction(
              walletId: walletId,
              transaction: result.primaryTx,
              status: TransactionStatus.pending,
              receivingAddresses: ['${pluginOutput.pluginId}:${pluginOutput.pluginScriptType}'],
              sendingAddresses: [],
              inputValue: totalInput,
              netAmount: -pluginOutput.amount,
            );

            // Convert witness TX if present
            BitcoinTransaction? witnessBtx;
            if (result.hasPairedWitness) {
              final witnessOutputValue = result.witnessTx!.outputs.fold<BigInt>(
                  BigInt.zero, (sum, o) => sum + o.satoshis);
              witnessBtx = BitcoinTransaction.fromDartSvTransaction(
                walletId: walletId,
                transaction: result.witnessTx!,
                status: TransactionStatus.pending,
                receivingAddresses: ['${pluginOutput.pluginId}:witness'],
                sendingAddresses: [],
                inputValue: result.witnessFeeSats + witnessOutputValue,
                netAmount: -result.witnessFeeSats,
              );
            }

            return (primaryBtx, true, witnessBtx); // preSigned: plugin built and signed the tx
          }
        }

        // Standard multi-output mode (individual lock builders per output)
        for (final output in outputs) {
          totalOutputAmount += output.amount;

          switch (output) {
            case P2PKHOutputSpec p2pkh:
              final toAddress = dartsv.Address.fromBase58(p2pkh.address);
              final recipientBuilder = dartsv.P2PKHLockBuilder.fromAddress(toAddress);
              txBuilder.spendToLockBuilder(recipientBuilder, p2pkh.amount);
              receivingAddresses.add(p2pkh.address);

            case P2MSOutputSpec p2ms:
              // Build multisig output
              final pubKeys = p2ms.publicKeys
                  .map((hex) => dartsv.SVPublicKey.fromHex(hex))
                  .toList();
              final msLockBuilder = dartsv.P2MSLockBuilder(
                pubKeys,
                p2ms.threshold,
                sorting: true, // BIP67 lexicographical sorting for determinism
              );
              txBuilder.spendToLockBuilder(msLockBuilder, p2ms.amount);
              receivingAddresses.add('multisig:${p2ms.threshold}-of-${p2ms.totalKeys}');

            case OPReturnOutputSpec opReturn:
              if (opReturn.separateOutputs) {
                // One transaction output per data chunk
                for (final chunk in opReturn.dataChunks) {
                  final lockBuilder = OpReturnLockBuilder([chunk]);
                  txBuilder.spendToLockBuilder(lockBuilder, BigInt.zero);
                  receivingAddresses.add('op_return');
                }
              } else {
                // All chunks in a single transaction output (default)
                final lockBuilder = OpReturnLockBuilder(opReturn.dataChunks);
                txBuilder.spendToLockBuilder(lockBuilder, BigInt.zero);
                receivingAddresses.add('op_return');
              }

            case PluginOutputSpec plugin:
              final pluginInstance = PluginRegistry().getPlugin(plugin.pluginId);
              if (pluginInstance == null) {
                throw Exception('No plugin registered for "${plugin.pluginId}"');
              }
              final lockBuilder = pluginInstance.createLockBuilder(plugin);
              if (lockBuilder == null) {
                throw Exception(
                  'Plugin "${plugin.pluginId}" cannot build lock for '
                  'script type "${plugin.pluginScriptType}"',
                );
              }
              txBuilder.spendToLockBuilder(lockBuilder, plugin.amount);
              receivingAddresses.add('${plugin.pluginId}:${plugin.pluginScriptType}');
          }
        }
      } else {
        // Legacy mode - split amount across addresses
        totalOutputAmount = legacyAmount;
        for (final address in legacyAddresses) {
          final toAddress = dartsv.Address.fromBase58(address);
          final amountPerAddress = legacyAmount ~/ BigInt.from(legacyAddresses.length);

          final recipientBuilder = dartsv.P2PKHLockBuilder.fromAddress(toAddress);
          txBuilder.spendToLockBuilder(recipientBuilder, amountPerAddress);
          receivingAddresses.add(address);
        }
      }

      // Add change address (proven pattern)
      final changeAddr = changeAddress ?? selectedUtxos.first.address;
      final changeAddress_ = dartsv.Address.fromBase58(changeAddr);
      txBuilder.sendChangeToPKH(changeAddress_);

      // Add inputs from selected UTXOs with public keys
      for (int i = 0; i < selectedUtxos.length; i++) {
        final utxo = selectedUtxos[i];
        final publicKey = publicKeys[i];

        final lockedAddress = dartsv.Address.fromBase58(utxo.address);
        final lockingScript = dartsv.P2PKHLockBuilder.fromAddress(lockedAddress).getScriptPubkey();

        final outpoint = dartsv.TransactionOutpoint(
          utxo.txid,
          utxo.vout,
          utxo.satoshis,
          lockingScript,
        );

        // Prime the scriptSig with the public key for this UTXO
        final unlockBuilder = dartsv.P2PKHUnlockBuilder(publicKey);
        txBuilder.spendFromOutpoint(outpoint, dartsv.TransactionInput.MAX_SEQ_NUMBER, unlockBuilder);
      }

      // Apply transaction settings (proven pattern)
      txBuilder
          .withFeePerKb(1) // Low fee rate valid for BSV network
          .withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);

      // Build unsigned transaction (skip sanity checks for flexibility)
      final unsignedTx = txBuilder.build(false);
      final rawHex = unsignedTx.serialize();
      final txid = unsignedTx.id;

      // Calculate actual fee and change from built transaction
      final totalOutput = unsignedTx.outputs.fold<BigInt>(
        BigInt.zero,
        (sum, output) => sum + output.satoshis,
      );
      final fee = totalInput - totalOutput;

      // Create transaction record
      return (BitcoinTransaction(
        txid: txid,
        rawHex: rawHex,
        status: TransactionStatus.created,
        inputValue: totalInput,
        outputValue: totalOutput,
        fee: fee,
        receivingAddresses: receivingAddresses,
        sendingAddresses: selectedUtxos.map((u) => u.address).toList(),
        netAmount: -(totalOutputAmount + fee),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        lockTime: 0,
        version: 2,
      ), false, null); // preSigned: false — needs signing, no witness
    } catch (e, stackTrace) {
      return (null, false, null);
    }
  }


  /// Get public keys for all UTXOs being spent
  /// 
  /// For each UTXO, this method:
  /// Returns (publicKeys, addresses, derivationIndices) for UTXOs.
  /// Derivation indices are from the read model and can be passed to SignTransactionCommand.
  Future<({List<dartsv.SVPublicKey> publicKeys, List<String> addresses, List<int> derivationIndices})> _getPublicKeysForUTXOs(
    String walletId,
    List<BitcoinUtxo> utxos,
  ) async {
    final publicKeys = <dartsv.SVPublicKey>[];
    final addresses = <String>[];
    final derivationIndices = <int>[];

    // Get the wallet's extended private key
    dartsv.HDPrivateKey? hdPrivateKey;

    final xpriv = await _secureStorage.getXPriv(walletId);
    if (xpriv != null) {
      // Parse the extended private key directly
      hdPrivateKey = dartsv.HDPrivateKey.fromXpriv(xpriv);
    } else {
      // Try mnemonic if xpriv not available (e.g., wallet created from seed phrase)
      final mnemonic = await _secureStorage.getMnemonic(walletId);
      if (mnemonic != null) {
        // Get wallet network type from storage
        final walletData = await _storage.getWallet(walletId);
        final networkStr = walletData?['network'] as String? ?? 'test';
        final networkType = networkStr == 'main'
            ? dartsv.NetworkType.MAIN
            : dartsv.NetworkType.TEST;

        // Derive HD private key from mnemonic
        hdPrivateKey = dartsv.HDPrivateKey.fromSeed(
          dartsv.Mnemonic().toSeedHex(mnemonic, ''),
          networkType,
        );
      }
    }

    // WIF wallet: single private key, no HD derivation
    if (hdPrivateKey == null) {
      final wif = await _secureStorage.getWIF(walletId);
      if (wif == null) {
        throw Exception('Wallet xpriv, mnemonic, or WIF not found in secure storage');
      }
      final privateKey = dartsv.SVPrivateKey.fromWIF(wif);
      final publicKey = privateKey.publicKey;
      // All UTXOs in a WIF wallet belong to the same key
      for (final utxo in utxos) {
        publicKeys.add(publicKey);
        addresses.add(utxo.address);
        derivationIndices.add(0); // WIF has no derivation
      }
      return (publicKeys: publicKeys, addresses: addresses, derivationIndices: derivationIndices);
    }

    // HD wallet: derive public key per UTXO using derivation path
    for (final utxo in utxos) {
      // Get address metadata to find derivation index
      final addressMetadata = await _storage.getAddressMetadata(walletId, utxo.address);
      if (addressMetadata == null) {
        throw Exception('Address metadata not found for ${utxo.address}');
      }

      final derivationPath = "m/0/${addressMetadata.derivationIndex}";

      final derivedHdKey = hdPrivateKey.deriveChildKey(derivationPath);
      final privateKey = derivedHdKey.privateKey;
      final publicKey = privateKey.publicKey;

      publicKeys.add(publicKey);
      addresses.add(utxo.address);
      derivationIndices.add(addressMetadata.derivationIndex ?? 0);
    }

    return (publicKeys: publicKeys, addresses: addresses, derivationIndices: derivationIndices);
  }

  /// Request wallet to sign the transaction
  /// Returns (signedHex, error) — signedHex is null on failure
  Future<(String?, String?)> _signTransaction({
    required String walletId,
    required String txid,
    required String unsignedTxHex,
    required List<String> utxoKeys,
    required List<dartsv.SVPublicKey> publicKeys,
    required List<String> addresses,
    required List<int> derivationIndices,
  }) async {

    final completer = Completer<TransactionSignedResponse>();
    final receiver = await context.system.spawn(
      'sign-receiver-$txid',
      () => _SigningReceiverActor(completer),
    );

    // Send SignTransactionCommand to wallet
    _walletManager.tell(
      WalletCommandMessage(
        walletId,
        SignTransactionCommand(
          walletId: walletId,
          transactionId: txid,
          rawTransaction: unsignedTxHex,
          utxoKeys: utxoKeys,
          publicKeys: publicKeys.map((key) => key.toHex()).toList(),
          addresses: addresses,
          derivationIndices: derivationIndices,
        ),
      ),
      sender: receiver,
    );
    
    // Wait for signing response
    try {
      final response = await completer.future.timeout(
        Duration(seconds: 20),
        onTimeout: () {
          return TransactionSignedResponse(
            walletId: walletId,
            txid: txid,
            signedHex: '',
            success: false,
            error: 'Signing timeout',
          );
        },
      );

      if (!response.success) {
        _log.warning('[sign] Failed: ${response.error}');
        return (null, response.error ?? 'Unknown signing error');
      }

      return (response.signedHex, null);
    } finally {
      // Clean up temporary receiver actor to prevent resource leak
      await context.system.stop(receiver);
    }
  }

  /// Get block headers for validation
  Future<List<spiffy.BlockHeader>> _getBlockHeaders(List<int> blockHeights) async {
    final headers = <spiffy.BlockHeader>[];

    for (final height in blockHeights) {
      final header = await _storage.getBlockHeaderByHeight(height);
      if (header != null) {
        headers.add(header);
      }
    }

    return headers;
  }

  /// Create a minimal BEEF wrapper containing a single transaction with no
  /// ancestor chain. Used for plugin-built transactions where the plugin
  /// manages its own inputs and the standard BEEF ancestor chain is not
  /// applicable.
  Uint8List _createMinimalBEEF(Uint8List rawTx) {
    // BEEF format: version(4) + nBUMPs(varint) + nTxs(varint) + [hasBUMP(1) + tx]
    final writer = BytesBuilder();
    // Version 0100BEEF (little-endian)
    writer.add([0x01, 0x00, 0xBE, 0xEF]);
    // Number of BUMPs: 0
    writer.addByte(0x00);
    // Number of transactions: 1
    writer.addByte(0x01);
    // Has BUMP: false (0x00)
    writer.addByte(0x00);
    // Raw transaction
    writer.add(rawTx);
    return Uint8List.fromList(writer.toBytes());
  }

  /// Create BEEF package from transactions, proofs, and headers
  Future<Uint8List> _createBEEF({
    required BitcoinTransaction paymentTransaction,
    required List<BitcoinTransaction> ancestorTransactions,
    required List<MerkleProof> merkleProofs,
    required List<spiffy.BlockHeader> blockHeaders,
  }) async {
    try {
      for (final ancestor in ancestorTransactions) {
      }
      for (final proof in merkleProofs) {
      }
      
      // 1. Convert all transactions to raw bytes
      final txBytes = <Uint8List>[];
      
      // Add ancestor transactions first (in order they were collected)
      for (final tx in ancestorTransactions) {
        txBytes.add(Uint8List.fromList(hex.decode(tx.rawHex)));
      }
      
      // Add payment transaction last (the new transaction being created)
      txBytes.add(Uint8List.fromList(hex.decode(paymentTransaction.rawHex)));
      
      // 2. Build BUMPs from merkle proofs
      final bumps = <BUMP>[];
      for (final proof in merkleProofs) {
        bumps.add(CryptoUtils.buildBUMPFromMerkleProof(proof));
      }
      
      // 3. Set hasMerkle flags - only ancestors with proofs have true
      final hasMerkle = <bool>[];
      for (final ancestor in ancestorTransactions) {
        final hasProof = merkleProofs.any((p) => p.txid == ancestor.txid);
        hasMerkle.add(hasProof);
      }
      // Payment transaction doesn't have a merkle proof yet (unconfirmed)
      hasMerkle.add(false);
      
      // 4. Build bumpIndex array - maps transactions with proofs to their BUMP index
      final bumpIndex = <int>[];
      for (int i = 0; i < ancestorTransactions.length; i++) {
        if (hasMerkle[i]) {
          // Find which BUMP this transaction corresponds to
          final proofIdx = merkleProofs.indexWhere((p) => p.txid == ancestorTransactions[i].txid);
          if (proofIdx != -1) {
            bumpIndex.add(proofIdx);
          }
        }
      }
      
      // Debug: Log what we're passing to BEEF.create()
      for (int i = 0; i < txBytes.length; i++) {
      }


      // 5. Create BEEF using the existing BEEF.create() method
      final beef = BEEF.create(
        bumps: bumps,
        txs: txBytes,
        hasMerkle: hasMerkle,
        bumpIndex: bumpIndex,
      );
      
      // 6. Serialize BEEF
      final serialized = beef.serialize();
      // 7. Verify BEEF can be parsed (sanity check)
      try {
        final parsed = BEEF.parse(serialized);
      } catch (e, stackTrace) {
        throw Exception('Created BEEF is invalid: $e');
      }
      
      return serialized;
    } catch (e) {
      rethrow;
    }
  }


  /// Send error response to caller
  void _sendError(String invoiceId, String error, {ActorRef? sender}) {
    final target = sender ?? context.sender;
    target?.tell(BEEFPaymentResponse.error(
      invoiceId: invoiceId,
      error: error,
    ));
  }

  /// Reserve multiple UTXOs via the wallet aggregate.
  ///
  /// Uses the timeout-as-success pattern: the aggregate sends a LocalMessage
  /// with an error on failure, but sends nothing on success. A 2-second timeout
  /// with no error means the reservation succeeded.
  Future<bool> _reserveUTXOs(String walletId, List<BitcoinUtxo> utxos, String reservationId) async {
    final receivers = <ActorRef>[];
    final futures = <Future<void>>[];

    try {
      for (final utxo in utxos) {
        final completer = Completer<void>();
        final receiverName = 'reserve-receiver-${utxo.key.replaceAll(':', '-')}-${DateTime.now().microsecondsSinceEpoch}';
        final receiver = await context.system.spawn(
          receiverName,
          () => _ReservationReceiverActor(completer),
        );
        receivers.add(receiver);

        _walletManager.tell(
          WalletCommandMessage(
            walletId,
            ReserveUTXOCommand(
              walletId: walletId,
              utxoKey: utxo.key,
              reservedByTxId: reservationId,
              reservationReason: 'payment',
              reservationDuration: const Duration(minutes: 2),
            ),
          ),
          sender: receiver,
        );

        futures.add(completer.future);
      }

      // Timeout = success (no errors received), any StateError = failure
      await Future.wait(futures).timeout(const Duration(seconds: 2));
      return true;
    } on TimeoutException {
      // No errors received within timeout — all reservations succeeded
      return true;
    } catch (e) {
      _log.info('UTXO reservation failed: $e');
      _releaseReservation(walletId: walletId, reservationId: reservationId);
      return false;
    } finally {
      for (final receiver in receivers) {
        await context.system.stop(receiver);
      }
    }
  }

  /// Release a UTXO reservation (fire-and-forget).
  /// The 2-minute expiry is a safety net if this fails.
  void _releaseReservation({required String walletId, required String reservationId}) {
    _walletManager.tell(WalletCommandMessage(
      walletId,
      ReleaseUTXOsCommand(
        walletId: walletId,
        reservationId: reservationId,
      ),
    ));
  }

  /// Record outgoing transaction in wallet history (in PENDING state)
  Future<void> _recordOutgoingTransaction({
    required String walletId,
    required BitcoinTransaction transaction,
    required List<String> spentUtxoKeys,
    required List<String> recipientAddresses,
    required BigInt paymentAmount,
    String? changeAddress,
    bool deferSpend = false,
  }) async {
    // Calculate change amount
    final changeAmount = transaction.outputValue - paymentAmount;

    final command = RecordOutgoingTransactionCommand(
      walletId: walletId,
      txid: transaction.txid,
      rawHex: transaction.rawHex,
      totalInputSats: transaction.inputValue.toInt(),
      totalOutputSats: transaction.outputValue.toInt(),
      fee: transaction.fee.toInt(),
      numInputs: spentUtxoKeys.length,
      numOutputs: recipientAddresses.length + (changeAddress != null ? 1 : 0),
      txVersion: transaction.version,
      txLockTime: transaction.lockTime,
      spentUtxoKeys: spentUtxoKeys,
      recipientAddresses: recipientAddresses,
      paymentAmount: paymentAmount,
      changeAddress: changeAddress,
      changeAmount: changeAmount > BigInt.zero ? changeAmount : null,
      deferSpend: deferSpend,
    );
    
    _walletManager.tell(
      WalletCommandMessage(walletId, command),
      sender: context.self,
    );
  }

  /// Handle funding provisioning request.
  ///
  /// Looks up the plugin, selects the largest available UTXO (or uses a
  /// params-specified one), builds the provision tree, records each
  /// transaction, and registers earmarked UTXOs in the wallet.
  Future<void> _handleProvisionFunding(ProvisionFundingMessage msg) async {
    final originalSender = context.sender;
    final walletId = msg.walletId;

    String? reservationId;
    try {
      // 1. Look up plugin
      final plugin = PluginRegistry().getPlugin(msg.pluginId);
      if (plugin is! TransactionBuilderPlugin) {
        throw Exception('Plugin "${msg.pluginId}" is not a TransactionBuilderPlugin');
      }

      // 2. Get available UTXOs and select the largest
      final availableUtxos = await _storage.getPaymentUTXOs(walletId);
      if (availableUtxos.isEmpty) {
        throw Exception('No available UTXOs for provisioning');
      }
      final sortedUtxos = List<BitcoinUtxo>.from(availableUtxos)
        ..sort((a, b) => b.satoshis.compareTo(a.satoshis));
      final selectedUtxo = sortedUtxos.first;
      final derivationIndex = selectedUtxo.derivationIndex ?? 0;

      // 2a. Reserve the selected UTXO to prevent double-spending
      reservationId = 'provision-$walletId-${DateTime.now().millisecondsSinceEpoch}';
      final reserved = await _reserveUTXOs(walletId, [selectedUtxo], reservationId);
      if (!reserved) {
        throw Exception('Failed to reserve UTXO for provisioning — it may already be in use');
      }

      // 3. Create callback signer (same pattern as plugin TX build path)
      final xpriv = await _secureStorage.getXPriv(walletId);
      final wif = await _secureStorage.getWIF(walletId);
      final keyMaterial = xpriv ?? wif;
      if (keyMaterial == null) {
        throw Exception('No signing key available for wallet $walletId');
      }

      late dartsv.SVPrivateKey signingKey;
      if (xpriv != null) {
        final hdKey = dartsv.HDPrivateKey.fromXpriv(xpriv);
        final derived = hdKey.deriveChildNumber(0).deriveChildNumber(derivationIndex);
        signingKey = derived.privateKey;
      } else {
        signingKey = dartsv.SVPrivateKey.fromWIF(wif!);
      }

      final sigHashType = dartsv.SighashType.SIGHASH_ALL.value |
          dartsv.SighashType.SIGHASH_FORKID.value;
      final callbackSigner = CallbackTransactionSigner(
        sigHashType: sigHashType,
        onSign: (Uint8List sighash, int inputIndex) {
          final sig = dartsv.SVSignature.fromPrivateKey(signingKey);
          sig.nhashtype = sigHashType;
          sig.sign(hex.encode(sighash));
          return Uint8List.fromList(sig.toDER());
        },
      );

      final publicKey = signingKey.publicKey;

      // 4. Build plugin request and call provisionFunding
      final request = PluginTransactionRequest(
        fundingUtxos: [selectedUtxo],
        signer: callbackSigner,
        publicKeys: [publicKey],
        params: msg.pluginParams,
      );

      final provisions = await plugin.provisionFunding(request);
      _log.info('[provision $walletId] built ${provisions.length} TXs '
          '(${provisions.where((p) => p.role == "earmark").length} earmarks)');

      // 5. Record each provisioned transaction
      for (final ptx in provisions) {
        final tx = dartsv.Transaction.fromHex(ptx.rawHex);
        final outputValue = tx.outputs.fold<BigInt>(
            BigInt.zero, (sum, o) => sum + o.satoshis);

        final btx = BitcoinTransaction.fromDartSvTransaction(
          walletId: walletId,
          transaction: tx,
          status: TransactionStatus.pending,
          receivingAddresses: [ptx.role == 'earmark' ? 'earmark:${ptx.purpose}' : 'split'],
          sendingAddresses: [],
          inputValue: outputValue + BigInt.from(ptx.feeSats),
          netAmount: BigInt.from(-ptx.feeSats),
        );

        // Identify spent UTXOs for this TX
        final spentKeys = <String>[];
        for (final input in tx.inputs) {
          spentKeys.add('${input.prevTxnId}:${input.prevTxnOutputIndex}');
        }

        await _recordOutgoingTransaction(
          walletId: walletId,
          transaction: btx,
          spentUtxoKeys: spentKeys,
          recipientAddresses: btx.receivingAddresses,
          paymentAmount: BigInt.zero,
        );
      }

      // 6. Register earmarked UTXOs in the wallet
      final earmarks = provisions.where((p) => p.role == 'earmark').toList();
      final changeAddress = selectedUtxo.address;
      final scriptPubKey = selectedUtxo.scriptPubKey;

      for (final earmark in earmarks) {
        _walletManager.tell(
          WalletCommandMessage(walletId, ReceiveUTXOCommand(
            walletId: walletId,
            txid: earmark.txid,
            vout: earmark.fundingVout,
            satoshis: BigInt.from(earmark.fundingSats),
            scriptPubKey: scriptPubKey,
            address: changeAddress,
            initialStatus: UTXOStatus.available,
            derivationIndex: derivationIndex,
            pluginMetadata: {
              'pluginId': 'funding-earmark',
              'purpose': earmark.purpose,
            },
          )),
        );
      }

      // 7. Send response
      if (originalSender != null) {
        originalSender.tell(ProvisionFundingResponse(
          walletId: walletId,
          transactionCount: provisions.length,
          earmarkCount: earmarks.length,
          success: true,
        ));
      }
    } catch (e) {
      _log.warning('[provision $walletId] failed: $e');
      if (reservationId != null) {
        _releaseReservation(walletId: walletId, reservationId: reservationId);
      }
      if (originalSender != null) {
        originalSender.tell(ProvisionFundingResponse.error(
          walletId: walletId,
          error: e.toString(),
        ));
      }
    }
  }

  @override
  Future<void> postStop() async {
  }
}

/// Helper actor to receive UTXO reservation error responses.
/// On success, the aggregate sends nothing — the completer times out (= success).
/// On failure, the aggregate sends a LocalMessage with an error payload.
class _ReservationReceiverActor extends Actor {
  final Completer<void> completer;

  _ReservationReceiverActor(this.completer);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is LocalMessage && !completer.isCompleted) {
      final payload = message.payload;
      if (payload is Map && payload.containsKey('error')) {
        completer.completeError(StateError(payload['error'].toString()));
      }
    }
  }
}

/// Helper actor to receive signing response
class _SigningReceiverActor extends Actor {
  final Completer<TransactionSignedResponse> completer;
  
  _SigningReceiverActor(this.completer);
  
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is TransactionSignedResponse && !completer.isCompleted) {
      completer.complete(message);
    }
  }
}

