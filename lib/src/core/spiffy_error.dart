import 'dart:async';
import 'dart:io';

import '../services/blockchain_data_source.dart';

/// Why an operation failed, for an app to say in its own words (bead
/// spiffyvault-9ae.5). The English `error` text next to it stays, for logs.
///
/// A code crosses isolates and messages by [name]; [byName] reads it back
/// and answers null for a name this version does not know.
enum SpiffyErrorCode {
  /// The wallet's spendable coins do not cover the amount and its fee.
  insufficientFunds,

  /// The text to pay is not an address.
  addressInvalid,

  /// The address to pay is a mainnet address and the wallet is not on
  /// mainnet.
  addressMainnet,

  /// The address to pay is a testnet address and the wallet is on mainnet.
  addressTestnet,

  /// ARC's policy fee rate could not be read, so nothing was built.
  feeRateUnavailable,

  /// The coins chosen are reserved by another payment.
  coinsInUse,

  /// A blockchain data source or the network could not be reached.
  chainServiceUnreachable,

  /// The wallet or the actor system has not started.
  notInitialized,

  /// An actor or a service did not answer in time.
  timedOut,

  /// The user cancelled it.
  cancelled;

  /// The code named [name], or null.
  static SpiffyErrorCode? byName(String? name) {
    for (final code in values) {
      if (code.name == name) return code;
    }
    return null;
  }

  /// The code of [error]: its own for a [SpiffyCoded] error, else what its
  /// type says (a data source or socket error, a timeout), else null.
  static SpiffyErrorCode? of(Object? error) => switch (error) {
        SpiffyCoded(:final spiffyCode?) => spiffyCode,
        DataSourceException() || SocketException() || HttpException() => chainServiceUnreachable,
        TimeoutException() => timedOut,
        _ => null,
      };
}

/// An error that carries a [SpiffyErrorCode], or null when this one has
/// none (a `CoordinatorFailure` whose reply gave no code).
abstract interface class SpiffyCoded {
  SpiffyErrorCode? get spiffyCode;
}

/// A [StateError] with a code: what libspiffy throws where it threw a
/// [StateError] before, so `on StateError` still catches it.
class SpiffyStateError extends StateError implements SpiffyCoded {
  @override
  final SpiffyErrorCode spiffyCode;

  SpiffyStateError(this.spiffyCode, super.message);
}

/// An [ArgumentError] with a code, for a value refused as an argument.
class SpiffyArgumentError extends ArgumentError implements SpiffyCoded {
  @override
  final SpiffyErrorCode spiffyCode;

  SpiffyArgumentError.value(this.spiffyCode, super.value, [super.name, super.message]) : super.value();
}
