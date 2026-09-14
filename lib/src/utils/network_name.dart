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

  /// dartsv network type for [network]; anything that is not mainnet
  /// (testnet, regtest, unknown, null) uses testnet address encoding.
  static dartsv.NetworkType toDartsv(String? network) =>
      isMainnet(network) ? dartsv.NetworkType.MAIN : dartsv.NetworkType.TEST;

  /// The spelling persisted in wallet metadata and read models.
  static String canonical(String? network) =>
      isMainnet(network) ? 'mainnet' : 'testnet';
}
