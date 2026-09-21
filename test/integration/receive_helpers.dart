/// Handing a counterparty's BEEF to a wallet, the way an app does it.
///
/// There are two ways in (beads libspiffy-xggs, libspiffy-ckr4), and which
/// one applies is a property of the BEEF, not a choice: a BEEF carrying the
/// proof of its own subject is an import (`ImportTransactionCommand`,
/// answered by `TransactionImportedEvent`); one without is a payment
/// (`ValidateBEEFCommand`, answered by `BEEFValidationResultEvent`, and
/// submitted to ARC once it validates).
library;

import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:libspiffy/coordinator.dart' as coord;
import 'package:libspiffy/libspiffy.dart';

/// The coordinator's first answer to a receive, whichever way it went in.
typedef Received = ({bool success, String? error, bool awaitingHeader});

/// Hands [beefHex] (subject [subjectTxid]) to [walletId] and returns the
/// coordinator's first answer about [subjectTxid].
Future<Received> receiveBeef(
  LibSpiffyActorSystem system,
  String walletId,
  String beefHex,
  String subjectTxid, {
  String? fromCounterparty,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final proven = BEEF.parse(Uint8List.fromList(hex.decode(beefHex))).carriesProofOf(subjectTxid);
  if (proven) {
    final imported = system.coordinatorEvents!
        .where((e) => e is coord.TransactionImportedEvent && e.transactionId == subjectTxid)
        .cast<coord.TransactionImportedEvent>()
        .first
        .timeout(timeout);
    system.coordinator.tell(coord.ImportTransactionCommand(
      walletId: walletId,
      beef: hex.decode(beefHex),
      fromCounterparty: fromCounterparty,
    ));
    final e = await imported;
    return (success: e.success, error: e.error, awaitingHeader: false);
  }
  final answered = system.coordinatorEvents!
      .where((e) => e is coord.BEEFValidationResultEvent && e.txid == subjectTxid)
      .cast<coord.BEEFValidationResultEvent>()
      .first
      .timeout(timeout);
  system.coordinator.tell(coord.ValidateBEEFCommand(
    walletId: walletId,
    beefHex: beefHex,
    fromCounterparty: fromCounterparty,
  ));
  final e = await answered;
  return (success: e.valid, error: e.error, awaitingHeader: e.awaitingHeader);
}
