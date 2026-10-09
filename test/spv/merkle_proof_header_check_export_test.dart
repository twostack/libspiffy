// Bead libspiffy-09oj: an app checks a merkle proof against its headers
// through the public API, not by importing lib/src.
import 'package:libspiffy/libspiffy.dart';
import 'package:test/test.dart';

void main() {
  test('the merkle proof header check is part of the public API', () {
    expect(checkBumpAgainstHeaders, isA<Function>());
    expect(checkBumpHexAgainstHeaders, isA<Function>());
    expect(ProofHeaderStatus.values, isNotEmpty);
    expect(ProofHeaderCheck, isNotNull);
  });
}
