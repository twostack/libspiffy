/// Where a wallet key comes from: a path of its HD tree, or a type-42
/// (BRC-42) derivation from its anchor key (spv-understanding.md, "Payment
/// modes").
library;

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart' as dartsv;

import 'address_chain.dart';

/// The type-42 (BRC-42) derivation of a payment destination (beads
/// libspiffy-zxkd, libspiffy-fdal): the payee's anchor key
/// [anchorPublicKey] A, the [anchorContext] it was issued for, the payer's
/// key [senderPublicKey] B, and the [invoiceNumber] the two agreed. This is
/// the hand-off a payer gives with the payment.
///
/// A wallet has one anchor per context (`WalletKeys.anchorPath`), so
/// identities that share a wallet publish unrelated anchors. With the
/// anchor private key a, the payee's wallet derives the destination
/// `C = A + t·G` and its spend key `c = a + t`, where
/// `t = HMAC-SHA256(ECDH(a, B), invoiceNumber)` ([Type42]). This record is
/// what the wallet keeps for such an address, and all it keeps: the child
/// private key is derived when a spend is signed and never stored, because
/// the payer knows t, and c with t gives away a.
///
/// [anchorContext] is null in a hand-off whose payer did not have it; the
/// payee's wallet then finds the context among the anchors it issued. The
/// record the payee's wallet keeps always has it.
class Type42Derivation {
  /// The payee's anchor key A, compressed (33 bytes), lower-case hex.
  final String anchorPublicKey;

  /// The opaque bytes the anchor was issued for, lower-case hex.
  final String? anchorContext;

  /// The payer's public key B, compressed (33 bytes), lower-case hex.
  final String senderPublicKey;
  final String invoiceNumber;

  /// Throws [ArgumentError] unless both keys are compressed points on
  /// secp256k1, [anchorContext] (when given) is 1 to [maxAnchorContextLength]
  /// bytes, and [invoiceNumber] is 1 to [maxInvoiceNumberLength] characters.
  /// Keys and context are stored as they are re-encoded, so each has one
  /// spelling.
  factory Type42Derivation({
    required String anchorPublicKey,
    List<int>? anchorContext,
    required String senderPublicKey,
    required String invoiceNumber,
  }) {
    if (invoiceNumber.isEmpty || invoiceNumber.length > maxInvoiceNumberLength) {
      throw ArgumentError.value(
          invoiceNumber, 'invoiceNumber', 'must be 1 to $maxInvoiceNumberLength characters');
    }
    return Type42Derivation._(
      publicKeyHex(anchorPublicKey, 'anchorPublicKey'),
      anchorContext == null ? null : anchorContextHex(anchorContext),
      publicKeyHex(senderPublicKey, 'senderPublicKey'),
      invoiceNumber,
    );
  }

  const Type42Derivation._(this.anchorPublicKey, this.anchorContext, this.senderPublicKey, this.invoiceNumber);

  /// This derivation with its anchor's context [contextHex] (as
  /// [anchorContextHex] spells it).
  Type42Derivation withAnchorContext(String contextHex) =>
      Type42Derivation._(anchorPublicKey, contextHex, senderPublicKey, invoiceNumber);

  /// The longest invoice number taken: BRC-43's 800-character key ID behind
  /// the security level and a 400-character protocol name.
  static const int maxInvoiceNumberLength = 1203;

  /// The longest anchor context taken, in bytes: room for an identity key,
  /// an epoch and more, without letting a context grow every record.
  static const int maxAnchorContextLength = 256;

  /// BRC-29's protocol ID: the invoice number of a BRC-29 payment is
  /// `2-3241645161d8-<derivationPrefix> <derivationSuffix>` (BRC-43
  /// security level 2).
  static const String brc29Protocol = '3241645161d8';

  /// The BRC-29 invoice number for [derivationPrefix] and
  /// [derivationSuffix], as go-sdk's key deriver spells it.
  static String brc29InvoiceNumber(String derivationPrefix, String derivationSuffix) =>
      '2-$brc29Protocol-$derivationPrefix $derivationSuffix';

  /// [context] in lower-case hex. Throws [ArgumentError] when it is empty or
  /// longer than [maxAnchorContextLength] bytes: an anchor is never issued
  /// for no context, because every caller that forgot one would share it.
  static String anchorContextHex(List<int> context) {
    if (context.isEmpty || context.length > maxAnchorContextLength) {
      throw ArgumentError.value(
          context.length, 'anchorContext', 'must be 1 to $maxAnchorContextLength bytes');
    }
    return hex.encode(context);
  }

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

  Map<String, String> toMap() => {
        'anchorPublicKey': anchorPublicKey,
        if (anchorContext != null) 'anchorContext': anchorContext!,
        'senderPublicKey': senderPublicKey,
        'invoiceNumber': invoiceNumber,
      };

  /// Reads [toMap]'s output; null for anything else (a snapshot's record
  /// may come back as an untyped map).
  static Type42Derivation? fromMap(Object? map) {
    if (map is! Map) return null;
    final anchor = map['anchorPublicKey'];
    final context = map['anchorContext'];
    final sender = map['senderPublicKey'];
    final invoice = map['invoiceNumber'];
    if (anchor is! String || (context != null && context is! String) || sender is! String || invoice is! String) {
      return null;
    }
    return Type42Derivation._(anchor, context as String?, sender, invoice);
  }

  @override
  bool operator ==(Object other) =>
      other is Type42Derivation &&
      other.anchorPublicKey == anchorPublicKey &&
      other.anchorContext == anchorContext &&
      other.senderPublicKey == senderPublicKey &&
      other.invoiceNumber == invoiceNumber;

  @override
  int get hashCode => Object.hash(anchorPublicKey, anchorContext, senderPublicKey, invoiceNumber);

  @override
  String toString() => 'type-42($anchorPublicKey${anchorContext == null ? '' : '/$anchorContext'}, '
      '$senderPublicKey, $invoiceNumber)';
}

/// A type-42 destination the wallet derived as a payer (bead
/// libspiffy-zxkd): [address] pays the holder of the anchor key
/// [Type42Derivation.anchorPublicKey], and [derivation] (with the wallet's
/// payer key B at `m/3'/1'/{payerKeyIndex}'`) is what the recipient derives
/// it from, so it is the hand-off that goes with the payment.
class Type42Destination {
  final String address;
  final Type42Derivation derivation;
  final int payerKeyIndex;

  const Type42Destination({required this.address, required this.derivation, required this.payerKeyIndex});

  Map<String, Object> toMap() => {'address': address, ...derivation.toMap(), 'payerKeyIndex': payerKeyIndex};

  /// Reads [toMap]'s output; null for anything else.
  static Type42Destination? fromMap(Object? map) {
    if (map is! Map) return null;
    final derivation = Type42Derivation.fromMap(map);
    final address = map['address'];
    final index = map['payerKeyIndex'];
    if (derivation == null || address is! String || index is! int) return null;
    return Type42Destination(address: address, derivation: derivation, payerKeyIndex: index);
  }

  @override
  bool operator ==(Object other) =>
      other is Type42Destination &&
      other.address == address &&
      other.derivation == derivation &&
      other.payerKeyIndex == payerKeyIndex;

  @override
  int get hashCode => Object.hash(address, derivation, payerKeyIndex);

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
