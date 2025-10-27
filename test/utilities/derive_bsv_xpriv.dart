/// Utility to derive a BSV-compatible xpriv from a mnemonic
/// 
/// This script derives an xpriv at m/44'/236'/0' (BSV coin type)
/// instead of m/44'/0'/0' (Bitcoin coin type)
/// 
/// Run with: dart run test/utilities/derive_bsv_xpriv.dart

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/utils/beef.dart';

void main() {
  print('═══════════════════════════════════════════════════════════');
  print(' BSV Xpriv Derivation Utility (BIP44 m/44\'/236\'/0\')');
  print('═══════════════════════════════════════════════════════════\n');
  
  // REPLACE THIS WITH YOUR ACTUAL MNEMONIC
  const mnemonic = 'your twelve word mnemonic phrase goes here replace this text';
  
  // Choose network
  const networkType = dartsv.NetworkType.TEST; // Change to .MAIN for mainnet
  
  print('Network: ${networkType == dartsv.NetworkType.MAIN ? 'MAINNET' : 'TESTNET'}');
  print('Derivation path: m/44\'/236\'/0\'');
  print('');


  // final jopKey = dartsv.HDPrivateKey.fromXpriv("tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R");
  final jopKey = dartsv.HDPrivateKey.fromXpriv("tprv8ZgxMBicQKsPfMi8zRfbn9aPteVMnmnNRuAkWzALcAmyKycA5LJ9xfwGCgqTjskEUSDWn6RaNL6Bu6iXcGmQr6ZfMaQvT4bDyWpBpyPgL9m");
  // final j1 = jopKey.publicKey.toAddress(dartsv.NetworkType.TEST);
  // final jobKeyD1 = jopKey.deriveChildNumber(1);

  for (int i = 0; i < 20; i++){
    final j1 = jopKey.deriveChildNumber(i);
    print("j1 Addr : " +  j1.publicKey.toAddress(dartsv.NetworkType.MAIN).toBase58());

    final j2 = jopKey.deriveChildKey("m/0'/${i}");
    print("j2 Addr : " + j2.publicKey.toAddress(dartsv.NetworkType.MAIN).toBase58());
  }

  // final j1 = jopKey.deriveChildKey("m/44'/236'/0/0");
  // final j12 = jopKey.deriveChildKey("m/44'/236'/0'/1");
  // final j2 = jopKey.deriveChildKey("m/44'/0'/0'/0'");
  // final j22 = jopKey.deriveChildKey("m/44'/0'/0'/1'");

  // print(j1.publicKey.toAddress(dartsv.NetworkType.TEST));
  // print(j12.publicKey.toAddress(dartsv.NetworkType.TEST));
  // print(j2.publicKey.toAddress(dartsv.NetworkType.TEST));
  // print(j22.publicKey.toAddress(dartsv.NetworkType.TEST));
  try {
    // Step 1: Generate seed from mnemonic
    final mnemonicObj = dartsv.Mnemonic();
    final seed = mnemonicObj.toSeed(mnemonic);
    
    // Step 2: Create HD private key from seed
    final hdPrivateKey = dartsv.HDPrivateKey.fromSeed(hex.encode(seed), networkType);
    print('✓ Root xpriv: ${hdPrivateKey.xprivkey}');
    print('  (Path: m)');
    print('');
    
    // Step 3: Derive to BIP44 BSV account (m/44'/236'/0')
    final bsvAccount = hdPrivateKey
        .deriveChildKey("m/44'/236'/0'"); // BSV coin type 236
    
    print('✓ BSV Account xpriv: ${bsvAccount.xprivkey}');
    print('  (Path: m/44\'/236\'/0\')');
    print('');
    
    // Show corresponding xpub
    final hdPublicKey = bsvAccount.hdPublicKey;
    print('✓ BSV Account xpub: ${hdPublicKey.xpubkey}');
    print('');
    
    // Derive first receiving address as verification
    final receivingChain = hdPublicKey.deriveChildNumber(0);
    final firstAddress = receivingChain.deriveChildNumber(0);
    final address = dartsv.Address.fromPublicKey(firstAddress.publicKey, networkType);
    
    print('✓ First receiving address (m/44\'/236\'/0\'/0/0):');
    print('  ${address.toBase58()}');
    print('');
    
    print('═══════════════════════════════════════════════════════════');
    print(' IMPORT THIS XPRIV INTO YOUR WALLET:');
    print('═══════════════════════════════════════════════════════════');
    print(bsvAccount.xprivkey);
    print('═══════════════════════════════════════════════════════════\n');
    
  } catch (e) {
    print('❌ Error: $e');
    print('\nMake sure to replace the placeholder mnemonic with your actual mnemonic!');
  }
}

