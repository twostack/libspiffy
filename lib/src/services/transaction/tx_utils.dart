


import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';

import '../../models/bitcoin_utxo.dart';
import '../../storage/wallet_storage.dart';
import 'builder/hodl_lockbuilder.dart';
import 'wallet_account.dart';

/*
The details for a method of locking up coins until a future date using a
specific custom BSV output locking script as defined in hodl_lockbuilder.dart
 */
class LockerDetails {
  String? scriptHex;
  int? lockUntil;
  String? pubkeyHash;
  int? blockheight;
  int? blockTime;
  int? amount;
  String? transactionId;
}



class TxUtils {

  final String _networkType;
  final WalletStorage? _storage;

  TxUtils(this._networkType, {WalletStorage? storage}) : _storage = storage;


  ///
  /// sendingAccount - Account that will be funding the transaction
  /// recipientAddress - base85 address of recipient
  /// amount - amount of satoshis to send to recipient
  ///
  Future<Transaction?> makePKHTransaction(WalletAccount? sendingAccount,
      List<TransactionOutpoint> fundingUtxos, String recipientAddress,
      int amount) async {
    if (sendingAccount != null) {
      var toAddress = Address.fromBase58(recipientAddress);
      var changeAddress = Address.fromBase58(sendingAccount.address());

      //build initial transaction
      var builder = new TransactionBuilder();

      //create funding inputs
      var privKey = sendingAccount.privateKey;
      if (privKey != null) {
        var signer = DefaultTransactionSigner( SighashType.SIGHASH_ALL.value | SighashType.SIGHASH_FORKID.value,   privKey);

        fundingUtxos.forEach((outpoint) {
          builder.spendFromOutpointWithSigner(
              signer,
              outpoint,
              TransactionInput.MAX_SEQ_NUMBER,
              P2PKHUnlockBuilder(privKey.publicKey)
          );
        });

        builder.spendToPKH(toAddress, BigInt.from(amount))
            .sendChangeToPKH(changeAddress)
            .withFeePerKb(100)
            .withOption(TransactionOption.DISABLE_DUST_OUTPUTS);

        var signedTx = builder.build(true); //skip txn sanity checks

        return signedTx;

        //verify that the signedTx correctly spends it's inputs

      }
    }


    return null;
  }

  Transaction? createUnlockingTxn(SVPrivateKey signingKey, LockerDetails lockDetails, String transactionHex) {
    // var signingKey = hdPrivateKey.deriveChildNumber(1).privateKey;
    var ownerAddress = Address.fromPublicKey(signingKey.publicKey, _networkType == "test" ? NetworkType.TEST : NetworkType.MAIN);
    var ownerPkh = ownerAddress.pubkeyHash160;

    var lockingTxn = Transaction.fromHex(transactionHex);

    var contractScript = lockingTxn.outputs[0].script;

    var lockedValue = BigInt.from(lockDetails.amount ?? 0);
    //assemble preimage >
    var (txSpendForPreimage, _) = _spendFromLocktimeTxn(signingKey, lockingTxn, ScriptBuilder().build(), lockedValue);
    var unlockHeight = (lockDetails.lockUntil ?? 0) + 1;
    txSpendForPreimage.nLockTime = unlockHeight;
    var sigHashType = SighashType.SIGHASH_ALL.value | SighashType.SIGHASH_FORKID.value;
    var hasher = Sighash();
    hasher.hash(txSpendForPreimage, sigHashType, 0, contractScript, lockedValue);
    var txCreditPreImage = hasher.preImage ?? Uint8List(0);
    //assemble preimage <

    var bobSpendingSig = DefaultTransactionSigner.signPreimageWithKey(signingKey, txCreditPreImage, sigHashType);

    //create scriptSig with pre-image data
    var scriptSig = ScriptBuilder()
        .addData(Uint8List.fromList(hex.decode(bobSpendingSig.toTxFormat())))
        .addData(Uint8List.fromList(hex.decode(signingKey.publicKey.toHex())))
        .addData(txCreditPreImage)
        .build();

    var (txSpend, _) = _spendFromLocktimeTxn(signingKey, lockingTxn, scriptSig, lockedValue);
    txSpend.nLockTime = unlockHeight;

    //setup the flags needed for script verification
    var scriptFlags = Set<VerifyFlag>()..addAll([VerifyFlag.SIGHASH_FORKID, VerifyFlag.UTXO_AFTER_GENESIS]);

    var interp = Interpreter();
    // if (kDebugMode) {
    // }
    try {
      interp.correctlySpends(scriptSig, contractScript, txSpend, 0, scriptFlags, Coin.ofSat(lockedValue));
    } on Exception catch (ex) {
      return null;
    }
    return txSpend;
  }


  Future<(Transaction?, List<TransactionOutpoint>)> buildLockingTransaction(
      SVPrivateKey signingKey, String duration, String amount) async {
    try {
      var ownerAddress = Address.fromPublicKey(signingKey.publicKey, NetworkType.TEST);
      var ownerPkh = ownerAddress.pubkeyHash160;
      var lockBuilder = HodlLockBuilder(hex.decode(ownerPkh), BigInt.parse(duration));
      // var txn = buildLockingTransaction(lockBuilder.getScriptPubkey(), lockBuilder.lockHeight!);

      //
      List<TransactionOutpoint> fundingOutpoints = await getFundingInputs(signingKey.publicKey, ownerAddress, BigInt.parse(amount) + BigInt.from(10)); //buffer additional ten sats to cover fees

      var sighashType = SighashType.SIGHASH_FORKID.value | SighashType.SIGHASH_ALL.value;
      //bob will fund by spending from rawTx
      var builder = TransactionBuilder();
      //fund the transaction
      fundingOutpoints.forEach((outpoint) {
        var unlockingScript = P2PKHUnlockBuilder(signingKey.publicKey);
        var txSigner = DefaultTransactionSigner(sighashType, signingKey);
      });

      var signedTx = builder
          .spendToLockBuilder(lockBuilder, BigInt.parse(amount))
          .sendChangeToPKH(ownerAddress)
          .withFeePerKb(100)
          .build(true);

      return (signedTx, fundingOutpoints);
    } on TransactionAmountException catch (ex) {
      return (null, <TransactionOutpoint>[]);
    } on TransactionException catch (ex) {
      return (null, <TransactionOutpoint>[]);
    }
  }


  /*
   * This is a very naive way of just looking through the set of UTXOs, iterating over them
   * and selecting UTXOs until the total amount exceeds the required amount
   */
  Future<List<TransactionOutpoint>> getFundingInputs(SVPublicKey userPubKey, Address address, BigInt requiredAmount) async {
    if (_storage == null) {
      throw StateError('WalletStorage not available for UTXO selection');
    }

    // Note: This method signature doesn't include walletId, so we can't properly
    // query storage. This is a design issue with the original API.
    // For now, we'll throw an exception with guidance.
    throw UnsupportedError(
      'getFundingInputs requires walletId parameter. '
      'Use WalletStorage.getSpendableUTXOs(walletId) directly instead.'
    );
    
    // Proper implementation would be:
    // final spendableUtxos = await _storage.getSpendableUTXOs(walletId);
    // return _selectUTXOsForAmount(spendableUtxos, requiredAmount, address);
  }

  (Transaction, BigInt) _spendFromLocktimeTxn( SVPrivateKey privateKey, Transaction locktimeTxn, SVScript scriptSig, BigInt lockedValue) {
    var address = Address.fromPublicKey(privateKey.publicKey, _networkType == "test" ? NetworkType.TEST : NetworkType.MAIN);

    //assume bob has locked up
    var sighashType = SighashType.SIGHASH_ALL.value | SighashType.SIGHASH_FORKID.value;
    var txSigner = DefaultTransactionSigner(sighashType, privateKey);
    var lockingScriptBuilder = P2PKHLockBuilder.fromAddress(address);

    //we will need to do pre-image calc of unlock

    try {
      var builder = TransactionBuilder()
          .spendFromTxnWithSigner(txSigner, locktimeTxn, 0, 1, DefaultUnlockBuilder.fromScript(scriptSig));

      builder.withFeePerKb(100);

      //deduct sats for fee
      var fee = BigInt.two; //builder.estimateFee();
      return (builder.spendToLockBuilder(lockingScriptBuilder, lockedValue - fee).build(true), fee);
    } on TransactionFeeException catch (e) {
      rethrow;
    }
  }

  void _addtoUtxoSet(currentItem) {
    if (_storage == null) {
      throw StateError('WalletStorage not available for UTXO management');
    }

    // Note: This method signature is too vague - we don't know the type of currentItem
    // or which wallet it belongs to. This is a design issue with the original API.
    // For now, we'll throw an exception with guidance.
    throw UnsupportedError(
      '_addtoUtxoSet is deprecated. '
      'Use WalletStorage.storeUTXO(walletId, utxo) directly instead. '
      'Or emit a ReceiveUTXOCommand to the wallet aggregate for proper event sourcing.'
    );
    
    // Proper implementation would be:
    // if (currentItem is! BitcoinUtxo) {
    //   throw ArgumentError('currentItem must be a BitcoinUtxo');
    // }
    // await _storage.storeUTXO(walletId, currentItem as BitcoinUtxo);
  }

}