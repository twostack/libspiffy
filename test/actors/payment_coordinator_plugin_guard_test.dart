/// Bead libspiffy-uetb (from libspiffy-u150 / V-61): PaymentCoordinatorActor
/// called TransactionBuilderPlugin methods unguarded.
///
/// `_isPluginTransaction` read `plugin.supportedActions`, the plugin build
/// path called `buildTransaction`, `requiredFundingUtxoCount` and
/// `validateTransactionStructure`, and `_handleProvisionFunding` called
/// `provisionFunding` — every one of them straight into third-party code
/// with no guard. A faulty plugin therefore took the payment down with its
/// own exception, and the caller was told either the plugin's raw error
/// text or a generic "Failed to build payment transaction" that named
/// nobody.
///
/// V-61 guarded the registry's own calls (`identifyScript`,
/// `extractMetadata`, `createLockBuilder`, `createUnlockBuilder`): catch per
/// plugin, log against the `pluginId`, and never let the throw out. These
/// calls follow the same shape, except that a payment cannot silently carry
/// on without the plugin that was asked to build it: it fails, with a
/// message naming the plugin.
library;

import 'dart:async';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart' as log;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/payment_coordinator_actor.dart';
import 'package:libspiffy/src/actors/payment_messages.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/models/address_metadata.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';
import 'package:libspiffy/src/plugin/plugin_registry.dart';
import 'package:libspiffy/src/plugin/plugin_types.dart';
import 'package:libspiffy/src/plugin/provisioned_transaction.dart';
import 'package:libspiffy/src/plugin/transaction_builder_plugin.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/read_model_storage.dart';

const _pluginId = 'uetb_faulty';
const _walletId = 'uetb-wallet';
const _externalAddress = 'n4VQ5YdHf7hLQ2gWQYYrcxoE5B7nWuDFNF'; // testnet, not ours
final _fundingTxid = 'dd' * 32;

/// The wallet's only key: the scripted wallet manager signs with it and the
/// funding UTXO is locked to its address.
final _walletKey = dartsv.SVPrivateKey.fromHex('7c' * 32, dartsv.NetworkType.TEST);
final _walletAddress = _walletKey.publicKey.toAddress(dartsv.NetworkType.TEST).toString();

void main() {
  late ActorSystem system;
  late ActorRef coordinator;
  late _FaultyPlugin plugin;
  late List<log.LogRecord> logs;
  late StreamSubscription<log.LogRecord> logSubscription;
  late log.Level previousLevel;

  setUp(() async {
    plugin = _FaultyPlugin();
    PluginRegistry().register(plugin);

    logs = [];
    previousLevel = log.Logger.root.level;
    log.Logger.root.level = log.Level.ALL;
    logSubscription = log.Logger.root.onRecord.listen(logs.add);

    system = LocalActorSystem();
    final walletManager = await system.spawn('wallet-manager', () => _SigningWalletManager());
    final projection = await system.spawn('projection', () => _Silent());
    coordinator = await system.spawn(
      'payment-coordinator',
      () => PaymentCoordinatorActor(
        walletManager: walletManager,
        walletProjection: projection,
        storage: _PluginStorage(),
        secureStorage: InMemorySecureStorage(),
        reservationReplyTimeout: const Duration(seconds: 2),
        signingReplyTimeout: const Duration(seconds: 5),
      ),
    );
  });

  tearDown(() async {
    PluginRegistry().unregister(_pluginId);
    await logSubscription.cancel();
    log.Logger.root.level = previousLevel;
    await system.shutdown();
  });

  Future<T> ask<T>(Message message) async {
    final collector = _Collector();
    final replyTo = await system.spawn('reply-${DateTime.now().microsecondsSinceEpoch}', () => collector);
    coordinator.tell(message, sender: replyTo);
    return await collector.firstOfType<T>().timeout(const Duration(seconds: 20));
  }

  PayInvoiceMessage payment() => PayInvoiceMessage(
        walletId: _walletId,
        invoiceId: 'uetb-invoice',
        addresses: const [],
        amount: BigInt.from(20000),
        outputs: [
          PluginOutputSpec(
            pluginId: _pluginId,
            pluginScriptType: 'p2pkh',
            params: const {'action': 'spend', 'to': _externalAddress},
            amount: BigInt.from(20000),
          ),
        ],
      );

  void expectLogged(String what) {
    expect(
      logs.where((r) => r.message.contains(_pluginId) && r.message.contains(what)),
      isNotEmpty,
      reason: 'the plugin failure while $what must be logged against its pluginId; '
          'logged: ${logs.map((r) => r.message).toList()}',
    );
  }

  group('uetb: a faulty TransactionBuilderPlugin fails the payment, naming itself', () {
    test('supportedActions throws', () async {
      plugin.throwFrom = 'supportedActions';

      final response = await ask<BEEFPaymentResponse>(payment());

      expect(response.success, isFalse);
      expect(response.error, contains(_pluginId),
          reason: 'the caller must be told which plugin failed, not shown its stack trace');
      expectLogged('reading its supported actions');
    });

    test('buildTransaction throws', () async {
      plugin.throwFrom = 'buildTransaction';

      final response = await ask<BEEFPaymentResponse>(payment());

      expect(response.success, isFalse);
      expect(response.error, contains(_pluginId),
          reason: '"Failed to build payment transaction" names nobody');
      expectLogged('building the transaction');
    });

    test('validateTransactionStructure throws', () async {
      plugin.throwFrom = 'validateTransactionStructure';

      final response = await ask<BEEFPaymentResponse>(payment());

      expect(response.success, isFalse);
      expect(response.error, contains(_pluginId));
      expectLogged('validating the transaction');
    });

    test('requiredFundingUtxoCount throws', () async {
      plugin.throwFrom = 'requiredFundingUtxoCount';

      final response = await ask<BEEFPaymentResponse>(payment());

      expect(response.success, isFalse);
      expect(response.error, contains(_pluginId));
      expectLogged('how many funding UTXOs');
    });

    test('provisionFunding throws', () async {
      plugin.throwFrom = 'provisionFunding';

      final response = await ask<ProvisionFundingResponse>(ProvisionFundingMessage(
        walletId: _walletId,
        pluginId: _pluginId,
        pluginParams: const {'action': 'spend'},
      ));

      expect(response.success, isFalse);
      expect(response.error, contains(_pluginId));
      expectLogged('provisioning funding');
    });
  });

  // A plugin that works is covered by the cases above: in the
  // `validateTransactionStructure` test, `supportedActions`,
  // `requiredFundingUtxoCount` and `buildTransaction` all run through the
  // guards and answer normally before validation throws.
}

/// A `TransactionBuilderPlugin` that throws from exactly one of its methods.
class _FaultyPlugin extends TransactionBuilderPlugin {
  /// Name of the method that throws; null for a plugin that works.
  String? throwFrom;

  Never _boom(String method) => throw StateError('$method exploded');

  @override
  String get pluginId => _pluginId;
  @override
  String get displayName => 'Faulty (test)';
  @override
  List<String> get scriptTypes => const ['p2pkh'];
  @override
  String? identifyScript(dartsv.SVScript script) => null;
  @override
  Map<String, dynamic>? extractMetadata(dartsv.SVScript script) => null;
  @override
  dartsv.LockingScriptBuilder? createLockBuilder(PluginOutputSpec spec) => null;
  @override
  dartsv.UnlockingScriptBuilder? createUnlockBuilder(PluginUnlockSpec spec) => null;

  @override
  List<String> get supportedActions {
    if (throwFrom == 'supportedActions') _boom('supportedActions');
    return const ['spend'];
  }

  @override
  int requiredFundingUtxoCount(String action) {
    if (throwFrom == 'requiredFundingUtxoCount') _boom('requiredFundingUtxoCount');
    return 1;
  }

  @override
  bool validateTransactionStructure(dartsv.Transaction tx, String action) {
    if (throwFrom == 'validateTransactionStructure') _boom('validateTransactionStructure');
    return true;
  }

  @override
  Future<List<ProvisionedTransaction>> provisionFunding(PluginTransactionRequest request) async {
    if (throwFrom == 'provisionFunding') _boom('provisionFunding');
    return const [];
  }

  @override
  Future<TransactionBuilderResult> buildTransaction(PluginTransactionRequest request) async {
    if (throwFrom == 'buildTransaction') _boom('buildTransaction');
    final builder = dartsv.TransactionBuilder();
    var total = BigInt.zero;
    for (var i = 0; i < request.fundingUtxos.length; i++) {
      final utxo = request.fundingUtxos[i];
      total += utxo.satoshis;
      builder.spendFromOutpointWithSigner(
        request.signer,
        dartsv.TransactionOutpoint(
          utxo.txid,
          utxo.vout,
          utxo.satoshis,
          dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(utxo.address)).getScriptPubkey(),
        ),
        dartsv.TransactionInput.MAX_SEQ_NUMBER,
        dartsv.P2PKHUnlockBuilder(request.publicKeys[i]),
      );
    }
    const fee = 500;
    builder.spendToLockBuilder(
      dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(request.params['to'] as String)),
      total - BigInt.from(fee),
    );
    return TransactionBuilderResult(primaryTx: builder.build(false), primaryFeeSats: BigInt.from(fee));
  }
}

/// Wallet manager stand-in: confirms every reservation and signs every input
/// with the wallet's single key, exactly as the aggregate does.
class _SigningWalletManager extends Actor {
  final List<WalletCommand> commands = [];

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is! WalletCommandMessage) return;
    final command = message.command;
    commands.add(command);
    if (command is ReserveUTXOCommand) {
      context.sender?.tell(UTXOReservedResponse(
        walletId: command.walletId,
        utxoKey: command.utxoKey,
        reservedByTxId: command.reservedByTxId,
        success: true,
      ));
    } else if (command is SignInputCommand) {
      final digest = dartsv.Sighash().hash(
        dartsv.Transaction.fromHex(command.rawTransaction),
        command.sighashType,
        command.inputIndex,
        dartsv.SVScript.fromHex(command.subscriptHex),
        command.satoshis,
      );
      final signature = dartsv.SVSignature.fromPrivateKey(_walletKey)..nhashtype = command.sighashType;
      signature.sign(hex.encode(hex.decode(digest).reversed.toList()));
      context.sender?.tell(InputSignedResponse(
        walletId: command.walletId,
        commandId: command.commandId,
        inputIndex: command.inputIndex,
        signatureHex: signature.toTxFormat(),
        publicKeyHex: _walletKey.publicKey.toHex(),
        success: true,
      ));
    }
  }
}

/// Read model with one spendable UTXO at the wallet's only address.
class _PluginStorage implements ReadModelStorage {
  @override
  Future<List<BitcoinUtxo>> getPaymentUTXOs(String walletId) async {
    final now = DateTime.now();
    return [
      BitcoinUtxo(
        txid: _fundingTxid,
        vout: 0,
        value: dartsv.Coin.ofSat(BigInt.from(100000)),
        address: _walletAddress,
        scriptPubKey:
            dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(_walletAddress)).getScriptPubkey().toHex(),
        status: UTXOStatus.available,
        blockHeight: 1239645,
        createdAt: now,
        updatedAt: now,
      ),
    ];
  }

  @override
  Future<List<AddressMetadata>> getAddressesByPurpose(String walletId, String purpose) async => const [];

  @override
  Future<AddressMetadata?> getAddressMetadata(String walletId, String address) async =>
      address == _walletAddress
          ? AddressMetadata(
              address: _walletAddress,
              scriptType: 'p2pkh',
              derivationIndex: 0,
              isChange: false,
              purpose: 'receive',
              usageCount: 1,
              balance: BigInt.from(100000),
              createdAt: DateTime.now(),
              isWatched: false,
            )
          : null;

  @override
  Future<Map<String, dynamic>?> getWallet(String walletId) async =>
      {'walletId': walletId, 'walletType': 'wif', 'network': 'testnet'};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('ReadModelStorage.${invocation.memberName} not expected');
}

class _Silent extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

class _Collector extends Actor {
  final List<dynamic> received = [];
  final StreamController<dynamic> _stream = StreamController.broadcast();

  Future<T> firstOfType<T>() async {
    for (final m in received) {
      if (m is T) return m;
    }
    return (await _stream.stream.firstWhere((m) => m is T)) as T;
  }

  @override
  Future<void> onMessage(dynamic message) async {
    final payload = message is LocalMessage ? message.payload : message;
    received.add(payload);
    _stream.add(payload);
  }
}
