/// BRC-100 key operations on a wallet's anchor key
/// ([Brc100KeyOperationCommand]): the anchor acts as BRC-100's root key, so
/// an anchor issued for an identity signs, encrypts and derives as that
/// identity, and never does any of it with a payment spend key.
///
/// Testnet only: ScriptTypeRegistry is a process-wide singleton pinned to
/// the first network it is built with.
library;

import 'dart:convert';

import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:test/test.dart';

import 'package:libspiffy/src/actors/libspiffy_actor_system.dart';
import 'package:libspiffy/src/core/bitcoin_wallet_aggregate.dart';
import 'package:libspiffy/src/core/wallet/wallet_keys.dart';
import 'package:libspiffy/src/core/wallet/type42_book.dart';
import 'package:libspiffy/src/core/wallet_commands.dart';
import 'package:libspiffy/src/core/wallet_events.dart';
import 'package:libspiffy/src/crypto/brc100_keys.dart';
import 'package:libspiffy/src/models/brc100_key_request.dart';
import 'package:libspiffy/src/models/key_path.dart';
import 'package:libspiffy/src/services/dartsv_crypto_service.dart';
import 'package:libspiffy/src/storage/in_memory_secure_storage.dart';
import 'package:libspiffy/src/utils/bip32.dart';

import '../actors/in_memory_event_store.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
final _identity = utf8.encode('brc100/identity');

void main() {
  final crypto = DartSVCryptoService();
  late InMemorySecureStorage secureStorage;
  late InMemoryEventStore store;
  late BitcoinWalletAggregate wallet;
  late WalletKeys keys;
  late dartsv.SVPrivateKey anchor;
  final peer = Brc100Keys(dartsv.SVPrivateKey.fromHex(
      '583755110a8c059de5cd81b8a04e1be884c46083ade3f779c1e022f6f89da94c', dartsv.NetworkType.TEST));

  setUpAll(LibSpiffyActorSystem.registerEventTypes);

  setUp(() async {
    secureStorage = InMemorySecureStorage();
    store = InMemoryEventStore();
    wallet = BitcoinWalletAggregate(
      aggregateId: 'w',
      aggregateType: 'BitcoinWallet',
      eventStore: store,
      cryptoService: crypto,
      secureStorage: secureStorage,
    );
    await wallet.preStart();
    await wallet.commandHandler(CreateWalletCommand(walletId: 'w', walletName: 'w', mnemonic: _mnemonic));
    keys = WalletKeys(cryptoService: crypto, secureStorage: secureStorage);
    final root = await crypto.mnemonicToHDPrivateKey(_mnemonic, network: dartsv.NetworkType.TEST);
    anchor = Bip32.derivePrivatePath(root, WalletKeys.anchorPath(_identity)).privateKey;
  });

  Future<Brc100KeyResult> run(Brc100KeyRequest request) => keys.brc100KeyOperation(
      wallet.currentState, Brc100KeyOperationCommand(walletId: 'w', anchorContext: _identity, request: request));

  test('the anchor is the root key: the identity key is the anchor, and what it signs and seals a peer checks '
      'and opens against that key', () async {
    final me = Brc100Counterparty.key(anchor.publicKey.toHex());
    final signed = await run(Brc100KeyRequest(
      operation: Brc100KeyOperation.createSignature,
      securityLevel: 2,
      protocolName: 'auth message signature',
      keyID: 'n1 n2',
      counterparty: peer.identityKey,
      data: [1, 2, 3],
    ));
    expect(signed.identityKey, anchor.publicKey.toHex().toLowerCase());
    expect(
        peer.verifySignature(Brc43Protocol.authMessageSignature, 'n1 n2', [1, 2, 3], signed.bytes!, counterparty: me),
        isTrue);

    final sealed = await run(Brc100KeyRequest(
      operation: Brc100KeyOperation.encrypt,
      securityLevel: 1,
      protocolName: 'messagebox',
      keyID: '1',
      counterparty: peer.identityKey,
      data: utf8.encode('hello'),
    ));
    expect(utf8.decode(peer.decrypt(Brc43Protocol.messageBox, '1', sealed.bytes!, counterparty: me)), 'hello');

    final fromPeer = peer.encrypt(Brc43Protocol.messageBox, '1', utf8.encode('back'), counterparty: me);
    final opened = await run(Brc100KeyRequest(
      operation: Brc100KeyOperation.decrypt,
      securityLevel: 1,
      protocolName: 'messagebox',
      keyID: '1',
      counterparty: peer.identityKey,
      data: fromPeer,
    ));
    expect(utf8.decode(opened.bytes!), 'back');
  });

  test('the BRC-29 public key a payer derives for the identity is the one the wallet derives for itself', () async {
    final payTo = peer.derivePublicKey(Brc43Protocol.brc29, 'p s', Brc100Counterparty.key(anchor.publicKey.toHex()));
    final own = await run(Brc100KeyRequest(
      operation: Brc100KeyOperation.getPublicKey,
      securityLevel: 2,
      protocolName: '3241645161d8',
      keyID: 'p s',
      counterparty: peer.identityKey,
      forSelf: true,
    ));
    expect(own.publicKey, payTo.toHex().toLowerCase());
  });

  test('nothing but a public key is given out for a BRC-29 key: those are payment spend keys', () async {
    for (final operation in Brc100KeyOperation.values.where((o) => o != Brc100KeyOperation.getPublicKey)) {
      await expectLater(
        run(Brc100KeyRequest(
          operation: operation,
          securityLevel: 2,
          protocolName: '3241645161d8',
          keyID: 'p s',
          counterparty: peer.identityKey,
          data: List.filled(32, 1),
        )),
        throwsA(isA<StateError>()),
        reason: operation.name,
      );
    }
  });

  test('nor for the key of any type-42 address the wallet recorded, whatever its protocol', () async {
    const invoice = '2-nodecast pay-abc';
    await wallet.commandHandler(IssueAnchorKeyCommand(walletId: 'w', anchorContext: _identity));
    await wallet.commandHandler(RecordType42AddressesCommand(walletId: 'w', derivations: [
      Type42Derivation(
        anchorPublicKey: anchor.publicKey.toHex(),
        anchorContext: _identity,
        senderPublicKey: peer.identityKey,
        invoiceNumber: invoice,
      ),
    ]));

    final request = Brc100KeyRequest(
      operation: Brc100KeyOperation.createSignature,
      securityLevel: 2,
      protocolName: 'nodecast pay',
      keyID: 'abc',
      counterparty: peer.identityKey,
      data: List.filled(32, 1),
    );
    await expectLater(run(request), throwsA(isA<StateError>()));

    final otherKey = Brc100KeyRequest(
      operation: Brc100KeyOperation.createSignature,
      securityLevel: 2,
      protocolName: 'nodecast pay',
      keyID: 'abd',
      counterparty: peer.identityKey,
      data: List.filled(32, 1),
    );
    expect((await run(otherKey)).bytes, isNotEmpty);
  });

  test('a malformed request is an ArgumentError', () async {
    await expectLater(
        run(Brc100KeyRequest(
            operation: Brc100KeyOperation.encrypt, securityLevel: 1, protocolName: 'app', keyID: '1')),
        throwsArgumentError);
    await expectLater(
        run(Brc100KeyRequest(
            operation: Brc100KeyOperation.encrypt,
            securityLevel: 1,
            protocolName: 'messagebox',
            keyID: '1',
            counterparty: 'nobody')),
        throwsArgumentError);
  });

  test('a payment made as the identity: the identity anchor is the payer key, the BRC-100 payee derives the same '
      'address from the BRC-29 key ID and our identity key, and no payer key is used up', () async {
    await wallet.commandHandler(DeriveType42DestinationCommand(
      walletId: 'w',
      anchorPublicKey: peer.identityKey,
      invoiceNumber: Type42Derivation.brc29InvoiceNumber('cHJlZml4', 'c3VmZml4'),
      payerAnchorContext: _identity,
    ));
    final destination =
        store.journal[wallet.persistenceId]!.whereType<Type42DestinationDerivedEvent>().single.destination;
    expect(destination.derivation.senderPublicKey, anchor.publicKey.toHex().toLowerCase());
    expect(destination.payerKeyIndex, isNull);
    expect(destination.payerAnchorContext, '6272633130302f6964656e74697479');
    expect(Type42Book.payerKeysUsed(wallet.currentState.metadata), 0);

    final payeeKey = peer.derivePrivateKey(
        Brc43Protocol.brc29, 'cHJlZml4 c3VmZml4', Brc100Counterparty.key(anchor.publicKey.toHex()));
    expect(destination.address, payeeKey.publicKey.toAddress(dartsv.NetworkType.TEST).toBase58());
  });

  test('a wallet does not pay its own anchor with that anchor', () async {
    await expectLater(
        keys.deriveType42Destination(
            wallet.currentState,
            DeriveType42DestinationCommand(
                walletId: 'w', anchorPublicKey: anchor.publicKey.toHex(), payerAnchorContext: _identity)),
        throwsStateError);
  });
}
