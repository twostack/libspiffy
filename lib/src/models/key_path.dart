/// Where a wallet key comes from: a path of its HD tree, or a type-42
/// (BRC-42) derivation from its anchor key (spv-understanding.md, "Payment
/// modes").
library;

import 'package:dartsv/dartsv.dart' as dartsv;

import 'address_chain.dart';

/// A payment destination a payer derived from the payee's anchor key with
/// BRC-42 (bead libspiffy-zxkd): the payer's public key [senderPublicKey]
/// (compressed, hex) and the [invoiceNumber] the two agreed.
///
/// With the anchor private key a, the payee's wallet derives the
/// destination `C = A + t·G` and its spend key `c = a + t`, where
/// `t = HMAC-SHA256(ECDH(a, B), invoiceNumber)` ([Type42]). This record is
/// what the wallet keeps for such an address, and all it keeps: the child
/// private key is derived when a spend is signed and never stored, because
/// the payer knows t, and c with t gives away a.
class Type42Derivation {
  /// The payer's public key B, compressed (33 bytes), lower-case hex.
  final String senderPublicKey;
  final String invoiceNumber;

  /// Throws [ArgumentError] unless [senderPublicKey] is a compressed point
  /// on secp256k1 and [invoiceNumber] is 1 to [maxInvoiceNumberLength]
  /// characters. The key is stored as it is re-encoded, so one key has one
  /// spelling.
  factory Type42Derivation({required String senderPublicKey, required String invoiceNumber}) {
    if (invoiceNumber.isEmpty || invoiceNumber.length > maxInvoiceNumberLength) {
      throw ArgumentError.value(
          invoiceNumber, 'invoiceNumber', 'must be 1 to $maxInvoiceNumberLength characters');
    }
    return Type42Derivation._(publicKeyHex(senderPublicKey, 'senderPublicKey'), invoiceNumber);
  }

  const Type42Derivation._(this.senderPublicKey, this.invoiceNumber);

  /// The longest invoice number taken: BRC-43's 800-character key ID behind
  /// the security level and a 400-character protocol name.
  static const int maxInvoiceNumberLength = 1203;

  /// BRC-29's protocol ID: the invoice number of a BRC-29 payment is
  /// `2-3241645161d8-<derivationPrefix> <derivationSuffix>` (BRC-43
  /// security level 2).
  static const String brc29Protocol = '3241645161d8';

  /// The BRC-29 invoice number for [derivationPrefix] and
  /// [derivationSuffix], as go-sdk's key deriver spells it.
  static String brc29InvoiceNumber(String derivationPrefix, String derivationSuffix) =>
      '2-$brc29Protocol-$derivationPrefix $derivationSuffix';

  /// [hex] as a compressed public key, re-encoded in lower-case hex. Throws
  /// [ArgumentError] naming [name] when it is not a compressed point on
  /// secp256k1: the payer's and the anchor key are taken only in the one
  /// encoding that is hashed into the shared secret.
  static String publicKeyHex(String hex, String name) {
    if (hex.length != 66 || !(hex.startsWith('02') || hex.startsWith('03'))) {
      throw ArgumentError.value(hex, name, 'must be a compressed public key (33 bytes, hex)');
    }
    try {
      return dartsv.SVPublicKey.fromHex(hex).toHex().toLowerCase();
    } catch (e) {
      throw ArgumentError.value(hex, name, 'is not a point on secp256k1: $e');
    }
  }

  Map<String, String> toMap() => {'senderPublicKey': senderPublicKey, 'invoiceNumber': invoiceNumber};

  /// Reads [toMap]'s output; null for anything else (a snapshot's record
  /// may come back as an untyped map).
  static Type42Derivation? fromMap(Object? map) {
    if (map is! Map) return null;
    final sender = map['senderPublicKey'];
    final invoice = map['invoiceNumber'];
    if (sender is! String || invoice is! String) return null;
    return Type42Derivation._(sender, invoice);
  }

  @override
  bool operator ==(Object other) =>
      other is Type42Derivation && other.senderPublicKey == senderPublicKey && other.invoiceNumber == invoiceNumber;

  @override
  int get hashCode => Object.hash(senderPublicKey, invoiceNumber);

  @override
  String toString() => 'type-42($senderPublicKey, $invoiceNumber)';
}

/// A type-42 destination the wallet derived as a payer (bead
/// libspiffy-zxkd): [address] pays the recipient whose anchor key is
/// [recipientPublicKey], and [derivation] (the wallet's payer key B at
/// `m/3'/1'/{payerKeyIndex}'` and the invoice number) is what the recipient
/// derives it from, so it is the hand-off that goes with the payment.
class Type42Destination {
  final String address;
  final String recipientPublicKey;
  final Type42Derivation derivation;
  final int payerKeyIndex;

  const Type42Destination({
    required this.address,
    required this.recipientPublicKey,
    required this.derivation,
    required this.payerKeyIndex,
  });

  Map<String, Object> toMap() => {
        'address': address,
        'recipientPublicKey': recipientPublicKey,
        ...derivation.toMap(),
        'payerKeyIndex': payerKeyIndex,
      };

  /// Reads [toMap]'s output; null for anything else.
  static Type42Destination? fromMap(Object? map) {
    if (map is! Map) return null;
    final derivation = Type42Derivation.fromMap(map);
    final address = map['address'];
    final recipient = map['recipientPublicKey'];
    final index = map['payerKeyIndex'];
    if (derivation == null || address is! String || recipient is! String || index is! int) return null;
    return Type42Destination(
        address: address, recipientPublicKey: recipient, derivation: derivation, payerKeyIndex: index);
  }

  @override
  bool operator ==(Object other) =>
      other is Type42Destination &&
      other.address == address &&
      other.recipientPublicKey == recipientPublicKey &&
      other.derivation == derivation &&
      other.payerKeyIndex == payerKeyIndex;

  @override
  int get hashCode => Object.hash(address, recipientPublicKey, derivation, payerKeyIndex);

  @override
  String toString() => '$address <- $derivation';
}

/// Where the key of a wallet address comes from; the wallet aggregate
/// derives the private key from it when it signs.
sealed class KeyPath {
  const KeyPath();

  /// The derivation index of an HD path; null for a type-42 path, which has
  /// none.
  int? get derivationIndex;
}

/// The key at `m/{chain}/{derivationIndex}` of the wallet's HD tree. Ignored
/// by the aggregate for a single-key (WIF) wallet, whose one key signs.
final class HdKeyPath extends KeyPath {
  @override
  final int derivationIndex;
  final AddressChain chain;

  const HdKeyPath(this.derivationIndex, {this.chain = AddressChain.receive});

  @override
  bool operator ==(Object other) =>
      other is HdKeyPath && other.derivationIndex == derivationIndex && other.chain == chain;

  @override
  int get hashCode => Object.hash(derivationIndex, chain);

  @override
  String toString() => 'm/${chain.index}/$derivationIndex';
}

/// The type-42 child of the wallet's anchor key for [derivation].
final class Type42KeyPath extends KeyPath {
  final Type42Derivation derivation;

  const Type42KeyPath(this.derivation);

  @override
  int? get derivationIndex => null;

  @override
  bool operator ==(Object other) => other is Type42KeyPath && other.derivation == derivation;

  @override
  int get hashCode => derivation.hashCode;

  @override
  String toString() => derivation.toString();
}
