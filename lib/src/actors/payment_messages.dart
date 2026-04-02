import 'dart:typed_data';
import 'package:dactor/dactor.dart';
import '../models/invoice_output_spec.dart';

/// Request to pay an invoice with BEEF-formatted transaction
///
/// This message triggers automatic UTXO selection, transaction building,
/// ancestor chain collection, and BEEF package construction.
class PayInvoiceMessage implements Message {
  /// Payer's wallet ID
  final String walletId;

  /// Invoice identifier for correlation
  final String invoiceId;

  /// Legacy: Payment addresses from invoice (P2PKH only)
  final List<String> addresses;

  /// Legacy: Total amount to pay in satoshis
  final BigInt amount;

  /// Structured output specifications (P2PKH, P2MS, etc.)
  /// When provided, this takes precedence over addresses/amount
  final List<InvoiceOutputSpec>? outputs;

  /// Optional change address (auto-generated if null)
  final String? changeAddress;

  /// Optional payment metadata for correlation
  final Map<String, dynamic>? paymentMetadata;

  /// Fee estimate in satoshis (defaults to 1000 sats if not specified)
  final BigInt? feeEstimateSats;

  PayInvoiceMessage({
    required this.walletId,
    required this.invoiceId,
    required this.addresses,
    required this.amount,
    this.outputs,
    this.changeAddress,
    this.paymentMetadata,
    this.feeEstimateSats,
  });

  /// Get effective total amount to pay
  BigInt get effectiveAmount {
    if (outputs != null && outputs!.isNotEmpty) {
      return outputs!.fold(BigInt.zero, (sum, o) => sum + o.amount);
    }
    return amount;
  }

  @override
  String get correlationId => 'pay-invoice-$invoiceId-${DateTime.now().millisecondsSinceEpoch}';

  @override
  Map<String, dynamic> get metadata => {
        'walletId': walletId,
        'invoiceId': invoiceId,
        'amount': effectiveAmount.toString(),
        ...?paymentMetadata,
      };

  @override
  ActorRef? get replyTo => null;

  @override
  DateTime get timestamp => DateTime.now();
}

/// Response with BEEF package ready to send to receiver
/// 
/// Contains serialized BEEF with payment transaction, ancestor transactions,
/// merkle proofs, and block headers for SPV validation.
class BEEFPaymentResponse implements Message {
  /// Invoice being paid
  final String invoiceId;
  
  /// Serialized BEEF ready to send to receiver
  final Uint8List beefBytes;
  
  /// Transaction ID of the payment
  final String txid;
  
  /// Total amount paid in satoshis
  final BigInt amountPaid;
  
  /// Change amount returned to payer in satoshis
  final BigInt changeAmount;
  
  /// Number of ancestor transactions included in BEEF
  final int ancestorCount;
  
  /// Whether payment creation succeeded
  final bool success;
  
  /// Error message if payment failed
  final String? error;

  /// Witness transaction ID (null if no paired witness).
  final String? witnessTxid;

  /// Serialized BEEF for the witness transaction (null if no paired witness).
  final Uint8List? witnessBeefBytes;

  BEEFPaymentResponse({
    required this.invoiceId,
    required this.beefBytes,
    required this.txid,
    required this.amountPaid,
    required this.changeAmount,
    required this.ancestorCount,
    required this.success,
    this.error,
    this.witnessTxid,
    this.witnessBeefBytes,
  });

  /// Constructor for error responses
  BEEFPaymentResponse.error({
    required this.invoiceId,
    required this.error,
  })  : beefBytes = Uint8List(0),
        txid = '',
        amountPaid = BigInt.zero,
        changeAmount = BigInt.zero,
        ancestorCount = 0,
        success = false,
        witnessTxid = null,
        witnessBeefBytes = null;

  @override
  String get correlationId => 'beef-payment-response-$invoiceId';

  @override
  Map<String, dynamic> get metadata => {
    'invoiceId': invoiceId,
    'success': success,
    'txid': txid,
    'ancestorCount': ancestorCount,
  };

  @override
  ActorRef? get replyTo => null;

  @override
  DateTime get timestamp => DateTime.now();
}

/// Internal message forwarded to PaymentCoordinatorActor for funding provisioning.
class ProvisionFundingMessage implements Message {
  final String walletId;
  final String pluginId;
  final Map<String, dynamic> pluginParams;

  ProvisionFundingMessage({
    required this.walletId,
    required this.pluginId,
    required this.pluginParams,
  });

  @override
  String get correlationId => 'provision-funding-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'pluginId': pluginId};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

/// Response from PaymentCoordinatorActor after funding provisioning.
class ProvisionFundingResponse implements Message {
  final String walletId;
  final int transactionCount;
  final int earmarkCount;
  final bool success;
  final String? error;

  ProvisionFundingResponse({
    required this.walletId,
    required this.transactionCount,
    required this.earmarkCount,
    required this.success,
    this.error,
  });

  ProvisionFundingResponse.error({
    required this.walletId,
    required this.error,
  })  : transactionCount = 0,
        earmarkCount = 0,
        success = false;

  @override
  String get correlationId => 'provision-funding-response-$walletId';
  @override
  Map<String, dynamic> get metadata => {'walletId': walletId, 'success': success};
  @override
  ActorRef? get replyTo => null;
  @override
  DateTime get timestamp => DateTime.now();
}

