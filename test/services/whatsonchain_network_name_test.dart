import 'package:libspiffy/libspiffy.dart';
import 'package:test/test.dart';

/// The wallet read models store 'mainnet' / 'testnet' while the actor system
/// uses 'main' / 'test'; the WhatsOnChain data source takes either.
void main() {
  test('both spellings of each network are accepted', () {
    for (final name in ['main', 'mainnet', 'test', 'testnet']) {
      expect(() => WhatsOnChainDataSource(networkType: name), returnsNormally, reason: name);
    }
  });

  test('regtest has no WhatsOnChain API and is refused', () {
    expect(() => WhatsOnChainDataSource(networkType: 'regtest'), throwsArgumentError);
  });
}
