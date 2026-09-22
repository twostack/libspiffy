/// SPVActor receive-path gaps where a received payment validated with its
/// outputs silently dropped:
///
/// - libspiffy-4fq: the P2PK branch read dartsv's script info under 'pubKey',
///   but dartsv names it 'publicKey' (an SVPublicKey). No P2PK output was
///   ever given an address, so a P2PK payment to a wallet key was never
///   credited.
/// - libspiffy-n8b9: with an invoice id, an invoice lookup that failed (the
///   invoice coordinator did not answer) or found no such invoice returned
///   no outputs and skipped the invoice check: the result was valid with
///   nothing credited and nothing reported as paying the invoice.
/// - libspiffy-rp6x: an output whose locking script could not be read (a
///   template or a plugin threw) was logged and treated as nobody's while the
///   result stayed valid, with no way for a caller to see it.
///
/// The harness is the one of spv_attribution_read_model_lag_test.dart: a
/// real WalletManagerActor (the wallet aggregate answers ownership) and no
/// wallet projection.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart' show BEEFValidationResultEvent, CoordinatorEvent, SPVValidationResultEvent;
import 'package:libspiffy/src/actors/invoice_messages.dart';
import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/actors/wallet_manager_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart' show PluginOutputSpec;
import 'package:libspiffy/src/plugin/plugin_registry.dart';
import 'package:libspiffy/src/plugin/plugin_types.dart';
import 'package:libspiffy/src/plugin/script_plugin.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';
import 'in_memory_event_store.dart';

/// The key the fixture transaction's output 1 pays.
const _payerXpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';
const _payerRootAddress = 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12';
const _recipientMnemonic = 'legal winner thank year wave sausage worth useful '
    'legal winner thank yellow';

/// The locking script the throwing plugin claims: `<"boom"> OP_DROP OP_1`,
/// which no dartsv template recognises.
final _pluginScriptHex = '04${hex.encode('boom'.codeUnits)}7551';

void main() {
  final payerKey = dartsv.HDPrivateKey.fromXpriv(_payerXpriv)
      .deriveChildNumber(0)
      .deriveChildNumber(0)
      .privateKey;
  final g = dartsv.Transaction.fromHex(kFixtureTxHex);

  /// Spends the fixture transaction's output 1 (2 BSV) to [outputs].
  dartsv.Transaction spendFixture(List<(dartsv.LockingScriptBuilder, int)> outputs) {
    final out = g.outputs[1];
    final builder = dartsv.TransactionBuilder()
      ..spendFromOutpointWithSigner(
        dartsv.DefaultTransactionSigner(
            dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, payerKey),
        dartsv.TransactionOutpoint(g.id, 1, out.satoshis, out.script),
        dartsv.TransactionInput.MAX_SEQ_NUMBER,
        dartsv.P2PKHUnlockBuilder(payerKey.publicKey),
      );
    for (final (lock, sats) in outputs) {
      builder.spendToLockBuilder(lock, BigInt.from(sats));
    }
    builder.withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);
    return builder.build(false);
  }

  Uint8List bytes(String txHex) => Uint8List.fromList(hex.decode(txHex));

  BEEF paymentBeef(dartsv.Transaction payment) => BEEF.create(
        bumps: [fixtureBump()],
        txs: [bytes(kFixtureTxHex), bytes(payment.serialize())],
        hasMerkle: [true, false],
        bumpIndex: [0],
      );

  dartsv.LockingScriptBuilder p2pkh(String address) => dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address(address));

  late LocalActorSystem system;
  late InMemoryEventStore eventStore;
  late ActorRef walletManager;
  late InMemoryWalletStorage readModel;

  setUp(() async {
    system = LocalActorSystem(ActorSystemConfig());
    eventStore = InMemoryEventStore();
    readModel = InMemoryWalletStorage();
    await readModel.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    walletManager = await system.spawn(
      'wallet-manager',
      () => WalletManagerActor(
        eventStore: eventStore,
        cryptoService: DartSVCryptoService(),
        secureStorage: InMemorySecureStorage(),
        aggregateIdleTimeout: null,
      ),
    );
  });

  tearDown(() => system.shutdown());

  var spvCount = 0;
  Future<ActorRef> spawnSpv({ActorRef? invoices, ActorRef? ownership}) async {
    final invoiceCoordinator = invoices ?? await system.spawn('invoices-$spvCount', () => _Silent());
    return system.spawn(
      'spv-${spvCount++}',
      () => SPVActor(walletManager: ownership ?? walletManager, invoiceCoordinator: invoiceCoordinator, storage: readModel),
    );
  }

  List<Event> journal(String walletId) => eventStore.journal['BitcoinWallet_$walletId'] ?? const [];

  Future<void> createWallet(String walletId) async {
    final created = await walletManager.ask<WalletCreatedMessage>(
      CreateWalletMessage(walletId, walletId, mnemonic: _recipientMnemonic),
      const Duration(seconds: 10),
    );
    expect(created.success, isTrue, reason: created.error);
  }

  Future<AddressGeneratedResponse> generateAddress(String walletId) async {
    final generated = await walletManager.ask<AddressGeneratedResponse>(
      WalletCommandMessage(walletId, GenerateAddressCommand(walletId: walletId, includePublicKey: true)),
      const Duration(seconds: 10),
    );
    expect(generated.success, isTrue, reason: generated.error);
    return generated;
  }

  var receiverCount = 0;
  Future<SPVValidationResult> receive(ActorRef spv, String walletId, dartsv.Transaction payment,
      {String? invoiceId}) async {
    final done = Completer<SPVValidationResult>();
    final receiver = await system.spawn('receiver-${receiverCount++}', () => _Receiver(done));
    spv.tell(
      ReceiveTransactionMessage(
        transactionId: payment.id,
        beef: paymentBeef(payment),
        fromCounterparty: 'payer',
        targetWalletId: walletId,
        invoiceId: invoiceId,
      ),
      sender: receiver,
    );
    return done.future.timeout(const Duration(seconds: 20));
  }

  Future<TransactionImportedEvent> settled(String walletId, String txid) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      final imported = journal(walletId).whereType<TransactionImportedEvent>().where((e) => e.txid == txid);
      if (imported.isNotEmpty) return imported.single;
      if (DateTime.now().isAfter(deadline)) fail('wallet $walletId never recorded $txid');
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  Iterable<UTXOReceivedEvent> received(String walletId, String txid) =>
      journal(walletId).whereType<UTXOReceivedEvent>().where((e) => e.txid == txid);

  group('libspiffy-4fq: P2PK outputs', () {
    test('a P2PK output locked to a wallet key is credited to the wallet', () async {
      await createWallet('p2pk');
      final generated = await generateAddress('p2pk');
      final walletKey = dartsv.SVPublicKey.fromHex(generated.publicKeyHex!);
      final spv = await spawnSpv();

      final payment = spendFixture([
        (dartsv.P2PKLockBuilder(walletKey), 150000000),
        (p2pkh(_payerRootAddress), 49990000),
      ]);
      final result = await receive(spv, 'p2pk', payment);
      expect(result.isValid, isTrue, reason: result.validationError);
      expect([for (final u in result.spendableUTXOs) (u['vout'], u['address'], u['scriptType'])],
          [(0, generated.address, 'P2PK')],
          reason: 'the P2PK output pays the wallet key, whose address is the wallet\'s');

      final imported = await settled('p2pk', payment.id);
      expect([for (final e in received('p2pk', payment.id)) (e.vout, e.address, e.satoshis)],
          [(0, generated.address, 150000000)],
          reason: 'the P2PK payment must be credited');
      expect(imported.walletReceivedSats, 150000000);
    });

    test('the P2PK output\'s address is asked about in the ownership query', () async {
      final key = dartsv.SVPrivateKey.fromHex('22' * 32, dartsv.NetworkType.TEST).publicKey;
      final keyAddress = key.toAddress(dartsv.NetworkType.TEST).toBase58();
      final queries = <WalletOwnershipQuery>[];
      final ownership = await system.spawn('ownership', () => _RecordingOwnership(queries, {keyAddress}));
      final spv = await spawnSpv(ownership: ownership);

      final payment = spendFixture([(dartsv.P2PKLockBuilder(key), 199990000)]);
      final result = await receive(spv, 'any', payment);
      expect(result.isValid, isTrue, reason: result.validationError);
      expect(queries.single.addresses, contains(keyAddress));
      expect([for (final u in result.spendableUTXOs) u['address']], [keyAddress]);
    });
  });

  group('libspiffy-n8b9: invoice payments the invoice path cannot verify', () {
    test('an invoice coordinator that does not answer fails the result instead of validating it with nothing',
        () async {
      await createWallet('silent');
      final address = (await generateAddress('silent')).address;
      final spv = await spawnSpv(invoices: await system.spawn('silent-invoices', () => _Silent()));

      final payment = spendFixture([(p2pkh(address), 150000000), (p2pkh(_payerRootAddress), 49990000)]);
      final result = await receive(spv, 'silent', payment, invoiceId: 'inv-silent');
      expect(result.isValid, isFalse,
          reason: 'the payment could not be checked against its invoice; it must not be reported received');
      expect(result.validationError, contains('inv-silent'));
    });

    test('an unknown invoice id fails the result and marks nothing paid', () async {
      await createWallet('unknown');
      final address = (await generateAddress('unknown')).address;
      final invoices = _Invoices({});
      final spv = await spawnSpv(invoices: await system.spawn('unknown-invoices', () => invoices));

      final payment = spendFixture([(p2pkh(address), 150000000), (p2pkh(_payerRootAddress), 49990000)]);
      final result = await receive(spv, 'unknown', payment, invoiceId: 'inv-unknown');
      expect(result.isValid, isFalse);
      expect(result.validationError, contains('inv-unknown'));
      expect(invoices.markedPaid, isEmpty);
    });

    test('a found invoice that the transaction does not pay fails the result', () async {
      await createWallet('unpaid');
      final address = (await generateAddress('unpaid')).address;
      final other = (await generateAddress('unpaid')).address;
      final invoices = _Invoices({'inv-unpaid': (walletId: 'unpaid', address: other, amount: 150000000)});
      final spv = await spawnSpv(invoices: await system.spawn('unpaid-invoices', () => invoices));

      final payment = spendFixture([(p2pkh(address), 150000000), (p2pkh(_payerRootAddress), 49990000)]);
      final result = await receive(spv, 'unpaid', payment, invoiceId: 'inv-unpaid');
      expect(result.isValid, isFalse, reason: 'nothing in the transaction pays the invoice');
      expect(result.validationError, contains('inv-unpaid'));
      expect(invoices.markedPaid, isEmpty);
    });

    test('a found invoice that the transaction pays is received, and reported as what pays it', () async {
      await createWallet('paid');
      final address = (await generateAddress('paid')).address;
      final invoices = _Invoices({'inv-paid': (walletId: 'paid', address: address, amount: 150000000)});
      final spv = await spawnSpv(invoices: await system.spawn('paid-invoices', () => invoices));

      final payment = spendFixture([(p2pkh(address), 150000000), (p2pkh(_payerRootAddress), 49990000)]);
      final result = await receive(spv, 'paid', payment, invoiceId: 'inv-paid');
      expect(result.isValid, isTrue, reason: result.validationError);
      expect([for (final u in result.spendableUTXOs) u['address']], [address]);
      await settled('paid', payment.id);
      // Bead libspiffy-yyby: the invoice is marked paid by the coordinator,
      // once ARC says the network holds the payment; a valid BEEF says
      // nothing about the network having taken it. What it pays the invoice
      // is reported here, for the coordinator to mark it with.
      expect(invoices.markedPaid, isEmpty);
      expect(result.invoicePaidAmount, BigInt.from(150000000));
      expect(result.invoicePaidAddresses, [address]);
      expect(invoices.checks, 1, reason: 'the invoice is looked up once per receive');
    });
  });

  group('libspiffy-rp6x: outputs whose locking script cannot be read', () {
    tearDown(() => PluginRegistry().unregister(_ThrowingPlugin.id));

    test('a plugin that throws reading an output: the result lists the output, the transaction is recorded',
        () async {
      PluginRegistry().register(_ThrowingPlugin());
      await createWallet('plugin');
      final address = (await generateAddress('plugin')).address;
      final spv = await spawnSpv();

      final payment = spendFixture([
        (p2pkh(address), 150000000),
        (_ScriptLock(_pluginScriptHex), 1000),
        (p2pkh(_payerRootAddress), 49989000),
      ]);
      final result = await receive(spv, 'plugin', payment);
      expect(result.isValid, isTrue, reason: 'the transaction is valid and is recorded: ${result.validationError}');
      expect(result.unreadableOutputs, hasLength(1), reason: 'the unreadable output must not vanish silently');
      final unreadable = result.unreadableOutputs.single;
      expect(unreadable['vout'], 1);
      expect(unreadable['satoshis'], 1000);
      expect(unreadable['script'], _pluginScriptHex);
      expect(unreadable['reason'], contains('metadata exploded'));

      final imported = await settled('plugin', payment.id);
      expect(imported.rawHex, payment.serialize(), reason: 'the transaction is kept whole');
      expect([for (final e in received('plugin', payment.id)) e.vout], [0],
          reason: 'the readable wallet output is still credited');
    });

    test('a template that throws reading an output (P2PK with a key off the curve) is listed', () async {
      await createWallet('template');
      final address = (await generateAddress('template')).address;
      final spv = await spawnSpv();
      // 33 bytes, shaped like a compressed key, not a point on the curve.
      final badP2pkHex = '21${'02'}${'ff' * 32}ac';

      final payment = spendFixture([
        (p2pkh(address), 150000000),
        (_ScriptLock(badP2pkHex), 1000),
        (p2pkh(_payerRootAddress), 49989000),
      ]);
      final result = await receive(spv, 'template', payment);
      expect(result.isValid, isTrue, reason: result.validationError);
      expect([for (final u in result.unreadableOutputs) (u['vout'], u['script'])], [(1, badP2pkHex)]);
      await settled('template', payment.id);
    });

    Future<(ActorRef, List<CoordinatorEvent>)> coordinatorOver(ActorRef projection) async {
      final probe = await system.spawn('probe', () => _Silent());
      final coordinator = WalletCoordinatorActor(
        walletManager: probe,
        invoiceCoordinator: probe,
        paymentCoordinator: probe,
        spvActor: probe,
        arcActor: probe,
        headerSyncActor: probe,
        benfordCoordinator: probe,
        channelManager: probe,
        walletProjection: projection,
        storage: readModel,
      );
      final events = <CoordinatorEvent>[];
      final sub = coordinator.events.listen(events.add);
      addTearDown(sub.cancel);
      return (await system.spawn('coordinator', () => coordinator), events);
    }

    test('the coordinator passes the unreadable outputs of a payment on in BEEFValidationResultEvent', () async {
      // Answers the coordinator's two projection questions at once, so the
      // payment is answered without waiting out a projection that is not
      // here (its row is not stored either: the answer says so).
      final projection = await system.spawn('projection', () => _AppliedProjection());
      final (ref, events) = await coordinatorOver(projection);
      final unreadable = {'vout': 3, 'satoshis': 1, 'script': '51', 'reason': 'boom'};
      // A payment: its subject carried no proof of its own.
      ref.tell(SPVValidationResult(
          txid: 'cd' * 32, isValid: true, targetWalletId: 'w', unreadableOutputs: [unreadable]));

      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (events.whereType<BEEFValidationResultEvent>().isEmpty) {
        if (DateTime.now().isAfter(deadline)) fail('no BEEFValidationResultEvent: $events');
        await Future.delayed(const Duration(milliseconds: 10));
      }
      expect(events.whereType<BEEFValidationResultEvent>().single.unreadableOutputs, [unreadable]);
    });

    test('the coordinator passes the unreadable outputs on in SPVValidationResultEvent', () async {
      final probe = await system.spawn('probe', () => _Silent());
      final coordinator = WalletCoordinatorActor(
        walletManager: probe,
        invoiceCoordinator: probe,
        paymentCoordinator: probe,
        spvActor: probe,
        arcActor: probe,
        headerSyncActor: probe,
        benfordCoordinator: probe,
        channelManager: probe,
        walletProjection: probe,
        storage: readModel,
      );
      final events = <CoordinatorEvent>[];
      final sub = coordinator.events.listen(events.add);
      final ref = await system.spawn('coordinator', () => coordinator);
      final unreadable = {'vout': 3, 'satoshis': 1, 'script': '51', 'reason': 'boom'};
      // An import: its BEEF carried the subject's proof.
      ref.tell(SPVValidationResult(
          txid: 'ab' * 32, isValid: true, unreadableOutputs: [unreadable], subjectCarriesProof: true));

      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (events.whereType<SPVValidationResultEvent>().isEmpty) {
        if (DateTime.now().isAfter(deadline)) fail('no SPVValidationResultEvent');
        await Future.delayed(const Duration(milliseconds: 10));
      }
      expect(events.whereType<SPVValidationResultEvent>().single.unreadableOutputs, [unreadable]);
      await sub.cancel();
    });
  });
}

class _Silent extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

class _Receiver extends Actor {
  final Completer<SPVValidationResult> done;
  _Receiver(this.done);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is SPVValidationResult && !done.isCompleted) done.complete(message);
  }
}

/// Answers ownership queries (every wallet exists, owns [owned]) and keeps
/// each query.
class _RecordingOwnership extends Actor {
  final List<WalletOwnershipQuery> queries;
  final Set<String> owned;
  _RecordingOwnership(this.queries, this.owned);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletOwnershipQuery) {
      queries.add(message);
      // ignore: invalid_use_of_internal_member
      context.sender?.tell(WalletOwnershipResponse(
        walletId: message.walletId,
        walletFound: true,
        ownedAddresses: message.addresses.intersection(owned),
      ));
    }
  }
}

/// An invoice coordinator knowing [invoices] (one P2PKH address each).
class _Invoices extends Actor {
  final Map<String, ({String walletId, String address, int amount})> invoices;
  final markedPaid = <String>[];
  var checks = 0;
  _Invoices(this.invoices);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is CheckInvoiceMessage) {
      checks++;
      final invoice = invoices[message.invoiceId];
      // ignore: invalid_use_of_internal_member
      context.sender?.tell(InvoiceDetailsResponse(
        invoiceId: message.invoiceId,
        walletId: invoice?.walletId,
        addresses: invoice == null ? const [] : [invoice.address],
        amount: BigInt.from(invoice?.amount ?? 0),
        status: InvoiceStatus.pending,
        createdAt: DateTime.now(),
        found: invoice != null,
      ));
    } else if (message is MarkInvoicePaidMessage) {
      markedPaid.add(message.invoiceId);
    }
  }
}

/// A locking script given as hex.
class _ScriptLock extends dartsv.LockingScriptBuilder {
  final String scriptHex;
  _ScriptLock(this.scriptHex);

  @override
  dartsv.SVScript getScriptPubkey() => dartsv.SVScript.fromHex(scriptHex);

  @override
  void parse(dartsv.SVScript script) {}
}

/// Claims [_pluginScriptHex] and throws reading its metadata.
class _ThrowingPlugin extends ScriptPlugin {
  static const id = 'throwing-test-plugin';

  @override
  String get pluginId => id;
  @override
  String get displayName => 'Throwing';
  @override
  List<String> get scriptTypes => const ['boom'];
  @override
  String? identifyScript(dartsv.SVScript script) => script.toHex() == _pluginScriptHex ? 'boom' : null;
  @override
  Map<String, dynamic>? extractMetadata(dartsv.SVScript script) => throw StateError('metadata exploded');
  @override
  dartsv.LockingScriptBuilder? createLockBuilder(PluginOutputSpec spec) => null;
  @override
  dartsv.UnlockingScriptBuilder? createUnlockBuilder(PluginUnlockSpec spec) => null;
}

/// A wallet projection that has applied everything: answers the FIFO
/// barrier and every awaiter at once.
class _AppliedProjection extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    if (message is GetProjectionInfo || message is AwaitEventApplied) {
      context.sender?.tell(EventAppliedResponse());
    }
  }
}
