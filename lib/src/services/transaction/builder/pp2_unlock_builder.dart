

import 'dart:typed_data';

import 'package:dartsv/dartsv.dart';

class PP2UnlockBuilder extends UnlockingScriptBuilder {

  final List<int> _outpointTxId;

  PP2UnlockBuilder(this._outpointTxId);

  @override
  SVScript getScriptSig() {
    return ScriptBuilder()
        .addData(Uint8List.fromList(_outpointTxId))
        .build();
  }

  @override
  void parse(SVScript script) {
    // TODO: implement parse
  }

}