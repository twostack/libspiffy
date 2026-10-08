/// How a payment hides which of its outputs is the payer's change and
/// which coins funded it (bead libspiffy-o7a4). Off unless a caller asks:
/// `PayInvoiceCommand(privacy: null)` builds the payment as before.
///
/// Every random choice it makes (the order coins are tried in, how many
/// change parts, their amounts) is drawn from a generator seeded with the
/// invoice id, so paying the same invoice again over the same coins signs
/// the same transaction (bead libspiffy-4r0).
class PaymentPrivacy {
  /// Change is paid as up to this many outputs, each to its own fresh change
  /// address, with Benford-distributed amounts. 1 pays one change output.
  final int maxChangeParts;

  /// Draw the number of change parts from 2 to [maxChangeParts] for each
  /// payment, rather than always [maxChangeParts].
  final bool randomChangeParts;

  /// No change part is smaller than this; less change makes fewer parts.
  final int minChangePartSats;

  /// Fund the payment from coins smaller than it, coins of one parent
  /// transaction together (already linked to each other on chain), rather
  /// than from the largest coins. Falls back to the largest coins when the
  /// smaller ones cannot pay within [maxInputs].
  final bool spreadInputs;

  /// The most inputs a spread selection takes. Coins spent together show
  /// they have one owner, so this bounds how many it links.
  final int maxInputs;

  const PaymentPrivacy({
    this.maxChangeParts = 1,
    this.randomChangeParts = false,
    this.minChangePartSats = 1000,
    this.spreadInputs = false,
    this.maxInputs = 6,
  })  : assert(maxChangeParts >= 1),
        assert(minChangePartSats >= 1),
        assert(maxInputs >= 1);

  Map<String, dynamic> toMap() => {
        'maxChangeParts': maxChangeParts,
        'randomChangeParts': randomChangeParts,
        'minChangePartSats': minChangePartSats,
        'spreadInputs': spreadInputs,
        'maxInputs': maxInputs,
      };

  factory PaymentPrivacy.fromMap(Map<String, dynamic> map) => PaymentPrivacy(
        maxChangeParts: map['maxChangeParts'] as int? ?? 1,
        randomChangeParts: map['randomChangeParts'] as bool? ?? false,
        minChangePartSats: map['minChangePartSats'] as int? ?? 1000,
        spreadInputs: map['spreadInputs'] as bool? ?? false,
        maxInputs: map['maxInputs'] as int? ?? 6,
      );

  @override
  String toString() => 'PaymentPrivacy(${toMap()})';
}
