import 'package:test/test.dart';

// Only the public library: this file does not compile when either helper is
// missing from its exports (bead libspiffy-47np).
import 'package:libspiffy/libspiffy.dart';

void main() {
  test('an app can interpret the network of a wallet row it reads from ReadModelStorage', () async {
    final storage = InMemoryWalletStorage();
    await storage.storeWallet('w', 'w', networkType: 'mainnet');

    final row = await storage.getWallet('w');

    expect(NetworkName.isMainnet(row!['network'] as String?), isTrue);
    expect(row['network'], WalletRowRules.canonicalNetwork('mainnet'));
  });

  test('a ReadModelStorage implementer can apply the wallet row rules', () {
    expect(WalletRowRules.canonicalNetwork('main'), NetworkName.canonical('mainnet'));
    expect(WalletRowRules.defaultNetwork, NetworkName.canonical(null));
  });
}
