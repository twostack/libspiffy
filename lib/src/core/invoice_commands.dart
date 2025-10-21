import 'package:eventador/eventador.dart';

/// Base class for all invoice commands
abstract class InvoiceCommand extends Command {
  final String invoiceId;
  
  InvoiceCommand({
    required this.invoiceId,
  });
}

/// Command to create a new invoice
class CreateInvoiceCommand extends InvoiceCommand {
  final String walletId;
  final List<String> addresses;  // Pre-generated addresses from wallet
  final BigInt amount;
  final String? description;
  final Duration? expiresIn;
  final Map<String, dynamic>? invoiceMetadata;
  
  CreateInvoiceCommand({
    required String invoiceId,
    required this.walletId,
    required this.addresses,
    required this.amount,
    this.description,
    this.expiresIn,
    this.invoiceMetadata,
  }) : super(invoiceId: invoiceId);
}

/// Command to mark an invoice as paid
class MarkInvoicePaidCommand extends InvoiceCommand {
  final String txid;
  final BigInt amountReceived;
  final List<String> addressesPaidTo;
  final DateTime? paidAt;
  
  MarkInvoicePaidCommand({
    required String invoiceId,
    required this.txid,
    required this.amountReceived,
    required this.addressesPaidTo,
    this.paidAt,
  }) : super(invoiceId: invoiceId);
}

/// Command to cancel an invoice
class CancelInvoiceCommand extends InvoiceCommand {
  final String? reason;
  
  CancelInvoiceCommand({
    required String invoiceId,
    this.reason,
  }) : super(invoiceId: invoiceId);
}

/// Command to expire an invoice
class ExpireInvoiceCommand extends InvoiceCommand {
  ExpireInvoiceCommand({
    required String invoiceId,
  }) : super(invoiceId: invoiceId);
}

/// Command to check invoice status
class CheckInvoiceStatusCommand extends InvoiceCommand {
  CheckInvoiceStatusCommand({
    required String invoiceId,
  }) : super(invoiceId: invoiceId);
}

