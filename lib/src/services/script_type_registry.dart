import 'package:dartsv/dartsv.dart';
import 'package:hex/hex.dart';
import 'package:convert/convert.dart';

import '../models/bitcoin_transaction.dart' as bitcointx;

// Import local models

/// A wrapper around DartSV's script template system focused on accounting
///
/// This class provides a simplified interface to DartSV's script recognition
/// capabilities, focused specifically on the needs of the accounting system.
/// It allows for identification of script types, extraction of metadata,
/// and determination of script spendability.
///
/// This registry is a core component of the script-centric wallet model,
/// serving as the central point for script type identification and analysis.
/// It delegates to the appropriate Script Templates for type-specific operations
/// like spendability determination.
class ScriptTypeRegistry {
  // Use the singleton instance
  static final ScriptTypeRegistry _instance = ScriptTypeRegistry._internal();

  NetworkType _networkType = NetworkType.TEST;


  set networkType(NetworkType value) {
    _networkType = value;
  } // Private constructor

  ScriptTypeRegistry._internal() {
    // Initialize the template registry with standard templates
    TemplateRegistry.initialize();
  }

  /// Returns the singleton instance of the registry
  factory ScriptTypeRegistry({NetworkType networkType = NetworkType.TEST}) {
    _instance.networkType = networkType;
    return _instance;
  }

  /// Register a custom script template
  ///
  /// This allows library clients to register additional script templates
  /// for recognition by the accounting system.
  /// Register a custom script template
  ///
  /// This allows library clients to register additional script templates
  /// for recognition by the accounting system.
  void registerScriptType(dynamic template) {
    // The template should be a ScriptTemplate from DartSV
    // Get the singleton instance
    final registry = ScriptTemplateRegistry();
    registry.register(template);
  }

  /// Find the template type that matches a script
  ///
  /// Returns the name of the template that matches the script, or null if no match is found
  String? findTemplateType(SVScript script) {
    return identifyScriptType(script);
  }

  /// Convert a script type identifier to a BitcoinScriptType enum
  ///
  /// This provides a mapping between the string identifiers used by the
  /// ScriptTemplateRegistry and the BitcoinScriptType enum used by the
  /// accounting system.
  bitcointx.BitcoinScriptType toBitcoinScriptType(String? scriptTypeIdentifier) {
    if (scriptTypeIdentifier == null) return bitcointx.BitcoinScriptType.unknown;

    switch (scriptTypeIdentifier.toLowerCase()) {
      case 'p2pkh':
        return bitcointx.BitcoinScriptType.p2pkh;
      case 'p2pk':
        return bitcointx.BitcoinScriptType.p2pk;
      case 'p2ms':
        return bitcointx.BitcoinScriptType.p2ms;
      case 'p2sh':
        return bitcointx.BitcoinScriptType.p2sh;
      case 'opreturn':
      case 'op_return': // Handle both formats
        return bitcointx.BitcoinScriptType.opReturn;
      case 'custom':
        return bitcointx.BitcoinScriptType.custom;
      default:
        return bitcointx.BitcoinScriptType.unknown;
    }
  }

  /// Identify the type of a script
  ///
  /// Returns a string identifier for the script type, or null if the type
  /// cannot be determined. The returned identifier is always lowercase.
  String? identifyScriptType(SVScript script) {
    // Get the singleton instance of ScriptTemplateRegistry
    final registry = ScriptTemplateRegistry();
    final scriptType = registry.identifyScriptType(script);

    // Convert to lowercase for consistency
    return scriptType?.toLowerCase();
  }

  /// Extract metadata from a script
  ///
  /// Returns a map of metadata extracted from the script, or null if no
  /// metadata can be extracted.
  Map<String, dynamic>? extractScriptMetadata(SVScript script) {
    // Get the singleton instance of ScriptTemplateRegistry
    final registry = ScriptTemplateRegistry();
    final scriptType = registry.identifyScriptType(script);
    if (scriptType == null) return null;

    // Normalize the script type to lowercase
    final normalizedScriptType = scriptType.toLowerCase();

    final result = <String, dynamic>{};
    result['scriptType'] = normalizedScriptType;
    result['bitcoinScriptType'] =
        toBitcoinScriptType(normalizedScriptType).toString().split('.').last;

    // Add script info from the template
    final scriptInfo = registry.extractScriptInfo(script);
    if (scriptInfo != null) {
      result.addAll(scriptInfo);
    }

    // Extract additional metadata based on script type
    switch (normalizedScriptType) {
      case 'p2pkh':
        _extractP2PKHMetadata(script, result);
        break;
      case 'p2pk':
        _extractP2PKMetadata(script, result);
        break;
      case 'p2ms':
        _extractP2MSMetadata(script, result);
        break;
      case 'p2sh':
        _extractP2SHMetadata(script, result);
        break;
      case 'opreturn':
      case 'op_return': // Handle both formats
        _extractOPReturnMetadata(script, result);
        break;
    }

    return result;
  }

  // Helper methods for extracting metadata from specific script types

  void _extractP2PKHMetadata(SVScript script, Map<String, dynamic> metadata) {
    // P2PKH scripts contain a public key hash
    if (script.chunks.length >= 5) {
      try {
        // The public key hash is in the 3rd chunk (index 2)
        final pubKeyHash = script.chunks[2].buf;
        if (pubKeyHash != null) {
          metadata['pubKeyHash'] = HEX.encode(pubKeyHash);

          // Try to derive an address from the pubkey hash
          try {
            // Use SVAddressHelper to create an address from the pubkey hash
            // This is a simplified approach - in a real implementation we would use
            // the appropriate network type and address format
            metadata['address'] = Address.fromPubkeyHash(hex.encode(pubKeyHash), _networkType);
          } catch (e) {
            // Address derivation failed
          }
        }
      } catch (e) {
        // Metadata extraction failed
      }
    }
  }

  void _extractP2PKMetadata(SVScript script, Map<String, dynamic> metadata) {
    // P2PK scripts contain a full public key
    if (script.chunks.length >= 2) {
      try {
        // The public key is in the 1st chunk (index 0)
        final pubKey = script.chunks[0].buf;
        if (pubKey != null) {
          metadata['publicKey'] = HEX.encode(pubKey);

          // Try to derive an address from the public key
          try {
            // Use the public key to derive an address
            // This is a simplified approach - in a real implementation we would use
            // the appropriate network type and address format
            var svPubKey = SVPublicKey.fromHex(hex.encode(pubKey));
            metadata['address'] = Address.fromPublicKey(svPubKey, _networkType);
          } catch (e) {
            // Address derivation failed
          }
        }
      } catch (e) {
        // Metadata extraction failed
      }
    }
  }

  void _extractP2MSMetadata(SVScript script, Map<String, dynamic> metadata) {
    // P2MS scripts contain multiple public keys and a threshold
    try {
      // Extract the threshold (m of n)
      int? m;
      int? n;

      final lockBuilder = P2MSLockBuilder.fromScript(script);

      // The first chunk contains the threshold (m)
      if (script.chunks.isNotEmpty) {
        // Convert OP_1 through OP_16 to actual numbers
        if (script.chunks[0].opcodenum >= OpCodes.OP_1 &&
            script.chunks[0].opcodenum <= OpCodes.OP_16) {
          m = script.chunks[0].opcodenum - OpCodes.OP_1 + 1;
        }
      }

      // The last chunk contains the total number of keys (n)
      if (script.chunks.length >= 2) {
        final lastChunk = script.chunks[script.chunks.length - 2];
        if (lastChunk.opcodenum >= OpCodes.OP_1 &&
            lastChunk.opcodenum <= OpCodes.OP_16) {
          n = lastChunk.opcodenum - OpCodes.OP_1 + 1;
        }
      }

      if (m != null) metadata['threshold'] = m;
      if (n != null) metadata['totalKeys'] = n;

      // Extract the public keys
      List<String> publicKeys = [];
      for (int i = 1; i < script.chunks.length - 2; i++) {
        final chunk = script.chunks[i];
        if (chunk.buf != null) {
          publicKeys.add(HEX.encode(chunk.buf!));
        }
      }

      if (publicKeys.isNotEmpty) {
        metadata['publicKeys'] = publicKeys;
      }
    } catch (e) {
      // Metadata extraction failed
    }
  }

  void _extractP2SHMetadata(SVScript script, Map<String, dynamic> metadata) {
    // P2SH scripts contain a script hash
    if (script.chunks.length >= 3) {
      try {
        // The script hash is in the 2nd chunk (index 1)
        final scriptHash = script.chunks[1].buf;
        if (scriptHash != null) {
          metadata['scriptHash'] = HEX.encode(scriptHash);

        }
      } catch (e) {
        // Metadata extraction failed
      }
    }
  }

  void _extractOPReturnMetadata(
      SVScript script, Map<String, dynamic> metadata) {
    // Check for secure OP_RETURN pattern (OP_FALSE OP_RETURN)
    bool isSecurePattern = false;
    if (script.chunks.length >= 2) {
      // Check for OP_FALSE (0x00) followed by OP_RETURN (0x6a)
      if (script.chunks[0].opcodenum == 0x00 &&
          script.chunks[1].opcodenum == 0x6a) {
        isSecurePattern = true;
      }
    }
    metadata['isSecurePattern'] = isSecurePattern;

    // Extract the data from the OP_RETURN
    if (script.chunks.length > 2) {
      List<String> dataChunks = [];
      for (int i = 2; i < script.chunks.length; i++) {
        final chunk = script.chunks[i];
        if (chunk.buf != null) {
          dataChunks.add(HEX.encode(chunk.buf!));
        }
      }

      if (dataChunks.isNotEmpty) {
        metadata['dataChunks'] = dataChunks;

        // Try to interpret the data as UTF-8 text
        try {
          List<String> textChunks = [];
          for (final hexData in dataChunks) {
            final bytes = HEX.decode(hexData);
            final text = String.fromCharCodes(bytes);
            textChunks.add(text);
          }
          metadata['textChunks'] = textChunks;
        } catch (e) {
          // Text interpretation failed
        }
      }
    }
  }

  /// Check if a script can be spent with the given keys
  ///
  /// Returns true if the script can be spent with the given keys, false otherwise.
  /// This is a simplified check that only determines if the keys could potentially
  /// satisfy the script, without performing full script validation.
  bool canBeSpentBy(SVScript script, List<SVPublicKey> keys) {
    // Get the singleton instance of ScriptTemplateRegistry
    final registry = ScriptTemplateRegistry();
    return registry.canBeSatisfiedBy(script, keys);
  }

  /// Verify that a scriptSig correctly spends a scriptPubKey
  ///
  /// This uses DartSV's Interpreter.correctlySpends method to perform full script validation,
  /// which is the most accurate way to determine if a script can be spent.
  ///
  /// @param scriptSig The unlocking script
  /// @param scriptPubKey The locking script
  /// @param txn The transaction containing the scriptSig
  /// @param inputIndex The index of the input containing the scriptSig
  /// @param satoshis The amount of satoshis being spent
  /// @return true if the script correctly spends the output, false otherwise
  bool verifyScriptSpend(SVScript scriptSig, SVScript scriptPubKey,
      Transaction txn, int inputIndex, BigInt satoshis) {
    try {
      // Setup the flags needed for script verification
      final scriptFlags = <VerifyFlag>{
        VerifyFlag.SIGHASH_FORKID,
        VerifyFlag.UTXO_AFTER_GENESIS
      };

      // Create an interpreter and verify the script
      final interpreter = Interpreter();
      interpreter.correctlySpends(scriptSig, scriptPubKey, txn, inputIndex, scriptFlags, Coin.ofSat(satoshis));

      // If we get here, the script verification succeeded
      return true;
    } catch (e) {
      // If an exception was thrown, the script verification failed
      return false;
    }
  }

  /// Check if a BitcoinOutput can be spent by the given wallet
  ///
  /// This is a convenience method that delegates to the appropriate Script Template
  /// based on the output's script type.
  ///
  /// Note: This is a simplified check that only determines if the keys could potentially
  /// satisfy the script, without performing full script validation. For full script
  /// validation, use verifyOutputSpend.
  // bool canOutputBeSpentBy(bitcointx.TransactionOutput output, List<String> walletAddresses,
  //     {List<String>? walletPubKeys}) {
  //   try {
  //
  //     // For P2PKH, we can check if the address is in the wallet
  //     if (output.scriptType == bitcointx.BitcoinScriptType.p2pkh ) {
  //       final locker = P2PKHLockBuilder.fromScript(output.script, networkType: _networkType);
  //       return walletAddresses.contains(locker.address?.toBase58());
  //     }
  //
  //     // For OP_RETURN, always return false as they are not spendable
  //     if (output.scriptType == bitcointx.BitcoinScriptType.opReturn) {
  //       return false;
  //     }
  //
  //     // For other script types, use the Script Template
  //     if (walletPubKeys != null && walletPubKeys.isNotEmpty) {
  //       // Convert string public keys to SVPublicKey objects
  //       final pubKeys = walletPubKeys
  //           .map((key) => SVPublicKey.fromHex(key))
  //           .whereType<SVPublicKey>()
  //           .toList();
  //
  //       if (pubKeys.isNotEmpty) {
  //         return canBeSpentBy(output.script, pubKeys);
  //       }
  //     }
  //   } catch (e) {
  //     // If there's an error in script analysis, assume it's not spendable
  //   }
  //
  //   return false;
  // }
  //
  /// Verify that a transaction input correctly spends an output
  ///
  /// This uses DartSV's Interpreter.correctlySpends method to perform full script validation,
  /// which is the most accurate way to determine if an input can spend an output.
  ///
  /// @param txn The transaction containing the input
  /// @param inputIndex The index of the input to verify
  /// @param prevOutputScript The locking script of the output being spent
  /// @param prevOutputValue The amount of satoshis in the output being spent
  /// @return true if the input correctly spends the output, false otherwise
  bool verifyOutputSpend(Transaction txn, int inputIndex,
      String prevOutputScript, BigInt prevOutputValue) {
    try {
      // Get the input's script - this can be null from the dartsv library
      final inputScript = txn.inputs[inputIndex].script;

      // Handle the case where the script is null by creating an empty script
      final scriptSig = inputScript ?? ScriptBuilder.createEmpty();

      // Parse the previous output's script using the non-nullable method
      // If parsing fails, it will return an empty script which will fail verification
      final scriptPubKey = createScriptFromString(prevOutputScript);

      // Verify the script spend
      return verifyScriptSpend( scriptSig, scriptPubKey, txn, inputIndex, prevOutputValue);
    } catch (e) {
      // If an exception was thrown, the script verification failed
      return false;
    }
  }


  /// Get the ASM string representation of a script
  ///
  /// Returns a string representation of the script in ASM format.
  /// Get the ASM string representation of a script
  ///
  /// Returns a string representation of the script in ASM format.
  String scriptToString(SVScript script) {
    // Convert script chunks to ASM string
    List<String> asmParts = [];

    for (var chunk in script.chunks) {
      if (chunk.opcodenum == 0) {
        asmParts.add('0');
      } else if (chunk.opcodenum == OpCodes.OP_1NEGATE) {
        asmParts.add('-1');
      } else if (chunk.opcodenum >= OpCodes.OP_1 &&
          chunk.opcodenum <= OpCodes.OP_16) {
        asmParts.add((chunk.opcodenum - OpCodes.OP_1 + 1).toString());
      } else if (chunk.buf == null) {
        // This is an opcode, get the name from the OpCodes map
        String? opName;
        OpCodes.opcodeMap.forEach((name, code) {
          if (code == chunk.opcodenum) opName = name;
        });
        asmParts.add(opName ?? 'UNKNOWN_OPCODE');
      } else {
        // This is data, convert to hex
        asmParts.add(HEX.encode(chunk.buf!));
      }
    }

    return asmParts.join(' ');
  }

  /// Create an SVScript from a string representation
  ///
  /// Returns an SVScript created from the given ASM string representation.
  /// Returns null if the script cannot be parsed.
  SVScript? scriptFromString(String scriptString) {
    try {
      return SVScript.fromASM(scriptString);
    } catch (e) {
      return null;
    }
  }

  /// Create a non-nullable SVScript from a string representation
  ///
  /// This is similar to scriptFromString but returns a default empty script
  /// instead of null if the script cannot be parsed.
  /// Use this when you need a non-nullable SVScript.
  SVScript createScriptFromString(String scriptString) {
    try {
      return SVScript.fromASM(scriptString);
    } catch (e) {
      // Return an empty script if parsing fails
      // Create a truly empty script with no buffer content
      return ScriptBuilder.createEmpty();
    }
  }
}
