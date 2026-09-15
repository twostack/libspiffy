import 'package:eventador/eventador.dart';
import '../actors/invoice_messages.dart';
import 'invoice_output_spec.dart';
import 'persistent_map.dart';

/// Represents the current state of an invoice aggregate (write model)
///
/// This is the internal state of the InvoiceAggregate, rebuilt from events.
/// It's separate from InvoiceReadModel which is optimized for queries.
///
/// Immutable (bead libspiffy-mmb): every field is final, [addresses] and
/// [outputs] are unmodifiable lists of unmodifiable values, and [metadata] is
/// unmodifiable (nested maps and lists included). Applying an event produces
/// a new state ([copyWith]); the collections a constructor is given are
/// copied, not shared.
class InvoiceState extends State {
  final String invoiceId;

  final bool isCreated;
  final String walletId;
  final List<String> addresses;
  final BigInt amount;

  /// Structured output specifications (P2PKH, P2MS, etc.)
  /// When present, this takes precedence over addresses/amount for payment construction
  final List<InvoiceOutputSpec>? outputs;

  final String? description;
  final InvoiceStatus status;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? paidAt;
  final String? paymentTxid;
  final BigInt? amountReceived;
  final Map<String, dynamic> metadata;

  @override
  final int version;

  @override
  final DateTime lastModified;

  InvoiceState({
    required this.invoiceId,
    required this.isCreated,
    required this.walletId,
    required List<String> addresses,
    required this.amount,
    List<InvoiceOutputSpec>? outputs,
    this.description,
    required this.status,
    required this.createdAt,
    this.expiresAt,
    this.paidAt,
    this.paymentTxid,
    this.amountReceived,
    required Map<String, dynamic> metadata,
    this.version = 0,
    DateTime? lastModified,
  })  : addresses = List<String>.unmodifiable(addresses),
        outputs = outputs == null ? null : List<InvoiceOutputSpec>.unmodifiable(outputs.map(_frozenOutput)),
        metadata = freezeMap(metadata),
        lastModified = lastModified ?? DateTime.now(),
        super(version: version, lastModified: lastModified ?? DateTime.now());

  /// A state whose collections are already frozen, shared as they are.
  InvoiceState._shared({
    required this.invoiceId,
    required this.isCreated,
    required this.walletId,
    required this.addresses,
    required this.amount,
    required this.outputs,
    required this.description,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    required this.paidAt,
    required this.paymentTxid,
    required this.amountReceived,
    required this.metadata,
    required this.version,
    required this.lastModified,
  }) : super(version: version, lastModified: lastModified);

  /// [output] with unmodifiable collections that no caller shares.
  static InvoiceOutputSpec _frozenOutput(InvoiceOutputSpec output) => switch (output) {
        final P2MSOutputSpec o when o.runtimeType == P2MSOutputSpec => P2MSOutputSpec(
            publicKeys: List<String>.unmodifiable(o.publicKeys),
            threshold: o.threshold,
            amount: o.amount,
            label: o.label,
          ),
        final OPReturnOutputSpec o when o.runtimeType == OPReturnOutputSpec => OPReturnOutputSpec(
            dataChunks: List<List<int>>.unmodifiable([for (final chunk in o.dataChunks) List<int>.unmodifiable(chunk)]),
            separateOutputs: o.separateOutputs,
            label: o.label,
          ),
        final PluginOutputSpec o when o.runtimeType == PluginOutputSpec => PluginOutputSpec(
            pluginId: o.pluginId,
            pluginScriptType: o.pluginScriptType,
            params: unmodifiableDeepCopy(o.params) as Map<String, dynamic>,
            amount: o.amount,
            label: o.label,
          ),
        _ => output,
      };

  /// Create an empty invoice state (before creation)
  factory InvoiceState.empty(String invoiceId) {
    final now = DateTime.now();
    return InvoiceState(
      invoiceId: invoiceId,
      isCreated: false,
      walletId: '',
      addresses: const [],
      amount: BigInt.zero,
      description: null,
      status: InvoiceStatus.pending,
      createdAt: now,
      expiresAt: null,
      paidAt: null,
      paymentTxid: null,
      amountReceived: null,
      metadata: const {},
      version: 0,
      lastModified: now,
    );
  }

  /// Check if invoice is expired
  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  /// Check if invoice can be paid
  bool get canBePaid {
    return status == InvoiceStatus.pending && !isExpired;
  }

  /// Check if invoice can be cancelled
  bool get canBeCancelled {
    return status == InvoiceStatus.pending;
  }

  /// Get total amount from outputs or fallback to amount field
  BigInt get totalAmount =>
      outputs?.fold<BigInt>(BigInt.zero, (sum, o) => sum + o.amount) ?? amount;

  /// Get all P2PKH addresses from outputs or fallback to addresses field
  List<String> get allAddresses =>
      outputs
          ?.whereType<P2PKHOutputSpec>()
          .map((o) => o.address)
          .toList() ??
      addresses;

  static const Object _unset = Object();

  /// A copy of this state with the given fields replaced. The nullable
  /// fields take an explicit null. Collections given are copied; the ones
  /// not given are shared (they are immutable).
  @override
  InvoiceState copyWith({
    int? version,
    DateTime? lastModified,
    bool? isCreated,
    String? walletId,
    List<String>? addresses,
    BigInt? amount,
    Object? outputs = _unset,
    Object? description = _unset,
    InvoiceStatus? status,
    DateTime? createdAt,
    Object? expiresAt = _unset,
    Object? paidAt = _unset,
    Object? paymentTxid = _unset,
    Object? amountReceived = _unset,
    Map<String, dynamic>? metadata,
  }) {
    return InvoiceState._shared(
      invoiceId: invoiceId,
      isCreated: isCreated ?? this.isCreated,
      walletId: walletId ?? this.walletId,
      addresses: addresses == null ? this.addresses : List<String>.unmodifiable(addresses),
      amount: amount ?? this.amount,
      outputs: identical(outputs, _unset)
          ? this.outputs
          : outputs == null
              ? null
              : List<InvoiceOutputSpec>.unmodifiable((outputs as List<InvoiceOutputSpec>).map(_frozenOutput)),
      description: identical(description, _unset) ? this.description : description as String?,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: identical(expiresAt, _unset) ? this.expiresAt : expiresAt as DateTime?,
      paidAt: identical(paidAt, _unset) ? this.paidAt : paidAt as DateTime?,
      paymentTxid: identical(paymentTxid, _unset) ? this.paymentTxid : paymentTxid as String?,
      amountReceived: identical(amountReceived, _unset) ? this.amountReceived : amountReceived as BigInt?,
      metadata: metadata == null ? this.metadata : freezeMap(metadata),
      version: version ?? this.version,
      lastModified: lastModified ?? this.lastModified,
    );
  }
}
