/// What a running wallet import is doing, for an app to say in its own
/// words (bead spiffyvault-9ae.5). The progress message stays English, for
/// logs.
enum ImportStep {
  /// Creating or opening the wallet.
  opening,

  /// Finding the wallet's used addresses and their transactions.
  discovering,

  /// Fetching the transactions found.
  fetching,

  /// Recording the fetched transactions in the wallet.
  recording,

  /// Settling the wallet's coins and balance.
  finalizing,

  /// The import is done.
  done;

  /// The step named [name], or null.
  static ImportStep? byName(String? name) {
    for (final step in values) {
      if (step.name == name) return step;
    }
    return null;
  }
}
