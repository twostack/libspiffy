import 'package:test/test.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import 'package:libspiffy/src/actors/coordinator_messages.dart'
    show ImportWalletCommand;
import 'package:libspiffy/src/actors/import_actor.dart'
    show ImportWalletMessage;
import 'package:libspiffy/src/models/wallet_read_model.dart';
import 'package:libspiffy/src/models/wallet_state.dart';
import 'package:libspiffy/src/storage/wallet_row_rules.dart';
import 'package:libspiffy/src/utils/network_name.dart';

/// Audit 2026-09-14 KM-3 / H1: 'main' and 'mainnet' were compared
/// inconsistently across the aggregate, projection, coordinators and
/// importer. NetworkName is the single place every comparison goes through,
/// so it must accept every spelling in use.
void main() {
  group('NetworkName', () {
    test('isMainnet accepts every mainnet spelling', () {
      expect(NetworkName.isMainnet('main'), isTrue);
      expect(NetworkName.isMainnet('mainnet'), isTrue);
      expect(NetworkName.isMainnet('livenet'), isTrue);
      expect(NetworkName.isMainnet(' MainNet '), isTrue,
          reason: 'case and whitespace insensitive');
    });

    test('isMainnet is false for testnet spellings, regtest, unknown and null', () {
      expect(NetworkName.isMainnet('test'), isFalse);
      expect(NetworkName.isMainnet('testnet'), isFalse);
      expect(NetworkName.isMainnet('regtest'), isFalse);
      expect(NetworkName.isMainnet('bogus'), isFalse);
      expect(NetworkName.isMainnet(''), isFalse);
      expect(NetworkName.isMainnet(null), isFalse);
    });

    test('toDartsv maps both mainnet spellings to MAIN and everything else to TEST', () {
      expect(NetworkName.toDartsv('main'), equals(dartsv.NetworkType.MAIN));
      expect(NetworkName.toDartsv('mainnet'), equals(dartsv.NetworkType.MAIN));
      expect(NetworkName.toDartsv('livenet'), equals(dartsv.NetworkType.MAIN));
      expect(NetworkName.toDartsv('test'), equals(dartsv.NetworkType.TEST));
      expect(NetworkName.toDartsv('testnet'), equals(dartsv.NetworkType.TEST));
      expect(NetworkName.toDartsv('regtest'), equals(dartsv.NetworkType.TEST),
          reason: 'regtest keys and addresses use the testnet encoding');
      expect(NetworkName.toDartsv(null), equals(dartsv.NetworkType.TEST));
    });

    // x27: regtest used to be persisted as 'testnet', which selected the
    // testnet genesis and CDN directory for a regtest wallet.
    test('canonical persists mainnet/testnet/regtest regardless of input spelling', () {
      expect(NetworkName.canonical('main'), equals('mainnet'));
      expect(NetworkName.canonical('mainnet'), equals('mainnet'));
      expect(NetworkName.canonical('livenet'), equals('mainnet'));
      expect(NetworkName.canonical('test'), equals('testnet'));
      expect(NetworkName.canonical('testnet'), equals('testnet'));
      expect(NetworkName.canonical(null), equals('testnet'));
      expect(NetworkName.canonical('regtest'), equals('regtest'));
      expect(NetworkName.canonical(' RegTest '), equals('regtest'));
    });

    test('isRegtest accepts regtest in any case and nothing else', () {
      expect(NetworkName.isRegtest('regtest'), isTrue);
      expect(NetworkName.isRegtest(' REGTEST '), isTrue);
      expect(NetworkName.isRegtest('testnet'), isFalse);
      expect(NetworkName.isRegtest('test'), isFalse);
      expect(NetworkName.isRegtest(null), isFalse);
    });
  });

  /// Bead libspiffy-sxk5. Knowing every spelling is not enough if the layers
  /// disagree about what NO spelling means. Three defaults existed: the
  /// storage backends wrote 'mainnet', the models `empty()` 'mainnet', and
  /// `NetworkName`, the aggregate and the actor system all meant testnet.
  ///
  /// Each expectation below reads the default a layer actually declares --
  /// none of them restates the answer -- so a layer that changes its mind
  /// fails here instead of encoding one network's addresses for a wallet
  /// another layer thinks is on the other.
  group('an unspecified network means the same network in every layer', () {
    /// The network a layer resolves its own default to.
    String resolved(String? declared) => NetworkName.canonical(declared);

    final expected = NetworkName.canonical(null);

    test('the read models: what a row created without a network gets', () {
      expect(WalletRowRules.defaultNetwork, expected,
          reason: 'the three storage backends write this on an insert; it '
              'was mainnet, so an external storeWallet(id, name) produced a '
              'mainnet row for a testnet wallet');
      expect(NetworkName.isMainnet(WalletRowRules.defaultNetwork), isFalse,
          reason: 'and testnet is the safe direction to be wrong in: a '
              'wallet wrongly taken for testnet cannot encode an address '
              'that receives real coins');
    });

    test('the write model and the read model before creation', () {
      expect(resolved(WalletState.empty('w').networkType), expected);
      expect(resolved(WalletReadModel.empty('w').networkType), expected);
    });

    test('the actor layer, which spells the same network its own way', () {
      // 'test' is the P2P/dartsv vocabulary, not a fourth network: what has
      // to hold is that it resolves to the same one, not that it is spelled
      // the same.
      final command =
          ImportWalletCommand(walletId: 'w', walletName: 'W', wif: 'x');
      expect(resolved(command.networkType), expected);
      final message =
          ImportWalletMessage(walletId: 'w', walletName: 'W', wif: 'x');
      expect(resolved(message.networkType), expected);
    });
  });
}
