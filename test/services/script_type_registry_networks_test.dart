import 'package:dartsv/dartsv.dart';
import 'package:libspiffy/src/services/script_type_registry.dart';
import 'package:test/test.dart';

/// Bead spiffyvault-mnz.6: a mainnet import failed with "ScriptTypeRegistry
/// already initialized with NetworkType.TEST, cannot reinitialize with
/// NetworkType.MAIN": the registry was one instance for the isolate, fixed
/// to the first network asked for.
void main() {
  test('a registry for each network, in either order, each writing its own addresses', () {
    final key = SVPrivateKey.fromHex('5c' * 32, NetworkType.MAIN).publicKey;
    final script = P2PKHLockBuilder.fromAddress(key.toAddress(NetworkType.MAIN)).getScriptPubkey();

    final test = ScriptTypeRegistry(networkType: NetworkType.TEST);
    final main = ScriptTypeRegistry(networkType: NetworkType.MAIN);

    expect(identical(ScriptTypeRegistry(networkType: NetworkType.TEST), test), isTrue);
    expect(identical(ScriptTypeRegistry(networkType: NetworkType.MAIN), main), isTrue);
    expect(main.identifyScriptType(script), 'p2pkh');
    expect(main.extractScriptMetadata(script)?['address'], key.toAddress(NetworkType.MAIN).toBase58());
    expect(test.extractScriptMetadata(script)?['address'], key.toAddress(NetworkType.TEST).toBase58());
  });
}
