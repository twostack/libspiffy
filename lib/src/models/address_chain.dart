/// The chain of the HD tree an address of the wallet is derived on: the key
/// path is `m/{chain.index}/{derivationIndex}` under the wallet's account key.
library;

/// Which chain of the wallet's HD tree an address is on.
///
/// * [receive] (`m/0/i`): addresses the key holder issues to be paid —
///   invoices, the root address.
/// * [change] (`m/1/i`): change outputs of the wallet's own transactions.
/// * [delegated] (`m/2/i`): addresses issued from the wallet's extended
///   public key by a party that holds no private key — a service that keeps
///   an xpub wallet for an offline payee and answers invoice requests on
///   its behalf (spv-understanding.md, "Payment modes"). The payee's own
///   wallet never issues on this chain; it records a delegated address when
///   the service hands a payment to it over, and signs for it like any
///   other. Keeping the two issuers on separate chains is what stops them
///   handing out the same address.
///
/// [index] is the BIP32 child number of the chain, and so part of every key
/// path; never reorder the values.
enum AddressChain {
  receive,
  change,
  delegated;

  /// The chain with BIP32 child number [index].
  static AddressChain fromIndex(int index) {
    if (index < 0 || index >= values.length) {
      throw ArgumentError.value(index, 'index', 'not an address chain (0 receive, 1 change, 2 delegated)');
    }
    return values[index];
  }

  /// The chain a record stores: [chain] when it has one, else the
  /// change/receive flag every record written before the delegated chain
  /// existed carries (`isChange`). Absent both, the receive chain, as every
  /// journal written before the chain was recorded at all.
  static AddressChain fromRecord({Object? chain, Object? isChange}) {
    if (chain is int) return fromIndex(chain);
    if (chain is String) return AddressChain.values.byName(chain);
    return isChange == true ? AddressChain.change : AddressChain.receive;
  }
}
