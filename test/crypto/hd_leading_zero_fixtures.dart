/// Inputs for which dartsv 3.0.0 HD derivation throws
/// `Bad state: Too few elements` (libspiffy-hvp), plus two near misses it
/// derives correctly, all found by a deterministic
/// search: BIP39 mnemonics from Random(n) entropy, a counter over indexes,
/// 32-byte seeds from Random(s). Each fixture's property (which key has a
/// leading zero byte) is asserted where it is used, against the reference in
/// bip32_reference.dart.
library;

/// BIP39 mnemonic (entropy b1375705964c4910184dbeeb0d8d2a2d): m/0 is fine,
/// the receive key m/0/0 has a leading zero byte.
const kShortReceive00Mnemonic = 'raise rival scrap clutch setup marine gentle '
    'result twelve hockey enhance force';

/// BIP39 mnemonic (entropy ebecb8958f647de662364bfd6244caa3): the receive
/// chain key m/0 has a leading zero byte, so every m/0/i derivation throws.
const kShortReceiveChainMnemonic = 'typical grape century burst elephant '
    'veteran match siren word banana crawl elder';

/// BIP39 mnemonic (entropy 3422b06a433c29c97f22e6c44363101f): the change
/// chain key m/1 has a leading zero byte, so every m/1/i derivation throws.
const kShortChangeChainMnemonic = 'crouch better box major secret tool wish '
    'fresh session brand series disease';

/// The fixed test mnemonic used across the suite.
const kAbandonMnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

/// Receive indexes of [kAbandonMnemonic] whose key m/0/i has a leading zero
/// byte (the first three found counting from 0).
/// payment_channel_aggregate_actor_test derived m/0/(clock % 1000000).
const kAbandonShortReceiveIndexes = [113, 349, 945];

/// Near misses that dartsv 3.0.0 derives correctly (guards, not regressions):
/// a seed whose receive chain public key m/0 has an x coordinate with a
/// leading zero byte (serP must stay 33 bytes in the HMAC input) ...
const kShortChainPubXSeed =
    'a419b25a48672733c4cdd7485eff60de9fc84d434b62d13d03e496058edb59c8';

/// ... and a seed whose master private key has a leading zero byte
/// (ser256(k) must stay 32 bytes in a hardened HMAC input).
const kShortMasterSeed =
    '9a11d8b5211e1464bf917362a1b1080f54704e2c6ea8771e9b175d0f09085ed6';
