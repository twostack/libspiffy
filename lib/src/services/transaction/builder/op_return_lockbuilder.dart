import 'dart:typed_data';

import 'package:dartsv/dartsv.dart';

/// Lock builder for raw OP_RETURN (data carrier) outputs.
///
/// Produces scripts of the form:
///   OP_FALSE OP_RETURN <chunk1> <chunk2> ...
///
/// Each data chunk is added as a separate pushdata element.
/// Unlike the protocol-specific builders (B, MAP, AIP), this builder
/// does not prepend any protocol prefix — it embeds raw data directly.
class OpReturnLockBuilder extends LockingScriptBuilder {
  final List<List<int>> dataChunks;

  OpReturnLockBuilder(this.dataChunks);

  OpReturnLockBuilder.fromScript(SVScript script) : dataChunks = [] {
    parse(script);
  }

  @override
  SVScript getScriptPubkey() {
    var builder = ScriptBuilder();
    builder.opFalse().opCode(OpCodes.OP_RETURN);

    for (final chunk in dataChunks) {
      builder.addData(Uint8List.fromList(chunk));
    }

    return builder.build();
  }

  @override
  void parse(SVScript script) {
    if (script.chunks.length < 2) {
      throw ScriptException(
        ScriptError.SCRIPT_ERR_UNKNOWN_ERROR,
        'Not a valid OP_RETURN script',
      );
    }

    final chunks = script.chunks;

    if (chunks[0].opcodenum != OpCodes.OP_FALSE ||
        chunks[1].opcodenum != OpCodes.OP_RETURN) {
      throw ScriptException(
        ScriptError.SCRIPT_ERR_UNKNOWN_ERROR,
        'Script must start with OP_FALSE OP_RETURN',
      );
    }

    dataChunks.clear();
    for (int i = 2; i < chunks.length; i++) {
      dataChunks.add(chunks[i].buf ?? []);
    }
  }
}
