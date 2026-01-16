/// Supported wallet types in LibSpiffy
enum WalletType {
  /// HD wallet created from mnemonic seed phrase
  /// Supports unlimited address generation via BIP32/44 derivation
  hd,
  
  /// Wallet created from extended private key (xpriv)
  /// Supports HD address generation like mnemonic wallets
  xpriv,
  
  /// Wallet created from WIF (Wallet Import Format) private key
  /// Single address only - no address derivation supported
  wif,

  /// Watch-only wallet from extended public key (xpub)
  /// Can generate addresses but CANNOT sign transactions
  xpub,
}

extension WalletTypeExtension on WalletType {
  String toStorageString() {
    switch (this) {
      case WalletType.hd:
        return 'hd';
      case WalletType.xpriv:
        return 'xpriv';
      case WalletType.wif:
        return 'wif';
      case WalletType.xpub:
        return 'xpub';
    }
  }
  
  static WalletType fromStorageString(String value) {
    switch (value) {
      case 'hd':
        return WalletType.hd;
      case 'xpriv':
        return WalletType.xpriv;
      case 'wif':
        return WalletType.wif;
      case 'xpub':
        return WalletType.xpub;
      default:
        throw ArgumentError('Unknown wallet type: $value');
    }
  }
}

