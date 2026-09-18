/// Bead libspiffy-f0sj (sweep D-2): `TransactionBroadcastEvent.broadcastResponse`
/// was the literal `'broadcast_success'` on every event ever journaled, because
/// `BroadcastTransactionCommand` had no field to carry ARC's actual answer.
///
/// The journal is immutable: a fabricated field in it is permanent. Where the
/// caller knows what ARC said, the event records that; where it does not, the
/// honest record is an absence (null), not a plausible success.
library;

import 'package:test/test.dart';

import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';

import '../actors/in_memory_event_store.dart';

const _walletId = 'f0sj-wallet';
const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

Future<(BitcoinWalletAggregate, InMemoryEventStore)> _wallet() async {
  final store = InMemoryEventStore();
  final wallet = BitcoinWalletAggregate(
    aggregateId: _walletId,
    aggregateType: 'BitcoinWallet',
    eventStore: store,
    cryptoService: DartSVCryptoService(),
    secureStorage: InMemorySecureStorage(),
  );
  await wallet.preStart();
  await wallet.commandHandler(CreateWalletCommand(
    walletId: _walletId,
    walletName: 'f0sj',
    mnemonic: _mnemonic,
  ));
  return (wallet, store);
}

TransactionBroadcastEvent _broadcastEvent(InMemoryEventStore store) =>
    store.allEvents.whereType<TransactionBroadcastEvent>().single;

void main() {
  group('TransactionBroadcastEvent records ARC\'s actual answer', () {
    test('the journaled event carries the response the command was given', () async {
      final (wallet, store) = await _wallet();

      await wallet.commandHandler(BroadcastTransactionCommand(
        walletId: _walletId,
        transactionId: 'aa' * 32,
        signedTransaction: '00',
        broadcastResponse: 'SEEN_ON_NETWORK',
      ));

      final event = _broadcastEvent(store);
      expect(event.txid, 'aa' * 32);
      expect(event.broadcastResponse, 'SEEN_ON_NETWORK',
          reason: 'the journal must hold what ARC answered, not a placeholder');
      // And it survives the journal round trip.
      expect(
        TransactionBroadcastEvent.fromMap(event.toMap()).broadcastResponse,
        'SEEN_ON_NETWORK',
      );
    });

    test('a rejection is recorded as a rejection, not as a success', () async {
      final (wallet, store) = await _wallet();

      await wallet.commandHandler(BroadcastTransactionCommand(
        walletId: _walletId,
        transactionId: 'bb' * 32,
        signedTransaction: '00',
        broadcastResponse: 'REJECTED',
      ));

      expect(_broadcastEvent(store).broadcastResponse, 'REJECTED');
    });

    test('no response supplied is recorded as an absence, not a fabricated success', () async {
      final (wallet, store) = await _wallet();

      await wallet.commandHandler(BroadcastTransactionCommand(
        walletId: _walletId,
        transactionId: 'cc' * 32,
        signedTransaction: '00',
      ));

      final event = _broadcastEvent(store);
      expect(event.broadcastResponse, isNull,
          reason: 'where no answer is known the honest record is an absence');
      expect(TransactionBroadcastEvent.fromMap(event.toMap()).broadcastResponse, isNull);
    });

    test('old journals carrying the broadcast_success literal still replay', () {
      // Exactly the shape events written before this bead have on disk.
      final replayed = TransactionBroadcastEvent.fromMap({
        'walletId': _walletId,
        'txid': 'dd' * 32,
        'broadcastResponse': 'broadcast_success',
        'eventId': 'evt-1',
        'timestamp': DateTime.utc(2026, 1, 1).toIso8601String(),
        'version': 7,
      });

      expect(replayed.broadcastResponse, 'broadcast_success');
      expect(replayed.txid, 'dd' * 32);
      expect(replayed.typeName, TransactionBroadcastEvent.stableTypeName);
    });
  });
}
