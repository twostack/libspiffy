/// libspiffy-mmb: aggregate state objects are immutable (copy-on-write).
///
/// WalletState, InvoiceState and ChannelState were updated in place by the
/// aggregates' event handlers, and their collections were plain mutable maps
/// and lists. So:
///
/// * a state object someone held (a test, a projection, a command handler
///   reading `currentState` before persisting) changed underneath its holder
///   when the next event applied;
/// * anyone holding the state could modify its UTXOs, addresses, watch
///   addresses, metadata records, invoice addresses/outputs/metadata and
///   channel ancestor txids, changing the aggregate without an event;
/// * collections a caller put in a command (UTXO plugin metadata, wallet and
///   invoice metadata, invoice output keys, channel ancestor txids) were
///   shared with the state, so the caller changing them later changed the
///   aggregate's state;
/// * an event whose application threw midway left the state half-applied;
/// * `ChannelState.copyWith` (and so eventador's `nextVersion`) threw
///   UnimplementedError.
///
/// Every test below fails on the in-place implementation.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart' show Event;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/invoice_messages.dart' show InvoiceStatus;
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/channel_commands.dart';
import 'package:libspiffy/src/core/channel_events.dart';
import 'package:libspiffy/src/core/channel_state.dart';
import 'package:libspiffy/src/core/invoice_aggregate.dart';
import 'package:libspiffy/src/core/invoice_commands.dart';
import 'package:libspiffy/src/core/invoice_events.dart';
import 'package:libspiffy/src/core/payment_channel_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/invoice_output_spec.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';
import 'wallet_event_fixtures.dart';

const _walletId = 'mmb-immutable-wallet';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

BitcoinWalletAggregate _wallet([InMemoryEventStore? store]) => BitcoinWalletAggregate(
      aggregateId: _walletId,
      aggregateType: 'BitcoinWallet',
      eventStore: store ?? InMemoryEventStore(),
      cryptoService: DartSVCryptoService(),
      secureStorage: InMemorySecureStorage(),
    );

/// A journal touching every wallet state collection.
WalletJournalBuilder _richJournal() {
  final j = WalletJournalBuilder(_walletId)..created();
  j.address('mreceive1', 1, label: 'first');
  j.address('mchange1', 1, change: true);
  j.events.add(WatchAddressAddedEvent(
    walletId: _walletId,
    address: 'mwatched1',
    scriptType: 'p2pkh',
    registeredAt: DateTime.utc(2021, 5, 2),
    version: j.events.length + 1,
    timestamp: DateTime.utc(2021, 5, 2),
  ));
  j.received(1, 0, sats: 5000, status: UTXOStatus.available, confirmations: 7);
  j.received(2, 0, sats: 3000, pluginMetadata: {
    'pluginId': 'tok',
    'nested': {'ids': [1, 2]},
  });
  j.reserved(1, 0, by: 'pay-1');
  j.imported(10);
  j.recorded(11);
  return j;
}

/// Every mutation a holder of [state] could attempt on its collections.
Map<String, void Function()> _walletMutations(WalletState state) {
  final utxoKey = state.utxos.keys.first;
  final anyUtxo = state.utxos.values.first;
  final outgoing = state.metadata['outgoingTransactions'] as Map;
  return {
    'utxos[]=': () => state.utxos['new:0'] = anyUtxo,
    'utxos.remove': () => state.utxos.remove(utxoKey),
    'utxos.clear': () => state.utxos.clear(),
    'addresses[]=': () => state.addresses['mnew'] = 'label',
    'addresses.remove': () => state.addresses.remove(state.addresses.keys.first),
    'watchAddresses[]=': () => state.watchAddresses['mnew'] = 'p2pkh',
    'watchAddresses.clear': () => state.watchAddresses.clear(),
    'metadata[]=': () => state.metadata['injected'] = true,
    'metadata.remove': () => state.metadata.remove('outgoingTransactions'),
    'address_indices[]=': () => (state.metadata['address_indices'] as Map)['mnew'] = 9,
    'outgoingTransactions.clear': () => outgoing.clear(),
    'outgoing record[]=': () => (outgoing.values.first as Map)['status'] = 'confirmed',
    'outgoing record list.add': () => ((outgoing.values.first as Map)['recipientAddresses'] as List).add('mnew'),
    'utxo pluginMetadata[]=': () =>
        state.utxos.values.firstWhere((u) => u.pluginMetadata != null).pluginMetadata!['pluginId'] = 'other',
    'utxo pluginMetadata nested': () => ((state.utxos.values
            .firstWhere((u) => u.pluginMetadata != null)
            .pluginMetadata!['nested'] as Map)['ids'] as List)
        .add(3),
  };
}

void main() {
  group('mmb: wallet state', () {
    test('a state handed out does not change when later events apply', () {
      final j = _richJournal();
      final wallet = _wallet()..replay(j.events);
      final held = wallet.currentState;
      final heldMap = held.toMap();
      final heldVersion = held.version;

      final tail = WalletJournalBuilder(_walletId, start: DateTime.utc(2022), firstVersion: j.events.length + 1);
      tail.address('mreceive2', 2);
      tail.received(3, 1, sats: 700);
      tail.confirmed(2, 0, 3);
      tail.released(1, 0, restored: UTXOStatus.available);
      tail.spent(1, 0);
      tail.txConfirmed(11);
      tail.imported(12);
      tail.recorded(13);
      for (final event in tail.events) {
        wallet.eventHandler(event);
      }

      expect(wallet.currentState.version, heldVersion + tail.events.length);
      expect(held.version, heldVersion, reason: 'the held state keeps its version');
      expect(held.toMap(), heldMap, reason: 'the held state is not changed by later events');
    });

    test('the collections a state exposes cannot be modified', () {
      final events = _richJournal().events;
      final names = _walletMutations((_wallet()..replay(events)).currentState).keys;
      final modifiable = <String>[];
      for (final name in names) {
        // Each attempt on a state of its own, so one accepted modification
        // does not disturb the next attempt.
        final wallet = _wallet()..replay(events);
        final before = wallet.currentState.toMap();
        try {
          _walletMutations(wallet.currentState)[name]!();
          modifiable.add(name);
        } on UnsupportedError {
          expect(wallet.currentState.toMap(), before, reason: 'a refused $name changes nothing');
        }
      }
      expect(modifiable, isEmpty, reason: 'these state collections accepted a modification');
    });

    test('a WalletState does not share the collections it was built from', () {
      final created = DateTime.utc(2026);
      final utxos = <String, BitcoinUtxo>{
        'aa:0': BitcoinUtxo.create(
            txid: 'aa', vout: 0, satoshis: BigInt.from(10), scriptPubKey: '00', address: 'm1', createdAt: created),
      };
      final addresses = <String, String?>{'m1': null};
      final watch = <String, String>{'m2': 'p2pkh'};
      final metadata = <String, dynamic>{
        'records': {'r1': {'status': 'pending'}},
      };
      final state = WalletState(
        walletId: 'w',
        name: 'n',
        isCreated: true,
        networkType: 'testnet',
        walletType: WalletType.hd,
        timestamp: created,
        utxos: utxos,
        addresses: addresses,
        watchAddresses: watch,
        nextDerivationIndex: 1,
        metadata: metadata,
        confirmedBalance: dartsv.Coin.ofSat(BigInt.zero),
        unconfirmedBalance: dartsv.Coin.ofSat(BigInt.zero),
        reservedBalance: dartsv.Coin.ofSat(BigInt.zero),
        lastModified: created,
      );
      final copy = state.copyWithWallet(utxos: utxos, metadata: metadata);
      final before = state.toMap();
      final copyBefore = copy.toMap();

      utxos.clear();
      addresses['m3'] = 'late';
      watch.clear();
      ((metadata['records'] as Map)['r1'] as Map)['status'] = 'confirmed';
      metadata['late'] = 1;

      expect(state.toMap(), before);
      expect(copy.toMap(), copyBefore);
    });

    test('collections a caller put in a command do not reach into the state', () async {
      final store = InMemoryEventStore();
      final wallet = _wallet(store);
      await wallet.preStart();
      final walletMetadata = <String, dynamic>{
        'network': 'testnet',
        'profile': {'tags': ['a']},
      };
      await wallet.commandHandler(CreateWalletCommand(
          walletId: _walletId, walletName: 'w', mnemonic: _mnemonic, walletMetadata: walletMetadata));
      final root = wallet.currentState.rootAddress!;
      final pluginMetadata = <String, dynamic>{
        'pluginId': 'tok',
        'nested': {'ids': [1]},
      };
      await wallet.commandHandler(ReceiveUTXOCommand(
        walletId: _walletId,
        txid: 'ab' * 32,
        vout: 0,
        satoshis: BigInt.from(1000),
        scriptPubKey: dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(root)).getScriptPubkey().toHex(),
        address: root,
        pluginMetadata: pluginMetadata,
      ));
      final recipients = ['muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg'];
      final spent = ['${'ab' * 32}:0'];
      final tx = dartsv.Transaction()
        ..addInput(dartsv.TransactionInput('ab' * 32, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
      await wallet.commandHandler(RecordOutgoingTransactionCommand(
        walletId: _walletId,
        txid: 'cd' * 32,
        rawHex: tx.serialize(),
        totalInputSats: 1000,
        totalOutputSats: 900,
        fee: 100,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        spentUtxoKeys: spent,
        recipientAddresses: recipients,
        paymentAmount: BigInt.from(900),
      ));
      final before = wallet.currentState.toMap();

      ((walletMetadata['profile'] as Map)['tags'] as List).add('late');
      ((pluginMetadata['nested'] as Map)['ids'] as List).add(2);
      pluginMetadata['pluginId'] = 'other';
      recipients.add('mlate');
      spent.add('late:0');

      expect(wallet.currentState.toMap(), before);
    });

    test('an event that fails to apply leaves the state unchanged', () {
      final j = _richJournal();
      final wallet = _wallet()..replay(j.events);
      final before = wallet.currentState.toMap();
      final bad = _ThrowingAddressGeneratedEvent(
        walletId: _walletId,
        address: 'mhalfapplied',
        derivationIndex: 40,
        version: j.events.length + 1,
        timestamp: DateTime.utc(2022),
      );
      expect(() => wallet.eventHandler(bad), throwsA(isA<StateError>()));
      expect(wallet.currentState.toMap(), before, reason: 'no part of the failed event is applied');
      expect(wallet.currentState.addresses.containsKey('mhalfapplied'), isFalse);
    });
  });

  group('mmb: invoice state', () {
    const invoiceId = 'mmb-immutable-invoice';
    final keys = [
      for (final seed in ['11', '22'])
        dartsv.SVPrivateKey.fromHex(seed * 32, dartsv.NetworkType.TEST).publicKey.toHex(),
    ];

    Future<(InvoiceAggregate, List<String>, Map<String, dynamic>, List<InvoiceOutputSpec>, List<String>)>
        created() async {
      final invoice = InvoiceAggregate(aggregateId: invoiceId, aggregateType: 'Invoice', eventStore: InMemoryEventStore());
      await invoice.preStart();
      final addresses = ['maddr1'];
      final metadata = <String, dynamic>{
        'order': 'A-1',
        'lines': [1, 2],
      };
      final publicKeys = List<String>.of(keys);
      final outputs = <InvoiceOutputSpec>[
        P2PKHOutputSpec(address: 'maddr1', amount: BigInt.from(1000)),
        P2MSOutputSpec(publicKeys: publicKeys, threshold: 1, amount: BigInt.from(500)),
      ];
      await invoice.commandHandler(CreateInvoiceCommand(
        invoiceId: invoiceId,
        walletId: 'w',
        addresses: addresses,
        amount: BigInt.from(1500),
        outputs: outputs,
        invoiceMetadata: metadata,
      ));
      return (invoice, addresses, metadata, outputs, publicKeys);
    }

    test('a state handed out does not change when the invoice is paid', () async {
      final (invoice, _, _, _, _) = await created();
      final held = invoice.currentState;
      final heldMap = InvoiceAggregate.invoiceStateToMap(held);
      await invoice.commandHandler(MarkInvoicePaidCommand(
          invoiceId: invoiceId, txid: 'ab' * 32, amountReceived: BigInt.from(1500), addressesPaidTo: ['maddr1']));
      expect(invoice.currentState.status, InvoiceStatus.paid);
      expect(held.status, InvoiceStatus.pending);
      expect(InvoiceAggregate.invoiceStateToMap(held), heldMap);
    });

    test('the collections a state exposes cannot be modified', () async {
      final (invoice, _, _, _, _) = await created();
      final state = invoice.currentState;
      final before = InvoiceAggregate.invoiceStateToMap(state);
      final modifiable = <String>[];
      <String, void Function()>{
        'addresses.add': () => state.addresses.add('mnew'),
        'outputs.add': () => state.outputs!.add(P2PKHOutputSpec(address: 'm', amount: BigInt.one)),
        'outputs publicKeys.add': () => (state.outputs![1] as P2MSOutputSpec).publicKeys.add('02'),
        'metadata[]=': () => state.metadata['injected'] = 1,
        'metadata nested list.add': () => (state.metadata['lines'] as List).add(3),
      }.forEach((name, mutate) {
        try {
          mutate();
          modifiable.add(name);
        } on UnsupportedError {
          // expected
        }
      });
      expect(modifiable, isEmpty, reason: 'these state collections accepted a modification');
      expect(InvoiceAggregate.invoiceStateToMap(state), before);
    });

    test('collections a caller put in the command do not reach into the state', () async {
      final (invoice, addresses, metadata, outputs, publicKeys) = await created();
      final before = InvoiceAggregate.invoiceStateToMap(invoice.currentState);
      addresses.add('mlate');
      metadata['late'] = true;
      (metadata['lines'] as List).add(3);
      outputs.add(P2PKHOutputSpec(address: 'mlate', amount: BigInt.one));
      publicKeys[0] = '02${'00' * 32}';
      expect(InvoiceAggregate.invoiceStateToMap(invoice.currentState), before);
    });

    test('an event that fails to apply leaves the state unchanged', () async {
      final (invoice, _, _, _, _) = await created();
      final before = InvoiceAggregate.invoiceStateToMap(invoice.currentState);
      final bad = _ThrowingInvoicePaidEvent(
        invoiceId: invoiceId,
        walletId: 'w',
        txid: 'ab' * 32,
        amountReceived: BigInt.from(1500),
        addressesPaidTo: const ['maddr1'],
        version: invoice.currentState.version + 1,
      );
      expect(() => invoice.eventHandler(bad), throwsA(isA<StateError>()));
      expect(InvoiceAggregate.invoiceStateToMap(invoice.currentState), before);
      expect(invoice.currentState.status, InvoiceStatus.pending);
    });
  });

  group('mmb: channel state', () {
    const channelId = 'mmb-immutable-channel';
    final funding = BigInt.from(100000);

    /// A client channel ready to open: refund countersigned, funding
    /// broadcast in flight.
    List<ChannelEvent> readyToOpen() => [
          ChannelRequestedEvent(
            channelId: channelId,
            walletId: 'w1',
            clientPeerId: 'client-peer',
            serverPeerId: 'server-peer',
            clientPubKeyHex: '02${'11' * 32}',
            clientAddressB58: 'mclient',
            derivationIndex: 4,
            fundingAmountSats: funding,
            lockTimeUnix: 4000000000,
            version: 1,
          ),
          ServerAcceptanceRecordedEvent(
              channelId: channelId, serverPubKeyHex: '03${'22' * 32}', serverAddressB58: 'mserver', version: 2),
          RefundBuiltEvent(
            channelId: channelId,
            fundingTxId: 'cd' * 32,
            fundingOutputIndex: 0,
            fundingTxHex: '0100',
            refundTxHex: '0200',
            clientSignatureHex: '3044',
            version: 3,
          ),
          RefundCountersignedEvent(
              channelId: channelId, serverSignatureHex: '3045', signedRefundTxHex: '0201', version: 4),
          FundingBroadcastStartedEvent(channelId: channelId, fundingTxId: 'cd' * 32, attempt: 1, version: 5),
        ];

    Future<(PaymentChannelAggregate, List<String>)> opened() async {
      final store = InMemoryEventStore()..journal['PaymentChannel_$channelId'] = <Event>[...readyToOpen()];
      final channel = PaymentChannelAggregate(aggregateId: channelId, eventStore: store, cryptoService: DartSVCryptoService());
      await channel.preStart();
      final ancestors = ['ef' * 32];
      await channel.commandHandler(OpenChannelCommand(
        channelId: channelId,
        fundingTxId: 'cd' * 32,
        fundingOutputIndex: 0,
        fundingTxHex: '0100',
        fundingAncestorTxids: ancestors,
      ));
      expect(channel.currentState.status, ChannelStatus.open);
      return (channel, ancestors);
    }

    PaymentRecordedEvent payment(PaymentChannelAggregate channel, {bool throwing = false}) {
      final args = (
        amount: BigInt.from(1000),
        client: funding - BigInt.from(1000),
        server: BigInt.from(1000),
        version: channel.currentState.version + 1,
      );
      return throwing
          ? _ThrowingPaymentRecordedEvent(
              channelId: channelId,
              amountSats: args.amount,
              newClientBalanceSats: args.client,
              newServerBalanceSats: args.server,
              sequenceNumber: 1,
              paymentTxHex: '03',
              paymentTxId: '12' * 32,
              clientSignatureHex: '30',
              version: args.version)
          : PaymentRecordedEvent(
              channelId: channelId,
              amountSats: args.amount,
              newClientBalanceSats: args.client,
              newServerBalanceSats: args.server,
              sequenceNumber: 1,
              paymentTxHex: '03',
              paymentTxId: '12' * 32,
              clientSignatureHex: '30',
              version: args.version);
    }

    test('a state handed out does not change when later events apply', () async {
      final (channel, _) = await opened();
      final held = channel.currentState;
      final heldMap = PaymentChannelAggregate.channelStateToMap(held);
      channel.eventHandler(payment(channel));
      expect(channel.currentState.latestSequenceNumber, 1);
      expect(held.latestSequenceNumber, 0);
      expect(PaymentChannelAggregate.channelStateToMap(held), heldMap);
    });

    test('the ancestor txids a state exposes cannot be modified', () async {
      final (channel, _) = await opened();
      final state = channel.currentState;
      expect(() => state.fundingAncestorTxids.add('late'), throwsUnsupportedError);
      expect(state.fundingAncestorTxids, ['ef' * 32]);
    });

    test('the ancestor txids a caller put in the command do not reach into the state', () async {
      final (channel, ancestors) = await opened();
      ancestors.add('late');
      expect(channel.currentState.fundingAncestorTxids, ['ef' * 32]);
    });

    test('an event that fails to apply leaves the state unchanged', () async {
      final (channel, _) = await opened();
      final before = PaymentChannelAggregate.channelStateToMap(channel.currentState);
      expect(() => channel.eventHandler(payment(channel, throwing: true)), throwsA(isA<StateError>()));
      expect(PaymentChannelAggregate.channelStateToMap(channel.currentState), before);
    });

    test('copyWith and nextVersion keep every field', () async {
      final (channel, _) = await opened();
      channel.eventHandler(payment(channel));
      final state = channel.currentState;
      final next = state.nextVersion(DateTime.utc(2030)) as ChannelState;
      expect(next.version, state.version + 1);
      expect(next.lastModified, DateTime.utc(2030));
      expect(PaymentChannelAggregate.channelStateToMap(next)..remove('version')..remove('lastModified'),
          PaymentChannelAggregate.channelStateToMap(state)..remove('version')..remove('lastModified'));
    });
  });
}

/// An [AddressGeneratedEvent] whose chain cannot be read: application fails
/// after the address itself has been read.
class _ThrowingAddressGeneratedEvent extends AddressGeneratedEvent {
  _ThrowingAddressGeneratedEvent({
    required super.walletId,
    required super.address,
    required super.derivationIndex,
    required super.version,
    required super.timestamp,
  });

  @override
  String? get purpose => throw StateError('unreadable purpose');
}

/// An [InvoicePaidEvent] whose payment time cannot be read.
class _ThrowingInvoicePaidEvent extends InvoicePaidEvent {
  _ThrowingInvoicePaidEvent({
    required super.invoiceId,
    required super.walletId,
    required super.txid,
    required super.amountReceived,
    required super.addressesPaidTo,
    required super.version,
  });

  @override
  DateTime get paidAt => throw StateError('unreadable paidAt');
}

/// A [PaymentRecordedEvent] whose payment txid cannot be read.
class _ThrowingPaymentRecordedEvent extends PaymentRecordedEvent {
  _ThrowingPaymentRecordedEvent({
    required super.channelId,
    required super.amountSats,
    required super.newClientBalanceSats,
    required super.newServerBalanceSats,
    required super.sequenceNumber,
    required super.paymentTxHex,
    required super.paymentTxId,
    required super.clientSignatureHex,
    required super.version,
  });

  @override
  String get paymentTxId => throw StateError('unreadable paymentTxId');
}
