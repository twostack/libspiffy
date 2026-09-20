/// libspiffy-bn03: WalletState.copyWith dropped isDeleted.
///
/// The override of eventador's `State.copyWith` (the one `State.nextVersion`
/// calls) rebuilt the state field by field and left out `isDeleted`, so any
/// copy of a deleted wallet's state came back not deleted. The tests compare
/// the serialised form of every copy with the original, over a state whose
/// every field differs from an empty wallet's, so a field added later and
/// forgotten in a copy method fails here too.
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/models/bitcoin_utxo.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/models/wallet_type.dart';
import 'package:test/test.dart';

void main() {
  /// A wallet state with every field set to something other than the value
  /// [WalletState.empty] gives it.
  WalletState everyFieldSet() {
    final created = DateTime.utc(2026, 9, 1, 12);
    return WalletState(
      walletId: 'bn03-wallet',
      name: 'Deleted wallet',
      rootAddress: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
      isCreated: true,
      isDeleted: true,
      // Not the empty state's network, which is testnet: this fixture's
      // whole point is that no field holds its default.
      networkType: 'mainnet',
      walletType: WalletType.xpriv,
      timestamp: created,
      utxos: {
        '${'a' * 64}:1': BitcoinUtxo(
          txid: 'a' * 64,
          vout: 1,
          value: dartsv.Coin.ofSat(BigInt.from(12345)),
          scriptPubKey: '76a914${'00' * 20}88ac',
          address: 'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12',
          status: UTXOStatus.available,
          blockHeight: 100,
          confirmations: 3,
          createdAt: created,
          updatedAt: created,
          derivationIndex: 0,
        ),
      },
      addresses: {'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12': 'root'},
      watchAddresses: {'n4VQ5YdHf7hLQ2gWQYYrcxoE5B7nWuDFNF': 'p2pkh'},
      nextDerivationIndex: 4,
      metadata: {
        'address_indices': {'mqCnSf8i6kmaQaJ54HjQ8EUJnuK4AnCv12': 0},
      },
      confirmedBalance: dartsv.Coin.ofSat(BigInt.from(1)),
      unconfirmedBalance: dartsv.Coin.ofSat(BigInt.from(12345)),
      reservedBalance: dartsv.Coin.ofSat(BigInt.from(2)),
      version: 7,
      lastModified: created.add(const Duration(hours: 1)),
    );
  }

  test('bn03: the fixture sets every serialised field to a non-default value', () {
    final fixture = everyFieldSet().toMap();
    final empty = WalletState.empty('bn03-wallet').toMap();
    expect(fixture.keys.toSet(), empty.keys.toSet());
    for (final key in fixture.keys.where((k) => k != 'walletId')) {
      expect(fixture[key].toString(), isNot(empty[key].toString()),
          reason: '$key keeps its default in the fixture: set it, so a copy that drops it is caught');
    }
  });

  test('bn03: copyWith() keeps every field', () {
    final original = everyFieldSet();
    expect(original.copyWith().toMap(), original.toMap());
  });

  test('bn03: copyWith(version, lastModified) changes only those two', () {
    final original = everyFieldSet();
    final later = DateTime.utc(2026, 9, 15);
    final copy = original.copyWith(version: 8, lastModified: later);
    expect(copy.version, 8);
    expect(copy.lastModified, later);
    expect(copy.toMap()..remove('version')..remove('lastModified'),
        original.toMap()..remove('version')..remove('lastModified'));
  });

  test('bn03: nextVersion() of a deleted wallet is still deleted', () {
    final deleted = everyFieldSet();
    final next = deleted.nextVersion() as WalletState;
    expect(next.version, deleted.version + 1);
    expect(next.isDeleted, isTrue);
    expect(next.watchAddresses, deleted.watchAddresses);
  });

  test('bn03: copyWithWallet() keeps every field', () {
    final original = everyFieldSet();
    expect(original.copyWithWallet().toMap(), original.toMap());
  });

  test('bn03: recalculateBalances() of a deleted wallet is still deleted', () {
    final original = everyFieldSet();
    final recalculated = original.recalculateBalances();
    expect(recalculated.isDeleted, isTrue);
    expect(recalculated.watchAddresses, original.watchAddresses);
  });
}
