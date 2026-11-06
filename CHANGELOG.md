## 5.15.1 (unreleased)

A payment whose ancestors share a block, sent by a wallet built on the BSV SDK, is accepted

- **A BUMP that leaves out the nodes its lower levels determine is walked to its root.** The BSV SDK merges the proofs of two transactions mined in the same block into one BUMP and trims every node the walk can compute from the levels below (`MerklePath.trim()`); a whole level can be empty. `BUMP.siblingAt` looked a node up only where it was stored, so such a BUMP failed with "Missing sibling" and the payment was refused as "Ancestor transaction at index 0 failed merkle proof validation". Found when the demo shop's till (wallet-toolbox) swept two phone payments to a phone. A missing node is now computed from its two children, as the SDK does; the root it leads to is still checked against the block header, so a tampered hash below it is refused as before.

## 5.15.0

Both networks broadcast through the BSV Association's Arcade by default: ARC is deprecated on 30 November 2026

- **`ArcServiceConfig.bsvaArcadeMainnet()`:** the mainnet Arcade at `https://arcade-v2-us-1.bsvblockchain.tech`, no API key, the ARC API at its root as on testnet. It publishes the network's own rate (1 sat/kB today, where GorillaPool's ARC publishes 100), so an app that wants to pay more passes `minimumFeeRate`.
- **`LibSpiffyActorSystem` with no `arcConfig` now uses Arcade on both networks:** mainnet was GorillaPool's ARC and testnet TAAL's, which answers 401 without an API key. An app that passes its own config is unchanged.
- The TAAL and GorillaPool presets stay, marked in their docs as ending with ARC.

## 5.14.0

A wallet signs a message with the key of one of its addresses

- **`SignMessageCommand(walletId, pubkeyHash, message)`, answered with `MessageSignedEvent(publicKey, signature)`:** the message signed as a Bitcoin Signed Message (compact, base64, as dartsv's `Message.sign`) by the wallet key whose public key hashes to `pubkeyHash`. It proves the wallet holds that address's key, for a token held there, say (overnode_v2-l6bx.7). The wallet adds the message prefix and hashes the message, so no caller can have a key sign a digest of its choosing. A hash the wallet holds no key for is refused, and so are watch-only wallets and a WIF wallet whose one key is another. Journals nothing.

## 5.13.0

A payee can answer its payer as soon as ARC accepts a payment, and ARC's fee policy is read once, when the app starts

- **`PaymentAcceptedEvent(walletId, invoiceId, txid, networkStatus, requestId)`:** a received payment validated, the read model holds it, and ARC accepted its submission while still taking it to the network (Arcade's `RECEIVED`). It comes before the payment's `BEEFValidationResultEvent`, which still comes with the status the network got to, and the invoice is still marked paid only then. A payee answers its payer at the first and tells it the outcome at the second; with Arcade that was a 5–9 s wait before any answer (spiffyvault-voo). A payment whose first ARC answer is already final (seen, mined, refused) gets no such event. `BroadcastTransactionMessage(acceptedTo:)` is told `BroadcastAcceptedMessage` when ARC's first answer is in flight; the sender is answered as before.
- **ARC's fee policy is read when ARCActor starts and kept for its life.** Every payment asked ARC for its policy, about 0.9 s from a phone, and a policy changes rarely. A read that fails is not kept: the next fee quote asks ARC again, and a payment is still never built at a rate ARC did not publish. Tests that need their own policy now set it before the system starts.

## 5.12.1

A payment is signed with the wallet's HD root derived once, not once for each coin it spends.

- **A transaction is signed with the wallet's HD root derived once.** A mnemonic wallet's root is the mnemonic stretched by PBKDF2, about 1.1 s on a phone with four secure-storage reads, and `WalletTransactionSigner.signTransaction` derived it again for every input it signed: a two-input payment spent 2.65 s signing on a Pixel. `WalletKeys.withHdRoot(walletId, body)` holds the root while `body` runs and drops it when the last overlapping call returns, so it is still never kept between operations. Signing a transaction now derives it once (bead libspiffy-kbhf).

## 5.12.0

Coins locked to a key outside the wallet's account are found and can be unlocked, the fee of an unlock can be quoted, and a mainnet wallet's import no longer fails when testnet scripts were read first. Needs eventador 4.2.0, which stores events one byte for each byte; with 4.1.0 an event of about 2 MiB (a transaction with many outputs and its parents) was written outside the journal's index, and the wallet's next write failed.

Lock keys (bead spiffyvault-mnz.5). hodlocker.com locked a RelayX user's coins to the RelayX paymail key at `m/0'/236'/0'/0/0`, outside the account `m/44'/236'/0'` the wallet is imported from, so an import read those locks and dropped them.

- **`AddLockKeyCommand(walletId, wif)` → `LockKeyAddedResponse`, `LockKeyAddedEvent`:** the wallet takes a private key outside its HD tree. The key goes to secure storage (`WalletKeys.lockKeysKey`), never into the journal; its address is one of the wallet's, so a HODLocker output locked to it is the wallet's coin. Idempotent; refused for a key of another network.
- **`LockKeyPath(address)`:** the `KeyPath` of a lock key's address. The read model records the address with `AddressMetadata.lockKeyPurpose`, and the wallet signs for it with the stored key, as an unlock does.
- **`ImportWalletCommand.lockKeyWifs`, `ImportWalletMessage.lockKeyWifs`, `importWalletFromXpriv(lockKeyWifs:)`:** keys handed to the wallet before the scan; an application derives them from the seed the account came from.

Unlock fees (bead spiffyvault-mnz.7). A HODLocker unlock holds the whole locking script in its preimage, about 1,300 bytes, so a coin of a few satoshis costs more to unlock than it holds and `UnlockCoinsCommand` refuses it.

- **`HodlockerLock.unlockSize(lockingScriptLength)`:** the signed size of an unlock; the unlock's fee is taken on it.
- **`QuoteUnlockFeeCommand(lockingScriptLength)` → `UnlockFeeQuotedEvent`:** ARC's policy rate on that size, for an application to tell a lock worth unlocking from one that is not. Nothing is built.

Fixed:

- **`ScriptTypeRegistry`:** one registry for each network. It was one instance for the isolate, fixed to the first network asked for, so every later use for the other network threw (`already initialized with NetworkType.TEST, cannot reinitialize with NetworkType.MAIN`): a mainnet import read no parent transactions and then failed (bead spiffyvault-mnz.6).

## 5.11.1

An import no longer fails at a transaction with many inputs. A mainnet wallet's import stopped at a transaction with 162 inputs: its parents were fetched one by one (94 seconds), and the wait for the wallet read model to apply the transaction had started before them, so its 30 seconds were over before the transaction was sent.

- **Import:** the wait for a transaction to be applied starts when its first command is sent, after its parents are fetched. A transaction's parents are fetched six at a time and each once, from storage when it holds them.
- **`WhatsOnChainDataSource`:** requests made at the same time keep to `requestsPerSecondLimit`. A request now takes its place in the last second's requests under the lock; before, requests that checked the limit together all went through.

## 5.11.0

Address discovery no longer counts a failed lookup as an unused address. An address whose history could not be read (after the data source's own retries) ended a chain's scan exactly as a real gap would, so an outage or a run of rate-limit errors during an import left every address past it unfound, with nothing to say so.

- **`AddressDiscoveryService.discoverAddresses` and `discoverAddressRange`:** throw a `DataSourceException` naming the address (an error of another type is wrapped, with it as `originalError`). An import fails with `SpiffyErrorCode.chainServiceUnreachable` and can be resumed.

HODLocker coins — coins time-locked to a wallet key until a block height — are the wallet's, and a seed-phrase import finds them (bead spiffyvault-mnz.1). dartsv names the HODLocker script `hodlocker`, and the import, the SPV receive path and the recording of the wallet's own transactions had no case for it, so every such output was dropped. A locked coin is recorded as plugin-managed, so it is never selected for a payment and is in no balance but the new locked one.

- **`HodlockerLock`:** reads a HODLocker script (`parseHex`, `parse`): the owner's key hash and the lock height. Every fixed byte of the contract is compared; dartsv's `ScriptPattern.isHODLocker` checks only the lengths of its leading constants. `metadata` is what a wallet's lock is recorded with (`pluginId: 'hodlocker'`, `lockHeight`, `ownerAddress`), `isLockedCoin` and `lockedSatoshis` read it back.
- **Import:** a HODLocker output whose key is one of the wallet's is imported with its lock. The lock transaction is in the history of the address that funded it; the key it is locked to has no history of its own, so its owner is also looked for among the addresses the scan found unused, and such an address is registered with the wallet before the coin. `AddressDiscoveryResult.unusedAddresses` lists them.
- **SPV receive and `RecordOutgoingTransactionCommand`:** a HODLocker output to a wallet key is the wallet's.
- **`ReceiveUTXOCommand`:** a HODLocker output is refused when its key is neither a wallet nor a watch address, and is recorded with its lock whatever metadata the sender gave.
- **`BalanceResponse.lockedBalance`, `BalanceUpdatedEvent.lockedBalance`:** the value of the wallet's HODLocker coins, mined or not; not part of `totalBalance` or any other number.

Coins can be locked and unlocked (bead spiffyvault-mnz.2).

- **`LockCoinsCommand(walletId, amount, lockHeight)` → `CoinsLockedEvent`:** pays `amount` to a HODLocker output locked to a fresh receive address of the wallet until `lockHeight`, with change, through the ordinary payment path, and broadcasts it. Refused for a height the chain has reached or one of 500000000 or more. The reply names the transaction and the owner address.
- **`UnlockCoinsCommand(walletId, utxoKey)` → `CoinsUnlockedEvent`:** spends a locked coin back to a fresh address of the wallet, less the fee: nLockTime at the lock height, the input's sequence `0xfffffffe`, and `<signature> <public key> <preimage>`, checked against the locking script before it is recorded and broadcast. Refused, with nothing built, while the header chain is below the lock height, so no transaction the network cannot take yet is sent.
- **`HodlockerOutputSpec`:** an invoice or payment output locked to an address until a height.
- **`AggregateSigningClient.signInputWithKey`:** `signInput` with the signing key's public key.
- **`HodlockerLock`** also reads a lock height written as a small-number opcode (`OP_1` to `OP_16`), which dartsv's pattern does not; the import, SPV and outgoing paths ask it before dartsv's templates.

## 5.10.0

Errors and import progress carry codes, for an app to say them in its own language (bead spiffyvault-9ae.5). SpiffyVault read libspiffy's English messages to tell the user what went wrong ("Insufficient funds", "ARC's policy fee rate could not be read"), and guessed an import's step from its progress. The English stays, for logs.

- **`SpiffyErrorCode`:** insufficientFunds, addressInvalid, addressMainnet, addressTestnet, feeRateUnavailable, coinsInUse, chainServiceUnreachable, notInitialized, timedOut, cancelled. `SpiffyErrorCode.of(error)` reads a code from an error: its own, or a `DataSourceException`, `SocketException`, `HttpException` or `TimeoutException` by its type. `byName` reads a code back after it crossed an isolate.
- **`SpiffyStateError`, `SpiffyArgumentError`:** coded errors, thrown where a `StateError` or `ArgumentError` was, so `on StateError` and `on ArgumentError` still catch them. Insufficient funds (payments, channel funding, the UTXO ledger), an unreadable fee rate, an address of the other network or no address at all, and a system not initialized throw them.
- **`CoordinatorReply.errorCode`:** set by `PaymentReadyEvent` (from `BEEFPaymentResponse.errorCode`), `UTXOSplitCompleteEvent` (from `SplitUTXOsResponse.errorCode`) and `ImportCompleteEvent` (from `WalletImportFailedEvent.errorCode`); null for every other reply, and for a failure with no code. `CoordinatorFailure.spiffyCode` is its reply's code, so `SpiffyErrorCode.of` reads it from what `ask` throws.
- **`ImportStep`:** opening, discovering, fetching, recording, finalizing, done. `ImportProgressEvent.step` and `WalletImportProgressEvent.step` say what an import is doing; `phase` is unchanged.

## 5.9.0

A reclaimed payment's own row is failed (bead spiffyvault-56z). The reclaim resolved the deferred payment as reclaimed, but nothing changed the payment's transaction row, so a payment the payee never broadcast showed as pending for ever, and the status scan kept asking about it.

- **When the self-spend reaches the network:** the reclaimed payment's row fails with its record, unless it is confirmed.
- **The status scan:** a pending or broadcast row whose deferred payment was reclaimed is failed, as one whose deferred payment failed already was. This repairs the rows that wallets already hold.

A wallet imported again can take back the payer keys its earlier payments used. A wallet imported by its phrase alone starts its payer keys at 0, so its next type-42 payments would use again the payer keys of payments made before, and a payee could link them.

- **`RecordType42DestinationsCommand`:** the app hands back the type-42 derivations its payment records kept. The wallet looks for each derivation's payer key among its own (`m/3'/1'/n'`, up to 100 past the highest found or used), derives the address itself, and journals a `Type42DestinationDerivedEvent` for each destination it does not hold yet, which moves the payer-key count past it. A derivation whose payer key is not the wallet's own is skipped. Answered with `Type42DestinationsRecordedEvent`: the addresses, how many were skipped, and the payer keys used now.

## 5.8.0

A payment the payee broadcast through another service is settled from a node's merkle proof (bead spiffyvault-ri8). The payer's wallet asked only its broadcaster, by txid, and a broadcaster knows only what was submitted to it. Such a payment stayed pending for ever and its change stayed on the way, and a reclaim of it was allowed after it was mined.

- **`MerkleProofSource`, `TeranodeMerkleProofSource`:** where a proof is looked up. `TeranodeMerkleProofSource` asks a Teranode asset service for `/merkle_proof/{txid}/hex`; `gorillaPoolTestnet` is a node that serves it. `LibSpiffyActorSystem.initialize(merkleProofSource:)` sets it; without one nothing changes.
- **The status scan:** a pending or broadcast transaction that ARC does not know, or keeps in flight, for an hour is looked up at the source, then at most every ten minutes. A proof that matches the stored header at its height applies the deferred spend and confirms the transaction, as an ARC MINED report does. Any other answer changes nothing.
- **`CheckDeferredPaymentStatusCommand`:** when ARC does not know the payment, the source is asked at once; a proof answers `MINED`, confirmed, with the source `merkleProofSource`.
- **A failed row stays failed on an in-flight answer:** only SEEN_ON_NETWORK or a proof brings it back. A reclaim that lost its race went back to broadcasting two seconds after it failed, and showed so for ever.
- **A lost reclaim's row is failed:** when the payment it reclaimed spends its coin, the self-spend's row fails with its record. A row left broadcasting while its deferred payment failed is failed by the next scan.

## 5.7.0

An app can scan one address of a wallet for coins (bead spiffyvault-017). SpiffyVault hands a fresh address to a payer outside it, such as an exchange, and nothing tells the wallet when that payer pays. The import could only rescan a whole wallet up to its gap limit, which is slow and misses an address past the gap.

- **`ImportWalletCommand.addresses`:** with `resume: true`, only these addresses of the wallet are scanned, instead of discovering its addresses. Each must be an address the wallet holds, or the scan fails. A history lookup that fails fails the scan, so an outage does not read as an empty address. Transactions the wallet has recorded are skipped, so a scan can be repeated. The wallet's other addresses still count as its own for the outputs of a scanned transaction. `LibSpiffyActorSystem.resumeWalletImport` takes `addresses` too.

## 5.6.0

An app can export a transaction that is not mined yet (bead spiffyvault-3fm). SpiffyVault's transaction screen copies a payment as BEEF before it is mined, for a payee or a person who checks it with SPV. `ExportTransactionQuery` refused such a transaction, so the app imported `AncestorChainService` from `src/`.

- **`ExportTransactionQuery.requireProof`:** true by default, as before. With false, a transaction with no proof of its own is exported with its ancestry back to the ancestors whose proofs the wallet holds (BRC-62, parents first). A mined transaction exports as before.

## 5.5.0

The app no longer needs the wallet's internals for what it does every day (bead overnode_v2-rww). OverNode sent commands to the wallet aggregate and messages to the ARC actor itself, and imported helpers from `src/`: the coordinator had no command for them. Each now has a public one.

- **`RecordType42AddressesCommand`:** records type-42 keys of the wallet's anchors as its own, so it signs with them and attributes outputs paying them. Answered with `Type42AddressesRecordedEvent` once the read model holds every address. For keys the wallet uses for itself, such as the key a token it makes is locked to (a hand-off received with a payment still records its addresses through `ImportTransactionCommand`).
- **`RenameWalletCommand`:** answered with `WalletRenamedEvent` once the wallet row holds the new name.
- **`BroadcastTransactionCommand`:** broadcasts a fully signed transaction the app holds and the wallet has no command for (a channel's settlement), answered with ARC's answer as `TransactionBroadcastEvent`.
- **`CheckPendingTransactionsCommand`:** asks ARC again about transactions waiting for a proof, as a new header does.
- **Public helpers:** `Bip32` (derivation that keeps hardened paths hardened), `AddressDiscoveryService`, and `AnchorKeys`: the path and public key of a wallet's anchor for a context, the rule `WalletKeys.anchorPath` follows, for tools that work from a wallet's seed.

## 5.4.0

A type-42 destination carries its tweak t (bead overnode_v2-93y.1). A broker that sells access to a recording checks that the buyer paid the creator without holding either private key: it recomputes the destination as `A + t·G` from the creator's anchor key A and the tweak t. The wallet computed t to derive the destination and dropped it, so a buyer could not give it.

- **`Type42Destination.tweak`:** t, `HMAC-SHA256(ECDH(b, A), invoiceNumber)`, as 32 bytes of lower-case hex. It discloses the one destination and nothing else. `DeriveType42DestinationCommand` sets it, and it is journaled with the destination; one journaled before 5.4.0 reads with none.

## 5.3.3

A client whose server cannot be reached no longer sends to it every two seconds (bead overnode_v2-7pf). Two tabs were still closing when a phone started, and neither host could be found ("No addresses found for peer"): every send failed at once. Each failure brought the next resend forward to `resendAfter`, so the close went every two seconds for as long as the host stayed away. Some hosts never come back.

- **A failed send brings forward one resend per wait.** After that the resends back off as usual, up to `resendAtMost`.
- **At the longest wait, with the last send failed, the resends stop.** The messages are kept. The new `ChannelPeerAwayEvent` (channel, peer) tells the app, which can watch for the peer.
- **The peer back, the kept messages go at once.** The app says so with the new `ChannelPeerReachable` message. Any message from the peer does the same.
- **A channel that ends past its lock time sends nothing more.** Before, only a close or a reject stopped the resends, so an expired channel, or one whose refund was claimed, went on sending its close for ever.

## 5.3.2

A tab with nothing paid closes when both sides close at once (bead overnode_v2-7pf). The host ended a room and closed its side first. The client had paid nothing, so the host held no payment to settle with. A minute later the client closed with its payment of nothing (bead libspiffy-w4l2). The host refused it because its channel was no longer `open`. The client resent its close every two seconds for hours, and its 1000 sats stayed locked until the refund lock time.

- **A server that is already closing takes the client's payment of nothing** and settles with it, paying the client back. The aggregate and the channel manager allow it only for the closing payment of nothing (`closing`, sequence 0). A channel that is `closing` still refuses every payment of money.
- **A refused payment no longer restarts the resend wait.** The close carries the latest payment, and the server answered each resend with a `channel_error` refusing it. Each refusal reset the wait to `resendAfter`, so the close went every two seconds instead of backing off to `resendAtMost`. A refusal now clears the payment once and leaves the wait as it was.

Events applied again at start are no longer acted on again (bead overnode_v2-7pf). A projection catches up from its checkpoint, which is saved every 100 events, so an app the OS stops replays up to 99 of them. A restore copies a backup's journal in for the projections to apply. Every channel event a projection applied went to `ChannelP2PAdapter`, which acted on it as if it were new. After a restore, one phone re-sent every channel message of the past (`channel_request`, `channel_accept`, `refund_signed`, `channel_close`, `channel_closed`, payments) to the peers concerned, and the app was told again of every channel opened and closed, and of every confirmation and paid invoice. Replay itself is unchanged: the read models are still built from it.

- **libspiffy notes the journal head when it starts,** before any actor can write, from the Isar or Postgres store (`PostgresEventStore.highestJournalId`, new). An applied event at or before that head was replayed. Requires eventador 4.1.0 (`ProjectionActor.appliedEventsWithSequence`).
- **A replayed channel event sends nothing and tells the app nothing.** It goes to the adapter on a stream of its own (`replayedChannelEvents`, a new optional parameter of `ChannelP2PAdapter` and `WalletCoordinatorActor`). `LibSpiffyActorSystem.channelEvents` carries only events journaled since the start.
- **A replayed confirmation, reverted confirmation or paid invoice is not announced** (`WalletCoordinatorActor`'s new `isReplayed`). What follows from the event is still done, in case the app stopped first: an invoice its payment pays, or a channel its failed funding can never open. Each step leaves alone what is already done.
- **After a restart a channel resumes from its journaled state.** A client's close goes again until `channel_closed` arrives. A funding sent has its `channel_open` go again until `channel_opened`. On a server, an open channel's settlement is armed. Only a run's live events used to arm these, so a restart lost them unless the projection happened to apply their event again. `ChannelP2PAdapter.resumeAfterRestart` reads the state and leaves alone a channel with nothing to send. The coordinator calls it at startup for each client channel the read model shows closing or funding. The adapter calls it for each channel a replayed event names, unless the replay shows that channel end, so a change the read model does not show yet is resumed too.

## 5.3.1

A coin proven spent by a transaction from elsewhere stays spent when the payment stuck on it fails (bead libspiffy-4kfq). A payment that stays unsettled past `ARCActor.inFlightStuckAfter` has its inputs checked. When one is spent by a confirmed transaction proven against the local headers, the payment fails (`INPUT_SPENT`), and the failure releases its inputs. The proven-spent coin was released too, and became available again. When the spender was not one of the wallet's own transactions (sent from another wallet with the same keys), `SpentOutputRepair` never found it. Every later payment could take the coin up again, sit at `SENT_TO_NETWORK` and fail: on one phone the same coin was spent five times, two of them channel fundings the server rightly refused to open.

- **After failing the payment, the ARC actor spends the coin** with `SpendUTXOCommand`, by the proven spender and at the block height of its proof, as `SpentOutputRepair` does for a spender of the wallet's own. Only for the wallet's own deferred payments: a transaction handed to the wallet is voided, as before, and spends none of its coins.
- **A channel whose funding can never be mined stops sending `channel_open`.** A client resent `channel_open` until the server answered, the channel closed or the settlement margin began, a day later; a funding the wallet failed never gets an answer. The server re-submitted the funding to ARC for each one, waiting about half a minute while its channel actor did nothing else, so with two such channels resending, another client's `channel_request` waited past its open timeout. New `RecordFundingFailedCommand` / `FundingFailedEvent` (`channel.funding.failed`): the client's channel state gets `fundingFailed`, its row becomes `failed`, the adapter sends no more `channel_open` and fails the app's open request (not `stillSent`), and the channel can no longer open. The coordinator records it when the wallet fails a deferred payment with purpose `channel-funding`, and at startup for a funding the wallet failed before (the channel journal is replayed to the adapter at every start, so the failure stops the resend each time too). `ResendChannelOpenCommand` refuses such a channel. `FullChannelStateResponse.fundingFailed` is new.

## 5.3.0

A channel request's failure says whether what failed is still being sent (bead overnode_v2-0o5.3.4). A payment the server has not acknowledged within `ChannelTiming.confirmWithin` and an open the server refused are both answered with a `CoordinatorFailure`, and both are resent: the payment may still land, the open may still be taken. A refused payment, a rejected open or a payment a settlement left out are final. The app could tell them apart only by the failure's wording.

- **`ErrorEvent.stillSent`**, and `CoordinatorFailure.stillSent` reading it: true when the client keeps resending what failed, so a later event that answers no request may report it landing (a `ChannelPaymentEvent`, a `ChannelOpenedEvent`). Set for an unacknowledged payment, for a `channel_error` refusing an open whose `channel_open` is still resent, and for a `channel_opened` the client failed to record while its `channel_open` is still resent. False everywhere else, and when no `ErrorEvent` reported the failure.

## 5.2.0

A client's channel opens when its server has opened it (bead libspiffy-jark). The server opens a channel only once ARC reports the network holds its funding, `SEEN_ON_NETWORK` or `MINED`; the client opened as soon as ARC took the funding, which on testnet ARC can answer `SENT_TO_NETWORK` for minutes. The server refused, the client never heard, and it went on paying into a channel the server had never opened: its tab looked spent and the server's empty.

- **The client opens on the server's `channel_opened`.** A new message: the server sends it for every `channel_open` it opens on, a repeat included. The client journals the new `FundingSentEvent` when ARC takes its funding (the channel stays `refundSigned`, its row `funding`, with `fundingSent` in its state) and its `ChannelOpenedEvent` only when `channel_opened` arrives. No payment can be made before.
- **`channel_open` is resent until the server answers.** As a payment and a close are, waiting `ChannelTiming.resendAfter`, then twice as long, up to `resendAtMost`. Each one has the server submit the funding and look at the network again, so a funding the network takes late still opens the channel. Resending stops when the settlement margin begins, with an `ErrorEvent`: the server would settle the channel as it opened it, and the refund returns the funding at the lock time.
- **A refused open answers the app, and the open goes on.** The server's `channel_error` answers `OpenChannelCommand` with a `CoordinatorFailure` carrying its reason, and `channel_open` is still resent; if the server opens later, a `ChannelOpenedEvent` that answers no request says so.
- `ResendChannelOpenCommand` resends a funded channel's `channel_open` while it waits for the server, and keeps resending it until `channel_opened`. `RetryChannelFundingCommand` refuses a channel whose funding is already sent.
- **Breaking for mixed versions:** a 5.2 client waits for a `channel_opened` a 5.1 server never sends. A 5.1 client ignores it and opens on its own, as before.

## 5.1.0

A channel message the app's transport loses is sent again, and a payment is answered when the server has it (bead overnode_v2-0o5.3.2). On a phone's connection a `payment_update` or `channel_close` was lost as often as not when the connection changed, and the adapter handed each message to the transport once. A lost payment was reported sent. Every payment carries the channel's balances, so the server refused every later one, and at close the client refused the server's settlement because it was not its latest payment: the channel stayed `closing` until the refund lock time.

- **A client resends what its server has not answered.** The latest unacknowledged `payment_update` is resent until a `payment_ack` covers it, and the client's `channel_close` until `channel_closed` arrives. The first resend waits `ChannelTiming.resendAfter` (2 s), and each wait is twice the last, up to `resendAtMost` (30 s). The app can tell the coordinator a send failed with the new `P2PSendFailed`, which brings the next resend forward; without it the resend still comes.
- **`ChannelPayCommand` is answered when the server acknowledges the payment**, not when `payment_update` is handed to the transport. `ChannelPaymentPendingEvent` says it is signed and on its way. A payment with no acknowledgement within `ChannelTiming.confirmWithin` (20 s) is answered with an `ErrorEvent`. It is not withdrawn: the client signed it and the server may hold it, the acknowledgement being what was lost. It is still resent and goes with the close, and if its acknowledgement comes later, a `ChannelPaymentEvent` that answers no request says so. A payment the server refuses is answered with the refusal and not resent; the server's `channel_error` now names the payment's `sequenceNumber`.
- **The server takes any later payment, and acknowledges a repeat again.** It required each payment to be exactly one sequence after its latest. Each payment carries the channel's balances, so one that follows a lost payment pays that one too; the aggregate already checked the balances follow from the server's own. A payment at or below its latest sequence is acknowledged again at its latest, with nothing journaled (`PaymentAcknowledgedResponse.repeat`).
- **The client's close carries its latest payment**, which the server takes before it settles, so a lost `payment_update` is still paid. A close of a channel the server already closed is answered with the settlement it closed with, handed over again (`ChannelClosedResponse.alreadyClosed` and `settlementTxHex`). The client's channel state keeps its signature on its latest payment again (`latestClientSignatureHex`) so a close after a restart carries it too.
- **The client takes a settlement from an earlier payment.** A server that never received the client's latest payment settles with the one before, which pays the client more. The client refused any settlement but its latest payment; it now takes one it signed that pays the server no more than its latest balance. The channel's `ChannelClosedEvent` records what the settlement pays (`finalClientBalance`, `finalServerBalance` on the coordinator event), and payments the settlement left out are answered as failed.
- **A channel with nothing paid closes cooperatively** (bead libspiffy-w4l2). Its server held no payment to settle with, so the client's funds waited for the refund lock time. A client closing a channel with no payment now first records a payment of nothing (`RecordPaymentCommand.closing`, the only payment of nothing the aggregate takes) and sends it with the close; the server settles with it, paying the client back.
- **Funding change of a satoshi or more comes back to the wallet** (bead libspiffy-kov9). Change at or below 546 sats, Bitcoin Core's dust limit, was left out of a channel's funding transaction and went to the miner. BSV has no dust limit, and the fee already paid for the change output.

## 5.0.0

Breaking changes are marked **Breaking**; each says what to change.

- **A coordinator request is answered with its own reply, and `ask` waits for it.** Every app wrote its own "send, then find the matching reply on `coordinatorEvents`" helper, and could not do it reliably: the commands' `correlationId` was derived from the wallet or invoice (two payments of one invoice shared it) or rebuilt from `DateTime.now()` on every read, nothing in the library read it, and `ErrorEvent` named no request. Every command and query with an answer is now a `CoordinatorRequest<R>`, with a `requestId` fixed when it is made (given, or generated), and declares its reply type `R`, a `CoordinatorReply`. The coordinator answers each with exactly one `R` carrying that id, on success and on every failure path, and an `ErrorEvent` a request causes carries it too. `LibSpiffyActorSystem.coordinator` is a `WalletCoordinator`: `ask(request, {timeout})` sends a request and completes with its reply, throwing `CoordinatorFailure` (carrying the failed reply or the `ErrorEvent`) when it failed, or when the coordinator stopped first (`closed`), and `TimeoutException` after the request's `replyTimeout`; a timeout does not cancel the request. `tell` sends without waiting; `on<E>({walletId})` follows one kind of event. Replies are still published on `coordinatorEvents` (bead libspiffy-xc78.1).
  - **Breaking:** `LibSpiffyActorSystem.coordinator` is a `WalletCoordinator`, not an `ActorRef`: `tell` works as before; code that typed it `ActorRef` changes the type.
  - **Breaking:** `queryId` is `requestId` on every query and response (`GetBalanceQuery`, `GetTransactionsQuery`, `GetTransactionDetailQuery`, `ExportTransactionQuery`, `GetDeferredPaymentsQuery`, `GetHeaderSyncStatusQuery`, and their answers); it is optional on `GetHeaderSyncStatusQuery` too. On replies `requestId` is nullable: the same event type is emitted without a request for what nobody asked (a receive replayed when its header arrived, a peer's headers).
  - **Breaking:** `DeleteWalletCommand` is answered with `WalletDeletedEvent`, and `ReleaseUTXOsCommand` with `UTXOsReleasedEvent`, once the read model shows it; a refusal of either, or of `RecordOutgoingCommand`, is its reply's `failure`, no longer an `ErrorEvent`. The wallet aggregate answers a deletion (`WalletDeletedResponse`) and a release (`UTXOsReleasedResponse`, naming the UTXOs released), and answers an outgoing recording once, with `TransactionRecordedResponse`, instead of first with a `UTXOReceivedResponse` per change output.
  - **Breaking:** `ImportWalletCommand` with a mnemonic imports the wallet's history: the wallet is created from the mnemonic and its import run as a resume, which derives its keys from the stored mnemonic. It created the wallet and imported nothing, answering with `WalletCreatedEvent`. Without a blockchain data source an import is refused with a failed `ImportCompleteEvent`.
  - **Breaking:** `TimestampCommand` is answered with ARC's answer to the broadcast; it reported success when the broadcast was handed to ARC, before ARC answered.
  - **Breaking:** `RefreshWalletCommand` is removed: it refreshed nothing and announced that it had. The named constructors `PaymentReadyEvent.error()` and `ProvisioningCompleteEvent.error()`, which nothing called, are removed; the `error` fields stay.
  - A `StoreHeadersCommand` whose batch throws is answered, with nothing stored; it was not answered at all.
  - Every coordinator event takes its `eventTimestamp` when it is made; it was the time it was read.
- **Channel commands are answered through `ask` too.** `OpenChannelCommand` is answered with the channel's `ChannelOpenedEvent` (5 minute default timeout: the counterparty and the funding broadcast are waited for), `ChannelPayCommand` with its `ChannelPaymentEvent`, `CloseChannelCommand` with `ChannelClosedEvent`, `ClaimChannelRefundCommand`, `RetryChannelFundingCommand` and `ResendChannelOpenCommand` with the events they had; a step of an open or close that fails, and the counterparty's `channel_reject` or `channel_error` during an open, is an `ErrorEvent` naming the request. The adapter answers a channel's requests of one kind in the order they were made (bead libspiffy-xc78.2).
  - **Breaking:** `AcceptChannelCommand` is answered with a new `ChannelAcceptedEvent`, `RejectChannelCommand` with `ChannelRejectedEvent`, and `ExpireChannelCommand` with `ChannelExpiredEvent`, which carries a failed expiry that was an `ErrorEvent`.
  - The channel's request, its acceptance and a payment are asked of the channel manager: told with no sender, a refusal of any of them (an unknown wallet, a payment above the client's balance) reached nobody, and the app waited for a channel or payment that never came.
  - A coordinator built without channel events answers a channel command with an `ErrorEvent`; it dropped it.
  - A server's settlement timer closes its channel without registering a close request, so it cannot take the answer of a close the app asked for.
- **Breaking: `NodeRpcDataSource` is removed**, as 4.7.0 announced. It read proofs with `gettxoutproof`, which only an SV Node serves; Teranode does not. Use `WhatsOnChainDataSource`, or a `BlockchainDataSource` of your own. The `svnode` test tag and its tests are gone with it (bead libspiffy-cquj).
- **Breaking: the deprecations kept for compatibility are removed.** `CdnHeaderSyncConfig.concurrentDownloads` (never read: chunks are validated in sequence); the `walletIdEqualTo`/`walletIdNotEqualTo` where clauses of `AddressEntity` and `statusEqualTo`/`statusNotEqualTo` of `BitcoinTransactionEntity` (use `walletIdEqualToAnyPurpose` and `statusEqualToAnyWalletId`, the composite indexes' prefixes); `LibSpiffyActorSystem.broadcastChannelEvent` (channel events are broadcast once the projection applied them); the unused `secureStorage` parameters of `PaymentCoordinatorActor` and `BenfordCoordinatorActor`, and `WalletCoordinatorActor`'s unused `importActor`. Deprecated events and commands that old journals hold stay, for replay (bead libspiffy-zoql).
- **Breaking: `ChannelP2PReceived` and `ChannelP2PMessageToSendEvent` are removed.** They were the channel-named copies of `P2PMessageReceived` and `P2PMessageToSendEvent`, and an app that listened only for the channel class missed the merkle-proof protocol's messages. Deliver what your transport receives as `P2PMessageReceived`, and send every `P2PMessageToSendEvent`.
- **A payment waiting for its block header is answered, not failed.** `BEEFValidationResultEvent.failure` is null while `awaitingHeader`, so `ask` returns the reply; the verdict the header brings is a second event with the same `requestId` (while the process runs). An `ImportTransactionCommand` whose proof waits for a header is answered by that verdict too, within its timeout: the coordinator kept no record of the request once the first reply came, and the verdict named none.
- **`BroadcastFailureEvent.willRetry` is ARC's answer**, required, not always true: no retry is queued on a backend without the retry queue (PostgreSQL), or for a definitive refusal.
- **`ProvisionedTransaction` is exported**: a plugin implementing `TransactionBuilderPlugin.provisionFunding` names its return type without importing `lib/src`.
- **The README, the developer guide and `lib/coordinator.dart` teach `ask`**, with a request-to-reply table; `example/coordinator_example.dart` runs it offline. The guide said a wallet created without key material gets a generated mnemonic: libspiffy generates no keys, and the refusal now says what to provide. The localnet tests and their harness use `ask` for every request they wait on; `next<T>()` remains for events nobody requested (bead libspiffy-xc78.3).

## 4.7.0

- **A BEEF settled through the wallet keeps the ancestry it carries.** A payment that spends an output the wallet does not own (a token purchase spending the seller's listing) was recorded without that output's parent: the app hands it to the plugin, and `TransactionRecordedEvent` carries no ancestors. Every spend of the payment's change then failed in `AncestorChainService` with "Transaction <the counterparty's txid> not found in storage" until the payment was mined and its proof arrived. `SettleBEEFCommand` now keeps what the BEEF carries for its subject, back to proven transactions with their BUMPs, when the subject is a transaction the wallet recorded: `RecordTransactionAncestorsCommand` journals `TransactionAncestorsRecordedEvent`, and the projection stores it as it stores a received BEEF's ancestors. The settlement returns once the read model holds them. Each transaction the settlement broadcasts goes with the BEEF, so ARC is sent the Extended Format of a transaction spending a counterparty's output; Arcade refuses one it cannot extend (460). An app settling such a payment hands the complete BEEF, the counterparty's transactions included. The BEEF ancestry walk moved from SPVActor to `BeefAncestry` (`lib/src/spv/beef_ancestry.dart`), which both use (bead libspiffy-yiba).
- **A channel's settlement and refund reach Arcade.** `PaymentChannelManagerActor` submitted the settlement (server) and the refund claim (client) without the funding transaction they spend. The funding output is no wallet UTXO, so the Extended Format fell back to raw; ARC looked the parent up itself, Arcade answered 460 and every channel close and refund failed. Both now go with a BEEF of the funding transaction and the spend (bead libspiffy-uqa4).
- **The app sets a minimum fee rate.** `ArcServiceConfig.minimumFeeRate` (and on every preset): the wallet pays ARC's published policy rate, or this floor when the policy is lower. GorillaPool's testnet ARC publishes 0 sat/kB, and nothing paying 0 is mined there. A floor is never a rate in place of a policy ARC could not be asked for. `FeeRate.isAbove` compares two rates exactly (bead libspiffy-23j2).
- **The default P2P user agent passes Teranode.** Teranode's wire-protocol service accepts a peer only if its user agent contains `BSV` or `Bitcoin SV`, and bans any other's IP for 24 hours; `/LibSpiffy:1.0/` did not pass, and one refused connection locked every client behind the same address out. The default is `LibSpiffyActorSystem.defaultUserAgent`, `/LibSpiffy-BSV:1.0/` (bead libspiffy-c04p). The P2P network line is a log record, not a `print`.
- **`checkBumpAgainstHeaders` is exported**, with `checkBumpHexAgainstHeaders`, `ProofHeaderCheck` and `ProofHeaderStatus`: an app checks a merkle proof against its headers without importing `lib/src` (bead libspiffy-09oj).
- **A plugin's placeholder signing pass is not logged as a plugin failure.** A plugin that checks the spend it built (a token's script) refuses the pass signed with placeholder signatures, by design; the next pass signs for real. Each refused pass was logged as a WARNING with a stack trace. The plugin guard now covers the whole build, so only a failure with nothing left to sign is the plugin's (bead libspiffy-kzwv).
- **`NodeRpcDataSource` is deprecated and goes in 5.0.0.** It reads proofs with `gettxoutproof`, which only an SV Node serves; Teranode does not, and the SV Node regtest stack it was tested against is retired (bead libspiffy-cquj).
- **The localnet tests run on Teranode.** `test/integration/localnet_harness.dart` targets `../localnet-teranode` (Teranode, Merkle Service, Arcade): coins from its faucet through Arcade, BEEFs from Arcade's merkle paths, the tip and a transaction's block from the DataHub, headers over the wire protocol on :18444. The SV Node + ARC stack in `../localnet` is retired; the `NodeRpcDataSource` tests that need an SV Node's RPC are tagged `svnode` (`dart test -P svnode`). Arcade refuses a later double spend outright (REJECTED) where ARC held it as DOUBLE_SPEND_ATTEMPTED, and a spend of an output spent in a block likewise (bead libspiffy-kynm).

## 4.6.1

- **A payment channel's payment pays every share of a satoshi or more.** `PaymentChannelBuilder` left a party's output out of a payment, and a refund failed, when its share was at or below 546 sats, Bitcoin Core's dust limit. BSV has no dust limit and ARC asks for none, so the share went to the miner: a 1000 sat room tab that paid the host 350 settled with one output, back to the client, and the host's 350 was lost. `dustThreshold` is replaced by `PaymentChannelBuilder.minimumOutputSats` (1); a share of nothing is still left out. The server no longer accepts a payment that leaves its own balance out: `_checkPaymentTransaction` requires the server's output to carry its whole balance (bead libspiffy-b4kv).

## 4.6.0

- **Arcade, the Teranode-era ARC, works as a broadcaster.** Arcade serves ARC's API at its root (no `/v1`) and accepts a submission with HTTP 202 and `txStatus: RECEIVED`, which `ArcService.submitTransaction` threw as a failure: every transaction Arcade accepted was reported failed and queued for retry. A 202 is an answer like a 200. `ArcServiceConfig.bsvaArcadeTestnet()` is the BSV Association's testnet Arcade. Arcade's `SEEN_MULTIPLE_NODES` is on the network, as `SEEN_ON_NETWORK` is, and its `PENDING_RETRY` is in flight (`ArcTransactionStatus`, `DeferredNetworkStatus`); both read as `unknown` before. `test/integration/arcade_testnet_live_test.dart` (`dart test -P arcade`) runs `ArcService` against the live instance. `submitBatchTransactions` does not work with Arcade, whose `/txs` takes `application/octet-stream` and answers with counts; nothing in libspiffy calls it (bead libspiffy-i5he).
- **A received payment is submitted in Extended Format.** The payee submitted a counterparty's payment raw: its inputs spend the payer's outputs, which no wallet here stores, so the Extended Format fell back to raw. ARC looked the parents up itself; Arcade refuses a raw transaction with 460, "Not extended format", and the payment was queued for retries that met the same answer. `SPVValidationResult.beefHex` carries the BEEF a receive came in, and the payment's broadcast extends it from that, also when the receive waited for a header and was replayed (bead libspiffy-3qt8).
- **A submission answered in flight is answered with the status the network gets to.** ARC waited for the network before answering a submission; Arcade answers every one RECEIVED at once and takes it to the network afterwards, so a payee's payment stayed "broadcasting" and its invoice unpaid until a status scan came round. ARCActor now hands an in-flight answer ([DeferredNetworkStatus.inFlight]) to a new `SubmissionWatcherActor`, which asks ARC after each of `ARCActor.inFlightFollowDelays` (1, 2, 4, 8 and 15 s by default; `LibSpiffyActorSystem.initialize(arcInFlightFollowDelays:)`) and stops at the first status that is not in flight. The caller of `BroadcastTransactionMessage`, `BroadcastBEEFMessage` or `BroadcastDeferredPaymentMessage` is answered with that status, and the wallet hears both answers. The follow runs outside ARCActor's mailbox: each wait is a timer message and each query's answer a message, so other submissions are not held behind it, and `StopArcWorkMessage` answers any still followed with ARC's latest answer (bead libspiffy-2t5z).
  - The follows the callers did themselves are gone: the wallet coordinator's for deferred-payment broadcasts and reclaims (bead libspiffy-ggsg), and `PaymentChannelManagerActor`'s for funding and settlement (bead libspiffy-m715), each of which slept in its own mailbox. `PaymentChannelManagerActor`'s `inFlightTimeout` and `inFlightPollInterval` are removed, and its `broadcastTimeout` defaults to 60 s, since a broadcast's answer now includes the follow.

## 4.5.3

- **Each wallet's row of an orphaned transaction gets the temporary data-source check.** The 4.5.2 stopgap waited 5 minutes between checks per transaction, not per wallet: a move between two wallets on one device has a row in each, and checking the payer's kept the payee's waiting, so the coin the payee received stayed pending while the payer's side confirmed (bead libspiffy-tfks). The wait is now per wallet and transaction. The check is still temporary (bead libspiffy-5it6).

## 4.5.2

- **Temporary stopgap: a transaction ARC goes on calling orphaned is looked up in the data source.** Transaction status comes from ARC; the data source (WhatsOnChain) is for wallet recovery, and this check is to be removed once ARC is fixed (bead libspiffy-5it6). A transaction ARC answered SEEN_IN_ORPHAN_MEMPOOL for good (here an ARC whose node could not have its parents: a regtest ARC configured for a testnet wallet) went through orphan remediation three times, after which only ARC was asked, so its outputs stayed pending and nothing could spend them (bead libspiffy-tfks). Once remediation has given up, the scan asks the configured data source every `ARCActor.orphanSourceCheckInterval` (5 minutes): a transaction it knows applies as on the network, and its merkle proof confirms it only when it matches a local header. Orphan remediation's resubmissions go in Extended Format too.

## 4.5.1

- **ARC is sent a transaction in Extended Format when its parents are at hand.** A transaction went to ARC raw, and ARC looks up the parent of every input to check it. A coin from a block ARC never saw (one an imported wallet received long ago) could not be found, and ARC refused the spend with 460, "Not extended format: parent transaction not found": a move from an imported single-key wallet to another wallet never reached the network, and the coin it paid stayed pending (bead libspiffy-7gen). ARCActor now submits every transaction, and every unproven ancestor it submits first, in Extended Format (BRC-30), each input carrying the satoshis and locking script of the output it spends. They come from the transaction's BEEF or, without one, from the transactions any wallet stores; when one is missing the transaction goes raw, as before. `ExtendedFormat` (`lib/src/utils/extended_format.dart`) encodes it. A BEEF broadcast (`BroadcastBEEFMessage`) now submits the BEEF's unproven ancestors first too, as the other broadcasts do.
- **A broadcast retry is sent as the first attempt was.** The durable retry queue kept the raw transaction only, so a retry went without the ancestors and without the outputs its inputs spend, and was refused with 460 for as long as it was retried. The queue entry now keeps the BEEF; a retry submits its unproven ancestors and the extended form again. An entry queued before this has no BEEF and is extended from the stored parents.

## 4.5.0

- **Spread inputs no longer fall back to the largest coin first.** `PaymentPrivacy.spreadInputs` tried random coins smaller than the payment and, when six of them could not pay it, took the wallet's largest coin: in a wallet of many small coins and one large one, nearly every payment was still funded by the large one (bead libspiffy-5hnt). It now tries the largest of the smaller coins within `maxInputs`, then the smallest single coin that pays, so the change is as small as one coin allows, and only then the largest coins.
- **A Benford split takes the largest coins first.** `SplitUTXOsToBenfordCommand(maxUtxosToSplit:)` took the first coins in storage order, so a wallet's largest coin could stay whole while its small coins were split again and again. It now takes the largest. New, all optional: `utxoKeys` splits only the coins named; `partSats` splits each into pieces of about that size, from 2 to `targetUtxoCount` of them; `minPartSats` makes no piece smaller, so a coin makes fewer pieces, or none when it cannot make two (its outcome says so). `SplitUTXOsCommand` carries the same three. `SplitUTXOsResponse.splitCount` counts the pieces each split made.

## 4.4.0

- **Opt-in payment privacy: change in parts, funding from smaller coins.** A payment's change was one output and its inputs the largest coins, so next to a payment split into parts the large input and the large change output told an observer which output was the payer's (bead libspiffy-o7a4). `PayInvoiceCommand(privacy: PaymentPrivacy(...))` asks for both remedies; without it a payment is built exactly as before.
  - `maxChangeParts` pays the change as up to that many outputs, each to a fresh change-chain address, with Benford-distributed amounts in random order; `randomChangeParts` draws the count from 2 to the maximum per payment; `minChangePartSats` (1,000 by default) is the smallest part, and less change makes fewer parts, or one output. The selection's fee counts every change output it may pay, and the fee is worked out again for the parts it does pay. `PaymentReadyEvent.changeAmount` is the change of all parts.
  - `spreadInputs` funds the payment from coins smaller than it, coins of one parent transaction together and before single coins (spending already-linked coins together shows nothing new), up to `maxInputs` (6 by default), since coins spent together show one owner. When they cannot pay within that, the largest coins do, as before.
  - Every random choice is drawn from a generator seeded with the invoice id: paying the same invoice again over the same coins signs the same transaction, as the repeat-payment rules need (libspiffy-4r0).
- `BenfordDistribution.distribute` takes an optional `random`, so a seeded generator gives the same amounts again.

## 4.3.1

- **A channel funding goes to ARC with its unconfirmed ancestors.** The channel built its funding BEEF and then broadcast the funding transaction alone, so a funding that spent a coin from a transaction ARC had not seen (fresh change, a split, a payment received peer to peer) was refused with 460, "Not extended format: parent transaction not found", and the channel never opened (bead libspiffy-b3z4). `BroadcastTransactionMessage` takes the transaction's `beefHex`, and ARCActor submits the BEEF's unproven ancestors, parents first, before the transaction, as it already did for a deferred payment; one ARC refuses is logged and passed over, since ARC may know it already. The client's funding broadcast and the server's re-submission of the funding it receives both pass their BEEF. A broadcast without one is unchanged.

## 4.3.0

- **A payment's change goes to a fresh address.** `PayInvoiceCommand` without a `changeAddress` sent the change back to the address of the payment's first input, so every payment reused an address and linked the change to the coin it came from (bead libspiffy-zjyu). The payment coordinator now asks the wallet for the next address on its change chain (m/1/i) when the payment pays change; a payment with no change takes none, and a plugin-built transaction is unchanged. A caller's `changeAddress` is still used as given. A single-key (WIF) wallet still has its one address. If the wallet gives no change address, the payment fails and says so rather than reuse one.
- **The change chain counts its own index.** Receive and change addresses took their indices from one counter, so change addresses would leave gaps on the receive chain, and address discovery, which stops after 20 unused addresses on each chain, would read a run of payments as the end of it. A change address now takes one past the highest change index the wallet holds, and neither a generated nor a discovered change address moves the receive counter.

## 4.2.0

- **P2P header sync writes a batch at a time.** Every header a peer sent was written in its own storage transaction, about 2 ms a header: one node took 100 s for localnet's 45,000 headers, and three in one process reached only 36,000 after 6.5 minutes (bead libspiffy-mii4). `BlockHeaderChain.acceptHeaders` validates a batch header by header and writes each run that extends the tip in one transaction; a header off the tip (a side branch, a reorganization) is decided after the run before it is written. A write that fails leaves the chain where the run began. A late duplicate of a full batch, all known and ending below the tip, no longer asks for the next batch again, which could have every later batch sent twice. The header cache evicts its lowest height without sorting every cached height per header (bead libspiffy-j1yc).
- **Where header sync stands, from the coordinator.** The actor system is ready before its headers are, and nothing said when they had caught up (bead libspiffy-ndfr). `GetHeaderSyncStatusQuery(queryId:)` is answered with `HeaderSyncStatusResponse`, and `HeaderSyncStatusEvent` is emitted when the chain catches up with its peers or falls behind them. Both carry a `HeaderSyncStatus`: `height`, `networkHeight` (as `LibSpiffyActorSystem.networkHeight`), `synced` (the last peer answer held less than a full batch) and `peerCount`. `BlockHeadersStoredEvent`, documented as every batch stored, was emitted only for `StoreHeadersCommand`; it now is for every batch from peers too, and carries `source`. `GetSPVStatusMessage` answers `isSynced` as `synced`, not as "initialized", and header sync no longer tells SPVActor it is synced at startup.
- **`StoreHeadersCommand` validates its headers.** It wrote them straight to storage, behind the header chain, which neither checked them nor moved its tip. They now go through the header chain like a peer's; a header that does not connect, or fails a consensus check, is refused and named in the `BlockHeadersStoredEvent`'s `error`.
- `WalletCoordinatorActor(headerSyncActor:)` is no longer deprecated: the coordinator uses it.

## 4.1.0

- **A reclaim that loses its race no longer strands the payment it reclaimed.** A buyer signs a swap half (a deferred payment holding its coin); the seller completes the swap and the network takes it first; the buyer's `ReclaimDeferredPaymentCommand` journals its self-spend, which can never be mined. The self-spend failed as before (bead libspiffy-wfvi), but the half kept its `reclaimTxid`, so completing, cancelling and reclaiming it again were all refused as "being reclaimed", and the buyer never recorded the swap the chain kept (bead libspiffy-bapp). Now a self-spend that fails, by a spend of its input or by ARC's `REJECTED`, hands every input it still holds back to the payment it reclaimed, which is plain outstanding again. `CompleteDeferredPaymentCommand` accepts a half whose inputs the completion itself already spent, and records the completion as seen when it has. `SpendUTXOCommand` records a spend whose spender is proven in a block (`blockHeight`, set only by a sender that verified the proof) even over a reservation or hold for another transaction: before, it was refused unless the wallet had recorded the spender itself, so a counterparty's mined completion, received with its proof, could not mark the coin spent. An unproven spend of an output reserved for another transaction is still refused (audit C1), since either spend may yet be mined. The same spend reported twice journals nothing; a spend by another transaction of an output already recorded as spent is refused as a double spend, proven or not. SPV receives pass the height when the BEEF carried the spender's proof, and `SpentOutputRepair` spends a reserved output when the spender's row has its block.
- **A fresh address from the public API.** The coordinator's `GenerateAddressCommand(walletId, label:, purpose:, includePublicKey:, requestId:)` answers with `AddressGeneratedEvent` (the address, its chain and derivation index, and its public key when asked for) once the read model holds the address, so a payment to it attributes at once. Before, an application had to import the aggregate's command from `package:libspiffy/internals.dart` (bead libspiffy-u5qe).
- **"Insufficient funds" names the amount and the shortfall**, both when the wallet has no spendable coin and when it has too little (bead libspiffy-khb7).
- **Nothing is printed to stdout.** eventador 4.0.0 moves its `[PersistentActor]` recovery lines, `Command processing failed …` and every other `print` to `package:logging` (loggers under `eventador.`), so a host speaking a protocol over stdio (an MCP server) need not divert them (bead libspiffy-oe77).
- **A sold listing's price is credited.** `CheckForeignSpendsCommand` marked a wallet output spent by a proven foreign spender and recorded nothing else, so a Listed NFT bought by a stranger lost its token output and the price it paid to the listing's owner key, a key of the selling wallet, never appeared among the wallet's UTXOs or in its balance (bead libspiffy-zyfr). A proven spender is now received by the wallet as any mined transaction of its is: the output it spends is marked spent, its outputs that pay the wallet's addresses are received as available in the block its proof names, and it joins the wallet's history. `ForeignSpendsCheckedEvent` is announced once the read model shows it. `ForeignSpend` gains `spenderBeefHex`, `recorded` and `recordError`. ARCActor answers `CheckOutputSpendersMessage` with the proven spender's BEEF and records nothing itself.

## 4.0.0

- **Breaking: `IsolateConfig` is gone, with every parameter that took one.** libspiffy never ran a storage operation in an isolate, and nothing read the setting. Removed: the class, `LibSpiffyActorSystem.initialize(isolateConfig:)`, `initializeLibSpiffy(isolateConfig:)`, `StorageFactory.createReadModelStorage(isolateConfig:)`, `StorageFactory.createStorages(isolateConfig:)` and `IsarWalletStorage(isar, config:)`. Delete the argument; nothing else changes.
- **Breaking: two settings that were stored and never read are gone.** `PaymentChannelAggregate(networkType:)`: the aggregate takes a channel's network from the server address it pays. `HeaderSyncActor(startHeight:)` and `InitiateHeaderSyncMessage(startHeight:)`: header sync continues from the tip of the stored chain. `LibSpiffyActorSystem.initialize(startHeight:)` stays and is documented as what it is, the height this node reports to peers in its version handshake.
- **`WalletRowRules` is exported.** `ReadModelStorage.storeWallet` states its contract in terms of `WalletRowRules.canonicalNetwork` and `WalletRowRules.defaultNetwork`; an application implementing the interface can now call them, and read a wallet row's `network` with `NetworkName`.
- **A deferred payment can carry a deadline, at which the wallet reclaims it by itself.** `PayInvoiceCommand(deadline:)` (a UTC instant, bead libspiffy-8442) is journaled with the payment's hold (`TransactionSpendDeferredEvent.deadline`), stored (`DeferredPayment.deadline`; Isar property, Postgres migration v029) and listed (`GetDeferredPaymentsQuery(dueBefore:)`, `DeferredPaymentQuery.dueBefore`). The coordinator sweeps every wallet's outstanding payments at `LibSpiffyActorSystem.initialize(deadlineSweepInterval:)` (a minute by default) and reclaims each one whose deadline has passed, as `ReclaimDeferredPaymentCommand` would; the answer is a `DeferredPaymentReclaimedEvent` with request id `deadline-<txid>`. A payment seen, mined, completed, failed or cancelled before its deadline is left alone. The deadline bounds the option the payment gives its holder and does not end it: the reclaim ends it when the network has it. A node that withdrew its halves past an age sets a deadline instead. Found on the way: `DeferredPaymentQuery.allStates` omitted `completed`, so `includeResolved` did not list completed halves; it does now.
- **Change from a payment is spendable when the network takes it, not a status scan later.** When ARC reported a payment on the network while the read model held its transaction row and not yet its outputs, the change stayed pending until the next status scan (30 s), and a `CheckDeferredPaymentStatusCommand` sent meanwhile did not answer until then. Settling a payment and checking it at once took 30 s. `ARCActor` worked out which UTXOs to spend and make available from the read model, which shows a recording one event at a time. The wallet aggregate now decides it from its own state: `ARCActor` sends one `ApplyDeferredSpendCommand` with the transaction, in place of a `SpendUTXOCommand` and a `MarkUTXOAvailableCommand` per UTXO. The same check now answers in under a second. **Breaking:** `ARCActor(deferredSpendRecheckDelay:)` is gone, with the recheck it timed.
- **A deferred payment that the counterparty completes.** A sale in one transaction is signed by two wallets: the first records a half (its own input signed, a placeholder for the other side's) as a deferred payment, which holds its input. `CompleteDeferredPaymentCommand(walletId, txid, rawHex)` records the completed transaction in the half's place: the aggregate refuses unless it has the same version, lock time, inputs, sequences and outputs, and the wallet's own unlocking scripts unchanged. The completed transaction takes over the hold; the half becomes `DeferredPaymentState.completed` (new, appended), and its own pending outputs are voided. Journaled as `DeferredSpendCompletedEvent` (`wallet.transaction.deferred_completed`). Withdrawing a half is `ReclaimDeferredPaymentCommand`, as for any deferred payment.
- **Outputs the wallet holds, spent by someone else.** `CheckForeignSpendsCommand` asks the data source (`SpentOutputLookup`) who spent each plugin output the wallet holds, or the outputs named. A spender that is mined and whose merkle proof matches the local headers marks the output spent and is returned with its raw transaction (`ForeignSpend`); anything less is reported as a lead and changes nothing. A token taken back by its issuer, a listing bought, a pot seized: the wallet learns of it by asking about what it holds, never by scanning. ARCActor answers `CheckOutputSpendersMessage`.

- **Plugin actions that need no funding coin.** When a plugin's `requiredFundingUtxoCount(action)` is 0, the payment coordinator selects and reserves no wallet coin. It does not refuse the payment when the wallet has no coins. It calls the plugin with an empty funding list; the plugin names the keys it signs with through `keyFor`. A token that pays its own fees (tstokenlib's Fuelled NFT) is moved this way. Before, the coordinator always selected a coin for the payment's amount and recorded it as spent, although the transaction never spent it.
- **Plugin payments hold every wallet output they spend.** A plugin's transaction can spend wallet outputs that the plugin found itself, such as a token the wallet holds, and the earmarks auto-provisioned for the payment. They are now held with the payment and spent when the network takes it, like the funding. A payment that spends an output already held by another payment, spent, or not yet on the network is refused with the reason.

- **A plugin can name the key that signs an input.**
  `PluginTransactionRequest.keyFor(pubkeyHash)` answers a `PluginKey`: a signer bound to the wallet key with that public key hash, and the key's public key. It fails when the wallet holds no such key. libspiffy finds the key for a plugin's input from the script the signature covers. A covenant that signs only the code after an `OP_CODESEPARATOR`, with its owner in a header before it, names nobody there, so its input was signed with the funding key. The payment and provisioning paths both offer the lookup.

- **An output the wallet holds as unspent, although its own confirmed transaction spends it, is repaired.** An imported wallet held two outputs as available that were spent in their parent's own block: the import recorded by height only, children before parents, and a child can mark only an output the wallet already holds. A deferred payment later spent one, and ARC kept it `SENT_TO_NETWORK` for ever. The import now records the oldest block first and, inside a block, parents before children. `SpentOutputRepair` runs once per wallet load and after an import: it reads only the wallet's own records, marks such an output spent, and fails an outstanding deferred payment that holds it (`DeferredNetworkStatus.inputSpent`, `INPUT_SPENT`, a definitive failure). A transaction handed to the wallet whose input a confirmed transaction spends is voided (`VoidUnsettledTransactionCommand`, `TransactionVoidedEvent`, `wallet.transaction.voided`): its row fails and its pending outputs are voided. `ARCActor` checks the inputs of a transaction unsettled for longer than `inFlightStuckAfter` (1 h) through the optional `SpentOutputLookup`, and acts only on a spender whose merkle proof matches a local header.
- **A payment carries the payer's memo.** `PayInvoiceCommand(memo:)` and `ValidateBEEFCommand(memo:)` journal the note with the payment (`TransactionRecordedEvent`, `TransactionImportedEvent`, `UTXOReceivedEvent`) and keep it on the transaction row (`BitcoinTransaction.memo`). The first non-empty memo stays: a later record never blanks or replaces it, on the in-memory, Isar and Postgres backends. A receive parked until its header arrives keeps its memo (`PendingReceive.memo`, Postgres migration v028).
- **A derived anchor key is kept for 5 minutes.** Deriving one reads the mnemonic from secure storage and stretches it to the seed, 0.3 to 0.4 s on a phone, and a BRC-100 message-box check runs two key operations every 30 s. The derived anchor key is kept, never the mnemonic or the HD root; removing a wallet's key material forgets it.
- **Commands are taken before the header sync ends.** `LibSpiffyActorSystem.ready` completes once the actors run, before the CDN sync and the P2P start that `initialize()` still waits for. Creating or importing a wallet needs no chain; on a first install the CDN sync runs for minutes, and wallet creation timed out behind it.
- **`networkHeight` is what peers reported.** spiffynode's tip tracker counted the catch-up headers libspiffy requested twice, so the tip ran ahead of the real one and the chain never looked synced (99%). `LibSpiffyActorSystem.networkHeight` is now the higher of the connected peers' handshake heights and the local chain, and 0 while no peer is connected.
- **P2P peers are dialled again when none is left.** spiffynode removes dead peers and adds none, so a laptop that slept stayed at zero peers until restart. Every 30 s (`LibSpiffyActorSystem.peerUpkeepInterval`) with no peer left, the seeds are resolved and dialled again, and header sync resumes when one connects.
- **The CDN header sync is retried, and reports how it ended.** One stalled chunk download ended the CDN sync, and the rest of the chain came from peers, slowly. The actor system now runs up to three passes, each resuming from the chain's tip on a fresh HTTP client, before it leaves headers to peers. `initialize(onHeaderSyncResult:)` is called with the `CdnSyncResult` of the startup sync: success, the error that ended it, or that no CDN was configured.
- **A wallet manager's refusal reaches the application with its reason.** The coordinator asked the wallet manager for a typed answer; a refusal (an unknown wallet, say) is a `FailureResponse`, and was reported as an ask type mismatch. The failure event now carries the manager's reason.
- **BRC-100 key operations, and BEEF V2 and Atomic BEEF.** `Brc100Keys` runs BRC-100's key methods on one root key: BRC-43 protocols, self and anyone counterparties, BRC-42 child keys, BRC-3 signatures, BRC-2 encryption and HMACs, pinned to the ts-stack conformance vectors. `Brc100KeyOperationCommand` runs them in the wallet with an anchor key as root; for payment spend keys it gives out public keys only. `Brc95` reads BEEF V1, V2 (BRC-96) and Atomic BEEF (BRC-95) into V1 and wraps V1 as Atomic, and refuses a BEEF that holds anything but the subject and its ancestors. `DeriveType42DestinationCommand(payerAnchorContext:)` pays with an anchor as the payer key, as a BRC-29 sender to a BRC-100 wallet must.

- **Breaking: Isar is now `isar_community` 3.3.2.** The original `isar` 3.1.0+1
  is unmaintained, and its Android library is aligned to 4 KB pages, which
  Google Play rejects for apps targeting Android 15 or later. `Isar` is part
  of the public API (`LibSpiffyActorSystem.initialize(isar:)`,
  `LibSpiffySchemas`), so hosts must switch too: depend on `isar_community`,
  `isar_community_flutter_libs` and `isar_community_generator` ^3.3.2, change
  `package:isar/isar.dart` imports to `package:isar_community/isar.dart`, and
  regenerate `.g.dart` files. Requires `eventador` 4.0.0 and `duraq_isar`
  3.0.0. Schema ids are unchanged, and databases written by Isar 3.1 open
  without migration (checked in both directions).
- **Hosts on macOS and iOS: the published `isar_community` 3.3.2 binary
  wastes disk space without bound.** It is built on libmdbx
  `v0.13.8-temp-upstream-fix`, which on Apple platforms preallocates the whole
  new file size past the end of the database file every time the file grows,
  and never releases it: a 135 MiB header store holds 1.9 GiB on disk, a full
  testnet header store about 59 GiB. Every Isar database is affected, not
  only headers. libmdbx fixed it in v0.13.9; `isar_community` has not released
  the upgrade (isar-community/isar-community#85, #129). Until it does,
  override both packages with the 3.3.2 build on libmdbx v0.13.12, as
  libspiffy's own `pubspec.yaml` does for `isar_community`:

  ```yaml
  dependency_overrides:
    isar_community:
      git:
        url: https://github.com/stephanfeb/isar-community.git
        ref: 3.3.2-libmdbx-0.13.12
        path: packages/isar_community
    isar_community_flutter_libs: # Flutter apps only
      git:
        url: https://github.com/stephanfeb/isar-community.git
        ref: 3.3.2-libmdbx-0.13.12
        path: packages/isar_community_flutter_libs
  ```

  The fixed binary does not give back space a database already holds past
  its end. With the database closed, extending the file by one page and
  truncating it back to its length releases it.
  `test/storage/isar_disk_allocation_test.dart` fails on the published binary.
- **Mainnet runs on the network it was given, everywhere.** The payment
  channel manager and the default crypto service were started without a
  network and so encoded mainnet settlement outputs as testnet; they now get
  the actor system's network. `WhatsOnChainDataSource` accepts both spellings
  (`main`/`mainnet`, `test`/`testnet`). `NetworkName` is exported so hosts can
  compare network names through one helper.
- **A payment to an address of the other network is refused.**
  `PaymentCoordinatorActor` takes the network (`LibSpiffyActorSystem` passes
  its own) and refuses a P2PKH output, from an invoice's address list or a
  structured output, whose address belongs to the other network ("is a
  mainnet address; this wallet is on testnet"). Both networks share keys, so
  such a payment reached a key the payee owns but a wallet that never sees it,
  and the payer's coins stayed held for it.
- **Mainnet ARC defaults to GorillaPool** (`ArcServiceConfig.gorillaPoolMainnet`,
  no API key). `gorillaPoolTestnet` is available too; testnet still defaults
  to TAAL.
- **Shut LibSpiffy down before closing Isar.** The new Isar core crashes the
  process if the database is closed, or the isolate ends, while writes started
  by wallet creation are still running. `LibSpiffyActorSystem.shutdown()`
  waits for them; closing the actor system alone does not.
- **A payment with no outputs is refused, not a division by zero.**
  `PayInvoiceCommand` with neither `outputs` nor `addresses` split the
  amount over zero addresses and failed with
  `IntegerDivisionByZeroException`, which told an application nothing
  (found by SpiffyVault: a payee whose wallet had refused to create an
  invoice was relayed to the payer as an invoice with no addresses). It
  now fails with an `ArgumentError` saying the invoice has nothing to pay.
- **Reading the chain tip no longer scans the whole header store.**
  `IsarWalletStorage.getChainTip` and `getBestHeight` walked the height
  index from the top with Isar's async `findFirst()`, which in Isar 3
  fetches every matching row and returns the first (only `findFirstSync`
  passes a limit of 1). Every call therefore read and decoded the entire
  header store: over a second on a phone holding testnet's history, paid
  by every SPV check and by every application reading confirmations
  (found by SpiffyVault: a one-second stall opening a wallet, timed to
  the tip read). Both queries now carry `limit(1)`, and the read is a
  one-row index walk. Anyone reading the header store with a descending
  where clause should do the same.
- **A wallet import fetches each transaction once and says so as it goes.**
  `ImportActor` fetched every transaction of every discovered address in
  turn, so a transaction touching several of the wallet's addresses (a
  payment with its change, a consolidation) was fetched — raw hex, proof
  and details, three requests — once per address and dropped as a
  duplicate only afterwards; and it reported progress once per address,
  so an address with hundreds of transactions left an application without
  a word for minutes (found by SpiffyVault: 819 history entries, a UI that
  sat at "Collecting transactions from address 1/…"). The per-address
  histories are now unioned first, each txid is fetched once, and
  `WalletImportProgressEvent` is emitted per transaction:
  `Fetching transactions: n/N` (n fetched with proof, progress 0.40–0.55)
  and then `Recording transactions: n/N` (n recorded through the wallet,
  0.55–0.90), with `totalTransactions` the number of distinct transactions.
  The `Collecting transactions from address i/N` and `Processing
  transactions` messages are gone.
- **An imported transaction's inputs are linked to what they spend.**
  `ImportActor` fetched every parent transaction to compute the fee and
  the sending addresses, then dropped them: `RecordImportedTransaction
  Command.ancestors` was empty for an import, so the wallet projection had
  no evidence for the inputs and left them unlinked (an application showed
  "Unknown" for the amount of every input of a received transaction). The
  fetched parents now travel as the import's ancestors (raw transaction,
  no BUMP), are filed in the ancestor store, and each input gets its
  transaction-address link with the spent output's address and amount.
  Transactions imported before this keep their unlinked inputs until
  re-imported.
- **A wallet import can be resumed.** An import ran in memory only; a host
  killed mid-way (a phone suspended and reclaimed) was left with a wallet
  that looked partly restored and no way to continue. `ImportWalletMessage
  (resume: true)` / `ImportWalletCommand(resume: true)` /
  `LibSpiffyActorSystem.resumeWalletImport` import an existing wallet
  again: the key is read from secure storage (`ImportActor(secureStorage:)`
  — the xpriv or WIF it was imported with, or the mnemonic and passphrase
  it was created with), discovery re-runs, addresses the read model holds
  and transactions it has recorded are skipped, the rest is imported. The
  same message resumes after a kill, retries after a network failure and
  rescans a wallet for history it gained elsewhere; sent while the import
  still runs it is ignored as a duplicate. A watch-only wallet is refused.
  `WalletImportCompletedEvent` / `ImportCompleteEvent` gain
  `transactionsSkipped` (already held) and `transactionsFailed` (could not
  be fetched or proven; not zero means the import is incomplete and a
  resume tries exactly these again).
- **A second import command for a running wallet no longer doubles its
  events.** The coordinator subscribed to the wallet's import notifications
  again without cancelling the first subscription.
- **`WhatsOnChainDataSource` abandons and retries a request that hangs.**
  A request on a connection the network silently dropped (a suspended
  phone, a carrier NAT) hung until the operating system gave up, a minute
  or more, and cost the caller a transaction each time. Requests now time
  out (`requestTimeout`, default 30 s) and a timeout, a dropped or refused
  connection or a failed handshake is retried with the same backoff as a
  429; a 404 or a malformed body is still an answer and is not retried.

## 3.0.1

P2P reaches the network from its DNS seeds again (found by cloak-cli, whose
first testnet and mainnet starts were refused with `Could not connect to any
of 1 peer(s)` although the seeds' nodes were up).

- **Every address of a seed is dialled.** A seed was dialled as one
  `host:port`, which reaches whichever address the resolver lists first; at
  the time two of `testnet-seed.bitcoinsv.io`'s four nodes accepted a
  connection and never answered. Peer entries, named or default, are now
  resolved to every address they hold (`PeerAddresses`), each dialled in
  parallel, and a start fails only if none answers. The error names each
  address, the seed it came from and why it failed, and each failure is
  logged; before, the reasons were collected and dropped.
- **The start goes on at the first peer that answers.** It waited for every
  dial, so one dead address held each start for its connect timeout (19 s
  on testnet). The other dials finish in the background, joining as peers
  or logged as failures; a peer that connects after the system shut down is
  closed rather than left holding its socket.
- **The seeds are the node's own.** `NetworkParams.dnsSeeds` holds them per
  network, replacing a private one-seed list: mainnet `seed.bitcoinsv.io`,
  `seed.satoshisvision.network`, `seed.bitcoinseed.directory`; testnet
  `testnet-seed.bitcoinsv.io`, `testnet-seed.bitcoincloud.net`,
  `testnet-seed.bitcoinseed.directory`, and GorillaPool's
  `testnet.gorillapool.io` and `seed.gorillapool.io`; regtest none.
- **Header sync asks the peer furthest ahead.** `getheaders` went to the
  first connected peer. With every seed address dialled that can be a node
  stuck far behind (one mainnet seed's node reports height 413,551), which
  answers with nothing past its own height. Peers are now asked in order of
  the height their version handshake reported (`inSyncOrder`).

## 3.0.0

Three payment modes, made explicit (spv-understanding.md, "Payment modes"):
both parties online; a service taking payments for an offline payee on the
payee's **delegated chain** (`m/2/i`) and handing them over proven; and a
payer paying an offline payee directly with **type-42 (BRC-42)** keys from an
anchor the payee publishes, one anchor per identity. An xpub wallet's money
is now watch-only, as it always should have been, and a transaction that is
not the wallet's is refused rather than recorded.

### Upgrading from 2.x

- **Change/receive flags are an `AddressChain`, and signing paths a
  `KeyPath`.** Replace `isChange: true` with `chain: AddressChain.change`,
  `SigningPath(i)` with `HdKeyPath(i)`, and the `derivationIndices` /
  `isChangeFlags` of `SignTransactionCommand` with `keyPaths`. See
  **Breaking** below for every renamed member.
- **`AddressMetadata.chain` is nullable**: null for a type-42 address.
- **Stored data needs no conversion.** Journals and snapshots written by 2.x
  replay as they were. Isar adds the new address fields itself. PostgreSQL
  deployments run migrations v025–v027 (`PostgresMigrations.migrate()`); v027
  refuses to roll back while a type-42 address row exists.
- An xpub wallet no longer reports spendable money: its UTXOs are
  `watchOnlyBalance`. An app that showed them as spendable was showing money
  it could not spend.

### Added

- **Payments for an offline payee** (bead libspiffy-m8qu; spv-understanding.md,
  "Payment modes"). A service keeps a payee's xpub as a watch-only wallet and
  answers invoice requests for them; the payee's wallet takes the payment
  once it is mined.
  - A third chain of the HD tree, **delegated** (`m/2/i`): an xpub wallet
    issues every address on it, so the service and the payee's own wallet
    (receive chain, `m/0/i`) can never hand out the same address.
  - `ExportTransactionQuery` / `TransactionExportedEvent`: a proven
    transaction of the wallet as a BEEF carrying its proof. Refused while
    the transaction has no proof verified on our header chain.
  - `ImportTransactionCommand.delegatedIndices`: the payee's wallet derives
    those delegated addresses from its own key, records them (without
    moving its own address counter) and then imports the payment, which it
    can spend like any other.
  - Address discovery (wallet import) scans the delegated chain as well as
    the receive and change chains.
  - `InvoiceCreatedEvent.issuedAddresses` names each address an invoice
    issued with its chain and derivation index (`IssuedAddress`), so the
    payment mode is visible where it is chosen; `TransactionExportedEvent
    .delegatedIndices` carries the indices the payee imports with.
- **`Type42`: BRC-42 (type-42) key derivation.** A payer derives a
  per-invoice destination from the recipient's public key
  (`deriveChildPublic`), and the recipient the matching spend key
  (`deriveChildPrivate`). Pinned to the official BRC-42 test vectors and to
  the Go-verified values of NodeCast's Tier-0 harness. A tweak of 0 mod N
  is refused.
- **Payer-broadcast payments to an offline payee with type-42** (bead
  libspiffy-zxkd; spv-understanding.md, "Payment modes"). No service and no
  xpub: the payer derives the address from the payee's published anchor
  key, broadcasts the payment itself and hands it over.
  - **Anchor keys, one per anchor context** (bead libspiffy-fdal), for a
    wallet that holds its keys: `m/3'/0'/k1'/k2'`, k1 and k2 from
    `SHA-256("libspiffy/type42-anchor" ‖ context)`. Identities sharing a
    wallet publish unrelated anchors; a context carrying an epoch lets an
    app rotate one. An empty context is refused. `IssueAnchorKeyCommand` /
    `AnchorPublicKeyEvent` (journaled once per context,
    `AnchorKeyIssuedEvent`), and `SignWithAnchorKeyCommand` /
    `AnchorSignedEvent` (ECDSA over SHA-256 of a message, RFC 6979, low S;
    byte for byte go-sdk's).
  - `DeriveType42DestinationCommand` / `Type42DestinationEvent`: a
    destination for a recipient's anchor key (and the context it was
    published with, passed through), with a payer key at `m/3'/1'/n'` never
    used twice, and a BRC-29 invoice number unless one is given. Journaled
    (`Type42DestinationDerivedEvent`), so a restarted wallet does not reuse
    a payer key.
  - `ImportTransactionCommand.type42Derivations` and
    `ValidateBEEFCommand.type42Derivations`: the hand-off {anchor, context,
    payer key, invoice number}. The payee's wallet finds the anchor's
    context (its issued anchors first, else the hand-off's, refused unless
    it gives the anchor), derives each destination from its own anchor key,
    journals the derivation (`Type42AddressRecordedEvent`; never a private
    key), takes the payment in and signs for it with the anchor key's
    type-42 child.
  - `TransactionExportedEvent.type42Derivations`: the hand-off for each
    type-42 destination the exported transaction pays, on the payer's side
    and the payee's.
  - `KeyPath` (`HdKeyPath`, `Type42KeyPath`), `Type42Derivation` and
    `Type42Destination` are exported; `AddressMetadata.type42` records a
    type-42 address row. Postgres migration v027 adds its columns.
  - A type-42 output cannot be found from the seed alone: a wallet restored
    by address discovery does not see it, and the payer's hand-off, given
    again, recovers it.
- **The validated header chain is exported**: `BlockHeaderChain`,
  `BlockHeaderAnchor`, `HeaderAcceptResult`, `HeaderRejectReason` and
  `NetworkParams`, for a host that answers header questions from it.

### Breaking

- **`AddressChain` replaces every change/receive flag.** `isChange` becomes
  `chain` on `AddressMetadata`, `DiscoveredAddress`,
  `RegisterDiscoveredAddressCommand`, `AddressDiscoveredEvent` and
  `SignMultisigTransactionCommand`; the `ReadModelStorage` address queries
  take `AddressChain? chain`.
  Journals, snapshots and stored rows written before are read as they were:
  an event or snapshot without a chain reads its `isChange`, and an Isar
  address row keeps `isChange` beside the new nullable `chain`. Postgres
  migration v026 replaces `addresses.is_change` with `chain`.
- **A key's path is a `KeyPath`**: an HD path (`HdKeyPath(index, chain:)`)
  or a type-42 derivation (`Type42KeyPath`). `SigningPath` is gone for it;
  `SignInputCommand.keyPath` replaces `derivationIndex` and `isChange`, and
  `SignTransactionCommand.keyPaths` replaces `derivationIndices` and
  `isChangeFlags`. `AddressMetadata.chain` is null for a type-42 address,
  which is on no chain.
- **`CryptoService`**: `derivePrivateKey(hdKey, addressIndex, {chain})` and
  `deriveAddress(hdPublicKey, addressIndex, {chain, network})` replace
  `derivePrivateKey(hdKey, accountIndex, addressIndex, {coinType, isChange})`
  (whose `accountIndex` was, in fact, the chain) and
  `generateReceivingAddress` / `generateChangeAddress`.
- `BuildFundingTransactionCommand` loses `derivationIndex` and `isChange`,
  which nothing read: channel funding signs each UTXO with its own path.
- `AddressGeneratedResponse` carries the address's `chain`.

### Changed

- The guides moved from `docs/` to `doc/`, pub's layout, beside the audit
  reports already there. `spv-understanding.md`, which the API documentation
  cites throughout, ships with the package.

### Fixed

- **An import was announced before the wallet's read model held it** when
  another wallet of the same process already held the transaction (a payer
  and its payee, or a service and the payee it hands a payment to): the
  wait matched any wallet's row and event of the txid. Every read-model
  wait of the coordinator and the channel manager now names its wallet.
- **A transaction that is not the wallet's was recorded as if it were.**
  One that pays none of the wallet's addresses (nor an invoice of it) and
  spends none of its outputs passed SPV: `ImportTransactionCommand` put it
  in the wallet's history with nothing in it, and `ValidateBEEFCommand`
  submitted it to ARC. Both now refuse it, saying so.

- **An xpub (watch-only) wallet's money was reported as spendable.** Such a
  wallet holds no private key, yet `WalletState.availableBalance`,
  `BalanceResponse.totalBalance`, `ReadModelStorage.getBalance` and the
  wallet row's balances counted its UTXOs, coin selection picked them, and
  signing then failed. Every UTXO of an xpub wallet is now watch-only funds on
  both layers: kept, reported as `watchOnlyBalance`, never spent (bead
  libspiffy-bfs1).
- **The Postgres wallet row recorded every wallet as `hd`**, and the
  in-memory row had no `walletType` at all. `getWallet(id)['walletType']` is
  now the type the wallet was created with, on every backend.

## 2.0.0 and earlier

See [doc/changelog-2.x-and-earlier.md](doc/changelog-2.x-and-earlier.md).
