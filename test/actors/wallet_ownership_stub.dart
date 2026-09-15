import 'package:dactor/dactor.dart';
import 'package:libspiffy/src/actors/wallet_messages.dart';

/// A stand-in for WalletManagerActor in SPVActor tests that run without
/// wallets: answers SPVActor's [WalletOwnershipQuery] (bead libspiffy-29t)
/// and ignores every other message.
///
/// Every queried wallet exists; it owns the addresses listed for it in
/// [ownedAddresses] and no UTXOs.
class WalletOwnershipStub extends Actor {
  final Map<String, Set<String>> ownedAddresses;

  WalletOwnershipStub([Map<String, Set<String>>? ownedAddresses]) : ownedAddresses = ownedAddresses ?? {};

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is WalletOwnershipQuery) {
      // ignore: invalid_use_of_internal_member
      context.sender?.tell(WalletOwnershipResponse(
        walletId: message.walletId,
        walletFound: true,
        ownedAddresses: message.addresses.intersection(ownedAddresses[message.walletId] ?? const {}),
      ));
    }
  }
}
