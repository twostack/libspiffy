import 'package:dartsv/dartsv.dart' as dartsv;

/// Normalises the network identifiers used across libspiffy.
///
/// Two spellings coexist: the actor system, importer and P2P layer use
/// `'main'` / `'test'` / `'regtest'`, while the wallet aggregate and the
/// read models store `'mainnet'` / `'testnet'`. Sites that compared against
/// only one spelling resolved a mainnet wallet as testnet (or the reverse)
/// depending on which component had written the value, which rejected
/// mainnet key imports and made change outputs undetectable on mainnet.
/// Every comparison now goes through these helpers, which accept both.
///
/// Regtest is its own network: its canonical name is `'regtest'` (it selects
/// the regtest genesis and proof-of-work limit in `NetworkParams` and the
/// `regtest` CDN directory), while keys and addresses use the testnet
/// encoding ([toDartsv]).
class NetworkName {
  NetworkName._();

  /// True for any spelling of the main network.
  static bool isMainnet(String? network) {
    switch (network?.trim().toLowerCase()) {
      case 'main':
      case 'mainnet':
      case 'livenet':
        return true;
      default:
        return false;
    }
  }

  /// True for any spelling of regtest.
  static bool isRegtest(String? network) => network?.trim().toLowerCase() == 'regtest';

  /// dartsv network type for [network]; anything that is not mainnet
  /// (testnet, regtest, unknown, null) uses testnet address encoding.
  static dartsv.NetworkType toDartsv(String? network) =>
      isMainnet(network) ? dartsv.NetworkType.MAIN : dartsv.NetworkType.TEST;

  /// The spelling persisted in wallet metadata and read models:
  /// `'mainnet'`, `'regtest'`, or `'testnet'` for everything else.
  static String canonical(String? network) {
    if (isMainnet(network)) return 'mainnet';
    if (isRegtest(network)) return 'regtest';
    return 'testnet';
  }
}
