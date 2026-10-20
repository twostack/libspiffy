import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:test/test.dart';

void main() {
  group('SpiffyErrorCode', () {
    test('a coded error answers its own code', () {
      expect(SpiffyErrorCode.of(SpiffyStateError(SpiffyErrorCode.insufficientFunds, 'Insufficient funds')),
          SpiffyErrorCode.insufficientFunds);
      expect(SpiffyErrorCode.of(SpiffyArgumentError.value(SpiffyErrorCode.addressMainnet, '1abc', 'address')),
          SpiffyErrorCode.addressMainnet);
    });

    test('a coded StateError is still a StateError, and an ArgumentError an ArgumentError', () {
      expect(SpiffyStateError(SpiffyErrorCode.notInitialized, 'not initialized'), isA<StateError>());
      expect(SpiffyArgumentError.value(SpiffyErrorCode.addressInvalid, 'x', 'address'), isA<ArgumentError>());
      expect(SpiffyStateError(SpiffyErrorCode.timedOut, 'slow').message, 'slow');
    });

    test('data source, socket and timeout errors have codes by their type', () {
      expect(SpiffyErrorCode.of(DataSourceException('down')), SpiffyErrorCode.chainServiceUnreachable);
      expect(SpiffyErrorCode.of(const SocketException('refused')), SpiffyErrorCode.chainServiceUnreachable);
      expect(SpiffyErrorCode.of(TimeoutException('slow')), SpiffyErrorCode.timedOut);
      expect(SpiffyErrorCode.of(StateError('anything else')), isNull);
      expect(SpiffyErrorCode.of(null), isNull);
    });

    test("a coordinator failure has its reply's code", () {
      final reply = PaymentReadyEvent(
        invoiceId: 'i',
        beefBytes: Uint8List(0),
        txid: '',
        amountPaid: BigInt.zero,
        changeAmount: BigInt.zero,
        ancestorCount: 0,
        success: false,
        error: 'Insufficient funds',
        errorCode: SpiffyErrorCode.insufficientFunds,
      );
      expect(SpiffyErrorCode.of(CoordinatorFailure('r', reply.failure!, event: reply)),
          SpiffyErrorCode.insufficientFunds);
      expect(SpiffyErrorCode.of(const CoordinatorFailure('r', 'stopped')), isNull);
    });

    test('a code crosses by its name; an unknown name reads as null', () {
      for (final code in SpiffyErrorCode.values) {
        expect(SpiffyErrorCode.byName(code.name), code);
      }
      expect(SpiffyErrorCode.byName('somethingNewer'), isNull);
      expect(ImportStep.byName(ImportStep.recording.name), ImportStep.recording);
      expect(ImportStep.byName(null), isNull);
    });
  });
}
