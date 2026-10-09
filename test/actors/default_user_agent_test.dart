// Bead libspiffy-c04p: Teranode's wire-protocol service accepts a peer only
// if its user agent contains "BSV" or "Bitcoin SV", and bans any other's IP
// for 24 hours. The default was '/LibSpiffy:1.0/'. The live check is
// localnet_node_e2e_test.dart, which syncs headers from ../localnet-teranode
// with the default.
import 'package:libspiffy/libspiffy.dart';
import 'package:test/test.dart';

void main() {
  test('the default user agent is one a Teranode peer accepts', () {
    expect(LibSpiffyActorSystem.defaultUserAgent, contains('BSV'));
    expect(LibSpiffyActorSystem.defaultUserAgent, matches(RegExp(r'^/[^/]+:[^/]+/$')),
        reason: 'BIP 14 form: /name:version/');
  });
}
