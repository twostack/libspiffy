import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:logging/logging.dart';

import '../core/wallet_commands.dart';
import '../models/key_path.dart';
import '../models/bitcoin_utxo.dart';
import '../storage/read_model_storage.dart';
import '../utils/network_name.dart';
import '../core/wallet_output_ownership.dart' show BareMultisigScript;
import 'wallet_messages.dart';

/// A signing request the wallet aggregate rejected, did not answer, or
/// answered with something that does not match the request.
class AggregateSigningException implements Exception {
  final String message;
  AggregateSigningException(this.message);

  @override
  String toString() => message;
}

/// Gets transactions signed by the wallet aggregate, the only component that
/// holds key material (audit A-H8).
///
/// Coordinators build transactions; this client asks the aggregate (through
/// the wallet manager) to sign them, taking each key's derivation path from
/// the read model's [AddressMetadata]. No private key, seed, or extended
/// private key is read or derived here.
///
/// Aggregate commands and replies used:
/// * [SignTransactionCommand] -> [TransactionSignedResponse]: signs every
///   P2PKH input of a wallet transaction and verifies each input with the
///   script interpreter before replying.
/// * [SignInputCommand] -> [InputSignedResponse]: returns the signature for
///   one input against a caller-supplied subscript and amount with the key at
///   an explicit path, and that key's public key (no event is journaled).
///   The per-input signing primitive for plugin-built transactions, and how
///   a key's public key is learned. (This used to go through
///   `SignMultisigTransactionCommand` and recover the public key from a
///   throwaway signature; that command is now left to payment channels.)
class AggregateSigningClient {
  static final _log = Logger('AggregateSigningClient');

  /// SIGHASH_ALL | SIGHASH_FORKID.
  static final int sigHashAllForkId =
      dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value;

  static int _receiverCounter = 0;

  final ActorSystem _system;
  final ActorRef _walletManager;
  final ReadModelStorage _storage;
  final Duration _replyTimeout;

  AggregateSigningClient({
    required ActorSystem system,
    required ActorRef walletManager,
    required ReadModelStorage storage,
    required Duration replyTimeout,
  })  : _system = system,
        _walletManager = walletManager,
        _storage = storage,
        _replyTimeout = replyTimeout;

  // ---------------------------------------------------------------------------
  // Derivation paths
  // ---------------------------------------------------------------------------

  /// The read model's derivation path for [address], or null when the read
  /// model does not know the address.
  ///
  /// Throws [AggregateSigningException] for a watch address row (bead
  /// libspiffy-vsap): the wallet holds no key for it, and the row has no
  /// derivation index, which read as m/0/0 (the root key's path). The
  /// aggregate refuses such an input too; this refuses before asking it.
  Future<KeyPath?> pathForAddress(String walletId, String address) async {
    final metadata = await _storage.getAddressMetadata(walletId, address);
    if (metadata == null) return null;
    return metadata.keyPath ??
        (throw AggregateSigningException('Address $address of wallet $walletId is a watch address: '
            'the wallet holds no key for it and has no signing path'));
  }

  /// The path of the wallet key at [address], or null when the read model
  /// does not know the address or it is a watch address (no key there).
  /// For signing that falls back to the aggregate's own key records: a
  /// bare multisig UTXO attributed to a watch address can still be the
  /// wallet's to sign with another of its keys.
  Future<KeyPath?> _keyPathOrNull(String walletId, String address) async =>
      (await _storage.getAddressMetadata(walletId, address))?.keyPath;

  // ---------------------------------------------------------------------------
  // Whole-transaction signing (P2PKH wallet UTXOs)
  // ---------------------------------------------------------------------------

  /// Signs [unsignedTxHex], whose inputs spend [utxos] in order, and returns
  /// the signed transaction hex.
  ///
  /// Derivation indices and chains come from the read model. When the read
  /// model lacks an address, no paths are sent and the aggregate resolves
  /// every key from its own address records.
  Future<String> signTransaction({
    required String walletId,
    required String transactionId,
    required String unsignedTxHex,
    required List<BitcoinUtxo> utxos,
  }) async {
    final paths = <KeyPath>[];
    for (final utxo in utxos) {
      final path = await _keyPathOrNull(walletId, utxo.address);
      if (path == null) {
        _log.info('No read-model key path for ${utxo.address}; '
            'the aggregate resolves the signing keys for $transactionId');
        paths.clear();
        break;
      }
      paths.add(path);
    }

    final reply = await _request<TransactionSignedResponse>(
      walletId,
      SignTransactionCommand(
        walletId: walletId,
        transactionId: transactionId,
        rawTransaction: unsignedTxHex,
        utxoKeys: utxos.map((u) => u.key).toList(),
        publicKeys: const [],
        addresses: utxos.map((u) => u.address).toList(),
        keyPaths: paths,
      ),
      'signing $transactionId',
    );
    if (!reply.success) {
      throw AggregateSigningException(
          'Wallet refused to sign $transactionId: ${reply.error ?? 'unknown error'}');
    }
    return reply.signedHex;
  }

  // ---------------------------------------------------------------------------
  // Per-input signing
  // ---------------------------------------------------------------------------

  /// The aggregate's signature for input [inputIndex] of [txHex], spending an
  /// output locked by [subscript] worth [satoshis], with the key at [path].
  Future<dartsv.SVSignature> signInput({
    required String walletId,
    required String txHex,
    required int inputIndex,
    required dartsv.SVScript subscript,
    required BigInt satoshis,
    required KeyPath path,
    int? sighashType,
  }) async =>
      (await _signInputWithKey(
        walletId: walletId,
        txHex: txHex,
        inputIndex: inputIndex,
        subscript: subscript,
        satoshis: satoshis,
        path: path,
        sighashType: sighashType ?? sigHashAllForkId,
      ))
          .signature;

  /// Sends [SignInputCommand] and returns the signature with the public key
  /// the aggregate reports for the signing key. The signature is checked to
  /// come from that key over this input's sighash.
  Future<({dartsv.SVSignature signature, dartsv.SVPublicKey publicKey})> _signInputWithKey({
    required String walletId,
    required String txHex,
    required int inputIndex,
    required dartsv.SVScript subscript,
    required BigInt satoshis,
    required KeyPath path,
    required int sighashType,
  }) async {
    final reply = await _request<InputSignedResponse>(
      walletId,
      SignInputCommand(
        walletId: walletId,
        rawTransaction: txHex,
        inputIndex: inputIndex,
        subscriptHex: subscript.toHex(),
        satoshis: satoshis,
        keyPath: path,
        sighashType: sighashType,
      ),
      'signing input $inputIndex',
    );
    if (!reply.success || reply.signatureHex.isEmpty || reply.publicKeyHex.isEmpty) {
      throw AggregateSigningException(
          'Wallet refused to sign input $inputIndex: ${reply.error ?? 'no signature'}');
    }
    final signature = dartsv.SVSignature.fromTxFormat(reply.signatureHex);
    final publicKey = dartsv.SVPublicKey.fromHex(reply.publicKeyHex);
    final digest = sighashDigest(
        dartsv.Transaction.fromHex(txHex), sighashType, inputIndex, subscript, satoshis);
    final signer = publicKey.getEncoded(true);
    if (!recoverPublicKeys(signature, digest).any((k) => k.getEncoded(true) == signer)) {
      throw AggregateSigningException(
          'The signature for input $inputIndex does not come from the reported key');
    }
    return (signature: signature, publicKey: publicKey);
  }

  /// The public key the wallet controls [address] with.
  ///
  /// Taken from the aggregate's [InputSignedResponse] for a throwaway spend of
  /// [address] with the key at the address's path; it must hash to
  /// [address]. Throws [AggregateSigningException] when the key at that path
  /// does not control the address.
  Future<dartsv.SVPublicKey> publicKeyForAddress(String walletId, String address,
      {KeyPath? path}) async {
    final effectivePath =
        path ?? await pathForAddress(walletId, address) ?? const HdKeyPath(0);
    final lockingScript =
        dartsv.P2PKHLockBuilder.fromAddress(dartsv.Address.fromBase58(address)).getScriptPubkey();
    final probe = dartsv.Transaction()
      ..version = 1
      ..nLockTime = 0;
    probe.inputs.add(dartsv.TransactionInput('00' * 32, 0, dartsv.TransactionInput.MAX_SEQ_NUMBER));
    probe.outputs.add(dartsv.TransactionOutput(BigInt.zero, dartsv.SVScript.fromHex('006a')));

    final signed = await _signInputWithKey(
      walletId: walletId,
      txHex: probe.serialize(),
      inputIndex: 0,
      subscript: lockingScript,
      satoshis: BigInt.one,
      path: effectivePath,
      sighashType: sigHashAllForkId,
    );
    if (_hash160Hex(signed.publicKey) != dartsv.Address.fromBase58(address).pubkeyHash160) {
      throw AggregateSigningException(
          'The wallet key at $effectivePath does not control $address');
    }
    return signed.publicKey;
  }

  // ---------------------------------------------------------------------------
  // Plugin builds
  // ---------------------------------------------------------------------------

  /// Runs [build] with a [dartsv.TransactionSigner] whose signatures come from
  /// the wallet aggregate.
  ///
  /// dartsv signs synchronously inside `TransactionBuilder.build()`, while the
  /// aggregate answers asynchronously, so the build runs in passes. A pass
  /// signs with the signatures already obtained and records every other
  /// sighash it meets (using a placeholder signature so the build can
  /// continue). Those inputs are then signed by the aggregate and the build is
  /// repeated. ECDSA signatures here are deterministic (RFC 6979), so later
  /// passes reproduce earlier transactions exactly; a build chaining
  /// transactions needs one pass per level plus a final pass in which every
  /// sighash is already signed. Only that final pass's result is returned, so
  /// [build] must not have side effects.
  ///
  /// Each input's key is resolved from its locking script: any 20-byte push
  /// (public key hash) or 33/65-byte push (public key) that names an address
  /// in the read model selects that address's path, and the returned
  /// signature must come from that key. Scripts naming no wallet address are
  /// signed with [fallbackPath].
  ///
  /// `signPreimage` is not supported: the aggregate has no command that signs
  /// an arbitrary digest.
  Future<T> buildWithSigner<T>({
    required String walletId,
    required KeyPath fallbackPath,
    required Future<T> Function(dartsv.TransactionSigner signer) build,
    int maxPasses = 8,
  }) async {
    final signatures = <String, dartsv.SVSignature>{};
    final network = await _walletNetwork(walletId);
    for (var pass = 1; pass <= maxPasses; pass++) {
      final signer = _AggregateBackedSigner(sigHashAllForkId, signatures);
      T result;
      try {
        result = await build(signer);
      } catch (e) {
        // A placeholder signature may legitimately break a build; only a
        // failure with nothing left to sign is final.
        if (signer.pending.isEmpty) rethrow;
        _log.fine('Signing pass $pass failed with ${signer.pending.length} '
            'unsigned inputs outstanding: $e');
        await _signPending(walletId, network, fallbackPath, signer.pending, signatures);
        continue;
      }
      if (signer.pending.isEmpty) return result;
      await _signPending(walletId, network, fallbackPath, signer.pending, signatures);
    }
    throw AggregateSigningException(
        'Transaction signing did not settle after $maxPasses passes');
  }

  Future<void> _signPending(
    String walletId,
    dartsv.NetworkType network,
    KeyPath fallbackPath,
    Map<String, _PendingInput> pending,
    Map<String, dartsv.SVSignature> signatures,
  ) async {
    for (final entry in pending.entries) {
      final input = entry.value;
      // A single signature (P2PKH, P2PK, 1-of-n) comes from the one wallet
      // key the script names; signature i of an m-of-n input from its i-th.
      final multisig = BareMultisigScript.parse(input.subscript);
      final owner = multisig != null && multisig.threshold > 1
          ? await _multisigSigner(walletId, network, multisig, input.signatureIndex, input.inputIndex)
          : await _ownerOf(walletId, network, input.subscript);
      final signed = await _signInputWithKey(
        walletId: walletId,
        txHex: input.txHex,
        inputIndex: input.inputIndex,
        subscript: input.subscript,
        satoshis: input.satoshis,
        path: owner?.path ?? fallbackPath,
        sighashType: input.sighashType,
      );
      if (owner != null && _hash160Hex(signed.publicKey) != owner.pubkeyHash) {
        throw AggregateSigningException('The wallet key at ${owner.path} does not own '
            'the output spent by input ${input.inputIndex}');
      }
      signatures[entry.key] = signed.signature;
    }
  }

  /// The wallet key that makes signature [index] of an input spending the
  /// bare multisig [multisig]: the [index]-th of the script's keys the
  /// wallet holds, in script order, which is the order `OP_CHECKMULTISIG`
  /// reads signatures in (bead libspiffy-0nfk; the aggregate's own
  /// `_multisigSigningKeys` picks the same keys). Throws when the wallet
  /// holds fewer of the keys than the script requires.
  Future<({KeyPath path, String pubkeyHash})> _multisigSigner(String walletId, dartsv.NetworkType network,
      BareMultisigScript multisig, int index, int inputIndex) async {
    final owners = <({KeyPath path, String pubkeyHash})>[];
    for (final keyHex in multisig.publicKeysHex) {
      if (owners.length == multisig.threshold) break;
      final hashHex = hex.encode(dartsv.hash160(hex.decode(keyHex)));
      final path = await _keyPathOrNull(walletId, dartsv.Address.fromPubkeyHash(hashHex, network).toBase58());
      if (path != null) owners.add((path: path, pubkeyHash: hashHex));
    }
    if (owners.length < multisig.threshold) {
      throw AggregateSigningException('Input $inputIndex spends a ${multisig.threshold}-of-'
          '${multisig.publicKeysHex.length} multisig output; the wallet holds ${owners.length} of the keys it needs');
    }
    return owners[index];
  }

  /// The wallet address named by [script], if any.
  Future<({KeyPath path, String pubkeyHash})?> _ownerOf(
      String walletId, dartsv.NetworkType network, dartsv.SVScript script) async {
    final seen = <String>{};
    for (final chunk in script.chunks) {
      final data = chunk.buf;
      if (data == null) continue;
      final String hashHex;
      if (data.length == 20) {
        hashHex = hex.encode(data);
      } else if (data.length == 33 || data.length == 65) {
        hashHex = hex.encode(dartsv.hash160(data));
      } else {
        continue;
      }
      if (!seen.add(hashHex)) continue;
      final address = dartsv.Address.fromPubkeyHash(hashHex, network).toBase58();
      final path = await _keyPathOrNull(walletId, address);
      if (path != null) return (path: path, pubkeyHash: hashHex);
    }
    return null;
  }

  Future<dartsv.NetworkType> _walletNetwork(String walletId) async {
    final wallet = await _storage.getWallet(walletId);
    return NetworkName.toDartsv((wallet?['network'] ?? wallet?['networkType']) as String?);
  }

  // ---------------------------------------------------------------------------
  // Transport
  // ---------------------------------------------------------------------------

  /// Sends [command] through the wallet manager and waits (at most the reply
  /// timeout) for the aggregate's reply of type [R].
  Future<R> _request<R>(String walletId, WalletCommand command, String what) async {
    final completer = Completer<R>();
    final receiver = await _system.spawn(
      'aggregate-signing-${_receiverCounter++}-${DateTime.now().microsecondsSinceEpoch}',
      () => _ReplyReceiver<R>(completer),
    );
    try {
      _walletManager.tell(WalletCommandMessage(walletId, command), sender: receiver);
      return await completer.future.timeout(
        _replyTimeout,
        onTimeout: () => throw AggregateSigningException(
            'No reply from the wallet when $what within $_replyTimeout'),
      );
    } finally {
      await _system.stop(receiver);
    }
  }

  // ---------------------------------------------------------------------------
  // Signature helpers (public data only)
  // ---------------------------------------------------------------------------

  /// The digest an ECDSA signature for this input signs (dartsv byte order).
  static List<int> sighashDigest(dartsv.Transaction tx, int sighashType, int inputIndex,
      dartsv.SVScript subscript, BigInt satoshis) {
    final hash = dartsv.Sighash().hash(tx, sighashType, inputIndex, subscript, satoshis);
    return hex.decode(hash).reversed.toList();
  }

  /// Every public key that could have produced [signature] over [digest].
  static List<dartsv.SVPublicKey> recoverPublicKeys(
      dartsv.SVSignature signature, List<int> digest) {
    final r = _uint256(signature.r);
    final s = _uint256(signature.s);
    final keys = <dartsv.SVPublicKey>[];
    for (var i = 0; i < 4; i++) {
      try {
        keys.add(dartsv.SVSignature.fromCompact([27 + 4 + i, ...r, ...s], digest).publicKey);
      } catch (_) {
        // Not a valid recovery id for this signature.
      }
    }
    return keys;
  }

  static List<int> _uint256(BigInt value) =>
      hex.decode(value.toRadixString(16).padLeft(64, '0'));

  static String _hash160Hex(dartsv.SVPublicKey key) =>
      hex.encode(dartsv.hash160(hex.decode(key.getEncoded(true))));
}

class _PendingInput {
  final String txHex;
  final int inputIndex;
  final dartsv.SVScript subscript;
  final BigInt satoshis;
  final int sighashType;
  final List<int> digest;

  /// Which of the input's signatures this is: 0, or up to m - 1 for an
  /// m-of-n bare multisig input.
  final int signatureIndex;

  _PendingInput(this.txHex, this.inputIndex, this.subscript, this.satoshis, this.sighashType,
      this.digest, this.signatureIndex);
}

/// Signs with signatures the aggregate has already produced and records the
/// inputs it could not sign yet (see [AggregateSigningClient.buildWithSigner]).
class _AggregateBackedSigner extends dartsv.TransactionSigner {
  @override
  final int sigHashType;
  final Map<String, dartsv.SVSignature> _signatures;
  final Map<String, _PendingInput> pending = {};

  _AggregateBackedSigner(this.sigHashType, this._signatures);

  /// Well-formed stand-in so a pass can finish before the real signature is
  /// known. Never survives into a returned transaction.
  static dartsv.SVSignature _placeholder(int sigHashType) {
    final value = BigInt.parse('7f${'11' * 31}', radix: 16);
    return dartsv.SVSignature.fromECParams(value, value)..nhashtype = sigHashType;
  }

  @override
  dartsv.Transaction sign(
      dartsv.Transaction unsignedTxn, dartsv.TransactionOutput utxo, int inputIndex) {
    final digest = AggregateSigningClient.sighashDigest(
        unsignedTxn, sigHashType, inputIndex, utxo.script, utxo.satoshis);
    final builder = unsignedTxn.inputs[inputIndex].scriptBuilder;
    if (builder == null) {
      throw dartsv.TransactionException(
          'Trying to sign a Transaction Input that is missing a SignedUnlockBuilder');
    }

    // dartsv calls a signer once per input, so an m-of-n bare multisig input
    // gets all m of its signatures here, one per wallet key (bead
    // libspiffy-0nfk). Each is cached under its own index: keyed by the
    // digest alone, every one of them was the first key's signature, and no
    // input needing two signatures could be signed.
    final count = BareMultisigScript.parse(utxo.script)?.threshold ?? 1;
    for (var index = 0; index < count; index++) {
      final key = '$sigHashType:${hex.encode(digest)}${count == 1 ? '' : ':$index'}';
      var signature = _signatures[key];
      if (signature == null) {
        pending.putIfAbsent(
          key,
          () => _PendingInput(_withoutUnlockingScripts(unsignedTxn), inputIndex, utxo.script,
              utxo.satoshis, sigHashType, digest, index),
        );
        signature = _placeholder(sigHashType);
      }
      builder.signatures.add(signature);
    }
    return unsignedTxn;
  }

  @override
  dartsv.SVSignature signPreimage(Uint8List preImage) {
    throw UnsupportedError('signPreimage is not available: the wallet aggregate signs '
        'transaction inputs, not arbitrary digests');
  }

  /// The transaction with empty unlocking scripts: the sighash does not cover
  /// them, and plugin unlocking scripts can be large.
  static String _withoutUnlockingScripts(dartsv.Transaction tx) {
    final copy = dartsv.Transaction()
      ..version = tx.version
      ..nLockTime = tx.nLockTime;
    for (final input in tx.inputs) {
      copy.inputs.add(dartsv.TransactionInput(
          input.prevTxnId, input.prevTxnOutputIndex, input.sequenceNumber));
    }
    for (final output in tx.outputs) {
      copy.outputs.add(dartsv.TransactionOutput(output.satoshis, output.script));
    }
    return copy.serialize();
  }
}

/// Receives the aggregate's reply to one command. Also completes with an
/// error on the wallet manager's `{'error': ...}` reply (unknown wallet).
class _ReplyReceiver<R> extends Actor {
  final Completer<R> completer;

  _ReplyReceiver(this.completer);

  @override
  Future<void> onMessage(dynamic message) async {
    if (completer.isCompleted) return;
    final payload = message is LocalMessage ? message.payload : message;
    if (payload is R) {
      completer.complete(payload);
    } else if (payload is FailureResponse) {
      completer.completeError(AggregateSigningException(payload.error));
    }
  }
}
