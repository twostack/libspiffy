import 'package:eventador/eventador.dart';
import '../models/invoice_output_spec.dart';

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

  /// Legacy: Pre-generated addresses from wallet (P2PKH only)
  final List<String> addresses;

  /// Legacy: Total amount for the invoice
  final BigInt amount;

  /// Structured output specifications (P2PKH, P2MS, etc.)
  /// When present, this takes precedence over addresses/amount
  final List<InvoiceOutputSpec>? outputs;

  final String? description;
  final Duration? expiresIn;
  final Map<String, dynamic>? invoiceMetadata;

  CreateInvoiceCommand({
    required String invoiceId,
    required this.walletId,
    required this.addresses,
    required this.amount,
    this.outputs,
    this.description,
    this.expiresIn,
    this.invoiceMetadata,
  }) : super(invoiceId: invoiceId);

  /// Get effective outputs - either explicit outputs or computed from addresses/amount
  List<InvoiceOutputSpec> get effectiveOutputs {
    if (outputs != null && outputs!.isNotEmpty) {
      return outputs!;
    }
    // Convert legacy addresses/amount to P2PKH outputs
    if (addresses.isEmpty) return [];
    final amountPerAddress = amount ~/ BigInt.from(addresses.length);
    return addresses
        .map((addr) => P2PKHOutputSpec(address: addr, amount: amountPerAddress))
        .toList();
  }

  /// Get effective total amount
  BigInt get effectiveAmount {
    if (outputs != null && outputs!.isNotEmpty) {
      return outputs!.fold(BigInt.zero, (sum, o) => sum + o.amount);
    }
    return amount;
  }
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

