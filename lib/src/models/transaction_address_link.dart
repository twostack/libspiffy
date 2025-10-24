/// Represents a link between a transaction and an address
class TransactionAddressLink {
  final String address;
  final String direction; // 'input' or 'output'
  final BigInt amount;
  final int? vout;
  final int? vin;

  TransactionAddressLink({
    required this.address,
    required this.direction,
    required this.amount,
    this.vout,
    this.vin,
  });
}

/// Contains all addresses involved in a transaction
class TransactionAddresses {
  final List<TransactionAddressLink> inputs;
  final List<TransactionAddressLink> outputs;

  TransactionAddresses({
    required this.inputs,
    required this.outputs,
  });

  List<String> get inputAddresses => inputs.map((l) => l.address).toList();
  List<String> get outputAddresses => outputs.map((l) => l.address).toList();
  List<String> get allAddresses => [...inputAddresses, ...outputAddresses];
}

