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

  final beef = BEEF.parse(Uint8List.fromList(hex.decode("0100beef01fe5dea120007010202a05924fcc63712d3e4b94b0c88baad234c2c8ad3d369704f53765e21a53a21010100002bb617ed9b7950dcc9ddd952364a5d039742b40b786d3ef8a3984a5cf5495640010000e0c82744e0d7c7a1e72102b82fa37ae09f4e6018ebb18773f888617b83250e750100009991c11c2ecb5087a29032a279d926bfe03c926c582a30743c902b57a3d980390100009d54821a3821713dadeeb3a614921f8c63866f82686cbcf019ed7a6c20a36d2b010000a1e33369efb20fa5a1311ddfed20747de1996fdc814aa19691106eafe28b3e5d0100005a2f7dcc9b1fddc64f57157e7c59082729622050a76cb6956ae6b15f1a9ff0c402020000000165b6c06790c23623c4988ee51b3f27c76bfb6a0c9e5bab3432968c51379af66a000000006b483045022100b735fb60adca4fa42e37746aa602c3206bf98572ae83e396da4fd11cb716b26d022017bf9955bd8fc4d60f2829236c7864d5b5540062c88113daef137c0ee441736c41210222824a8530bc570b7bae7c7600529b450a65eab1203c5f561d8082cd97b3dba1feffffff02872ec735150000001976a9149d02ce72bbdc1713d5537a0705d8ec7d9702c81088ac00c2eb0b000000001976a9146a418bf9e2e2b670e1aa7b7da59391e212b4ba1988ac5cea1200010000")));

  final jopKey = dartsv.HDPrivateKey.fromXpriv("tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R");
  // final j1 = jopKey.publicKey.toAddress(dartsv.NetworkType.TEST);
  // final jobKeyD1 = jopKey.deriveChildNumber(1);
  final j1 = jopKey.deriveChildKey("m/44'/236'/0/0");
  final j12 = jopKey.deriveChildKey("m/44'/236'/0'/1");
  final j2 = jopKey.deriveChildKey("m/44'/0'/0'/0'");
  final j22 = jopKey.deriveChildKey("m/44'/0'/0'/1'");

  print(j1.publicKey.toAddress(dartsv.NetworkType.TEST));
  print(j12.publicKey.toAddress(dartsv.NetworkType.TEST));
  print(j2.publicKey.toAddress(dartsv.NetworkType.TEST));
  print(j22.publicKey.toAddress(dartsv.NetworkType.TEST));
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

