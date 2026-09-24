/// The wallet's keys: key material in secure storage, the root address of a
/// new wallet, address derivation and private key lookup (bead
/// libspiffy-dp4; part of `BitcoinWalletAggregate`).
library;

import 'dart:convert';
import 'dart:math';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:eventador/eventador.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../../crypto/type42.dart';
import '../../models/address_chain.dart';
import '../../models/key_path.dart';
import '../../models/wallet_state.dart';
import '../../models/wallet_type.dart';
import '../../services/crypto_service.dart';
import '../../storage/secure_storage.dart';
import '../../utils/bip32.dart';
import '../../utils/network_name.dart';
import '../wallet_commands.dart';
import '../wallet_events.dart';
import 'address_book.dart';
import 'type42_book.dart';
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
      rootAddress = cryptoService.deriveAddress(hdPublicKey, 0, network: networkType);
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
      rootAddress = cryptoService.deriveAddress(hdPublicKey, 0, network: networkType);

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
      rootAddress = cryptoService.deriveAddress(hdPublicKey, 0, network: networkType);
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

    // The chain: change when asked for, else receive for a wallet that
    // holds its keys, and delegated for an xpub wallet. An xpub wallet
    // issues addresses on behalf of the key holder (a service answering
    // invoice requests for an offline payee, spv-understanding.md "Payment
    // modes"), and the key holder's own wallet issues receive addresses from
    // the same xpub: on one chain the two would hand out the same address.
    final AddressChain chain;
    if (command.purpose == AddressBook.changePurpose) {
      chain = AddressChain.change;
    } else if (currentState.walletType == WalletType.xpub) {
      chain = AddressChain.delegated;
    } else {
      chain = AddressChain.receive;
    }
    final address = cryptoService.deriveAddress(hdPublicKey, derivationIndex, chain: chain, network: networkType);

    // Derive public key if requested
    String? publicKeyHex;
    if (command.includePublicKey) {
      final childKey = Bip32.derivePublicPath(hdPublicKey, "m/${chain.index}/$derivationIndex");
      publicKeyHex = childKey.publicKey.toHex();
    }

    final event = AddressGeneratedEvent(
      eventId: const Uuid().v4(),
      walletId: command.walletId,
      timestamp: DateTime.now(),
      version: currentState.version + 1,
      address: address,
      derivationIndex: derivationIndex,
      chain: chain,
      label: command.label,
      purpose: command.purpose,
      publicKeyHex: publicKeyHex,
      correlationId: command.getCorrelationId(),
      metadata: command.metadata, // Preserve metadata (e.g., invoiceId from coordinator)
    );

    return [event];
  }

  /// The addresses [command] names on the delegated chain, derived from the
  /// wallet's own account key, in the command's order, and an
  /// [AddressDiscoveredEvent] for each the wallet has not recorded yet (bead
  /// libspiffy-m8qu).
  Future<({List<Event> events, List<String> addresses})> recordDelegatedAddresses(
      WalletState currentState, RecordDelegatedAddressesCommand command) async {
    if (!currentState.isCreated || currentState.isDeleted) {
      throw StateError('Cannot record delegated addresses for non-existent wallet ${command.walletId}');
    }
    if (currentState.walletType == WalletType.wif) {
      throw StateError('Wallet ${command.walletId} is a single-key (WIF) wallet: it has no HD tree, '
          'so no service can issue addresses on its delegated chain');
    }
    for (final index in command.derivationIndices) {
      if (index < 0) throw ArgumentError.value(index, 'derivationIndices', 'must not be negative');
    }
    final hdPublicKey = await accountXpub(command.walletId, currentState);
    final network = NetworkName.toDartsv(currentState.networkType);
    final events = <Event>[];
    final addresses = <String>[];
    for (final index in command.derivationIndices) {
      final address = cryptoService.deriveAddress(hdPublicKey, index, chain: AddressChain.delegated, network: network);
      addresses.add(address);
      if (currentState.addresses.containsKey(address) || addresses.indexOf(address) != addresses.length - 1) continue;
      events.add(AddressDiscoveredEvent(
        walletId: command.walletId,
        address: address,
        derivationIndex: index,
        chain: AddressChain.delegated,
        transactionCount: 0,
        version: currentState.version + events.length + 1,
      ));
    }
    return (events: events, addresses: addresses);
  }

  // ---------------------------------------------------------------------------
  // Type-42 (BRC-42) keys (bead libspiffy-zxkd)
  // ---------------------------------------------------------------------------

  /// Path of the anchor key A, which payers derive type-42 destinations
  /// from. Hardened: the payer of a type-42 payment knows its tweak t, so a
  /// child key c = a + t that leaks gives away a; under a hardened path a
  /// does not give away the account key the wallet's xpub is published for.
  static const String anchorPath = "m/3'/0'";

  /// Path of payer key [index], the key B the wallet derives a type-42
  /// destination with (fresh for every destination).
  static String payerKeyPath(int index) => "m/3'/1'/$index'";

  /// The HD private key the wallet's key paths are relative to: from the
  /// xpriv, else from the mnemonic (and the passphrase it was created with).
  Future<dartsv.HDPrivateKey> _hdPrivateKey(String walletId, WalletState currentState) async {
    final xpriv = await secureStorage.getXPriv(walletId);
    if (xpriv != null) return dartsv.HDPrivateKey.fromXpriv(xpriv);
    final mnemonic = await secureStorage.getMnemonic(walletId);
    if (mnemonic != null) {
      return cryptoService.mnemonicToHDPrivateKey(
        mnemonic,
        passphrase: await mnemonicPassphrase(walletId),
        network: NetworkName.toDartsv(currentState.networkType),
      );
    }
    throw StateError('No xpriv or mnemonic found for wallet $walletId');
  }

  /// The private key at the hardened [path] of an HD or XPRIV wallet.
  /// Throws for a wallet that has no HD private key: an xpub wallet holds no
  /// private key, and a WIF wallet no HD tree to put an anchor key on.
  Future<dartsv.SVPrivateKey> _type42Key(String walletId, WalletState currentState, String path, String what) async {
    if (!currentState.isCreated || currentState.isDeleted) {
      throw StateError('Wallet $walletId does not exist');
    }
    switch (currentState.walletType) {
      case WalletType.hd || WalletType.xpriv:
        return Bip32.derivePrivatePath(await _hdPrivateKey(walletId, currentState), path).privateKey;
      case WalletType.xpub:
        throw StateError('Wallet $walletId is watch-only (XPUB): it holds no $what, so it can neither '
            'take nor make type-42 payments');
      case WalletType.wif:
        throw StateError('Wallet $walletId is a single-key (WIF) wallet: it has no HD tree to derive a $what on');
    }
  }

  /// The anchor key a at [anchorPath].
  Future<dartsv.SVPrivateKey> anchorKey(String walletId, WalletState currentState) =>
      _type42Key(walletId, currentState, anchorPath, 'anchor key');

  /// The type-42 child of the anchor key for [derivation]: c = a + t.
  Future<dartsv.SVPrivateKey> type42ChildKey(
          String walletId, WalletState currentState, Type42Derivation derivation) async =>
      Type42.deriveChildPrivate(await anchorKey(walletId, currentState),
          dartsv.SVPublicKey.fromHex(derivation.senderPublicKey), derivation.invoiceNumber);

  String _p2pkh(dartsv.SVPublicKey key, WalletState currentState) =>
      key.toAddress(NetworkName.toDartsv(currentState.networkType)).toBase58();

  /// The addresses [command]'s derivations give from the wallet's own anchor
  /// key, in the command's order, and a [Type42AddressRecordedEvent] for
  /// each the wallet has not recorded yet.
  Future<({List<Event> events, List<String> addresses})> recordType42Addresses(
      WalletState currentState, RecordType42AddressesCommand command) async {
    final anchor = await anchorKey(command.walletId, currentState);
    final recorded = Type42Book.addressDerivations(currentState.metadata);
    final events = <Event>[];
    final addresses = <String>[];
    for (final derivation in command.derivations) {
      final child = Type42.deriveChildPrivate(
          anchor, dartsv.SVPublicKey.fromHex(derivation.senderPublicKey), derivation.invoiceNumber);
      final address = _p2pkh(child.publicKey, currentState);
      addresses.add(address);
      if (recorded.containsKey(address) || addresses.indexOf(address) != addresses.length - 1) continue;
      if (currentState.addresses.containsKey(address)) {
        throw StateError('Type-42 address $address of wallet ${command.walletId} is already one of its HD addresses');
      }
      events.add(Type42AddressRecordedEvent(
        walletId: command.walletId,
        address: address,
        derivation: derivation,
        version: currentState.version + events.length + 1,
      ));
    }
    return (events: events, addresses: addresses);
  }

  /// The type-42 destination [command] asks for, derived with the wallet's
  /// next payer key, as a [Type42DestinationDerivedEvent].
  Future<Type42DestinationDerivedEvent> deriveType42Destination(
      WalletState currentState, DeriveType42DestinationCommand command) async {
    final recipientHex = Type42Derivation.publicKeyHex(command.recipientPublicKey, 'recipientPublicKey');
    final index = Type42Book.payerKeysUsed(currentState.metadata);
    final payer = await _type42Key(command.walletId, currentState, payerKeyPath(index), 'payer key');
    final derivation = Type42Derivation(
      senderPublicKey: payer.publicKey.toHex(),
      invoiceNumber: command.invoiceNumber ?? Type42Derivation.brc29InvoiceNumber(_randomBase64(), _randomBase64()),
    );
    final destination =
        Type42.deriveChildPublic(dartsv.SVPublicKey.fromHex(recipientHex), payer, derivation.invoiceNumber);
    return Type42DestinationDerivedEvent(
      walletId: command.walletId,
      destination: Type42Destination(
        address: _p2pkh(destination, currentState),
        recipientPublicKey: recipientHex,
        derivation: derivation,
        payerKeyIndex: index,
      ),
      version: currentState.version + 1,
    );
  }

  static final Random _random = Random.secure();

  /// 16 random bytes, base64: a BRC-29 derivation prefix or suffix.
  static String _randomBase64() => base64.encode([for (var i = 0; i < 16; i++) _random.nextInt(256)]);

  // ---------------------------------------------------------------------------
  // Private keys
  // ---------------------------------------------------------------------------

  /// The private key [path] names.
  Future<dartsv.SVPrivateKey> privateKeyAt(String walletId, WalletState currentState, KeyPath path) =>
      switch (path) {
        HdKeyPath(:final derivationIndex, :final chain) =>
          privateKeyAtIndex(walletId, derivationIndex, currentState, chain: chain),
        Type42KeyPath(:final derivation) => type42ChildKey(walletId, currentState, derivation),
      };

  /// Retrieve the private key for a given address from secure storage
  /// Supports WIF, XPRIV, and HD wallets.
  ///
  /// [keyPath] lets a caller that holds the key's path (e.g. from the read
  /// model) supply it directly. When it is null the path is resolved from
  /// the aggregate's own address records, which is correct for every
  /// address the aggregate generated, discovered or recorded; unknown
  /// addresses default to the receive chain. A type-42 address the
  /// aggregate recorded is signed for with its record's key.
  Future<dartsv.SVPrivateKey> privateKeyForAddress(
    String address,
    String walletId,
    WalletState currentState, {
    KeyPath? keyPath,
  }) async {
    // A type-42 address is signed for with its recorded derivation, whatever
    // path the caller names: the aggregate's record is the authority.
    if (Type42Book.addressDerivations(currentState.metadata)[address] case final derivation?) {
      return type42ChildKey(walletId, currentState, derivation);
    }
    if (keyPath is Type42KeyPath) return type42ChildKey(walletId, currentState, keyPath.derivation);
    final hdPath = keyPath as HdKeyPath?;
    final derivationIndex = hdPath?.derivationIndex;
    final chain = hdPath?.chain;
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
      return privateKeyAtIndex(
        walletId,
        effectiveIndex,
        currentState,
        chain: chain ?? AddressBook.chainOf(currentState, address),
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
        derivedRoot = cryptoService.deriveAddress(hdPublicKey, 0,
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

  /// Get private key at a specific derivation index on [chain]
  /// (m/{chain}/{index}). Used for multisig signing where we know the exact
  /// path, and by [privateKeyForAddress] once it has resolved the path.
  Future<dartsv.SVPrivateKey> privateKeyAtIndex(
    String walletId,
    int derivationIndex,
    WalletState currentState, {
    AddressChain chain = AddressChain.receive,
  }) async {
    if (currentState.walletType == WalletType.wif) {
      // WIF wallet: single private key
      final wif = await secureStorage.getWIF(walletId);
      if (wif == null) {
        throw StateError('WIF not found for wallet $walletId');
      }
      return dartsv.SVPrivateKey.fromWIF(wif);
    } else if (currentState.walletType == WalletType.xpriv || currentState.walletType == WalletType.hd) {
      final hdPrivateKey = await _hdPrivateKey(walletId, currentState);
      return await cryptoService.derivePrivateKey(hdPrivateKey, derivationIndex, chain: chain);
    } else {
      throw StateError('Unsupported wallet type: ${currentState.walletType}');
    }
  }
}
