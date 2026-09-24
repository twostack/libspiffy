/// zvj part 2 (libspiffy-zvj): SPVActor picked each proven transaction's
/// BUMP by counting the proven transactions before it (the k-th proven
/// transaction was assumed to use bumps[k]) instead of reading the BEEF's
/// bumpIndex. BEEFs built by this library happen to list BUMPs in that
/// order; a BRC-62 BEEF from anyone else may not, and then every proof was
/// checked against the header of the wrong block.
///
/// Fixture: two real mined testnet transactions (G at 1239645, G2 at
/// 1701169) with their real proofs and headers; the payment spends outputs
/// of both with the key that owns them, so script checks run on real data.
import 'dart:async';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart';
import 'package:dartsv/dartsv.dart' as dartsv;
import 'package:libspiffy/src/actors/spv_actor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';
import 'package:libspiffy/src/utils/beef.dart';
import 'package:libspiffy/src/utils/bump.dart';
import 'package:test/test.dart';

import '../spv/testnet_proof_fixture.dart';
import 'wallet_ownership_stub.dart';

const _xpriv =
    'tprv8ZgxMBicQKsPeMiDjtXBGAyFY1wEMGgomjwf54ZmiZfKTNYvVdBa6GqWUwnvtHm6NKVkQkhCKxaobd9JPxNEXgDfVgJ5RNHJ3ivogSG3V1R';

void main() {
  final key = dartsv.HDPrivateKey.fromXpriv(_xpriv).deriveChildNumber(0).deriveChildNumber(0).privateKey;
  final address = key.publicKey.toAddress(dartsv.NetworkType.TEST);
  final lock = dartsv.P2PKHLockBuilder.fromAddress(address);

  dartsv.Transaction spend(List<(dartsv.Transaction, int)> inputs, int sats) {
    final builder = dartsv.TransactionBuilder();
    for (final (parent, vout) in inputs) {
      final out = parent.outputs[vout];
      builder.spendFromOutpointWithSigner(
        dartsv.DefaultTransactionSigner(
            dartsv.SighashType.SIGHASH_ALL.value | dartsv.SighashType.SIGHASH_FORKID.value, key),
        dartsv.TransactionOutpoint(parent.id, vout, out.satoshis, out.script),
        dartsv.TransactionInput.MAX_SEQ_NUMBER,
        dartsv.P2PKHUnlockBuilder(key.publicKey),
      );
    }
    builder.spendToLockBuilder(lock, BigInt.from(sats));
    builder.withOption(dartsv.TransactionOption.DISABLE_DUST_OUTPUTS);
    return builder.build(false);
  }

  Uint8List bytes(String txHex) => Uint8List.fromList(hex.decode(txHex));

  late LocalActorSystem system;
  late InMemoryWalletStorage storage;
  late ActorRef spv;
  late dartsv.Transaction g, g2;

  setUp(() async {
    g = dartsv.Transaction.fromHex(kFixtureTxHex);
    g2 = dartsv.Transaction.fromHex(kFixture2TxHex);
    storage = InMemoryWalletStorage();
    await storage.storeBlockHeader(fixtureHeader(), kFixtureHeight);
    await storage.storeBlockHeader(fixture2Header(), kFixture2Height);
    system = LocalActorSystem(ActorSystemConfig());
    // Wallet w owns the address the fixtures pay: a transaction that pays
    // none of its addresses is not received for it (bead libspiffy-m8qu).
    final sink = await system.spawn('sink', () => _Sink({address.toBase58()}));
    spv = await system.spawn(
        'spv', () => SPVActor(walletManager: sink, invoiceCoordinator: sink, storage: storage));
  });

  tearDown(() => system.shutdown());

  Future<SPVValidationResult> receive(String txid, BEEF beef) async {
    final done = Completer<SPVValidationResult>();
    final receiver = await system.spawn('receiver-${DateTime.now().microsecondsSinceEpoch}', () => _Receiver(done));
    spv.tell(
      ReceiveTransactionMessage(transactionId: txid, beef: beef, fromCounterparty: 'alice', targetWalletId: 'w'),
      sender: receiver,
    );
    return done.future.timeout(const Duration(seconds: 10));
  }

  // BUMPs listed in the opposite order to the proven transactions:
  // G (tx 0) uses bumps[1], G2 (tx 1) uses bumps[0].
  final reversedBumps = [BUMP.fromHex(fixture2BumpHex()), fixtureBump()];

  test('an unproven payment whose ancestors use BUMPs in a different order validates', () async {
    final pay = spend([(g, 1), (g2, 0)], 399000000);
    final beef = BEEF.create(
      bumps: reversedBumps,
      txs: [bytes(kFixtureTxHex), bytes(kFixture2TxHex), bytes(pay.serialize())],
      hasMerkle: [true, true, false],
      bumpIndex: [1, 0],
    );
    expect(beef.validate(), isTrue);

    final result = await receive(pay.id, beef);
    expect(result.isValid, isTrue, reason: result.validationError);
  });

  test('a proven transaction is checked against, and recorded with, its own BUMP', () async {
    final beef = BEEF.create(
      bumps: reversedBumps,
      txs: [bytes(kFixtureTxHex), bytes(kFixture2TxHex)],
      hasMerkle: [true, true],
      bumpIndex: [1, 0],
    );

    final result = await receive(kFixture2Txid, beef);
    expect(result.isValid, isTrue, reason: result.validationError);
    expect(result.transactionData!['blockHeight'], equals(kFixture2Height));
    expect(result.transactionData!['bumpProof'], equals(fixture2BumpHex()));

    final first = await receive(kFixtureTxid, beef);
    expect(first.isValid, isTrue, reason: first.validationError);
    expect(first.transactionData!['blockHeight'], equals(kFixtureHeight));
  });
}

/// Wallet manager and invoice coordinator stand-in; answers SPVActor's
/// ownership query (every wallet exists and owns nothing).
class _Sink extends WalletOwnershipStub {
  _Sink(Set<String> owned) : super({'w': owned});
}

class _Receiver extends Actor {
  final Completer<SPVValidationResult> done;
  _Receiver(this.done);

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is SPVValidationResult && !done.isCompleted) done.complete(message);
  }
}
