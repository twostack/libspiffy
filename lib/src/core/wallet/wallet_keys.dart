/// The wallet's keys: key material in secure storage, the root address of a
/// new wallet, address derivation and private key lookup (bead
/// libspiffy-dp4; part of `BitcoinWalletAggregate`).
library;

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../../models/wallet_state.dart';
import '../../models/wallet_type.dart';
import '../../services/crypto_service.dart';
import '../../storage/secure_storage.dart';
import '../../utils/bip32.dart';
import '../../utils/network_name.dart';
import '../wallet_commands.dart';
import '../wallet_events.dart';
import 'address_book.dart';
import 'state_records.dart';

final _log = Logger('BitcoinWalletAggregate');

/// The root of a wallet a [CreateWalletCommand] creates.
typedef WalletRoot = ({
  WalletType walletType,
  String rootAddress,
  String networkName,

  /// Account xpub: goes to secure storage only, never into the event (KM-8).
  String? hdPublicKeyXpub,
});

/// Key material and key derivation for one wallet aggregate.
class WalletKeys {
  final CryptoService cryptoService;
  final SecureStorage secureStorage;

  WalletKeys({required this.cryptoService, required this.secureStorage});

  // ---------------------------------------------------------------------------
  // Key material in secure storage
  // ---------------------------------------------------------------------------

  /// Every secure-storage key that [storeKeyMaterial] may write for a wallet.
  static List<String> keyMaterialKeys(String walletId) => [
        'wallet_wif_$walletId',
        'wallet_xpriv_$walletId',
        'wallet_xpub_$walletId',
        'wallet_mnemonic_$walletId',
        passphraseKey(walletId),
        hdPubKeyKey(walletId),
      ];

  static String passphraseKey(String walletId) => 'wallet_passphrase_$walletId';
  static String hdPubKeyKey(String walletId) => 'wallet_hdpubkey_$walletId';

  /// Store key material in secure storage BEFORE the WalletCreatedEvent is
  /// persisted (audit 2026-09-14 H4). Writing the secrets after the event
  /// (and after the success reply) meant a failed secure-storage write left
  /// a wallet whose events exist but that can never sign. Now a failed write
  /// fails the command with no event journaled, and a failed persist removes
  /// the secrets again (see `BitcoinWalletAggregate.onCommandFailure`).
  Future<void> storeKeyMaterial(CreateWalletCommand command, String? hdPublicKeyXpub) async {
    final walletId = command.walletId;

    if (command.wif != null && command.wif!.isNotEmpty) {
      await secureStorage.setWIF(walletId, command.wif!);
    } else if (command.xpriv != null && command.xpriv!.isNotEmpty) {
      await secureStorage.setXPriv(walletId, command.xpriv!);
      if (hdPublicKeyXpub != null) {
        await secureStorage.setString(hdPubKeyKey(walletId), hdPublicKeyXpub);
      }
    } else if (command.xpub != null && command.xpub!.isNotEmpty) {
      await secureStorage.setXPub(walletId, command.xpub!);
      await secureStorage.setString(hdPubKeyKey(walletId), command.xpub!);
    } else if (command.mnemonic != null && command.mnemonic!.isNotEmpty) {
      await secureStorage.setMnemonic(walletId, command.mnemonic!);
      // The passphrase is part of the seed: addresses were derived with it
      // at creation, so signing must use it too or the keys will not match.
      if (command.passphrase != null && command.passphrase!.isNotEmpty) {
        await secureStorage.setString(
          passphraseKey(walletId),
          command.passphrase!,
        );
      }
      if (hdPublicKeyXpub != null) {
        await secureStorage.setString(hdPubKeyKey(walletId), hdPublicKeyXpub);
      }
    }
  }

  /// Best-effort removal of everything [storeKeyMaterial] wrote for
  /// [walletId]. Failures are logged, never thrown: this runs on an error
  /// path and the original error must reach the caller.
  Future<void> removeKeyMaterial(String walletId, {required Object cause}) async {
    for (final key in keyMaterialKeys(walletId)) {
      try {
        await secureStorage.delete(key);
      } catch (e) {
        _log.severe(
            'Wallet $walletId: could not remove $key from secure storage after '
            'creation failed ($cause); remove it manually before retrying: $e');
      }
    }
  }

  /// BIP39 passphrase recorded at creation, or '' when none was given.
  Future<String> mnemonicPassphrase(String walletId) async =>
      await secureStorage.getString(passphraseKey(walletId)) ?? '';

  // ---------------------------------------------------------------------------
  // Wallet creation and address derivation
  // ---------------------------------------------------------------------------

  /// The wallet type, root address and account xpub of the wallet [command]
  /// creates, from its WIF, xpriv, xpub or mnemonic. Throws when the key does
  /// not parse or is for another network. Writes nothing.
  Future<WalletRoot> walletRoot(CreateWalletCommand command) async {
    // Determine wallet type and extract/generate keys
    final WalletType walletType;
    final String rootAddress;

    // Extract network type from metadata
    final metadata = command.walletMetadata ?? {};
    // Accept 'main'/'mainnet' (and 'test'/'testnet'); persist the canonical
    // spelling so every later reader resolves the same network.
    final networkTypeStr = NetworkName.canonical(metadata[WalletMetadataKeys.network] as String?);
    final networkType = NetworkName.toDartsv(networkTypeStr);

    // Account xpub: goes to secure storage only, never into the event (KM-8)
    String? hdPublicKeyXpub;

    if (command.wif != null && command.wif!.isNotEmpty) {
      // WIF WALLET: Single address from private key
      walletType = WalletType.wif;

      // Parse and validate WIF
      final privateKey = dartsv.SVPrivateKey.fromWIF(command.wif!);

      // Verify network type matches
      if (privateKey.networkType != networkType) {
        throw ArgumentError('WIF network type does not match wallet network type');
      }

      // Derive address from WIF key
      final publicKey = privateKey.publicKey;
      final address = publicKey.toAddress(networkType);
      rootAddress = address.toBase58();
    } else if (command.xpriv != null && command.xpriv!.isNotEmpty) {
      // XPRIV WALLET: HD derivation from extended private key
      walletType = WalletType.xpriv;

      // Parse and validate XPRIV
      final hdPrivateKey = dartsv.HDPrivateKey.fromXpriv(command.xpriv!);

      // Verify network type matches
      if (hdPrivateKey.networkType != networkType) {
        throw ArgumentError('XPRIV network type does not match wallet network type');
      }

      // Derive HD public key
      final hdPublicKey = cryptoService.deriveHDPublicKey(hdPrivateKey);
      hdPublicKeyXpub = hdPublicKey.xpubkey;

      // Generate root address (first receiving address at index 0)
      rootAddress = cryptoService.generateReceivingAddress(
        hdPublicKey,
        0,
        network: networkType,
      );
    } else if (command.xpub != null && command.xpub!.isNotEmpty) {
      // XPUB WALLET: Watch-only from extended public key
      walletType = WalletType.xpub;

      // Parse and validate XPUB
      final hdPublicKey = dartsv.HDPublicKey.fromXpub(command.xpub!);

      // Verify network type matches
      if (hdPublicKey.networkType != networkType) {
        throw ArgumentError('XPUB network type does not match wallet network type');
      }

      // Generate root address
      rootAddress = cryptoService.generateReceivingAddress(
        hdPublicKey,
        0,
        network: networkType,
      );

      // For XPUB wallets, the xpub itself is the HD public key
      hdPublicKeyXpub = command.xpub!;
    } else {
      // HD WALLET: Generate or validate mnemonic
      walletType = WalletType.hd;

      String mnemonic = command.mnemonic ?? '';

      //Force the caller to provide the mnemonic. Mnemonic validation
      //is responsibility of the caller.
      if (mnemonic.isEmpty) {
        throw ArgumentError('Invalid mnemonic phrase provided. Mnemonic is empty');
      }

      // Derive HD private key from mnemonic
      final hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(
        mnemonic,
        passphrase: command.passphrase ?? '',
        network: networkType,
      );

      // Derive HD public key
      final hdPublicKey = cryptoService.deriveHDPublicKey(hdPrivateKey);
      hdPublicKeyXpub = hdPublicKey.xpubkey;

      // Generate root address
      rootAddress = cryptoService.generateReceivingAddress(
        hdPublicKey,
        0,
        network: networkType,
      );
    }

    return (
      walletType: walletType,
      rootAddress: rootAddress,
      networkName: networkTypeStr,
      hdPublicKeyXpub: hdPublicKeyXpub,
    );
  }

  Future<List<Event>> generateAddress(WalletState currentState, GenerateAddressCommand command) async {
    // Business rule: Wallet must exist
    if (!currentState.isCreated) {
      throw StateError('Cannot generate address for non-existent wallet');
    }

    // For WIF wallets, always return the root address
    if (currentState.walletType == WalletType.wif) {
      // WIF wallets are single-address - return the existing address
      if (currentState.rootAddress == null) {
        throw StateError('WIF wallet has no root address');
      }

      // Get public key if requested
      String? publicKeyHex;
      if (command.includePublicKey) {
        final wif = await secureStorage.getWIF(command.walletId);
        if (wif == null) {
          throw StateError('WIF not found for wallet ${command.walletId}');
        }
        final privateKey = dartsv.SVPrivateKey.fromWIF(wif);
        publicKeyHex = privateKey.publicKey.toHex();
      }

      // Return AddressGeneratedEvent with same address and index 0
      final event = AddressGeneratedEvent(
        walletId: command.walletId,
        address: currentState.rootAddress!,
        derivationIndex: 0,
        label: command.label,
        purpose: command.purpose,
        publicKeyHex: publicKeyHex,
        correlationId: command.getCorrelationId(),
        metadata: command.metadata,
        timestamp: DateTime.now(),
        version: currentState.version + 1,
      );

      return [event];
    }

    // For HD and XPRIV wallets, derive new address
    // Use next available derivation index
    final derivationIndex = currentState.nextDerivationIndex;

    // Determine network type
    final networkType = NetworkName.toDartsv(currentState.networkType);

    // Retrieve HD public key from secure storage, recovering it from the
    // wallet's own key material if it is not there (libspiffy-atl2).
    final hdPublicKey = await accountXpub(command.walletId, currentState);

    // Generate address based on purpose
    final String address;
    final int derivationPath; // 0 for receiving, 1 for change
    if (command.purpose == AddressBook.changePurpose) {
      address = cryptoService.generateChangeAddress(
        hdPublicKey,
        derivationIndex,
        network: networkType,
      );
      derivationPath = 1;
    } else {
      // Default to receiving address
      address = cryptoService.generateReceivingAddress(
        hdPublicKey,
        derivationIndex,
        network: networkType,
      );
      derivationPath = 0;
    }

    // Derive public key if requested
    String? publicKeyHex;
    if (command.includePublicKey) {
      final childKey = Bip32.derivePublicPath(hdPublicKey, "m/$derivationPath/$derivationIndex");
      publicKeyHex = childKey.publicKey.toHex();
    }

    final event = AddressGeneratedEvent(
      eventId: const Uuid().v4(),
      walletId: command.walletId,
      timestamp: DateTime.now(),
      version: currentState.version + 1,
      address: address,
      derivationIndex: derivationIndex,
      label: command.label,
      purpose: command.purpose,
      publicKeyHex: publicKeyHex,
      correlationId: command.getCorrelationId(),
      metadata: command.metadata, // Preserve metadata (e.g., invoiceId from coordinator)
    );

    return [event];
  }

  // ---------------------------------------------------------------------------
  // Private keys
  // ---------------------------------------------------------------------------

  /// Retrieve the private key for a given address from secure storage
  /// Supports WIF, XPRIV, and HD wallets.
  ///
  /// [derivationIndex] and [isChange] let a caller that holds the derivation
  /// path (e.g. from the read model) supply it directly. When [isChange] is
  /// null the chain is resolved from the aggregate's own address records,
  /// which is correct for every address the aggregate generated or
  /// discovered; unknown addresses default to the receive chain.
  Future<dartsv.SVPrivateKey> privateKeyForAddress(
    String address,
    String walletId,
    WalletState currentState, {
    int? derivationIndex,
    bool? isChange,
  }) async {
    if (currentState.walletType == WalletType.wif) {
      // WIF wallet: single private key
      final wif = await secureStorage.getWIF(walletId);
      if (wif == null) {
        throw StateError('WIF not found for wallet $walletId');
      }
      return dartsv.SVPrivateKey.fromWIF(wif);
    } else if (currentState.walletType == WalletType.xpub) {
      throw StateError('Cannot retrieve private key: Wallet is watch-only (XPUB)');
    } else if (currentState.walletType == WalletType.xpriv || currentState.walletType == WalletType.hd) {
      // HD/XPRIV wallet: derive key for specific address
      int effectiveIndex;

      if (derivationIndex != null) {
        // Use caller-provided index (from read model — avoids write/read model split)
        effectiveIndex = derivationIndex;
      } else if (address == currentState.rootAddress) {
        effectiveIndex = 0; // Root address is always at index 0
      } else {
        // Fall back to aggregate state lookup
        // `addresses` maps address -> optional label, so presence must be
        // checked with containsKey: an unlabelled address has a null value.
        if (!currentState.addresses.containsKey(address)) {
          throw StateError('Address $address not found in wallet state');
        }
        effectiveIndex = AddressBook.addressIndices(currentState.metadata)[address] ?? 0;
      }

      // The chain: caller-supplied, else whatever the aggregate recorded when
      // it generated/discovered the address (receive for the root address and
      // for journals written before the chain was recorded).
      final effectiveIsChange = isChange ?? AddressBook.isChangeAddress(currentState, address);

      return privateKeyAtIndex(
        walletId,
        effectiveIndex,
        currentState,
        isChange: effectiveIsChange,
      );
    } else {
      throw StateError('Unsupported wallet type: ${currentState.walletType}');
    }
  }

  /// The account extended public key of an HD, XPRIV or XPUB wallet, as a
  /// parsed [dartsv.HDPublicKey].
  ///
  /// `wallet_hdpubkey_<walletId>` is written at creation by
  /// [storeKeyMaterial] and is the answer whenever it is there. A wallet can
  /// still be left without it: a creation interrupted before audit H4 wrote
  /// the secrets *after* the event, and a host that moves, restores or
  /// re-encrypts its secure storage may carry the seed across without the
  /// key derived from it. Such a wallet could never derive another address
  /// for the rest of its life, although the material the xpub comes from was
  /// sitting beside it — while [privateKeyAtIndex] kept signing, because the
  /// private side already walked a fallback chain. This walks the same one:
  /// the watch-only xpub, then the xpriv, then the mnemonic.
  ///
  /// **A recovered xpub is trusted only if it re-derives the wallet's
  /// journaled root address** (m/0/0, the path every release has used). It
  /// can be the wrong key: a mnemonic wallet's xpub depends on its BIP39
  /// passphrase, and a secure storage that lost the hdpubkey may have lost
  /// the passphrase too, in which case the mnemonic alone derives a
  /// *different* wallet. Returning that xpub would hand out addresses this
  /// wallet can never sign for, and coin sent to them would be unspendable —
  /// far worse than the failure it replaces. An unverifiable recovery is
  /// refused, naming what was found and what could not be confirmed.
  ///
  /// A verified recovery is written back to `wallet_hdpubkey_<walletId>` so
  /// it happens once. A failed write-back is logged, not thrown: the address
  /// derives regardless, and the recovery simply runs again next time.
  Future<dartsv.HDPublicKey> accountXpub(
      String walletId, WalletState currentState) async {
    final stored = await secureStorage.getString(hdPubKeyKey(walletId));
    if (stored != null) return dartsv.HDPublicKey.fromXpub(stored);

    final networkType = NetworkName.toDartsv(currentState.networkType);

    // In precedence order, and each entry names the key it reads so a
    // failure can say what was looked for.
    final sources = <(String, Future<String?> Function())>[
      ('wallet_xpub_$walletId', () async => secureStorage.getXPub(walletId)),
      ('wallet_xpriv_$walletId', () async {
        final xpriv = await secureStorage.getXPriv(walletId);
        if (xpriv == null) return null;
        return cryptoService
            .deriveHDPublicKey(dartsv.HDPrivateKey.fromXpriv(xpriv))
            .xpubkey;
      }),
      ('wallet_mnemonic_$walletId', () async {
        final mnemonic = await secureStorage.getMnemonic(walletId);
        if (mnemonic == null) return null;
        final hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(
          mnemonic,
          passphrase: await mnemonicPassphrase(walletId),
          network: networkType,
        );
        return cryptoService.deriveHDPublicKey(hdPrivateKey).xpubkey;
      }),
    ];

    final rootAddress = currentState.rootAddress;
    for (final (key, read) in sources) {
      final String? xpub;
      try {
        xpub = await read();
      } catch (e) {
        _log.warning('Wallet $walletId: $key did not yield an account xpub: $e');
        continue;
      }
      if (xpub == null) continue;

      final dartsv.HDPublicKey hdPublicKey;
      final String derivedRoot;
      try {
        hdPublicKey = dartsv.HDPublicKey.fromXpub(xpub);
        derivedRoot = cryptoService.generateReceivingAddress(hdPublicKey, 0,
            network: networkType);
      } catch (e) {
        _log.warning('Wallet $walletId: the account xpub recovered from $key '
            'does not derive an address: $e');
        continue;
      }

      if (rootAddress != null && derivedRoot != rootAddress) {
        // Deliberately terminal rather than a fall-through to the next
        // source: the key material is present and it is the WRONG key. An
        // absence is recoverable; a mismatch is a different wallet, and
        // guessing on is how unspendable addresses get handed out.
        throw StateError(
            'Wallet $walletId: the account xpub recovered from $key derives '
            'root address $derivedRoot, but the wallet was created with '
            '$rootAddress. The key material belongs to a different wallet, or '
            'the BIP39 passphrase it was created with '
            '(wallet_passphrase_$walletId) is missing. Restore '
            '${hdPubKeyKey(walletId)}, or the passphrase, before generating '
            'another address: an address derived from this key could not be '
            'signed for.');
      }

      _log.warning('Wallet $walletId: ${hdPubKeyKey(walletId)} was missing; '
          'recovered the account xpub from $key and verified it against the '
          'wallet root address. Restoring the key.');
      try {
        await secureStorage.setString(hdPubKeyKey(walletId), xpub);
      } catch (e) {
        _log.severe('Wallet $walletId: could not restore '
            '${hdPubKeyKey(walletId)}; the recovery will run again next time: $e');
      }
      return hdPublicKey;
    }

    throw StateError(
        'Wallet $walletId: no account xpub. ${hdPubKeyKey(walletId)} is not in '
        'secure storage and none of wallet_xpub_$walletId, '
        'wallet_xpriv_$walletId or wallet_mnemonic_$walletId could supply it. '
        'The wallet cannot derive another address until its key material is '
        'restored; its existing addresses and their coin are untouched.');
  }

  /// Get private key at a specific derivation index on the receive
  /// ([isChange] false, m/0/{index}) or change ([isChange] true, m/1/{index})
  /// chain. Used for multisig signing where we know the exact path, and by
  /// [privateKeyForAddress] once it has resolved the path.
  Future<dartsv.SVPrivateKey> privateKeyAtIndex(
    String walletId,
    int derivationIndex,
    WalletState currentState, {
    bool isChange = false,
  }) async {
    final networkType = NetworkName.toDartsv(currentState.networkType);

    if (currentState.walletType == WalletType.wif) {
      // WIF wallet: single private key
      final wif = await secureStorage.getWIF(walletId);
      if (wif == null) {
        throw StateError('WIF not found for wallet $walletId');
      }
      return dartsv.SVPrivateKey.fromWIF(wif);
    } else if (currentState.walletType == WalletType.xpriv || currentState.walletType == WalletType.hd) {
      // HD/XPRIV wallet: derive key at specific index
      final xprivStr = await secureStorage.getXPriv(walletId);
      if (xprivStr != null) {
        final hdPrivateKey = dartsv.HDPrivateKey.fromXpriv(xprivStr);
        // m/{chain}/{index}: chain 0 = receive, 1 = change
        return await cryptoService.derivePrivateKey(
          hdPrivateKey,
          0, // accountIndex
          derivationIndex, // addressIndex
          isChange: isChange,
        );
      }

      // Try mnemonic if xpriv not found
      final mnemonic = await secureStorage.getMnemonic(walletId);
      if (mnemonic != null) {
        final hdPrivateKey = await cryptoService.mnemonicToHDPrivateKey(
          mnemonic,
          passphrase: await mnemonicPassphrase(walletId),
          network: networkType,
        );
        // m/{chain}/{index}: chain 0 = receive, 1 = change
        return await cryptoService.derivePrivateKey(
          hdPrivateKey,
          0, // accountIndex
          derivationIndex, // addressIndex
          isChange: isChange,
        );
      }

      throw StateError('No xpriv or mnemonic found for wallet $walletId');
    } else {
      throw StateError('Unsupported wallet type: ${currentState.walletType}');
    }
  }
}
