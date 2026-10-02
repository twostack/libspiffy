/// A BRC-100 key operation for a wallet to run with a BRC-42 child of one of
/// its anchor keys, and its result.
library;

import 'persistent_map.dart';

/// The BRC-100 key methods a wallet runs on an anchor key's children.
enum Brc100KeyOperation {
  /// `getPublicKey`: the child public key ([Brc100KeyResult.publicKey]).
  getPublicKey,

  /// `createSignature` (BRC-3) over `SHA-256(data)`
  /// ([Brc100KeyResult.bytes], DER).
  createSignature,

  /// `verifySignature`: whether [Brc100KeyRequest.proof] signs `data`
  /// ([Brc100KeyResult.valid]).
  verifySignature,

  /// `encrypt` (BRC-2): `IV ‖ ciphertext ‖ tag` ([Brc100KeyResult.bytes]).
  encrypt,

  /// `decrypt` (BRC-2): the plaintext ([Brc100KeyResult.bytes]).
  decrypt,

  /// `createHmac` ([Brc100KeyResult.bytes]).
  createHmac,

  /// `verifyHmac`: whether [Brc100KeyRequest.proof] is the HMAC of `data`
  /// ([Brc100KeyResult.valid]).
  verifyHmac,
}

/// One BRC-100 key operation: [operation] with the child key named by the
/// BRC-43 protocol ([securityLevel], [protocolName]), [keyID] and
/// [counterparty] (`self`, `anyone` or a compressed public key in hex).
///
/// [counterparty] null takes BRC-100's default for the operation: `anyone`
/// for a signature, `self` for everything else. [forSelf] is for
/// `getPublicKey` and `verifySignature` only. [proof] is the signature or
/// HMAC a verify operation checks.
class Brc100KeyRequest {
  final Brc100KeyOperation operation;
  final int securityLevel;
  final String protocolName;
  final String keyID;
  final String? counterparty;
  final bool forSelf;
  final List<int> data;
  final List<int>? proof;

  Brc100KeyRequest({
    required this.operation,
    required this.securityLevel,
    required this.protocolName,
    required this.keyID,
    this.counterparty,
    this.forSelf = false,
    List<int> data = const [],
    List<int>? proof,
  })  : data = frozenList(data),
        proof = frozenListOrNull(proof);

  @override
  String toString() => '${operation.name}([$securityLevel, $protocolName], $keyID, ${counterparty ?? 'default'})';
}

/// What a [Brc100KeyRequest] gave: [publicKey] for `getPublicKey`, [bytes]
/// for a signature, a ciphertext, a plaintext or an HMAC, [valid] for a
/// verification. [identityKey] is the anchor public key the operation ran
/// under, which is the BRC-100 identity key when the anchor is the
/// identity.
class Brc100KeyResult {
  final String identityKey;
  final String? publicKey;
  final List<int>? bytes;
  final bool? valid;

  Brc100KeyResult({required this.identityKey, this.publicKey, List<int>? bytes, this.valid})
      : bytes = frozenListOrNull(bytes);
}
