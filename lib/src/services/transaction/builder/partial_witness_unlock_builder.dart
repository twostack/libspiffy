

import 'dart:typed_data';

import 'package:dartsv/dartsv.dart';

class PartialWitnessUnlockBuilder extends UnlockingScriptBuilder {

  final List<int> _preImage;
  final List<int> _partialHash;
  final List<int> _partialWitnessPreImage;
  final List<int> _fundingTxId;


  PartialWitnessUnlockBuilder(this._preImage, this._partialHash, this._partialWitnessPreImage, this._fundingTxId);

  @override
  SVScript getScriptSig() {

    var builder = ScriptBuilder()
        .addData(Uint8List.fromList(_preImage))
        .addData(Uint8List.fromList(_partialHash))
        .addData(Uint8List.fromList(_partialWitnessPreImage))
        .addData(Uint8List.fromList(_fundingTxId));

    var result = builder.build();
    return result;
  }

  @override
  void parse(SVScript script) {
    // TODO: implement parse
  }

}