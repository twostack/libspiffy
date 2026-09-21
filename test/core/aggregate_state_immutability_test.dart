/// libspiffy-mmb: aggregate state objects are immutable (copy-on-write),
/// and libspiffy-6r5w: so are the events and commands that carry collections
/// into them.
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
/// mmb left events and commands sharing the caller's collections: an event
/// is handed live to the projection, to every coordinator subscriber and to
/// the P2P broadcaster, so a caller that went on modifying the list it had
/// passed changed what all three read. The journal was safe only because
/// serialization happens to copy. 6r5w copies and freezes those collections
/// in the constructors, including the ones the app hands the coordinator.
///
/// Every test below fails on the in-place implementation.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart' show Event;
import 'package:test/test.dart';

import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/coordinator_messages.dart' as coord;
import 'package:libspiffy/src/actors/wallet_coordinator_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart' as wm;
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
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

  group('6r5w: events and commands', () {
    test('an event does not share the collections the caller built it from', () {
      final spent = ['${'ab' * 32}:0'];
      final recipients = ['muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg'];
      final event = TransactionRecordedEvent(
        walletId: _walletId,
        txid: 'cd' * 32,
        rawHex: '00',
        totalInputSats: 1000,
        totalOutputSats: 900,
        fee: 100,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        spentUtxoKeys: spent,
        recipientAddresses: recipients,
        paymentAmount: '900',
      );
      final spentBefore = [...event.spentUtxoKeys];
      final recipientsBefore = [...event.recipientAddresses];

      spent.add('late:0');
      recipients.add('mlate');
      recipients.removeAt(0);

      expect(event.spentUtxoKeys, spentBefore);
      expect(event.recipientAddresses, recipientsBefore);
      expect(event.getEventData()['recipientAddresses'], recipientsBefore,
          reason: 'what is journaled and broadcast is the copy too');
    });

    test("an event's nested maps and lists are copied, not just the top level", () {
      final metadata = <String, dynamic>{
        'profile': {'tags': ['a']},
        'lines': [1, 2],
      };
      final event = WalletCreatedEvent(
        walletId: _walletId,
        walletName: 'w',
        rootAddress: 'muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg',
        walletType: WalletType.hd,
        walletMetadata: metadata,
      );
      final before = event.getEventData().toString();

      ((metadata['profile'] as Map)['tags'] as List).add('late');
      (metadata['lines'] as List).add(3);
      metadata['injected'] = true;

      expect(event.getEventData().toString(), before);
      expect((event.walletMetadata!['profile'] as Map)['tags'], ['a']);
    });

    test('the collections an event exposes cannot be modified', () {
      final recorded = TransactionRecordedEvent(
        walletId: _walletId,
        txid: 'cd' * 32,
        rawHex: '00',
        totalInputSats: 1000,
        totalOutputSats: 900,
        fee: 100,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        spentUtxoKeys: ['${'ab' * 32}:0'],
        recipientAddresses: ['muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg'],
        paymentAmount: '900',
      );
      final created = WalletCreatedEvent(
        walletId: _walletId,
        walletName: 'w',
        rootAddress: 'muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg',
        walletType: WalletType.hd,
        walletMetadata: {'profile': {'tags': ['a']}},
      );
      final deferred = TransactionSpendDeferredEvent(
        walletId: _walletId,
        txid: 'cd' * 32,
        heldInputs: [
          {'utxoKey': '${'ab' * 32}:0', 'satoshis': '1000'},
        ],
      );
      final opened = ChannelOpenedEvent(
        channelId: 'c1',
        fundingTxId: 'ab' * 32,
        fundingOutputIndex: 0,
        fundingTxHex: '00',
        fundingAncestorTxids: ['cd' * 32],
        initialClientBalanceSats: BigInt.from(10),
        initialServerBalanceSats: BigInt.zero,
      );

      _expectAllRejected({
        'spentUtxoKeys.add': () => recorded.spentUtxoKeys.add('late:0'),
        'recipientAddresses.clear': () => recorded.recipientAddresses.clear(),
        'walletMetadata[]=': () => created.walletMetadata!['injected'] = true,
        'walletMetadata nested list.add': () =>
            ((created.walletMetadata!['profile'] as Map)['tags'] as List).add('late'),
        'heldInputs.add': () => deferred.heldInputs.add({'utxoKey': 'x:1'}),
        'heldInput[]=': () => deferred.heldInputs.first['satoshis'] = '9',
        'fundingAncestorTxids.add': () => opened.fundingAncestorTxids.add('late'),
      });
    });

    test('a command does not share the collections the caller built it from', () {
      final utxoKeys = ['${'ab' * 32}:0'];
      final publicKeys = ['02' * 33];
      final indices = [4];
      final flags = [false];
      final sign = SignTransactionCommand(
        walletId: _walletId,
        transactionId: 'tx-1',
        rawTransaction: '00',
        utxoKeys: utxoKeys,
        publicKeys: publicKeys,
        derivationIndices: indices,
        isChangeFlags: flags,
      );
      final signerMetadata = <String, dynamic>{'signer': {'ids': [1]}};
      final recipients = ['muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg'];
      final record = RecordOutgoingTransactionCommand(
        walletId: _walletId,
        txid: 'cd' * 32,
        rawHex: '00',
        totalInputSats: 1000,
        totalOutputSats: 900,
        fee: 100,
        numInputs: 1,
        numOutputs: 1,
        txVersion: 1,
        txLockTime: 0,
        spentUtxoKeys: utxoKeys,
        recipientAddresses: recipients,
        paymentAmount: BigInt.from(900),
        signerMetadata: signerMetadata,
      );

      utxoKeys.add('late:0');
      publicKeys.clear();
      indices.add(9);
      flags.add(true);
      recipients.add('mlate');
      ((signerMetadata['signer'] as Map)['ids'] as List).add(2);

      expect(sign.utxoKeys, ['${'ab' * 32}:0']);
      expect(sign.publicKeys, ['02' * 33]);
      expect(sign.derivationIndices, [4]);
      expect(sign.isChangeFlags, [false]);
      expect(record.spentUtxoKeys, ['${'ab' * 32}:0']);
      expect(record.recipientAddresses, ['muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg']);
      expect((record.signerMetadata!['signer'] as Map)['ids'], [1]);
    });

    test("an output spec a command carries does not share the caller's key list", () {
      final publicKeys = ['02' * 33, '03' * 33];
      final params = <String, dynamic>{'tokenId': 't', 'nested': {'ids': [1]}};
      final outputs = <InvoiceOutputSpec>[
        P2MSOutputSpec(publicKeys: publicKeys, threshold: 2, amount: BigInt.from(1000)),
        PluginOutputSpec(
            pluginId: 'p', pluginScriptType: 's', params: params, amount: BigInt.from(500)),
      ];
      final command = CreateInvoiceCommand(
        invoiceId: 'inv-1',
        walletId: _walletId,
        addresses: const [],
        amount: BigInt.from(1500),
        outputs: outputs,
      );

      publicKeys.add('04' * 33);
      outputs.removeLast();
      ((params['nested'] as Map)['ids'] as List).add(2);

      expect(command.outputs, hasLength(2), reason: 'the list itself was copied');
      expect((command.outputs![0] as P2MSOutputSpec).publicKeys, ['02' * 33, '03' * 33]);
      expect(((command.outputs![1] as PluginOutputSpec).params['nested'] as Map)['ids'], [1]);
      _expectAllRejected({
        'outputs.add': () =>
            command.outputs!.add(P2PKHOutputSpec(address: 'm', amount: BigInt.one)),
        'publicKeys.add': () => (command.outputs![0] as P2MSOutputSpec).publicKeys.add('05'),
        'params nested.add': () =>
            ((command.outputs![1] as PluginOutputSpec).params['nested'] as Map)['ids'] = [9],
      });
    });

    test('a coordinator command does not share the collections the app built it from', () {
      final walletMetadata = <String, dynamic>{'profile': {'tags': ['a']}};
      final create = coord.CreateWalletCommand(
          walletId: _walletId, name: 'w', walletMetadata: walletMetadata);
      final headers = <Map<String, dynamic>>[
        {'height': 1, 'hash': 'ab' * 32},
      ];
      final store = coord.StoreHeadersCommand(headers: headers);
      final payload = <String, dynamic>{'txids': ['ab' * 32]};
      final received =
          coord.P2PMessageReceived(fromPeerId: 'peer', messageType: 'm', payload: payload);
      final beef = <int>[1, 2, 3];
      final import = coord.ImportTransactionCommand(walletId: _walletId, beef: beef);

      ((walletMetadata['profile'] as Map)['tags'] as List).add('late');
      headers.add({'height': 2});
      headers.first['height'] = 99;
      (payload['txids'] as List).add('late');
      beef.add(4);

      expect((create.walletMetadata!['profile'] as Map)['tags'], ['a']);
      expect(store.headers, hasLength(1));
      expect(store.headers.first['height'], 1);
      expect(received.payload['txids'], ['ab' * 32]);
      expect(import.beef, [1, 2, 3]);
    });

    test("the event the aggregate journals does not share the caller's list", () async {
      final store = InMemoryEventStore();
      final wallet = _wallet(store);
      await wallet.preStart();
      await wallet.commandHandler(CreateWalletCommand(
          walletId: _walletId, walletName: 'w', mnemonic: _mnemonic));
      final root = wallet.currentState.rootAddress!;
      await wallet.commandHandler(ReceiveUTXOCommand(
        walletId: _walletId,
        txid: 'ab' * 32,
        vout: 0,
        satoshis: BigInt.from(1000),
        scriptPubKey: dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(root))
            .getScriptPubkey()
            .toHex(),
        address: root,
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
      final journaled =
          store.allEvents.whereType<TransactionRecordedEvent>().single;

      recipients.add('mlate');
      spent.add('late:0');

      expect(journaled.recipientAddresses, ['muq9kAb9ri62VChAMRkuwK5bTve4iDLWBg'],
          reason: 'the projection and every subscriber read this object live');
      expect(journaled.spentUtxoKeys, ['${'ab' * 32}:0']);
    });
  });

  /// Bead libspiffy-a0fk: the two directions 6r5w left open.
  group('a0fk: results and internal messages', () {
    // The fact that decided the outbound question. Freezing a result is a
    // behaviour change — an app that sorts one in place gets
    // UnsupportedError — and the objection is "it is the app's own copy".
    // It is not: the coordinator's `events` is a broadcast stream, so every
    // subscriber is handed the SAME instance, and one listener sorting its
    // result reorders it for the others. This drives a real coordinator.
    test('a coordinator result reaches every subscriber as one instance, '
        'which none of them can reorder under the others', () async {
      final system = LocalActorSystem();
      addTearDown(system.shutdown);
      final noop = await system.spawn('noop', () => _Noop());
      final coordinator = WalletCoordinatorActor(
        walletManager: noop,
        invoiceCoordinator: noop,
        paymentCoordinator: noop,
        spvActor: noop,
        arcActor: noop,
        headerSyncActor: noop,
        benfordCoordinator: noop,
        channelManager: noop,
        walletProjection: noop,
        storage: InMemoryWalletStorage(),
      );
      final seenByA = <coord.UTXOSplitCompleteEvent>[];
      final seenByB = <coord.UTXOSplitCompleteEvent>[];
      final subA = coordinator.events.listen((e) {
        if (e is coord.UTXOSplitCompleteEvent) seenByA.add(e);
      });
      final subB = coordinator.events.listen((e) {
        if (e is coord.UTXOSplitCompleteEvent) seenByB.add(e);
      });
      addTearDown(subA.cancel);
      addTearDown(subB.cancel);
      final ref = await system.spawn('coordinator', () => coordinator);

      ref.tell(wm.SplitUTXOsResponse(
        walletId: _walletId,
        success: true,
        splitCount: 2,
        txids: ['bb' * 32, 'aa' * 32],
      ));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (seenByA.isEmpty || seenByB.isEmpty) {
        if (DateTime.now().isAfter(deadline)) fail('no UTXOSplitCompleteEvent within 5s');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(identical(seenByA.single, seenByB.single), isTrue,
          reason: 'the premise: a broadcast stream hands every listener the same object');
      // Old code: subscriber A sorted the list, and B then read it sorted.
      expect(() => seenByA.single.txids.sort(), throwsUnsupportedError);
      expect(seenByB.single.txids, ['bb' * 32, 'aa' * 32]);
    });

    test('the outbound events copy and freeze what they are built from', () {
      final txids = ['aa' * 32];
      final utxos = <Map<String, dynamic>>[
        {'txid': 'aa' * 32, 'vout': 0, 'tags': ['x']},
      ];
      final payload = <String, dynamic>{'peers': ['p1']};
      final split = coord.UTXOSplitCompleteEvent(
        walletId: _walletId,
        transactionCount: 1,
        newUtxoCount: 1,
        totalFeePaid: BigInt.one,
        success: true,
        txids: txids,
        splits: const [],
      );
      final spv = coord.SPVValidationResultEvent(
        walletId: _walletId,
        txid: 'aa' * 32,
        isValid: true,
        spendableUTXOs: utxos,
      );
      final p2p = coord.P2PMessageToSendEvent(toPeerId: 'p', messageType: 'm', payload: payload);

      txids.add('late');
      utxos.first['vout'] = 9;
      (utxos.first['tags'] as List).add('late');
      (payload['peers'] as List).add('late');

      expect(split.txids, ['aa' * 32]);
      expect(spv.spendableUTXOs.single['vout'], 0, reason: 'nested maps are copied too');
      expect(spv.spendableUTXOs.single['tags'], ['x']);
      expect(p2p.payload['peers'], ['p1']);
      _expectAllRejected({
        'UTXOSplitCompleteEvent.txids': () => split.txids.add('x'),
        'SPVValidationResultEvent.spendableUTXOs': () => spv.spendableUTXOs.add({}),
        'SPVValidationResultEvent.spendableUTXOs[0]': () => spv.spendableUTXOs.first['vout'] = 1,
        'P2PMessageToSendEvent.payload': () => p2p.payload['x'] = 1,
      });
    });

    // libspiffy -> libspiffy. The same property: the actor that built the
    // list keeps a reference to it, and the actor that receives it reads it
    // later on another turn of its mailbox.
    test('the internal actor messages copy and freeze what they are built from', () {
      final spendable = <Map<String, dynamic>>[
        {'txid': 'aa' * 32, 'vout': 0},
      ];
      final feeData = <String, dynamic>{'mining': {'satoshis': 1, 'bytes': 1000}};
      final walletIds = ['w1'];
      final result = wm.SPVValidationResult(
        txid: 'aa' * 32,
        isValid: true,
        spendableUTXOs: spendable,
        spentUTXOs: const [],
      );
      final quote = wm.FeeQuoteMessage(feeData);
      final list = wm.WalletListMessage(walletIds);

      spendable.first['vout'] = 7;
      spendable.add({'late': true});
      (feeData['mining'] as Map)['satoshis'] = 0;
      walletIds.add('late');

      expect(result.spendableUTXOs, hasLength(1));
      expect(result.spendableUTXOs.single['vout'], 0);
      expect((quote.feeData['mining'] as Map)['satoshis'], 1,
          reason: 'a fee rate a sender changed after the reply was sent');
      expect(list.walletIds, ['w1']);
      _expectAllRejected({
        'SPVValidationResult.spendableUTXOs': () => result.spendableUTXOs.clear(),
        'FeeQuoteMessage.feeData': () => quote.feeData['mining'] = null,
        'WalletListMessage.walletIds': () => list.walletIds.add('x'),
      });
    });
  });
}

class _Noop extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {}
}

/// Each mutation in [mutations] must be refused; names the ones that were not.
void _expectAllRejected(Map<String, void Function()> mutations) {
  final accepted = <String>[];
  mutations.forEach((name, mutate) {
    try {
      mutate();
      accepted.add(name);
    } on UnsupportedError {
      // expected
    }
  });
  expect(accepted, isEmpty, reason: 'these collections accepted a modification');
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
