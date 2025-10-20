Note
Search Substack
Craig’s Substack

Craig’s Substack
IP-to-IP Negotiated Notes: An ECDH-Derived, Multi-Transfer Wallet Protocol for Private, Settled Digital-Cash Payments
Designing an address-unlinkable, constraint-aware payment workflow where both parties can transmit and settle, using per-invoice ECDH derivations and semi-randomised note splitting
Craig Wright
Aug 26, 2025
Keywords
Bitcoin (BSV); ECDH; secp256k1; SHA-256; RIPEMD-160; invoice hash; deterministic per-note keys; P2PKH; multi-transfer; note-splitting; either-side broadcast; receipts

Abstract
This work specifies a Bitcoin wallet workflow that conducts direct IP-to-IP negotiation between two identified parties and settles a payment as many independent on-chain transactions (“notes”). Identity keys are used only for ECDH and message authentication; they never appear on-chain. For each invoice and note index, a shared secret and an invoice fingerprint deterministically derive a unique recipient public key, ensuring unlinkability outside the two parties. The payer splits the total into bounded denominations agreed with the recipient and constructs one standard P2PKH transaction per note. Each transaction is funded with a disjoint input set and (if required) returns change to a per-note sender address derived deterministically so that change never overlaps across notes. Either party may submit any subset of fully signed transactions at any time; settlement is established by confirmation depth. The paper formalises notation, message frames, per-note key derivation, deterministic bounded splitting, disjoint coin-selection and change algorithms, ordering and pacing of broadcasts, selective-disclosure receipts, reissue rules prior to broadcast, and behaviours under reorgs. The result is a practical, auditable, and privacy-preserving method to enforce recipient constraints while keeping every note an independent on-chain payment.

Bitcoin IP-to-IP Note Settlement: Purpose, Rationale, and Implementation
What it is

A payment is settled as a set of small, standard on-chain transactions (“notes”), each paying a bounded amount to a unique address that only the recipient can spend. Bounds (per-note minimum and maximum) are negotiated up front, and the total is split into note amounts that sum exactly to the invoice total. Every note is valid on its own, funded by inputs that no other note in the same invoice uses, and optionally returns change to a unique, invoice-scoped sender address. Either side may submit any note to the network; confirmation depth defines settlement for that note.

Two long-lived identity keys authenticate the off-chain session and never appear on-chain. A per-invoice shared element derived from those identities, together with the hash of the canonical invoice JSON, scopes all derivations: per-note recipient addresses, per-note sender change addresses, the exact split of amounts, labels, and receipts. Because the scope is per invoice, derivations are never reused across invoices, and the same index i under a different invoice produces unrelated addresses.

Why it exists

• Policy-compliant intake for the payee. A recipient can publish firm bounds and a fee-rate floor once, then accept large totals without ever receiving an out-of-policy note. This simplifies operations and avoids exposing internal wallet structure.
• Determinism and symmetry for the payer. The payer derives exactly the same note set the recipient expects, without shipping secrets or bespoke scripts. If both ends can parse the same canonical JSON and run the same hashes and curve operations already used in Bitcoin, they interoperate.
• Audit without surveillance. A Merkle root commits to the entire set of notes. Later, either party can reveal proofs for any subset (for example, to an auditor) without disclosing the remainder. Off-chain logs are signed by identity keys, allowing reconstruction of intent without putting identities on-chain.

All of this uses only primitives that already exist in Bitcoin: secp256k1 keys, SHA-256 and RIPEMD-160, standard P2PKH outputs, and raw transaction serialisation. No new opcodes, no new script types, no new cryptographic gadgets.

What it does (functional view)

Identity and scope. Alice (payer) and Bob (payee) authenticate using long-lived identity keypairs. They exchange two compact, signed messages: the policy (Bob’s bounds, anchor, fee floor, expiry) and the invoice (Alice’s total, unit, terms, and a reference to the policy). From these they compute (i) a shared element via ECDH and (ii) the invoice fingerprint, the SHA-256 hash of the canonical invoice JSON. The pair {Z, H_I} defines the scope for everything that follows.

Bounded splitting. Within the published bounds, the total is decomposed into N note amounts. The number N is feasible by construction (between ceil(T ÷ v_max) and floor(T ÷ v_min)). The amounts are derived deterministically from {Z, H_I} so both parties compute the same vector and then permute it to remove any index-to-size correlation. Off-chain, the split leaks only that each note lies within bounds.

Per-note addressing. For each index i, the payer derives the recipient’s public key for that note by tweaking the recipient’s on-chain anchor with a scalar computed from {Z, H_I, i} and a role label. Only the recipient can compute the corresponding private key. In the same scope, the payer derives a unique sender change address for index i. Identity keys are never used on-chain; only anchors appear in settlement keys.

Disjoint funding and change. The payer assigns a strictly disjoint set of inputs to each note from a snapshot of her UTXO pool. No input appears in two notes. A standard size estimator and the negotiated fee-rate floor decide whether a note has one output (exact) or two (payee + change). When present, change always pays to the per-note sender change address. Change from one note never funds another note in the same invoice.

Transaction formation and broadcast. Each note is a standard P2PKH transaction, fully signed and valid in isolation. Either party may broadcast any subset; duplicate submission is benign. Broadcast may be all-at-once, paced, or in bursts; confirmation depth chosen by the recipient defines finality per note.

Receipts and selective disclosure. After notes exist, each side can compute a per-note leaf that commits to the index, txid, amount, and address payload, and then a Merkle root over the set of leaves. The root and a manifest of indices and txids provide a commitment that later supports selective proofs for any subset.

Failure handling. Deterministic behaviours cover insufficient inputs, pre-broadcast fee changes, external conflicts, reorgs, and expiry. Reissue preserves indices and addresses; older raw bytes are marked “superseded” off-chain and are not broadcast.

How it does it (implementation narrative)

Module 1 — Canonical JSON and signing. Provide byte-identical encodings of policy, invoice, logs, and receipts. Every signed artefact includes a detached signature made by the relevant identity key over the canonical bytes (signature fields omitted from the preimage). This guarantees both sides hash the same content when computing the invoice fingerprint and policy hash.

Module 2 — Scope and derivations. Given {Z, H_I}, derive deterministically: (a) per-note recipient keys (label “recv”), (b) per-note sender change keys (label “snd”), (c) the split of amounts (label “split”), and (d) any pacing schedule (label “pace”). Output: reproducible addresses, labels, and amounts that both wallets compute locally without sharing per-note data.

Module 3 — Coin selection with reservation. Take a snapshot of the payer’s spendable UTXOs and allocate disjoint input sets to each note. Preference order: exact matches; then single-input near-over with valid change; then few-input combinations with minimal overshoot, always respecting dust and fee floors. If inputs are too coarse, perform one payer→payer fan-out and restart reservations. Reservations are tagged by the note identifier so rebuilding from logs yields the same table.

Module 4 — Transaction builder. For each index, combine reserved inputs with the payee output (and optional change), order inputs and outputs deterministically, compute the fee at the floor, and sign every input in the standard way. Output: raw transaction bytes and txid per note. Log the per-note metadata (index, note id, invoice hash, recipient address, amount, txid) with signatures.

Module 5 — Broadcast manager. Compute a nominal plan (all-at-once, paced, or bursts) using seeds derived from {Z, H_I}. Either side may submit; duplicate submissions yield the same txid. Periodic rebroadcast continues until the recipient’s depth is reached or a note is cancelled or reissued. Hold-time limits trigger automatic reissue or cancel actions; all transitions are signed in the log.

Module 6 — Receipts and proofs. Compute the Merkle root over per-note leaves and store a manifest of indices and txids. Later, produce compact proofs for any subset by disclosing only those leaves and paths; a verifier recomputes the root without learning undisclosed notes.

Module 7 — Logging and audit. Every state transition—reservation, signing, broadcast, reissue, cancel, orphan—is recorded as canonical JSON with timestamps and identity signatures and chained by a “prev_hash” field. Given these logs plus the public chain, an auditor can reconstruct the intended settlement set and verify that exactly one transaction per index was meant to settle.

The need and its consequences

Operational fit. Many recipients want steady, bounded inflows rather than sporadic large hits. By decomposing a purchase into bounded notes, intake risk and internal accounting become simpler, while the payer gains a clear, deterministic procedure that never leaks identity keys on-chain.

Robustness. Notes are independent and inputs are disjoint, so partial progress is meaningful: a subset can confirm while the rest are queued or reissued. Reorg handling is straightforward: rebroadcast the same bytes.

Privacy by construction. Identity keys stay off-chain. Per-invoice and per-note derivations require the off-chain scope to reproduce, so outsiders cannot link the recipient’s addresses across the set. Change addresses are unique per note, defeating shared-change clustering. Pacing reduces simple time-based clustering. Selective receipts allow proving exactly what is needed—no more.

Determinism and interoperability. Independent implementations that follow the rules produce the same addresses, the same split, the same reservations, and the same receipts. Disputes are resolvable by recomputation from signed logs.

Scope discipline. Binding all derivations to {Z, H_I} prevents cross-invoice reuse. Index i is meaningful only within the invoice that defined it. This keeps the address space clean and prevents accidental collisions when many invoices are active.

Limitations and boundaries

The design uses standard transaction forms and well-understood cryptographic primitives. It does not compress notes into nonstandard constructs, introduce new script paths, or rely on external relays. Fees and confirmation policies remain subject to network conditions. The payer’s own inputs are clustered within each note by necessity; the privacy goal here is to avoid linking recipient notes to each other, not to conceal that a single payer funded each note.

What it means

This recentres Bitcoin settlement on two authenticated endpoints who deterministically derive everything needed for a payment and act independently to bring it to finality. The outcome is not merely “many small transactions”; it is a protocol for invoice-scoped, symmetric, auditable settlement:

• Invoice-scoped: every artefact—addresses, amounts, labels, receipts—derives from the invoice fingerprint and shared element.
• Symmetric: either party can complete settlement of any note at any time.
• Auditable: small, signed JSON records and a single Merkle root suffice to reconstruct and prove the payment’s history.

An engineer following the formal sections can implement these modules with no new cryptography, no changes to standard transaction formats, and no special network behaviour. A reader evaluating the design can see what it is, why it exists, how it works, and what it achieves, while staying strictly within Bitcoin’s established toolset.

1. Objective and model
   Objective. Specify a direct, invoice-scoped payment workflow in Bitcoin in which two principals — Alice (payer) and Bob (payee) — agree explicit bounds for the value of each note and settle a total as many independent on-chain transactions. Each note is a standard transaction paying a bounded amount to a unique recipient address computable by the payer yet spendable only by the payee. Identity keys have a single role: authenticate the off-chain session and yield shared material that scopes all deterministic derivations; identity keys never appear in locking scripts, never fund or receive outputs, and never enter the on-chain graph. “IP-to-IP” denotes a direct, mutually authenticated message channel adequate to exchange compact UTF-8 JSON documents and raw transaction serialisations; transport mechanics are outside scope and irrelevant to correctness. Either party may submit any fully formed note at any time; settlement finality is defined solely by the confirmation depth the payee requires for that note. The design enforces three global guarantees: note independence, strict non-overlap of inputs, and determinism sufficient for audit and replay.

Actors and keys. Alice maintains a long-lived identity pair Kₐ = (kₐ, Pₐ) and a sender anchor A = a·G used only to derive per-note change addresses. Bob maintains a long-lived identity pair Kᵦ = (kᵦ, Pᵦ) and a recipient anchor B = b·G used only to derive per-note receiving keys. Identity keys authenticate and scope; anchors settle on-chain. For each invoice the parties compute a shared secret
Z := ECDH(kₐ, Pᵦ) = ECDH(kᵦ, Pₐ),
and an invoice fingerprint
Hᴵ := SHA-256(canonical-JSON(invoice)),
which together bind all subsequent derivations to that invoice.

Scope and channel model. The off-chain state for a payment is a finite, authenticated transcript: policy → invoice → acknowledgements → (optional) per-note metadata → (optional) raw transactions → receipts. The only required capability of the channel is confidential, integrity-protected exchange of these small artefacts; routing, addressability, and link maintenance are orthogonal and out of scope.

Payment decomposition. Let T be the invoice total (in the smallest unit) and let the payee’s bounds be [vₘᵢₙ, vₘₐₓ] with 0 < vₘᵢₙ ≤ vₘₐₓ. The payment is decomposed into N ≥ 2 notes with amounts
a = (a₀, a₁, …, aₙ₋₁),
such that for every index i:
vₘᵢₙ ≤ aᵢ ≤ vₘₐₓ and Σ aᵢ = T.
Feasibility requires ⌈T ÷ vₘₐₓ⌉ ≤ N ≤ ⌊T ÷ vₘᵢₙ⌋. The pair (N, a) and all per-note labels are deterministically derived from (Z, Hᴵ) and the accepted policy so that both parties — given the same inputs — arrive at the identical target set without exchanging per-note values in the clear.

Recipient addressing (model-level). For each index i ∈ {0, …, N−1} a unique recipient public key Pᴮ,ᵢ is derived so that: (1) Alice can compute Pᴮ,ᵢ and therefore the standard address Addrᴮ,ᵢ for the note; (2) only Bob can compute the corresponding private key kᴮ,ᵢ that spends from Addrᴮ,ᵢ; (3) no two notes of the invoice share a recipient key; and (4) observers lacking Z and B cannot link these addresses to identities or to one another.

Funding and change (model-level). Let U be Alice’s snapshot of available unspent outputs at construction time. A reservation mapping R assigns to each index i a finite, exclusive input set Sᵢ ⊆ U with pairwise disjointness Sᵢ ∩ Sⱼ = ∅ for all i ≠ j. Each note transaction Tᵢ is funded only by Sᵢ. Where change is required, it is paid to a per-note sender address Addrᴬ,ᵢ derived deterministically from (Z, Hᴵ) and the sender anchor A. Change from one note never overlaps with change from any other note in the same invoice and is never selected to fund a different note of that invoice; intra-invoice reuse is prohibited by construction.

Broadcast and finality. Because every Tᵢ is fully formed and independent, either party may broadcast any subset in any order or schedule (all-at-once, paced, or opportunistic). Settlement finality for a note is established when its transaction to Addrᴮ,ᵢ reaches the payee’s required confirmation depth d. Duplicate submission is benign. Conflicts cannot arise within the invoice because input sets are disjoint.

Determinism and auditability. Determinism is a first-class requirement: given the same policy, invoice fingerprint, identities, and input snapshot U, both parties compute the same (N, a), the same recipient and change address sets (Addrᴮ,ᵢ, Addrᴬ,ᵢ), and the same per-note labels. A complete audit is reconstructible from persisted canonical JSON logs and the chain: the invoice and policy, Hᴵ, the mapping i ↦ txidᵢ, and an optional Merkle root over note receipts. No external oracle is required to re-derive or verify the set.

Definitions (normative)

D1 — Policy. A signed statement by the payee declaring [vₘᵢₙ, vₘₐₓ], any per-address cap (≤ vₘₐₓ), a fee-rate floor, and an expiry; hashed and referenced by the invoice.

D2 — Invoice. A signed statement by the payer declaring T, unit, terms, invoice number, and the hash of the accepted policy; its canonical hash Hᴵ scopes all derivations.

D3 — Note. A single standard on-chain transaction Tᵢ that pays aᵢ to Addrᴮ,ᵢ and, if necessary, returns change to Addrᴬ,ᵢ; valid, complete, and broadcastable in isolation.

D4 — Reservation. An exclusive assignment R(i) = Sᵢ of inputs to index i with Sᵢ ∩ Sⱼ = ∅ for i ≠ j.

D5 — Either-side broadcast. The right of both principals to announce any subset of {Tᵢ}; correctness and finality depend only on confirmation depth.

Invariants (safety and liveness)

I1 — Identity/settlement separation: identity keys authenticate and scope derivations; anchors alone appear in locking scripts.
I2 — Per-invoice scoping: all per-note derivations and labels are functions of (Z, Hᴵ); nothing is reused across invoices.
I3 — Note independence: each Tᵢ is valid without reference to any Tⱼ; no chained dependence within the invoice.
I4 — Disjoint inputs: Sᵢ ∩ Sⱼ = ∅ for all i ≠ j; input reuse within an invoice is impossible by construction.
I5 — Determinism: for fixed inputs (policy, invoice, Kₐ, Kᵦ, U) both parties derive the same (N, a), address sets, and labels.
I6 — Non-overlapping change: for any i ≠ j, change outputs of Tᵢ and Tⱼ pay to distinct Addrᴬ,ᵢ and Addrᴬ,ⱼ and are never selected to fund another note of the same invoice.
I7 — Finality by confirmation: a note is settled when its transaction has ≥ d confirmations to Addrᴮ,ᵢ; other notes are unaffected.
I8 — Multiplicity: the cardinality of the note set satisfies |{Tᵢ}| = N ≥ 2; aggregation into a single multi-output transaction is out of model.

2. Primitives, notation, and encodings
   Keys and curve (secp256k1). Private keys are scalars k in the range 1 ≤ k ≤ n−1 over the prime field 𝔽ₚ, with p = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F (decimal p = 2²⁵⁶ − 2³² − 977). The base point (generator) G has order n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141. Public keys are elliptic-curve points P = k·G on the curve y² = x³ + 7 (mod p). Private scalars are represented as fixed-length 32-byte big-endian values when serialised; public keys are represented in compressed SEC1 form (see serP).

Generator G. G is the unique base point defined by secp256k1 with affine coordinates (x_G, y_G) on 𝔽ₚ. All public keys and derivations are computed by scalar multiplication on this generator, using constant-time algorithms. No alternative generator is permitted; all parties MUST compute on the canonical G to guarantee interoperation and reproducibility.

Group order n. The order n is the prime 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141. All scalar arithmetic (addition, subtraction, multiplication) is carried out modulo n. Any derived scalar equal to 0 is invalid and MUST be skipped deterministically (e.g., by advancing the index) to maintain a one-to-one mapping between indices and usable keys.

ECDH shared element Z. ECDH(k, P′) is defined as the 32-byte big-endian x-coordinate of the point k·P′, where k is the caller’s private scalar and P′ is the counterparty’s public point. The raw ECDH output used in this specification is Z, a 32-byte array (left-padded with zeros if necessary). Only the x-coordinate is used; no further key-derivation primitive is introduced in this section.

Hash functions H and H160. H(x) denotes SHA-256 over the exact byte sequence x, returning 32 bytes. H160(x) denotes RIPEMD-160(SHA-256(x)), returning 20 bytes. All inputs to H and H160 are byte strings formed by the concatenation conventions defined below; strings such as literal labels (“recv”, “snd”, “split”) are 7-bit ASCII bytes in the concatenation, not hex text.

Generator-based serialisation serP(P). serP(P) denotes the compressed SEC1 encoding of the public point P: a single prefix byte 0x02 if y(P) is even or 0x03 if y(P) is odd, followed by the 32-byte big-endian x-coordinate. This yields 33 bytes. Uncompressed encodings (0x04 + x + y) are not used in this specification.

Base58Check(version ∥ payload ∥ checksum). Addresses are Base58Check encodings of a 1-byte version, a payload, and a 4-byte checksum. For pay-to-public-key-hash (P2PKH), version = 0x00, payload = H160(serP(P)), checksum = first four bytes of SHA-256(SHA-256(version ∥ payload)). The encoded address is the Base58 string of version ∥ payload ∥ checksum with no whitespace, no separators, and no leading “0x”.

Concatenation operator “∥”. The operator “∥” denotes byte-level concatenation: if x and y are byte strings, then x ∥ y is the byte string consisting of x immediately followed by y. When concatenating integers (other than LE32 below) they MUST first be encoded as fixed-length big-endian byte strings of their canonical size (e.g., 32 bytes for secp256k1 scalars). When concatenating literal labels, the labels are included as their raw ASCII bytes. No implicit conversions are permitted.

Little-endian index LE32(i). LE32(i) is the 4-byte little-endian encoding of the non-negative integer i modulo 2³². If i ≥ 2³², then LE32(i) = LE32(i mod 2³²). The index domain for this specification is 0 ≤ i ≤ 2³²−1; indices outside this range are invalid. LE32 is used only where explicitly stated; all other integers are big-endian.

Invoice fingerprint H_I. The invoice fingerprint H_I is a 32-byte value defined as H(canonical_json(invoice)). The function canonical_json(·) produces an unambiguous UTF-8 byte sequence for the invoice object according to the encoding rules below (key ordering, whitespace, numeric form, and normalisation are fixed). Any party recomputing H_I over the same invoice MUST obtain the same 32-byte value.

Note identifier NoteID. For a given invoice fingerprint H_I and note index i, the note identifier is NoteID = H(H_I ∥ LE32(i)), a 32-byte value. NoteID uniquely labels a note within an invoice scope; it MUST be used in off-chain logs, reservation locks, and receipts to reference the note without revealing addresses or amounts. For fixed H_I, distinct indices yield distinct NoteIDs up to the collision resistance of SHA-256.

Encoding rules for canonical JSON (normative).

• Character encoding. All JSON text is encoded as UTF-8. No byte order mark (BOM) is permitted.

• Unicode normalisation. All JSON string values MUST be normalised to NFC prior to byte-level serialisation. Field names are ASCII and need no normalisation.

• Object key order. Within every JSON object, keys MUST be sorted in strict lexicographic order by Unicode code point of the key strings (e.g., “addr” < “amount” < “invoice_hash” < “txid”). No deviations per locale are allowed.

• Whitespace. No insignificant whitespace is permitted in canonical JSON. Specifically: no spaces or tabs before or after “:”; no spaces after “,”; no trailing commas; no leading or trailing spaces around values. Arrays and objects are compact (e.g., {"a":1,"b":2}).

• Numbers. Integers are encoded in base-10 without leading zeros (except zero itself, which is “0”). No “+” sign. No fractional or scientific notation unless the field is explicitly defined as a float; in that case, use the shortest round-trip decimal form that parses identically (IEEE-754 round-trip), with a dot as decimal separator.

• Booleans and null. Encode as the lowercase literals “true”, “false”, and “null”.

• Byte strings. Fields that carry bytes (keys, hashes, signatures) are encoded as lowercase hexadecimal strings without “0x” prefix, unless a field is explicitly defined to contain Base58 (addresses) or base64url. For public keys, use hex of serP(P). For hashes (H, H160), use full-length lowercase hex.

• Time. Timestamp fields use ISO-8601 basic or extended form with UTC “Z” (e.g., “2025-08-26T00:00:00Z”). Offsets other than “Z” are not permitted in canonical form.

• Field presence. All required fields MUST appear exactly once. Optional fields MUST be omitted (not null) when absent.

• Determinism. canonical_json(x) is the byte sequence obtained after applying all the above rules; H_I is computed over those exact bytes. Any semantically equivalent but differently formatted JSON MUST NOT be used for hashing.

Unambiguous definitions (summary).

• H_I := H(canonical_json(invoice)) ∈ {0,1}²⁵⁶. This binds all derivations to a single, byte-exact invoice representation. Any alteration of any invoice field (including reordering or whitespace) changes H_I.

• NoteID := H(H_I ∥ LE32(i)) ∈ {0,1}²⁵⁶. This labels note i within the scope of H_I. NoteIDs are independent of addresses, amounts, and inputs; they exist to coordinate construction, logging, and receipts without exposing settlement details.

Implementation notes (conformance).

• All scalar reductions are mod n; all field reductions are mod p. Any derived scalar equal to 0 MUST trigger deterministic skip logic to preserve a total, collision-free mapping from indices to usable keys.

• All cryptographic hashes operate on the exact concatenated byte strings as defined; mixing hex text with raw bytes is an error. Literal labels used for domain separation are 7-bit ASCII and MUST be included as their byte values.

• Base58Check outputs are case-sensitive and MUST match the standard Bitcoin alphabet; no whitespace or line breaks are permitted in encoded addresses.

• When serialising or parsing serP(P), only 33-byte compressed encodings (0x02/0x03 + x) are valid in this specification; 65-byte uncompressed form MUST be rejected.

3. Identities, policy, invoice, and scope
   3.1 Roles and key material
   Alice (payer) holds a long-lived identity pair Kₐ = (kₐ, Pₐ) on secp256k1. Bob (payee) holds a long-lived identity pair Kᵦ = (kᵦ, Pᵦ) and a distinct settlement anchor b/B with B = b·G. Identity keys authenticate and sign off-chain artefacts; they do not appear in locking scripts. The anchor B is the sole on-chain base from which Bob’s per-note recipient keys are derived. Identity and anchor domains are strictly separated: kₐ, kᵦ are never used to authorise on-chain spends; b is never used to sign off-chain identity artefacts.

3.2 Shared secret and invoice scope
For each invoice, both parties compute a shared element
Z := ECDH(kₐ, Pᵦ) = ECDH(kᵦ, Pₐ) (32-byte x-coordinate, big-endian).
Define the invoice fingerprint
Hᴵ := H(canonical_json(invoice)) (SHA-256 over the exact UTF-8 bytes).
All derivations and labels for this invoice are functions of the pair {Z, Hᴵ}. This scoping is normative: any key, address, amount split, label, or receipt that does not include {Z, Hᴵ} in its preimage is invalid for this specification. Cross-invoice reuse is forbidden by construction because Hᴵ is invoice-unique and Z is recomputed per counterparty pair.

3.3 Policy (payee → payer): JSON schema and signature
Bob issues a signed policy describing bounds and operational parameters that the payer must satisfy when constructing notes. The policy is a single JSON object encoded canonically (see §2), then signed by Bob’s identity key kᵦ.

Canonical key order and field types (normative):

"pk_anchor": string — hex(serP(B)), 66 chars (0x02/0x03 + 64 hex).

"vmin": integer — minimum per-note amount (smallest unit), vmin > 0.

"vmax": integer — maximum per-note amount (smallest unit), vmax ≥ vmin.

"per_address_cap": integer — cap per derived recipient address; MUST satisfy vmin ≤ per_address_cap ≤ vmax.

"feerate_floor": integer — minimum fee-rate in units-per-byte (smallest unit per virtual byte), feerate_floor ≥ 1.

"expiry": string — ISO-8601 UTC, e.g., "2025-08-26T00:00:00Z".

"sig_key": string — hex(serP(Pᵦ)), Bob’s identity public key in compressed SEC1 hex.

"sig_alg": string — "secp256k1-sha256".

"sig": string — hex(ECDSAₖᵦ(SHA-256(canonical_json(policy_without_sig_fields)))).

Constraints and verification (normative):
• pk_anchor MUST equal the compressed SEC1 encoding of B; the private b MUST be distinct from kᵦ.
• vmin MUST be ≥ the current dust threshold; vmax MUST be ≥ vmin; per_address_cap MUST be within [vmin, vmax].
• feerate_floor MUST be a positive integer measured per byte; both parties compute size estimates identically.
• expiry MUST be strictly in the future at the time of acceptance.
• sig MUST verify under sig_key over the canonical bytes of the policy with "sig", "sig_key", "sig_alg" omitted from the preimage.
• H_policy := H(canonical_json(policy)) is the stable identifier referenced by the invoice.

Canonical skeleton (bytes hashed exactly as shown, no whitespace other than mandated):
{"pk_anchor":"…","vmin":…,"vmax":…,"per_address_cap":…,"feerate_floor":…,"expiry":"…","sig_key":"…","sig_alg":"secp256k1-sha256","sig":"…"}

3.4 Invoice (payer → payee): JSON schema and signature
Alice issues a signed invoice binding the total to the accepted policy and establishing the scope Hᴵ. The invoice is a single JSON object encoded canonically and signed by Alice’s identity key kₐ.

Canonical key order and field types (normative):

"invoice_number": string — UTF-8 identifier under the payer’s namespace.

"terms": string — UTF-8 human-readable terms or reference thereto.

"unit": string — unit of account label (e.g., "sat", "USD" when quoting; settlement remains on-chain).

"total": integer — total amount in the smallest settlement unit.

"policy_hash": string — hex(H_policy) computed from the accepted policy in §3.3.

"expiry": string — ISO-8601 UTC, optional but recommended; if present, MUST be in the future.

"sig_key": string — hex(serP(Pₐ)), Alice’s identity public key in compressed SEC1 hex.

"sig_alg": string — "secp256k1-sha256".

"sig": string — hex(ECDSAₖₐ(SHA-256(canonical_json(invoice_without_sig_fields)))).

Constraints and verification (normative):
• policy_hash MUST equal H_policy of the policy accepted for this invoice.
• total MUST satisfy feasibility with the accepted bounds: ⌈total ÷ vmax⌉ ≤ N ≤ ⌊total ÷ vmin⌋ for some integer N ≥ 2 (checked later during split).
• sig MUST verify under sig_key over the canonical bytes of the invoice with "sig", "sig_key", "sig_alg" omitted from the preimage.
• Hᴵ MUST be computed as H(canonical_json(invoice)) after the signature is attached; the same Hᴵ MUST be used in all subsequent derivations for this invoice.

Canonical skeleton:
{"invoice_number":"…","terms":"…","unit":"…","total":…,"policy_hash":"…","expiry":"…","sig_key":"…","sig_alg":"secp256k1-sha256","sig":"…"}

3.5 Authenticity and scoping procedure (end-to-end)

Bob constructs the policy object with fields 1–6, sets sig_key = hex(serP(Pᵦ)), sig_alg = "secp256k1-sha256", signs the canonical bytes of the object excluding the signature triplet, and attaches sig. He sends the exact UTF-8 bytes.

Alice verifies pk_anchor structure, bounds, feerate_floor, expiry, and the signature under Pᵦ; she computes H_policy = H(canonical_json(policy)).

Alice constructs the invoice object with fields 1–6, sets sig_key = hex(serP(Pₐ)), sig_alg = "secp256k1-sha256", signs the canonical bytes excluding the signature triplet, attaches sig, and sends the exact UTF-8 bytes.

Bob verifies policy_hash matches his H_policy, checks total and (optional) expiry, verifies Alice’s signature under Pₐ, and computes Hᴵ = H(canonical_json(invoice)).

Both compute Z := ECDH(kₐ, Pᵦ) = ECDH(kᵦ, Pₐ). The tuple {Z, Hᴵ} is recorded as the sole cryptographic scope for this invoice. Any per-note recipient key, sender change key, amount split, label, reservation lock, or receipt root that does not include {Z, Hᴵ} in its preimage MUST be rejected.

3.6 Security properties (normative)
• Domain separation by {Z, Hᴵ} prevents cross-invoice linkage and replay: the same index i under a different invoice produces unrelated recipient and change keys.
• Identity/anchor separation prevents misuse of long-term identity material on-chain and constrains blast radius of compromise: kₐ or kᵦ compromise does not expose b; b compromise affects only settlement keys, not identity assertions.
• Signatures bind human-readable terms to cryptographic scope: any alteration of policy or invoice (including key order or whitespace) changes the hash and invalidates the signature.

3.7 Rejection conditions (must fail)
• Missing or malformed "pk_anchor", "sig_key", or signatures in either artefact.
• vmin ≤ 0, vmax < vmin, per_address_cap outside [vmin, vmax], feerate_floor ≤ 0, or expired artefacts.
• policy_hash mismatch between invoice and policy.
• Failure to compute Z (invalid public keys).
• Any attempt to reuse an existing Hᴵ for a different set of invoice fields.

This section defines the precise identities, artefacts, and scoping required so that the remainder of the construction (per-note derivations, bounded splitting, disjoint funding, and receipts) operates deterministically and remains auditable without revealing identity keys on-chain.

4. Deterministic per-note recipient keys (sender can address; recipient alone can spend)
   4.1 Inputs and domain separation
   Inputs: the recipient anchor B = b·G (public), the per-invoice shared element Z (32 bytes), and the invoice fingerprint Hᴵ (32 bytes). Domain separation: the literal ASCII label “recv” is included in the preimage; indices use LE32(i). All byte concatenations are with the operator “∥”. Identity keys never appear on-chain.

4.2 Scalar derivation per note
For each note index i ≥ 0 derive a scalar tᵢ as a function of {Z, Hᴵ, i}:
tᵢ := int( SHA-256( Z ∥ Hᴵ ∥ "recv" ∥ LE32(i) ) ) mod n.
Reject-zero rule: if tᵢ = 0, re-derive with a counter appended until non-zero, leaving the index stable:
tᵢ := int( SHA-256( Z ∥ Hᴵ ∥ "recv" ∥ LE32(i) ∥ LE32(ctr) ) ) mod n, where ctr = 1,2,… until tᵢ ≠ 0.
This “counter bump” preserves a one-to-one mapping from index i to a usable scalar without shifting indices and without introducing a new primitive.

4.3 Recipient public key and address (sender view)
The sender computes the per-note recipient public key by a single public-key tweak anchored at B:
Pᴮ,ᵢ := B + tᵢ·G.
Encode the recipient address as a standard P2PKH address:
Addrᴮ,ᵢ := Base58Check( 0x00 ∥ H160( serP( Pᴮ,ᵢ ) ) ).
Properties: (a) Pᴮ,ᵢ ≠ B because tᵢ ≠ 0; (b) for fixed B, different i give independent points with overwhelming probability; (c) the sender never learns any private scalar corresponding to Pᴮ,ᵢ.

4.4 Recipient private key (recipient view)
Only the recipient, who knows b, computes the spending scalar:
kᴮ,ᵢ := ( b + tᵢ ) mod n,
with corresponding public key Pᴮ,ᵢ = kᴮ,ᵢ·G by linearity. The recipient uses kᴮ,ᵢ to spend outputs paid to Addrᴮ,ᵢ. The base scalar b is never revealed and never used to sign off-chain artefacts.

4.5 Collision resistance and non-reuse
Per-invoice scope: because tᵢ is a function of (Z, Hᴵ, "recv", i), two different invoices (different Hᴵ and/or Z) produce unrelated tᵢ values even at the same index. Per-note uniqueness: for a fixed invoice and anchor B, equality Pᴮ,ᵢ = Pᴮ,ⱼ with i ≠ j would require tᵢ ≡ tⱼ (mod n), which has negligible probability under SHA-256. Cross-role separation: the label “recv” fixes the derivation to recipient keys and prevents accidental overlap with other derivation namespaces (e.g., sender change which uses a different label).

4.6 One-wayness (proof sketch)
Sender cannot recover kᴮ,ᵢ. The sender knows tᵢ and the public keys B and Pᴮ,ᵢ = B + tᵢ·G. Suppose the sender could compute kᴮ,ᵢ from these. Then b ≡ kᴮ,ᵢ − tᵢ (mod n) would be recoverable, yielding the discrete logarithm of B to the base G. This contradicts the hardness of the elliptic-curve discrete logarithm problem on secp256k1. Therefore, learning kᴮ,ᵢ without b is infeasible.
Outsiders cannot link Pᴮ,ᵢ across notes or invoices. An observer sees addresses derived from Pᴮ,ᵢ but lacks Z and typically lacks Hᴵ. Without Z the observer cannot reproduce tᵢ, hence cannot predict or recognise the set {Pᴮ,ᵢ}. Because Pᴮ,ᵢ = B + tᵢ·G with tᵢ pseudorandom in [1, n−1], the distribution of Pᴮ,ᵢ is computationally indistinguishable from uniform over the subgroup generated by G given B, and linkage reduces to breaking the preimage resistance of SHA-256 or the ECDLP.

4.7 Side-channel and constant-time requirements
Scalar and point operations MUST be executed in constant time with respect to secret values (b and kᴮ,ᵢ). Implementations MUST avoid secret-dependent branches and table lookups during scalar multiplication and addition. The reduction “mod n” MUST be constant time. The counter-bump loop executes at most a negligible expected number of iterations (usually zero); its decision is data-independent with respect to b and only depends on the public hash tᵢ = 0 test, which is uniform at 1/n.

4.8 Derivation pseudocode (Unicode, canonical, no LaTeX)

Inputs
• Z: 32-byte ECDH element (x-coordinate).
• Hᴵ: 32-byte invoice fingerprint.
• B: recipient anchor public key (compressed or internal point).
• i: note index (0 ≤ i ≤ 2³²−1).

Functions
• H(x) := SHA-256(x).
• H160(x) := RIPEMD-160(SHA-256(x)).
• serP(P) := SEC1 compressed encoding of point P (33 bytes).
• LE32(u) := 4-byte little-endian of integer u.
• Base58Check(v ∥ p) := Base58Check with version v and payload p (checksum = first 4 bytes of double-SHA-256).

Procedure (sender view)

tᵢ ← int( H( Z ∥ Hᴵ ∥ "recv" ∥ LE32(i) ) ) mod n.

if tᵢ = 0 then
  ctr ← 1;
  repeat
   tᵢ ← int( H( Z ∥ Hᴵ ∥ "recv" ∥ LE32(i) ∥ LE32(ctr) ) ) mod n;
   ctr ← ctr + 1;
  until tᵢ ≠ 0.

Pᴮ,ᵢ ← point_add( B, scalar_mul( tᵢ, G ) ).

addrᴮ,ᵢ ← Base58Check( 0x00 ∥ H160( serP( Pᴮ,ᵢ ) ) ).

Output (Pᴮ,ᵢ, addrᴮ,ᵢ) for index i.

Procedure (recipient view)

Recompute tᵢ from {Z, Hᴵ, i} with the same counter-bump if necessary.

kᴮ,ᵢ ← ( b + tᵢ ) mod n.

Verify kᴮ,ᵢ·G equals Pᴮ,ᵢ (optional local check).

Use kᴮ,ᵢ to spend outputs paying to addrᴮ,ᵢ.

4.9 Conformance and rejection rules
• If serP(B) is not a valid compressed SEC1 encoding or not on curve, reject the invoice before derivation.
• If any tᵢ = 0 after counter-bump exhaustion (theoretically impossible for practical counters), reject index i and halt with an error state.
• Implementations MUST record the counter value used for each i (if any) in off-chain logs to guarantee reproducibility.
• Any per-note artefact (address, label, receipt) that cannot be recomputed from {Z, Hᴵ, i, B} MUST be considered invalid for this specification.

5. Deterministic bounded note-splitting (exact sum; indices independent of sizes)
   5.1 Inputs and feasibility
   Input parameters (all in the smallest settlement unit): total T ≥ 1; bounds [v_min, v_max] with 1 ≤ v_min ≤ v_max; per-invoice scope {Z, H_I}. Define the feasible note-count interval
   N_min := ⌈T ÷ v_max⌉ and N_max := ⌊T ÷ v_min⌋.
   Validity requires N_min ≤ N_max (otherwise the invoice is infeasible). A valid split consists of an integer N with N_min ≤ N ≤ N_max and an amount vector a[0…N−1] such that for all i: v_min ≤ a[i] ≤ v_max and Σ a[i] = T.

5.2 Deterministic seeding
Define a seed S := H( Z ∥ H_I ∥ "split" ) (32 bytes, SHA-256 of the exact bytes). All randomness below is deterministically derived from S. A counter-based PRNG is used: for j = 0,1,2,… define R_j := H( S ∥ LE32(j) ) and let u_j be the 64-bit unsigned integer formed from the first 8 bytes of R_j (big-endian). The function next_u64() returns u_j and increments j. This yields a reproducible, stateless stream for both parties.

5.3 Choosing N (reproducible, interior-biased)
If N_min = N_max, set N := N_min. Otherwise set span := N_max − N_min, mid := ⌊(N_min + N_max)/2⌋, and Δ := ⌊span/4⌋. Draw u := next_u64(). Map u to a symmetric jitter J in [−Δ, +Δ] by J := (u mod (2Δ+1)) − Δ. Set N₀ := mid + J, then clamp to the feasible interval:
N := min( max(N₀, N_min), N_max ).
This rule is deterministic, prefers interior counts when unconstrained, and never violates feasibility.

5.4 Range-safe uniform integer draws
To draw an integer r uniformly from [0, R−1] using next_u64() without modulo bias, use rejection sampling: let M := 2⁶⁴, lim := ⌊M/R⌋·R. Repeatedly draw u := next_u64() until u < lim, then return r := u mod R. This is used below for bounded choices.

5.5 Prefix-clamped construction (exact sum, bounds preserved)
Initialise rem := T. For i from 0 to N−2 do:

Compute the feasible interval for a[i] given the remaining slots:
slots := N−1−i
low := max( v_min, rem − v_max·slots )
high := min( v_max, rem − v_min·slots )
(low ≤ high must hold by feasibility; see §5.7.)

Draw r ∈ [0, (high−low)] uniformly using the range-safe method and set a[i] := low + r.

Set rem := rem − a[i].
After the loop set a[N−1] := rem. By construction v_min ≤ a[N−1] ≤ v_max (proof in §5.7). This produces v_min ≤ a[i] ≤ v_max for all i and Σ a[i] = T exactly.

5.6 Index/size de-correlation by permutation
To ensure indices are independent of sizes, apply a deterministic Fisher–Yates shuffle to the completed vector a using a seed derived from S but disjoint from the draw sequence above. Define S_perm := H( S ∥ "permute" ). Instantiate a second counter-based PRNG with S_perm and perform Fisher–Yates on positions 0…N−1, using range-safe draws for each swap index. The permutation is thus fixed by {Z, H_I} and independent of the prefix-clamping choices, so no structural correlation between index and size remains.

5.7 Correctness and termination
Feasibility of each step. Assume at step i (0 ≤ i ≤ N−2) that rem satisfies v_min·(N−i) ≤ rem ≤ v_max·(N−i). Then:
• Lower bound low = max( v_min, rem − v_max·(N−1−i) ) ensures that after choosing a[i] ≥ low the remaining rem′ = rem − a[i] can still be paid using at most (N−1−i) notes each of size ≤ v_max, because rem′ ≤ rem − (rem − v_max·(N−1−i)) = v_max·(N−1−i).
• Upper bound high = min( v_max, rem − v_min·(N−1−i) ) ensures that after choosing a[i] ≤ high the remaining rem′ can still be paid using at least (N−1−i) notes each of size ≥ v_min, because rem′ ≥ rem − (rem − v_min·(N−1−i)) = v_min·(N−1−i).
Hence low ≤ a[i] ≤ high implies v_min·(N−1−i) ≤ rem′ ≤ v_max·(N−1−i), maintaining the invariant. The base case at i = 0 holds by the choice of N (N_min ≤ N ≤ N_max). By induction the invariant holds for all i ≤ N−2. Termination occurs after exactly N steps. At i = N−1 we have rem′ = a[N−1] and v_min ≤ a[N−1] ≤ v_max by the invariant, and Σ a[i] = T by construction.

5.8 Determinism and replay
Every choice is a pure function of {Z, H_I}, the accepted bounds, and the deterministic PRNG streams from S and S_perm. Given identical inputs, independent implementations compute identical N, identical pre-permutation a, and an identical permutation. No per-note amounts need to be exchanged off-chain; both parties recompute the same vector.

5.9 Edge cases and rejection rules
• Infeasible invoice: if N_min > N_max (e.g., T < v_min or T > v_max·N_max under external constraints), reject the invoice before splitting.
• Tight bounds: if v_min = v_max then N is forced to N_min = N_max and the vector is constant a[i] = v_min for all i.
• Degenerate last step: if N = 1 the construction degenerates to a[0] := T, which must equal v_min = v_max = T to be feasible; otherwise reject at §5.1.
• Deterministic streams: the PRNG counters MUST NOT be shared between “split” and “permute”; S_perm isolates the shuffle. Counters MUST be reset to zero for each new seed.

5.10 Pseudocode (Unicode; canonical; no bias)

Seed and PRNG
seed_split := H( Z ∥ H_I ∥ "split" )
seed_perm := H( seed_split ∥ "permute" )

function next_u64(seed, counter):
R := H( seed ∥ LE32(counter) )
counter := counter + 1
return (first 8 bytes of R as uint64 big-endian), counter

function draw_uniform(R, range): # range ≥ 1
M := 2⁶⁴
lim := (M ÷ range) × range
loop:
(u, ctr) := next_u64(R.seed, R.ctr)
if u < lim: return (u mod range), (R.seed, ctr)
else: continue

Choosing N
span := N_max − N_min
if span = 0: N := N_min
else:
mid := ⌊(N_min + N_max)/2⌋
Δ := ⌊span/4⌋
(r, R_split) := draw_uniform( R_split, 2Δ + 1 )
J := r − Δ
N := clamp( mid + J, N_min, N_max )

Constructing a
rem := T
for i in 0 … N−2:
slots := N−1−i
low := max( v_min, rem − v_max × slots )
high := min( v_max, rem − v_min × slots )
(r, R_split) := draw_uniform( R_split, high − low + 1 )
a[i] := low + r
rem := rem − a[i]
a[N−1] := rem

Permutation (Fisher–Yates using seed_perm)
for j in (N−1) down to 1:
(r, R_perm) := draw_uniform( R_perm, j+1 )
swap a[j] ↔ a[r]

5.11 Rationale for the permutation step
Without permutation, prefix-clamping tends to bias early indices toward interior values of [v_min, v_max] when T is near a boundary, creating a weak but systematic index→size correlation. A seeded Fisher–Yates shuffle removes positional information while preserving multiset equality and the exact sum. Using S_perm derived from S ensures determinism tied to {Z, H_I} and prevents stream re-use, so the shuffle cannot be predicted or recomputed by third parties lacking the invoice scope.

5.12 Security and leakage considerations
The split leaks only that all amounts lie in [v_min, v_max]; no per-note sizes are revealed off-chain because both wallets compute a independently. On-chain, an external observer learns the multiset of paid amounts if all notes are broadcast promptly; timing diversity in broadcast is handled elsewhere. The permutation ensures indices carry no information about sizes in off-chain logs or receipts. Deterministic seeding binds all outcomes to the invoice; cross-invoice linkage by split structure is prevented by H_I.

6. Disjoint coin selection and strict non-overlap across notes
   6.1 Snapshot and reservation model
   Input pool U is the payer’s spendable UTXOs at invoice start, filtered for script type (payer’s own keys), maturity, and policy (confirmations, timelocks). U is a set of outpoints ⟨txid, vout, value, scriptPubKey, keyref⟩. At construction time the wallet takes a read-only snapshot U₀ and builds a reservation table R mapping each note index i to an exclusive input set Sᵢ ⊂ U₀. Exclusivity is strict: Sᵢ ∩ Sⱼ = ∅ for all i ≠ j. Each outpoint carries a reservation state: free → reserved(i) → committed(i) or free (on cancel). Reservations are keyed by NoteID to ensure stable recovery from logs.

6.2 Deterministic ordering
To maximise success and ensure reproducibility, notes are funded in a fixed order: sort indices by descending a[i]; ties break by ascending i. The UTXO pool is iterated in a fixed order: sort by (value ascending, then txid lexicographic ascending, then vout ascending). No random tie-breakers appear in selection; given U₀ and a[·], the same R is produced.

6.3 Fee and dust parameters
Let feerate_floor be the minimum units-per-byte. For a candidate with m inputs and n outputs (n ∈ {1,2}), estimate bytes as size ≈ 10 + 148·m + 34·n. Required fee = feerate_floor × size (integer, round up). Dust threshold δ_dust is the minimum output value permitted by local policy; any output < δ_dust is invalid. Change outputs must be either ≥ δ_dust or omitted (surplus folded into the fee only when explicitly permitted by policy).

6.4 Selection policy (bounded-knapsack with exact-match preference)
Goal for note i: choose Sᵢ such that Σ value(Sᵢ) = a[i] + fee + change, with change ∈ {0} ∪ [δ_dust, ∞). Preference order:
(1) exact match with zero change;
(2) single-input just-over target with valid change;
(3) fewest inputs subject to minimal overshoot and valid change.
Any candidate that would produce an output < δ_dust or violate feerate_floor is rejected.

6.5 Algorithm for building R (normative)

Inputs: U₀ (ordered), vector a[0…N−1], feerate_floor, δ_dust.
Outputs: reservation table R or failure.

Pre-pass: remove from U₀ any outpoint < δ_dust or not controlled by the payer. Initialise R := ∅. Let Used := ∅.

For i in sort_descending_by a[i] then ascending i:

Target initialisation
target := a[i]
best := ⊥

Stage A — exact single-input
For each u ∈ U₀ \ Used:
fee₁ := feerate_floor × (10 + 148·1 + 34·1)
if value(u) = target + fee₁: best := {u}; goto Commit

Stage B — exact few-inputs (bounded subset)
Search over combinations of up to K_max inputs (K_max default 4) from U₀ \ Used in ascending cardinality. For each candidate set C:
m := |C|; fee_m := feerate_floor × (10 + 148·m + 34·1)
if Σ value(C) = target + fee_m: best := C; goto Commit
(Prune by value sums exceeding target + fee_m + δ_dust unless Stage C.)

Stage C — single-input near-over
For each u ∈ U₀ \ Used:
fee₂ := feerate_floor × (10 + 148·1 + 34·2)
change := value(u) − target − fee₂
if change ≥ δ_dust and change is minimal among examined: best := {u}

Stage D — fewest-inputs minimal-overshoot
Increase m from 2 to M_max (M_max default 6). For each m, run a greedy bounded-knapsack over U₀ \ Used (largest-first or meet-in-the-middle for m≤4) to find C with Σ value(C) ≥ target + fee_m₂ where fee_m₂ := feerate_floor × (10 + 148·m + 34·2). Among feasible C, minimise overshoot := Σ value(C) − (target + fee_m₂) subject to overshoot = 0 or overshoot ≥ δ_dust. Choose the C with smallest m then smallest overshoot. Set best := C if found.

Commit
if best = ⊥: goto FailureForI
m := |best|
n := 1 if Σ value(best) = target + feerate_floor×(10 + 148·m + 34·1) else 2
fee := feerate_floor × (10 + 148·m + 34·n)
sum_in := Σ value(best)
if n = 1: change := 0
else: change := sum_in − target − fee
if change < δ_dust:
// attempt to repair by adding one more input once
pick the smallest u′ ∈ U₀ \ Used \ best
if u′ exists: recompute m, n=2, fee, change; if change ≥ δ_dust accept; else discard u′ and continue Stage D
if no repair possible: goto FailureForI
R[i] := best
mark all u ∈ best as reserved(i); Used := Used ∪ best
continue with next i

FailureForI:
Attempt optional fan-out (once per invoice). If fan-out succeeds and confirms per policy, refresh U₀ := U_fanout ⊎ (U₀ \ Used) and restart from i = 0. If fan-out is disabled or fails, abort with “insufficient granularity”.

Return R upon success for all i.

6.6 Definition of “locked” UTXO
A locked UTXO is an outpoint in state reserved(i) with metadata {NoteID, timestamp, size_estimate, fee_rate_used}. While reserved, it MUST NOT be considered by selection for any j ≠ i within the same invoice. A reserved UTXO transitions to committed(i) once Tᵢ is fully signed. If a note is cancelled before broadcast, all Sᵢ return to free; if reissued, Sᵢ remain reserved until the new Tᵢ is committed.

6.7 Failure modes and outcomes
• Insufficient value: Σ value(U₀) < Σ a[i] + fees_min → abort invoice (fan-out cannot create value).
• Insufficient granularity: value(U₀) is concentrated in large outputs so that every candidate either violates δ_dust for change or exceeds K_max/M_max → attempt fan-out.
• Conflicting external spend: if a reserved outpoint is spent externally (wallet mutation), invalidate R and rebuild from a fresh U snapshot; log the conflict under the offending outpoint.
• Policy violation: any candidate producing outputs below δ_dust or underpaying fee is rejected; if no candidate remains, treat as insufficient granularity.

6.8 Optional preparatory fan-out (payer-only, outside the note set)
Purpose: reshape coarse inputs into a set of smaller payer-owned outputs suitable for the target a[·].
Rules:
• Destination: strictly to the payer’s own addresses derived from the sender anchor under a distinct namespace label “fund” (not “snd”), e.g., Addr_fund,j; never to the payee; never counted as a note.
• Granularity: choose output sizes to cover the histogram of a[·] and expected change values, typically near v_max and mid-range values; all fan-out outputs ≥ max(δ_dust, v_min).
• Count: minimise number of fan-out outputs while ensuring coverage; a practical target is ⌈Σ a[i] ÷ v_max⌉ plus a small buffer.
• Fee and confirmation: construct with feerate ≥ feerate_floor and, by default, require at least one confirmation before using the resulting outputs in R (deterministic policy); if unconfirmed chaining is allowed by local policy, mark chained notes as risk-accepted in logs.
• Scope: fan-out transactions are labelled funding-only with a distinct manifest and are excluded from receipt accounting.
• Idempotence: perform at most one fan-out attempt per invoice; repeated fan-outs can re-fragment and harm determinism.

6.9 Determinism and auditability
Given U₀, a[·], feerate_floor, δ_dust, K_max, M_max, and the fixed iteration orders, the algorithm produces a unique R. The wallet MUST persist U₀ snapshot metadata, the reservation table R, size/fee calculations, and any fan-out manifest to allow exact recomputation. Change outputs created by notes MUST NOT be admitted into U₀ for funding other notes within the same invoice; they become eligible only after the invoice is closed (completed or aborted).

6.10 Pseudocode (Unicode; canonical)

function build_reservations(U₀, a[0…N−1], feerate_floor, δ_dust):
order_notes := sort_desc( (a[i], −i) ) # by amount desc, then i asc
order_utxo := sort_asc( (value, txid, vout) ) # deterministic pool order
Used := ∅; R := {}
fanout_done := false
repeat:
for i in order_notes:
best := select_inputs_disjoint(order_utxo \ Used, a[i], feerate_floor, δ_dust)
if best = ⊥:
if not fanout_done and policy_allows_fanout():
F := build_fanout(order_utxo \ Used, histogram(a), feerate_floor, δ_dust)
if F.success and F.confirmed:
U₀ := (U₀ \ F.inputs) ⊎ F.outputs
Used := ∅; R := {}; fanout_done := true; goto repeat
return ⊥
R[i] := best; Used := Used ∪ best
return R

6.11 Guarantees
• Strict non-overlap: by construction Sᵢ ∩ Sⱼ = ∅ for i ≠ j, and change from Tᵢ is excluded from funding Tⱼ.
• Independence: each Tᵢ can be signed and broadcast without reference to any Tⱼ.
• Compliance: every output is ≥ δ_dust; every transaction meets or exceeds feerate_floor.
• Reproducibility: with the persisted U₀ and logs, the same R is reconstructed exactly.

7. Per-note change addresses and change calculation (no overlap; deterministic; auditable)
   7.1 Scope and requirements
   Change outputs are per-note, invoice-scoped artefacts. For each index i, the payer derives exactly one sender-side change address Addrᴬ,ᵢ deterministically from {Z, Hᴵ} and a sender anchor A = a·G. Change produced by note i MUST pay to Addrᴬ,ᵢ. No change output from note i is eligible to fund any other note j ≠ i within the same invoice. Reissues before broadcast preserve the index i and Addrᴮ,ᵢ; Addrᴬ,ᵢ remains stable for i.

7.2 Sender change derivation (deterministic, per note)
Inputs: sender anchor A = a·G (public), per-invoice scope {Z, Hᴵ}. Domain separation uses the ASCII label “snd”.

Define the per-note tweak scalar:
sᵢ := int( SHA-256( Z ∥ Hᴵ ∥ "snd" ∥ LE32(i) ) ) mod n.

Reject-zero rule: if sᵢ = 0, deterministically bump a counter until non-zero:
sᵢ := int( SHA-256( Z ∥ Hᴵ ∥ "snd" ∥ LE32(i) ∥ LE32(ctr) ) ) mod n, ctr = 1,2,…

Define the per-note sender public key and address:
Pᴬ,ᵢ := A + sᵢ·G.
Addrᴬ,ᵢ := Base58Check( 0x00 ∥ H160( serP(Pᴬ,ᵢ) ) ).

Uniqueness and separation: for fixed A and invoice scope, indices map to distinct Pᴬ,ᵢ with overwhelming probability; “snd” prevents namespace collision with recipient derivations (“recv”).

7.3 Fee and change arithmetic (standard P2PKH)
Parameters:
• m = number of inputs for note i.
• n ∈ {1, 2} = number of outputs (1 = pay-only, 2 = pay + change).
• size_bytes ≈ 10 + 148·m + 34·n (P2PKH approximation).
• fee_rate_floor = minimum units-per-byte (smallest unit per byte).
• fee := ceil( fee_rate_floor × size_bytes ).
• δ_dust = dust threshold (policy parameter, smallest unit).
• sum_inputs := Σ value(inputⱼ) over the reserved set Sᵢ.
• target := a[i] (the note’s recipient amount).

Deterministic evaluation (no circularity):
Step A — assume n = 1 (no change). Compute fee₁ := ceil( fee_rate_floor × (10 + 148·m + 34·1) ).
• If sum_inputs = target + fee₁ → construct a 1-output transaction: pay target to Addrᴮ,ᵢ; no change.
• Else proceed to Step B.

Step B — assume n = 2 (pay + change). Compute fee₂ := ceil( fee_rate_floor × (10 + 148·m + 34·2) ).
• change := sum_inputs − target − fee₂.
• If change ≥ δ_dust → construct a 2-output transaction: pay target to Addrᴮ,ᵢ and change to Addrᴬ,ᵢ.
• If change ∈ [1, δ_dust−1] → invalid (dust). Either add one more input (recompute m, fee₂, change) or reselect Sᵢ per §6; if no valid candidate exists, fail funding for i.
• If change ≤ 0 → underfunded; add inputs or reselect Sᵢ.

Rounding rule: fees are rounded up to the nearest integer unit to avoid underpayment. All implementations MUST use identical size estimates and rounding to preserve determinism.

7.4 No-overlap and pool eligibility
No intra-invoice reuse: change created by Tᵢ MUST NOT be inserted into the funding pool U for any j ≠ i while the invoice is open (building, broadcasting, or awaiting confirmations). Change from Tᵢ becomes eligible only after the invoice is closed (completed or aborted). Enforcement is by NoteID tagging: every change UTXO carries {invoice_hash = Hᴵ, index = i} and a state “locked(change,i)” until closure.

7.5 Reissue semantics (pre-broadcast)
If a different fee rate is desired before broadcast, reissue note i by constructing a new transaction with possibly different inputs but the same index i, the same recipient address Addrᴮ,ᵢ, and the same sender change address Addrᴬ,ᵢ. Update fee, change, and txid in logs; mark the prior, unbroadcast serialisation as superseded. Addrᴬ,ᵢ stability guarantees that all change for i remains isolated to that index across reissues.

7.6 Security and leakage
Identity keys are not used on-chain. Sender change keys are invoice-scoped and per-note; without {Z, Hᴵ, A} an observer cannot regenerate Addrᴬ,ᵢ. Because change pays to unique addresses per index, clustering by shared change across notes of the same invoice is prevented by construction.

7.7 Conformance and rejection rules
• Reject if serP(A) is invalid or not on curve.
• Reject if sᵢ = 0 after counter-bump exhaustion (theoretical).
• Reject any candidate where change ∈ (0, δ_dust).
• Reject any construction whose fee < fee_rate_floor × estimated size (post-rounding).
• Persist {i, sum_inputs, m, n, size_bytes, fee, change, Addrᴮ,ᵢ, Addrᴬ,ᵢ, txid} for audit.

7.8 Pseudocode (Unicode; canonical)

Inputs
• a[i], Sᵢ (reserved inputs for i), fee_rate_floor, δ_dust, A, Z, Hᴵ.
• serP, H, H160, Base58Check as defined earlier.

Derive change address
sᵢ := int( H( Z ∥ Hᴵ ∥ "snd" ∥ LE32(i) ) ) mod n
if sᵢ = 0:
ctr := 1
repeat:
sᵢ := int( H( Z ∥ Hᴵ ∥ "snd" ∥ LE32(i) ∥ LE32(ctr) ) ) mod n
ctr := ctr + 1
until sᵢ ≠ 0
Pᴬ,ᵢ := point_add( A, scalar_mul( sᵢ, G ) )
Addrᴬ,ᵢ := Base58Check( 0x00 ∥ H160( serP(Pᴬ,ᵢ) ) )

Compute fee and change
m := |Sᵢ|
size₁ := 10 + 148×m + 34×1
fee₁ := ceil( fee_rate_floor × size₁ )
if Σ value(Sᵢ) = a[i] + fee₁:
outputs := [ (Addrᴮ,ᵢ, a[i]) ] # n = 1, no change
else:
size₂ := 10 + 148×m + 34×2
fee₂ := ceil( fee_rate_floor × size₂ )
change := Σ value(Sᵢ) − a[i] − fee₂
if change ≥ δ_dust:
outputs := [ (Addrᴮ,ᵢ, a[i]), (Addrᴬ,ᵢ, change) ] # n = 2
else if 0 < change < δ_dust:
fail "dust-change" # add input or reselect Sᵢ
else:
fail "underfunded" # add input or reselect Sᵢ

Construct transaction
Tᵢ := make_tx( inputs = Sᵢ, outputs = outputs )
sign_all_inputs(Tᵢ)
record_log( i, Hᴵ, Sᵢ, m, outputs, fee, change, txid(Tᵢ), Addrᴬ,ᵢ, Addrᴮ,ᵢ )

Policy enforcement
mark_change_utxo(Tᵢ, i, Hᴵ, state="locked(change,i)")
forbid_selection_of_locked_change_until_invoice_closed(Hᴵ)

7.9 Bytesize estimator and parameters (normative defaults)
• Input (P2PKH): 148 bytes. Output (P2PKH): 34 bytes. Overhead: 10 bytes.
• Implementations MAY use precise varint-aware sizing; if so, the same sizing method MUST be used deterministically by both parties.
• δ_dust is a fixed policy parameter for the implementation; it MUST be agreed implicitly by equal software or explicitly encoded in policy to avoid disagreements.

8. Transaction formation per note (independent, standard, fully signed)
   8.1 Build order (normative)

For each index i:

Inputs (funding). Take the reserved input set Sᵢ from the reservation table (pairwise disjoint across i). Let m = |Sᵢ| and sum_inputs = Σ value(Sᵢ).

Outputs (payee and optional change).
• Primary output: (Addrᴮ,ᵢ, a[i]).
• Change output (if required by §7): (Addrᴬ,ᵢ, change[i]).
Output ordering is deterministic: primary first, change second if present.

Transaction fields.
• nVersion = 1 (32-bit little-endian).
• vin count = m (varint).
• For each input j in Sᵢ in deterministic order (value ascending, then txid lexicographic ascending, then vout ascending):
– prevout.txid (32-byte little-endian), prevout.vout (4-byte little-endian).
– scriptSig = empty during preimage construction.
– nSequence = 0xFFFFFFFF unless explicitly negotiated otherwise.
• vout count = 1 or 2 (varint).
• For each output in the order specified:
– value (8-byte little-endian).
– scriptPubKey = standard P2PKH: OP_DUP OP_HASH160 <20-byte H160(serP(P))> OP_EQUALVERIFY OP_CHECKSIG.
• nLockTime = 0 unless explicitly negotiated otherwise.

Fee and dust validation. Verify the size estimate and fee satisfy the fee-rate floor; verify no output < δ_dust (§7).

Signing scope. For each input j = 0…m−1, construct the legacy SIGHASH preimage for SIGHASH_ALL:
– Start from the transaction template with all scriptSig empty.
– Replace the scriptSig of input j with the exact previous locking script (the P2PKH scriptPubKey of the UTXO referenced by Sᵢ[j]).
– Append the 4-byte SIGHASH type 0x00000001 (little-endian).
– Double-hash with SHA-256 to obtain zⱼ.
– Produce a deterministic ECDSA signature σⱼ over zⱼ using the private key that controls Sᵢ[j], with low-s normalisation; append one-byte hash type 0x01 to σⱼ.
– Set scriptSigⱼ := <PUSH σⱼ> <PUSH serP(Pⱼ)>, where Pⱼ is the corresponding public key.

Final serialisation and txid. Serialise the fully signed transaction using Bitcoin legacy (non-SegWit) encoding. Define txidᵢ := SHA-256(SHA-256(serialised_bytes)), expressed as 32-byte hash (displayed big-endian; stored and relayed as little-endian in prevouts). The note transaction Tᵢ is now complete and valid in isolation.

Deterministic labelling. Compute NoteIDᵢ := H(Hᴵ ∥ LE32(i)). Associate NoteIDᵢ with Tᵢ in logs and manifests.

8.2 Independence and validity (normative)

• Tᵢ references only inputs from Sᵢ and pays only to Addrᴮ,ᵢ and (if present) Addrᴬ,ᵢ.
• Tᵢ contains no pointers to any Tⱼ, j ≠ i; no input or change overlap is permitted within the invoice.
• Any subset of {Tᵢ} may be broadcast in any order without invalidating or starving the remainder.

8.3 NoteMeta schema (canonical JSON; log-only)

Minimal, required fields:

{"i": ,
"note_id": "<hex 32-byte NoteIDᵢ>",
"invoice_hash": "<hex 32-byte Hᴵ>",
"addr": "<base58 Addrᴮ,ᵢ>",
"amount": <int a[i]>,
"txid": "<hex 32-byte txidᵢ>"}

Recommended extensions for audit (all integers in smallest unit; strings lowercase hex unless noted):

{"size_bytes": ,
"fee": ,
"feerate_used": ,
"change_addr": "<base58 Addrᴬ,ᵢ or empty>",
"change_amount": <int or 0>,
"inputs": [
{"txid":"","vout":,"value":,"scriptPubKey":""}
],
"outputs": [
{"addr":"","value":}, {"addr":"","value":}?
],
"sig_alg": "secp256k1-sha256",
"created_at": "",
"status": "unsigned|signed|broadcast|confirmed|reissued|cancelled"}

All NoteMeta objects MUST be encoded canonically (UTF-8, sorted keys, no extraneous whitespace) when hashed or signed. The tuple (i, NoteIDᵢ, txidᵢ) is the stable handle for the note within an invoice.

8.4 Deterministic ordering and tie-breaking (normative)

• Inputs inside Tᵢ are ordered by (value ascending, txid lexicographic ascending, vout ascending).
• Outputs are ordered: primary recipient first, change second if present.
• scriptSig contains exactly one DER-encoded ECDSA signature with appended 0x01 hash-type byte and one compressed public key; no additional pushes are permitted.

8.5 Conformance and rejection rules

• Reject Tᵢ if any output value < 0 or > 2⁶³−1, or if Σ outputs + fee ≠ Σ inputs.
• Reject if any output < δ_dust.
• Reject if fee < fee-rate floor × size_bytes (post-rounding).
• Reject if any scriptSig is empty or fails standard verification under SIGHASH_ALL.
• Reject if NoteIDᵢ mismatches {Hᴵ, i}, or if addr ≠ Addrᴮ,ᵢ derived from {Z, Hᴵ, i, B}.
• On reissue prior to broadcast, the new transaction replaces txidᵢ in logs for the same i and NoteIDᵢ; Addrᴮ,ᵢ and Addrᴬ,ᵢ remain unchanged.

9. Ordering, pacing, and broadcast authority (either side may settle)
   9.1 Authority and symmetry
   Either party may broadcast any subset of the note transactions at any time. The payer (Alice) and the recipient (Bob) hold identical authority to submit a fully signed note TiTᵢ to the network. Duplicate broadcast of identical bytes is benign: identical transactions share the same txid and are deduplicated by nodes. Settlement for a note is defined solely by confirmation depth dd selected by the recipient in policy; once TiTᵢ achieves ≥ dd confirmations to Addrᴮ,ᵢ, that note is settled irrespective of the status of other notes in the invoice.

9.2 Broadcast strategies (permissible)
• All-at-once — submit all TiTᵢ immediately.
• Paced — submit TiTᵢ according to a deterministic schedule over a window [t0,t1][t₀, t₁] with minimum spacing.
• Grouped bursts — partition notes into batches of size β; submit batches with inter-batch gaps.

A strategy is advisory; either party may accelerate or decelerate within the agreed bounds.

9.3 Policy fields (broadcast) — payee → payer (canonical JSON)
Augment the policy (§3.3) with:

"broadcast": {
"authority": "either", // fixed literal
"strategy_default": "paced|all_at_once|bursts",
"min_spacing_ms": <int ≥ 0>, // minimum inter-note gap
"max_spacing_ms": <int ≥ min_spacing>, // upper bound for paced jitter
"burst_size": <int ≥ 1>, // used when strategy_default = "bursts"
"burst_gap_ms": <int ≥ 0>, // inter-burst gap
"window_start": "|"" ", // optional; empty string means immediate
"window_end": "|"" ", // optional; empty means no hard end
"rebroadcast_interval_s": <int ≥ 60>, // periodic re-announce until confirmed
"hold_time_max_s": <int ≥ 0>, // max age for unbroadcast notes before action
"confirm_depth": <int ≥ 0> // d, settlement depth
}

Normative constraints:
• If "window_start" and "window_end" are both present, require window_start < window_end.
• If "strategy_default" = "bursts", "burst_size" ≥ 2; otherwise "burst_size" is ignored.
• "confirm_depth" defines finality dd for all notes unless overridden in the invoice.

9.4 Invoice overrides — payer → payee (canonical JSON)
An invoice MAY propose narrower pacing within policy bounds:

"broadcast_overrides": {
"strategy": "paced|all_at_once|bursts", // optional; must be allowed by policy
"min_spacing_ms": , // ≤ policy.max_spacing_ms
"max_spacing_ms": , // ≥ min_spacing_ms and ≤ policy.max_spacing_ms
"burst_size": , // if strategy = "bursts" and ≤ policy.burst_size
"burst_gap_ms": , // ≤ policy.burst_gap_ms or equal
"window_start": "|"" ",
"window_end": "|"" ",
"confirm_depth": // ≥ policy.confirm_depth
}

Validation: every override must satisfy policy bounds; otherwise the invoice is invalid.

9.5 Deterministic pacing schedule (sender/recipient can compute identically)
Seed for schedule: S_pace := H( Z ∥ Hᴵ ∥ "pace" ). Derive a reproducible jitter stream from S_pace (as in §5.2). Let order of notes for scheduling be the stable index order 0…N−1.

All-at-once: for all i, schedule_time[i] := max(now, window_start).
Paced: for i = 0…N−1, draw δᵢ uniformly from [min_spacing_ms, max_spacing_ms] via deterministic PRNG; set schedule_time[0] := max(now, window_start); schedule_time[i] := schedule_time[i−1] + δᵢ ms; if schedule_time[i] > window_end (when set), cap at window_end.
Bursts: partition indices into batches of size β (β = burst_size). For batch k, set batch_time[k] := (k = 0 ? max(now, window_start) : batch_time[k−1] + burst_gap_ms). All notes in batch k share batch_time[k]; within a batch, apply a tiny deterministic intra-batch offset εᵢ ∈ [0, min_spacing_ms] to break ties.

Either party may use the same schedule; divergence does not affect correctness. The schedule is an off-chain convenience that does not appear on-chain.

9.6 Hold-time and lifecycle timers
Define τ_hold_max := hold_time_max_s (policy). A note ii moves through states:

constructed → signed → queued → broadcast → seen → confirmed | orphaned
↘ reissued → signed → queued …
↘ cancelled

Timer rules (normative):
• If queued and now − created_at ≥ τ_hold_max, choose exactly one:
(a) reissue ii with new inputs Sᵢ′ (same i, same Addrᴮ,ᵢ, same Addrᴬ,ᵢ), reset created_at; or
(b) cancel ii explicitly (see §9.8).
• If broadcast but not seen by the counterparty within 2 × rebroadcast_interval_s, rebroadcast.
• If seen but unconfirmed for more than κ × rebroadcast_interval_s (κ ≥ 3), continue periodic rebroadcast until confirmed or cancelled.

9.7 Reissue procedure (pre-broadcast; deterministic labels preserved)
Preconditions: note ii is not confirmed; the previous candidate Tᵢ has not been announced or is to be superseded; reasons include fee adjustment or input conflict.

Steps:

Release prior reservation Sᵢ to free (unless already conflicted on-chain).

Select new Sᵢ′ disjoint from every Sⱼ, j ≠ i (see §6).

Recompute fee and change at the negotiated floor (§7); derive the same Addrᴮ,ᵢ and Addrᴬ,ᵢ.

Build and sign new transaction Tᵢ′.

Update NoteMeta[i] with fields:
"supersedes": "",
"version": <prev_version + 1>,
"txid": "",
"status": "signed".

Mark the old raw bytes as voided_offchain = true and "status": "reissued".

Persist an append-only audit record of the transition.

Only the latest version for index i is eligible for broadcast. Earlier versions MUST NOT be re-broadcast once superseded.

9.8 Cancellation procedure (explicit, off-chain)
If a note will not be used:

Set NoteMeta[i].status := "cancelled".

Clear reservation Sᵢ to free; do not derive a new candidate unless re-enabled.

Record a signed cancellation entry by the party effecting the cancel:
{"i": i, "note_id": "<NoteIDᵢ>", "invoice_hash": "<Hᴵ>", "action": "cancel", "by": "<sig_key>", "at": "", "sig": ""}.

9.9 Duplicate broadcast semantics
• Identical bytes: if Alice and Bob both submit the same Tᵢ, the txid is identical; network deduplicates; state becomes "seen" then "confirmed".
• Divergent bytes (only possible after reissue): the policy forbids broadcasting superseded versions. If an older Tᵢ is propagated accidentally, whichever transaction confirms first defines settlement for i; the other is a double-spend loser and MUST be marked "obsolete" in logs. Implementations SHOULD guard by refusing to broadcast any version where NoteMeta[i].version < current_version.

9.10 Logging fields (canonical JSON; per note)
Extend NoteMeta (§8.3) with broadcast management:

{
"i": ,
"note_id": "",
"invoice_hash": "",
"txid": "",
"version": <int ≥ 1>,
"status": "queued|broadcast|seen|confirmed|reissued|cancelled|obsolete|orphaned",
"scheduled_at": "",
"broadcast_at": "|""",
"last_rebroadcast_at": "|""",
"confirm_depth": , // effective d
"supersedes": "|""",
"superseded_by": "|"""
}

All entries are UTF-8 canonical JSON (sorted keys). Signatures over log events MAY be added using identity keys to bind audit records.

9.11 Conformance and rejection rules
• If "broadcast_overrides" conflicts with policy bounds, reject the invoice.
• If a party attempts to broadcast a superseded version (version < current_version), reject locally and log an error; do not transmit.
• If a queued note exceeds τ_hold_max without reissue or cancel, mark "stale" and require explicit operator action before any broadcast.
• Confirmation acceptance: mark a note "confirmed" only after ≥ d confirmations for its output to Addrᴮ,ᵢ; d is taken from invoice override if present, else from policy.confirm_depth.

9.12 Determinism and auditability
The schedule derived from S_pace ensures both parties can compute the same nominal broadcast plan without coordination. Regardless of who submits, finality is defined by on-chain confirmations. The “supersedes” chain, version counter, and timestamped log records provide an append-only audit trail proving that, for each index i, exactly one transaction version was intended to settle, and any earlier candidates were explicitly voided off-chain before settlement.

10. Receipts and selective disclosure
    10.1 Purpose
    Receipts bind a complete set of notes for an invoice into a single commitment that can later be opened selectively. The commitment is a Merkle root M computed over per-note leaves Lᵢ. To acknowledge any subset, the prover discloses those leaves and their Merkle paths; all undisclosed leaves remain hidden. Domain separation by the invoice fingerprint Hᴵ prevents cross-invoice linkage.

10.2 Exact leaf structure (bytes, canonical)
Each leaf is the SHA-256 of a byte-exact concatenation of fixed-width fields. The recipient address is represented as its binary payload (version byte and 20-byte public-key hash), not as Base58 text.

Definitions
• label := ASCII bytes of the literal string "leaf".
• i := note index (0 ≤ i ≤ 2³²−1).
• LE32(i) := 4-byte little-endian encoding of i.
• txidᵢ := 32-byte transaction identifier in big-endian display order (exact bytes of the hex string).
• amountᵢ := 8-byte little-endian unsigned integer (smallest unit).
• Pᴮ,ᵢ := recipient public key for note i.
• h160ᵢ := RIPEMD-160(SHA-256(serP(Pᴮ,ᵢ))) (20 bytes).
• ver := 0x00 (1 byte; P2PKH version).
• addr_payloadᵢ := ver ∥ h160ᵢ (21 bytes). (Checksum and Base58 encoding are excluded.)

Leaf preimage and hash
preimageᵢ := label ∥ LE32(i) ∥ txidᵢ ∥ amountᵢ ∥ addr_payloadᵢ
Lᵢ := SHA-256(preimageᵢ) (32 bytes)

Notes
• All concatenations are byte-level.
• All numeric encodings and endianness are as stated; no alternative formats are permitted.
• If the implementation wishes to include additional fields (e.g., change_amount), they MUST be placed after addr_payloadᵢ and MUST also be fixed-width and identically encoded by both parties; otherwise omit them entirely.

10.3 Merkle tree construction (binary, deterministic)
• Leaves: the sequence [L₀, L₁, …, L_{N−1}] in ascending index order.
• Internal node hash: H(x ∥ y) := SHA-256(x ∥ y) with x,y each 32 bytes.
• Layering: pair adjacent elements left-to-right; if a layer has odd cardinality, duplicate the final element (Bitcoin-style padding) so every parent has two children. Repeat until a single 32-byte value remains; that value is the Merkle root M.
• Empty set: N ≥ 1 is required; for N = 1, M = L₀.

10.4 Stored commitment and manifest (canonical JSON)
Persist a compact manifest for the invoice. Canonical JSON rules from §2 apply (UTF-8, NFC, sorted keys, no extraneous whitespace).

Minimal manifest
{
"invoice_hash": "<hex 32-byte H_I>",
"merkle_root": "<hex 32-byte M>",
"count": ,
"entries": [
{"i": , "txid": "<hex 32-byte>"},
…
]
}

Recommendations
• Do not store amounts or addresses in the manifest; keep them private to the payer and payee.
• Optionally include "created_at" (ISO-8601 UTC) and detached signatures by identity keys to authenticate the record.

10.5 Selective disclosure proof (single leaf)
A proof for index i consists of:
• The disclosed leaf data (i, txidᵢ, amountᵢ, addr_payloadᵢ).
• The computed leaf hash Lᵢ.
• A Merkle path πᵢ = [(pos₀, s₀), (pos₁, s₁), …, (pos_{h−1}, s_{h−1})], where each sⱼ is a 32-byte sibling hash and posⱼ ∈ {"L","R"} indicates whether L (or the running hash) is on the left or right at that layer.
• The root M being claimed.

Verification procedure

Recompute preimageᵢ := "leaf" ∥ LE32(i) ∥ txidᵢ ∥ amountᵢ ∥ addr_payloadᵢ.

Compute L ← SHA-256(preimageᵢ).

For j = 0…h−1:
• If posⱼ = "L": L ← SHA-256( L ∥ sⱼ ).
• If posⱼ = "R": L ← SHA-256( sⱼ ∥ L ).

Accept if and only if L equals the claimed merkle_root M (as 32-byte value). Otherwise reject.

10.6 Selective disclosure proof (multiple leaves)
For a subset S ⊆ {0,…,N−1}, provide independent single-leaf proofs (as above) for each i ∈ S, or provide a multi-proof that minimises duplicate siblings by sharing path segments. A multi-proof may be represented as:
{
"invoice_hash": "",
"merkle_root": "",
"leaves": [
{"i": , "txid": "", "amount": , "addr_payload": "<hex 21-byte>"},
…
],
"sibling_hashes": ["<hex 32-byte>", …],
"structure": "" // e.g., a bitstring specifying merge order
}
Verification recomputes the same frontier using the structure bitstring; if unfamiliar with multi-proofs, verify each leaf independently.

10.7 Privacy properties
• For any disclosed leaf i, the verifier learns (i, txidᵢ, amountᵢ, addr_payloadᵢ).
• For any undisclosed leaf j ∉ S, no information beyond the length N and the set of indices S is revealed; sibling hashes are computationally indistinguishable from random without preimages.
• The manifest stores only (i, txidᵢ) pairs, avoiding publication of amounts and addresses.
• Domain separation by H_I ensures that identical (i, txidᵢ, amountᵢ, addr_payloadᵢ) under a different invoice yields a different leaf and root.

10.8 Examples of partial proofs (formats)

Example A — single-leaf proof (index 7)
{
"invoice_hash": "…h_i…",
"merkle_root": "…m…",
"leaf": {
"i": 7,
"txid": "…32-byte-hex…",
"amount": 1420,
"addr_payload": "00…20-byte-h160…"
},
"path": [
{"pos": "L", "hash": "…32-byte-hex…"},
{"pos": "R", "hash": "…32-byte-hex…"},
{"pos": "R", "hash": "…32-byte-hex…"}
]
}

Example B — two-leaf independent proofs (indices 3 and 11)
[
{
"invoice_hash": "…h_i…",
"merkle_root": "…m…",
"leaf": {"i": 3, "txid": "…", "amount": 600, "addr_payload": "00…"},
"path": [ … ]
},
{
"invoice_hash": "…h_i…",
"merkle_root": "…m…",
"leaf": {"i": 11, "txid": "…", "amount": 785, "addr_payload": "00…"},
"path": [ … ]
}
]

Example C — redacted manifest with selective disclosure
Manifest (public):
{
"invoice_hash": "…h_i…",
"merkle_root": "…m…",
"count": 72,
"entries": [
{"i": 0, "txid": "…"},
{"i": 1, "txid": "…"},
…
]
}
Disclosure: provide Example A for i = 7 only. Verifier checks that the txid in the proof matches the manifest entry for i = 7 and that the recomputed root equals merkle_root.

10.9 Edge conditions and rejection rules
• Reject any proof where the byte encodings (LE32(i), amountᵢ, addr_payloadᵢ) do not match the normative widths and endianness.
• Reject if txidᵢ is not a 32-byte value (invalid hex length or characters).
• Reject if any path element has an invalid "pos" or a non-32-byte sibling.
• Reject if the recomputed root ≠ merkle_root M.
• Reject if invoice_hash in the proof ≠ H_I for the invoice under consideration.

10.10 Construction and logging (normative)
• Both parties compute the same M from the same ordered leaf list.
• Store merkle_root M, count N, and entries [(i, txidᵢ)] in the manifest.
• Optionally sign the manifest with identity keys to authenticate receipt creation:
{"sig_key": "<hex serP(Pₐ or Pᵦ)>", "sig_alg": "secp256k1-sha256", "sig": ""}
• For each disclosed proof later, store the presented leaf and path alongside the manifest for audit.

10.11 Deterministic recomputation
Given H_I, the derivation rules, and full knowledge of the note set, either party can recompute every preimage and thus M exactly. Given only the manifest and a subset proof, a third party verifies membership of the disclosed leaves without learning the undisclosed ones.

10.12 Interoperability notes
• The use of addr_payload (ver ∥ h160) avoids ambiguity and normalisation issues inherent in Base58 strings and checksums, while remaining consistent with P2PKH addressing.
• If an implementation wishes to future-proof for alternative script types, include an extra 1-byte "script_tag" before addr_payloadᵢ to denote the payload format; for this specification, script_tag = 0x00 (P2PKH) and MUST be present if the extension is adopted by both parties.

11. Failure handling and exact behaviours
    11.1 Overview (normative)
    Failures are handled deterministically at two levels: per-note and per-invoice. Every transition is recorded in canonical JSON with timestamps and signatures by the acting party’s identity key. All timers are measured in seconds since the Unix epoch; all timestamps are ISO-8601 UTC.

— Global timers and flags —
• τ_hold_max := policy.broadcast.hold_time_max_s (maximum queued time before action).
• τ_rebroadcast := policy.broadcast.rebroadcast_interval_s (periodic re-announce).
• d_confirm := effective confirmation depth (invoice override or policy default).
• expires_at_policy := policy.expiry.
• expires_at_invoice := invoice.expiry (if present).
• fanout_allowed := implementation/policy toggle; at most one fan-out per invoice.
• supersedes flag := indicates a newer transaction version exists for the same index i.
• voided_offchain := indicates older raw bytes must not be broadcast.

11.2 Per-note state machine (textual diagram)

States:
S0 Constructed → S1 Signed → S2 Queued → S3 Broadcast → S4 Seen → S5 Confirmed
  ↘ R Reissued (loops back to S1)
  ↘ C Cancelled (terminal)
  ↘ O Orphaned (from S5; loops to S3 on rebroadcast)
  ↘ X Obsolete (terminal; older superseded bytes)
  ↘ F Conflict (terminal; external spend of reserved inputs)

Transitions (events → new state):
• construct(i) → S0
• sign(i) → S1
• enqueue(i) → S2
• t ≥ scheduled_at(i) ∧ authority_either → broadcast(i) → S3
• mempool_accept(i) → S4
• conf_depth(i) ≥ d_confirm → S5
• t − created_at(i) ≥ τ_hold_max ∧ S2 → reissue(i) → R → S1
• explicit_cancel(i) at S0/S1/S2/S3/S4 → C
• superseded(i) (new Tᵢ′ built) → old version → X; new version → S1
• external_conflict(Sᵢ) (reserved input spent elsewhere) → F
• reorg_orphan(i) at S5 → O → rebroadcast(i) → S3

Determinism: given identical logs and timers, the same sequence of transitions occurs.

11.3 Invoice-level state machine (textual diagram)

I0 Open → I1 Fan-out-Pending (optional) → I2 Building → I3 Ready → I4 Broadcasting → I5 Closing
  ↘ IF Insufficient-UTXO (terminal failure)
  ↘ IE Expired (terminal failure)
  ↘ IS Stopped (operator abort)
  ↘ IC Completed (terminal success: all i ∈ [0…N−1] in S5)

Triggers:
• accept(policy, invoice) → I0
• fanout_start (if required) → I1 → fanout_confirmed → I2
• reservations_built(R) → I3
• any_broadcast → I4
• all notes S5 → IC
• t ≥ expires_at_invoice or t ≥ expires_at_policy → IE
• Σ value(U₀) insufficient or granularity impossible after one fan-out → IF

11.4 Deterministic behaviours by failure class (normative)

A) Insufficient UTXOs
Condition: Σ value(U₀) < Σ a[i] + fees_min, or granularity failure after bounded-knapsack (§6).
Action sequence:

If fanout_allowed = true and no prior fan-out: perform exactly one preparatory fan-out (payer→payer) per §6.8; wait per policy (confirm or risk-accepted) deterministically.

Rebuild U₀ from fan-out result; rebuild R.

If still insufficient, set invoice.state := IF and emit failure record; no notes are issued or all outstanding notes are cancelled (see 11.6).
Audit: record {"event":"insufficient_utxo","at":…,"fanout_attempted":true|false}.

B) Fee change before broadcast
Condition: either party requires a new fee rate > fee_rate_floor while a note i is S0/S1/S2 and no broadcast has occurred for i.
Action sequence:

Reissue i: select new Sᵢ′ (disjoint), recompute fee at requested rate (must be ≥ floor), preserve Addrᴮ,ᵢ and Addrᴬ,ᵢ.

Set NoteMeta[i].supersedes := txid_old; version := version + 1.

Mark old bytes voided_offchain := true and status := "reissued".

New candidate enters S1 (Signed).
Audit: append {"i":i,"event":"reissue","supersedes":"<txid_old>","version":v}.

C) Conflicting spend detected
Condition: any u ∈ Sᵢ appears spent on-chain or reserved contradictorily by external wallet mutation while note i ∈ {S0,S1,S2}.
Action sequence:

Abort invoice build immediately: invoice.state := I2 (rebuild) or I5 (closing) depending on operator policy.

Invalidate R; take a fresh snapshot U′; rebuild reservations per §6 or fail IF.

For the conflicted note i, mark status := "conflict" and record the offending outpoint.
Audit: record {"i":i,"event":"conflict_external","outpoint":{"txid":…,"vout":…},"at":…}.
Determinism: any detected conflict forces a full reservation rebuild; partial salvage is not permitted.

D) Reorg
Condition: a confirmed note i (S5) is orphaned by reorganisation (conf_depth falls below d_confirm).
Action sequence:

Transition i → O (Orphaned).

Rebroadcast the same raw bytes of Tᵢ (no reconstruction, no re-sign).

Return to S3 (Broadcast) → S4 (Seen) → S5 (Confirmed) as usual.
Audit: record {"i":i,"event":"orphaned","rebroadcast":true,"txid":"","at":…}.
Constraint: reissue is not permitted for orphaned-but-valid transactions unless they later double-spend fail; first action is always rebroadcast.

E) Expiry
Condition: t ≥ expires_at_invoice or t ≥ expires_at_policy before all notes reach S5.
Action sequence:

For every i ∈ {S0,S1,S2}: set status := "cancelled"; release reservations.

For i ∈ {S3,S4}: continue passive monitoring until either confirmed (counted) or timeout set by operator; no new broadcasts after expiry.

Set invoice.state := IE and emit summary record with counts by status.
Audit: record {"event":"invoice_expired","at":…,"counts":{"cancelled":…,"broadcast":…,"confirmed":…}}.

11.5 Timers and automated actions (per note)

Scheduler tick (every τ_rebroadcast seconds):
• If status = "broadcast" ∨ "seen" and conf_depth < d_confirm → rebroadcast raw bytes.
• If status = "queued" and t − created_at ≥ τ_hold_max → reissue(i) (preferred) or cancel(i) per policy.
• If status = "signed" and scheduled_at reached → broadcast(i).

All actions are idempotent: rebroadcasting identical bytes preserves txid; reissuing increments version and voids older bytes.

11.6 Precise reissue and cancel records (canonical JSON)

Reissue record (append-only):
{
"invoice_hash":"",
"i":,
"note_id":"<hex NoteIDᵢ>",
"event":"reissue",
"version":, // new version
"supersedes":"",
"txid_new":"",
"addr_recv":"<base58 Addrᴮ,ᵢ>",
"addr_change":"<base58 Addrᴬ,ᵢ>",
"fee":, "feerate_used":,
"at":"",
"by":"<hex serP(Pₐ or Pᵦ)>",
"sig_alg":"secp256k1-sha256",
"sig":""
}

Cancel record (append-only):
{
"invoice_hash":"",
"i":,
"note_id":"<hex NoteIDᵢ>",
"event":"cancel",
"reason":"hold_timeout|operator|expiry|insufficient_utxo",
"version":,
"at":"",
"by":"<hex serP(Pₐ or Pᵦ)>",
"sig_alg":"secp256k1-sha256",
"sig":""
}

Conflict record (append-only):
{
"invoice_hash":"",
"i":,
"note_id":"<hex NoteIDᵢ>",
"event":"conflict_external",
"outpoint":{"txid":"","vout":},
"at":"",
"by":"<hex serP(Pₐ or Pᵦ)>",
"sig_alg":"secp256k1-sha256",
"sig":""
}

Orphaned record (append-only):
{
"invoice_hash":"",
"i":,
"note_id":"<hex NoteIDᵢ>",
"event":"orphaned",
"txid":"",
"rebroadcast":true,
"at":"",
"by":"<hex serP(Pₐ or Pᵦ)>",
"sig_alg":"secp256k1-sha256",
"sig":""
}

11.7 Rejection conditions (must fail immediately)
• Attempt to broadcast a superseded version (version < current_version).
• Attempt to broadcast after invoice expiry (except passive rebroadcasts of already-broadcast notes until final state is reached).
• Attempt to reuse change from one note to fund another note in the same invoice.
• Attempt to continue with reservations after detecting external conflict; a full rebuild is mandatory.

11.8 Determinism and auditability guarantees
• Given identical inputs (policy, invoice, {Z,Hᴵ}, U₀) and identical timer parameters, two independent implementations will produce identical reservation tables, note schedules, and failure-handling transitions.
• The append-only reissue/cancel logs, combined with NoteMeta and the receipt manifest (§10), are sufficient to reconstruct the exact intended settlement set and to demonstrate that exactly one transaction per index i was designated to settle, with earlier byte serialisations voided before settlement.

Generated image
12. Privacy and linkage analysis (bounded disclosures; role separation)
    12.1 Adversary model (explicit)
    • A₁ — Passive chain analyst: observes full blocks and mempools, parses scripts, amounts, timings, and addresses; cannot break SHA-256, RIPEMD-160, or the secp256k1 discrete-log problem.
    • A₂ — Passive network observer: sees when and from which IP a transaction is first announced; cannot tamper with payloads.
    • A₃ — Inquisitive counterparty: one party attempts to learn more than the protocol reveals; has its own keys and transcript but lacks the other party’s secret scalars.
    • A₄ — Data-broker adversary: correlates public off-chain artefacts (e.g., leaked policies, screenshots, manifests) with on-chain activity.
    Assumptions: preimage resistance of SHA-256, collision resistance where invoked, and hardness of ECDLP on secp256k1.

12.2 Role separation and cryptographic domains
Identity keys never appear in locking scripts; only settlement keys derived from anchors do. All recipient keys are derived in the “recv” domain:
Pᴮ,ᵢ = B + tᵢ·G, tᵢ := int(SHA-256(Z ∥ Hᴵ ∥ "recv" ∥ LE32(i))) mod n, tᵢ ≠ 0.
All sender-change keys are derived in the “snd” domain:
Pᴬ,ᵢ = A + sᵢ·G, sᵢ := int(SHA-256(Z ∥ Hᴵ ∥ "snd" ∥ LE32(i))) mod n, sᵢ ≠ 0.
Domain labels (“recv”, “snd”) and the invoice fingerprint Hᴵ ensure that the same index i across invoices yields unrelated points; identity/settlement separation prevents anchor leakage via off-chain signatures.

12.3 What an outsider can and cannot infer

(1) Linking recipient addresses across notes (same invoice).
Cannot: Without Z and Hᴵ, an outsider cannot recompute tᵢ and so cannot test membership of any address in the set {B + tᵢ·G}. Observing two spends reveals serP(Pᴮ,ᵢ) and serP(Pᴮ,ⱼ), but the relation Pᴮ,ᵢ − Pᴮ,ⱼ = (tᵢ − tⱼ)·G holds for all random points; without tᵢ, tⱼ it gives no anchor linkage.
Limit: If the anchor B itself is leaked off-chain and the adversary also learns Z or Hᴵ (both should remain secret), they could regenerate addresses; by design, neither Z nor Hᴵ is published.

(2) Linking across invoices (same payee).
Cannot: Hᴵ changes per invoice; tᵢ depends on Hᴵ. Even with B known, without Z the adversary cannot bind addresses to a particular invoice scope.
Limit: Long-term address-reuse does not occur; accidental reuse would require tᵢ collision or (b + tᵢ) mod n repeating—negligible under SHA-256 and modular arithmetic.

(3) Change-based clustering within an invoice.
Prevented: Change pays to per-note Addrᴬ,ᵢ under “snd”; selection forbids using change from one note to fund another of the same invoice. The common “shared-change” heuristic therefore does not tie notes i and j together.
Limit: Each individual note still clusters its own inputs (multi-input heuristic) to the payer, which is acceptable: the payer’s identity is not a privacy target here; recipient unlinkability is.

(4) Amount and bounds leakage.
Possible: When many notes are broadcast close in time, an observer may infer that outputs lie in [v_min, v_max] and approximate N by histogramming.
Limit: Exact partition a[·] remains hidden off-chain; permutation decouples indices from sizes; paced broadcast blurs simultaneity.

(5) Timing linkage.
Possible: If all notes are broadcast at once from a single IP, a₁/a₂ can cluster them temporally and by origin peer.
Mitigation below: either-side broadcast; paced or bursty schedules; diverse first-announcers.

(6) Off-chain artefact correlation.
Possible: If a policy or manifest leaks publicly (A₄), an adversary learns B and (i, txid) pairs.
Limit: txid alone does not reveal amounts or change; B does not reveal kᴮ,ᵢ or tᵢ; receipts commit to data but selective proofs reveal only chosen leaves.

12.4 Recommended mitigations (no new primitives)

M₁ — Either-side broadcast.
Let the recipient submit a random subset first. This breaks any single-origin heuristic; first-seen IP attribution no longer correlates the whole set to the payer.

M₂ — Paced or burst scheduling with deterministic jitter.
Use the S_pace-derived schedule (§9) to spread announcements over a window. Choose “bursts” with β ≪ N and non-uniform burst gaps to defeat simple time-window clustering.

M₃ — Wider published bounds than actually used.
Bob may publish [v_min_pub, v_max_pub] with v_min ≤ v_min_pub and v_max_pub ≤ v_max; enforce the true internal bounds off-chain. Observers only learn the loose public interval.

M₄ — Interleave multiple invoices.
When operationally feasible, the payer constructs two or more invoices concurrently and interleaves broadcasts. This raises ambiguity without changing any primitive.

M₅ — Strict no-reuse within invoice.
Enforce “no intra-invoice change reuse” and “no cross-note input reuse” (already normative) to preclude standard clustering hooks.

M₆ — Avoid deterministic time-of-day fingerprints.
Do not always start at the top of the hour; salt schedule start with H(Z ∥ Hᴵ ∥ "pace") to vary timing patterns.

M₇ — Minimal public metadata.
Manifests published externally should contain only (i, txid) and the Merkle root M; keep amounts, addresses, and H160 payloads private. Sign manifests with identity keys to prove authorship without revealing anchors.

12.5 Specific inferences and their limits (tabular)

• Inference: “These outputs belong to the same payer.”
Basis: multi-input heuristic per note.
Limit: Does not link different notes together; does not link recipient addresses across notes.

• Inference: “These outputs belong to the same payee.”
Basis: proximity, equal denominations in [v_min, v_max].
Limit: Without Z and Hᴵ, cannot prove common derivation from B; pacing and interleaving degrade confidence.

• Inference: “This set is one invoice of size T.”
Basis: near-simultaneous group of bounded outputs summing to ≈ T.
Limit: Pacing plus concurrent invoices makes partitioning NP-hard in practice; receipts reveal only when the payee consents.

• Inference: “These two payee public keys share an anchor B.”
Basis: Pᴮ,ᵢ − Pᴮ,ⱼ is some scalar times G.
Limit: Trivial in any cyclic group; provides no test for a shared anchor without tᵢ, tⱼ; computing b from B is ECDLP-hard.

12.6 Residual risks and operator guidance

R₁ — Broadcast-pattern fingerprinting.
Residual risk: sophisticated a₂ correlates bursts over long windows.
Guidance: vary β and gaps per invoice; occasionally switch who broadcasts first.

R₂ — Anchor disclosure.
Residual risk: if B is widely published and Z or Hᴵ leaks, address sets become derivable.
Guidance: treat Z and Hᴵ as confidential; never publish invoice JSON or transcripts; rotate anchors periodically (operational) without changing identity keys.

R₃ — Wallet hygiene.
Residual risk: accidental reuse if software ignores reject-zero logic or mis-scopes derivations.
Guidance: enforce reject-zero; unit tests that re-derive all Pᴮ,ᵢ and Pᴬ,ᵢ from logs; fail closed on any mismatch.

Summary. Outsiders cannot link recipient addresses across notes or invoices because identity keys never appear on-chain and per-note keys require {Z, Hᴵ} with domain separation. Amount bounds leak a coarse interval; pacing, interleaving, and wider published bounds blunt inference. Change addresses are per-note under “snd”, eliminating shared-change clustering. All recommendations require no new primitives—only deterministic use of the ones already defined.

13. Security considerations (keys, transcripts, and logs)
    13.1 Key domains and separation (normative)
    • Identity (off-chain): Kₐ = (kₐ, Pₐ), Kᵦ = (kᵦ, Pᵦ). Purpose: authenticate messages; sign policy, invoice, and logs. Identity keys MUST NEVER appear in locking scripts or be used to spend on-chain funds.
    • Anchors (on-chain bases): A = a·G (sender change domain), B = b·G (recipient receive domain). Purpose: derive settlement keys per invoice and per note. Anchor private scalars (a, b) MUST NEVER sign off-chain identity artefacts.
    • Scope tuple: {Z, Hᴵ}. Z := ECDH(kₐ, Pᵦ) = ECDH(kᵦ, Pₐ) (32-byte x-coordinate). Hᴵ := H(canonical_json(invoice)). Hᴵ MUST be unique per invoice and MUST NOT be reused. Z SHOULD be recomputed on demand and SHOULD NOT be stored at rest unless encrypted under an operator-controlled mechanism (implementation policy).

13.2 Key-handling checklist (operational)
✓ Generate identity and anchor keys on distinct cryptographic modules or profiles.
✓ Store kₐ, kᵦ, a, b in separate sealed locations; never co-reside identity and anchor secrets for the same principal on the same soft-keystore without OS isolation.
✓ Export only compressed public keys (serP) to peers; never export private material.
✓ Enforce constant-time scalar use; disable debug traces of secret scalars.
✓ Back up identity keys (kₐ, kᵦ) with out-of-band recovery; back up anchors (a, b) with the same or stronger controls; record public anchors (A, B) separately for verification.
✓ Rotate anchors periodically (operational policy) and immediately on suspected compromise; old anchors remain valid only for historical settlement and verification.
✓ Bind every signed artefact to the exact canonical JSON bytes; do not sign ad hoc serialisations.
✓ Treat transcripts and logs as confidential; encrypt at rest per environment policy; access is least-privilege.
✓ Never reuse Hᴵ; never derive keys or amounts without {Z, Hᴵ} and the correct domain label (“recv”, “snd”).
✓ Refuse to proceed if any signature verification or canonicalisation check fails.

13.3 Compromise impact summary
• kₐ or kᵦ compromised → attacker can forge off-chain messages/logs for that identity; on-chain funds unaffected; rotate identity key; rebind future policies/invoices; mark prior logs with rotation event.
• a (sender anchor) compromised → attacker can spend sender change if they control UTXOs addressed to Pᴬ,ᵢ; recipient funds unaffected; rotate A, quarantine outstanding change, rebuild change policy.
• b (recipient anchor) compromised → attacker may spend future notes to Addrᴮ,ᵢ; rotate B immediately; cease using the compromised anchor; existing receipts remain valid.

13.4 Log and transcript principles
• Canonical JSON only: UTF-8, NFC, sorted keys, no extraneous whitespace (see §2).
• Detached signatures: every signed record includes {"sig_key","sig_alg","sig"} where the signature is computed over the canonical bytes of the record with the signature triplet omitted from the preimage.
• Append-only: logs are monotone sequences with sequence numbers and a hash-chain (“prev_hash”) for tamper evidence.
• Minimal disclosure: store what is necessary for audit and exact recomputation; avoid storing private scalars or PRNG seeds.
• Time: all timestamps are ISO-8601 UTC; clocks SHOULD be monotonic-corrected.

13.5 Signature placement (normative)
• Policy (Bob) — signed by kᵦ.
• Invoice (Alice) — signed by kₐ.
• Reservation table R and per-note NoteMeta updates — signed by the party performing the action (payer when constructing/funding; either when broadcasting).
• Receipt manifest (Merkle root M) — at least signed by the recipient; co-signature by the payer is RECOMMENDED for bilateral acknowledgement.
• Reissue / cancel / conflict / orphan records — signed by the actor identity key initiating the state change.

13.6 Core log schemas (canonical JSON; required fields; sorted keys)

A) Key registry (local, not exchanged)
{
"anchors": {
"payer": {"pub":"<hex serP(A)>"},
"payee": {"pub":"<hex serP(B)>"}
},
"identities": {
"payer": {"pub":"<hex serP(Pₐ)>"},
"payee": {"pub":"<hex serP(Pᵦ)>"}
},
"created_at":"",
"sig_alg":"secp256k1-sha256",
"sig_key":"<hex serP(Pₐ or Pᵦ)>",
"sig":""
}

B) Policy record (Bob → Alice) — as §3.3 plus envelope
{
"policy": { …canonical policy object per §3.3… },
"hash":"",
"record_type":"policy_record",
"prev_hash":"<hex|"">",
"seq":,
"created_at":"",
"sig_key":"<hex serP(Pᵦ)>",
"sig_alg":"secp256k1-sha256",
"sig":""
}

C) Invoice record (Alice → Bob) — as §3.4 plus envelope
{
"invoice": { …canonical invoice object per §3.4… },
"invoice_hash":"<hex Hᴵ>",
"record_type":"invoice_record",
"prev_hash":"",
"seq":,
"created_at":"",
"sig_key":"<hex serP(Pₐ)>",
"sig_alg":"secp256k1-sha256",
"sig":""
}

D) Reservation table (payer, deterministic R) — summary plus per-note entries
{
"invoice_hash":"<hex Hᴵ>",
"record_type":"reservations",
"entries":[
{
"i":,
"note_id":"<hex NoteIDᵢ>",
"inputs":[{"txid":"","vout":,"value":}],
"sum_inputs":,
"feerate_used":,
"created_at":""
}, …
],
"prev_hash":"",
"seq":,
"sig_key":"<hex serP(Pₐ)>",
"sig_alg":"secp256k1-sha256",
"sig":""
}

E) NoteMeta (per note; extends §8.3 with lifecycle)
{
"i":,
"note_id":"",
"invoice_hash":"<hex Hᴵ>",
"addr":"<base58 Addrᴮ,ᵢ>",
"amount":,
"txid":"<hex|"">",
"change_addr":"<base58 Addrᴬ,ᵢ|"">",
"change_amount":,
"size_bytes":,
"fee":,
"feerate_used":,
"status":"unsigned|signed|queued|broadcast|seen|confirmed|reissued|cancelled|obsolete|orphaned",
"version":,
"scheduled_at":"<ISO-8601 UTC|"">",
"broadcast_at":"<ISO-8601 UTC|"">",
"created_at":"",
"updated_at":"",
"prev_hash":"",
"seq":,
"sig_key":"<hex serP(Pₐ or Pᵦ)>",
"sig_alg":"secp256k1-sha256",
"sig":""
}

F) Receipt manifest (Merkle root M) — see §10; repeated here with envelope
{
"invoice_hash":"<hex Hᴵ>",
"merkle_root":"",
"count":,
"entries":[{"i":,"txid":""}…],
"record_type":"receipt_manifest",
"prev_hash":"",
"seq":,
"created_at":"",
"sig_key":"<hex serP(Pᵦ)>",
"sig_alg":"secp256k1-sha256",
"sig":""
}

G) Event records (reissue / cancel / conflict / orphan) — see §11.6; all include {invoice_hash, i, note_id, prev_hash, seq, created_at, sig_key, sig_alg, sig}.

13.7 Transcript chaining (tamper evidence)
Each persisted record Rₖ includes "prev_hash" = H(canonical_bytes(Rₖ₋₁ without its signature triplet)) and "seq" = seqₖ₋₁ + 1. A daily (or per-invoice) journal root J := MerkleRoot( H(canonical_bytes(Rₖ)) for all k in window ) MAY be published or anchored externally to provide a timestamped, tamper-evident commitment to the log without revealing contents.

13.8 Retention and export
• Retain logs and manifests for the statutory/accounting horizon; redact only where policy permits.
• Export is the ordered canonical JSON stream with signatures; verification replays the hash-chain and signatures, recomputes R, NoteMeta, and M, and checks that exactly one final transaction per i reached "confirmed".

13.9 Conformance (must-pass checks)
• Identity/anchor separation enforced at API boundaries (no cross-domain signing).
• Hᴵ uniqueness per invoice; refusal to load or write logs if an Hᴵ collision is detected.
• All signatures verify over canonical bytes; any failure halts processing.
• Hash-chain continuity: each "prev_hash" matches the prior record; gaps or forks are rejected unless explicitly marked as a rotated journal with a signed boundary record.

This section specifies the mandatory operational controls for key isolation and the precise, signed, append-only logging required to reconstruct, verify, and audit every invoice, note, and receipt without exposing identity keys on-chain.

14. Minimal message frames (UTF-8 JSON; canonical where hashed)
    14.1 Policy (Bob → Alice)

Wire frame (compact):

{"pk_anchor":"<hex compressed B>",
"vmin":<int>,
"vmax":<int>,
"feerate_floor":<int>,
"expiry":"<ISO-8601 UTC>",
"sig":"<hex DER-ECDSA over SHA-256>"}
Canonical field order (for signature preimage):
expiry, feerate_floor, pk_anchor, vmax, vmin
(“sig” is excluded from the preimage)

Signature input (bytes to sign):
canonical_json({pk_anchor, vmin, vmax, feerate_floor, expiry}) → SHA-256 → ECDSA sign with K_B.

Verification rules (normative):
• pk_anchor is 33-byte SEC1 compressed hex (0x02/0x03 + 32-byte x), on-curve.
• vmin ≥ 1, vmax ≥ vmin, feerate_floor ≥ 1; expiry is future UTC.
• Verify sig with P_B over SHA-256(canonical_json(policy_without_sig)).
• H_policy := SHA-256(canonical_json(policy_with_sig)) is the policy hash used by the invoice.
• Canonical JSON per §2 (UTF-8, NFC strings, sorted keys, no extra whitespace).

14.2 Invoice (Alice → Bob)

Wire frame (compact):

{"invoice_number":"<string>",
"terms":"<string>",
"unit":"<string>",
"total":<int>,
"policy_hash":"<hex 32-byte H_policy>",
"expiry":"<ISO-8601 UTC>",
"sig":"<hex DER-ECDSA over SHA-256>"}
Canonical field order (for signature preimage):
expiry, invoice_number, policy_hash, terms, total, unit
(“sig” is excluded from the preimage)

Signature input (bytes to sign):
canonical_json({invoice_number, terms, unit, total, policy_hash, expiry}) → SHA-256 → ECDSA sign with K_A.

Verification rules (normative):
• total ≥ 1; policy_hash equals H_policy from the accepted policy (14.1).
• Verify sig with P_A over SHA-256(canonical_json(invoice_without_sig)).
• H_I := SHA-256(canonical_json(invoice_with_sig)) is the invoice fingerprint for all derivations.
• If expiry is present, it MUST be future UTC at acceptance.

14.3 NoteMeta (optional to exchange; log/audit)

Wire frame (compact):

{"i":<int>,
"addr":"<base58 P2PKH>",
"amount":<int>,
"invoice_hash":"<hex 32-byte H_I>",
"txid":"<hex 32-byte>"}
Canonical field order (when hashing/recording):
addr, amount, i, invoice_hash, txid

Verification rules (normative):
• i ∈ [0, 2³²−1]; amount ≥ 1.
• addr decodes to version 0x00 and a 20-byte payload.
• txid is 32-byte hex (big-endian textual form).
• invoice_hash equals H_I for this invoice.
• addr must equal Addr_B,i derived from {Z, H_I, i, B} (sender/recipient can recompute).
• Optional signatures over NoteMeta (if used) are made with the actor’s identity key over SHA-256(canonical_json(NoteMeta_without_sig)).

14.4 Canonical JSON recap (applies wherever “canonical_json” is referenced)

• UTF-8 encoding; no BOM; all strings NFC-normalised.
• Keys sorted lexicographically by Unicode code point.
• No insignificant whitespace (compact objects/arrays).
• Integers in base-10 without leading zeros (except “0”).
• Hex fields are lowercase, no “0x”.
• Timestamps are ISO-8601 with “Z”.

14.5 Cross-checks (receiver MUST perform)

Policy:

Parse and validate fields; verify ECDSA(sig, SHA-256(canonical_json(policy_without_sig)), P_B).

Compute H_policy = SHA-256(canonical_json(policy_with_sig)).

Invoice:

Verify policy_hash = H_policy.

Verify ECDSA(sig, SHA-256(canonical_json(invoice_without_sig)), P_A).

Compute H_I = SHA-256(canonical_json(invoice_with_sig)) and cache {Z, H_I} for derivations.

NoteMeta (if exchanged):

Verify invoice_hash = H_I.

Recompute Addr_B,i; check equality.

Optionally verify txid exists or matches a provided raw transaction.

All frames are minimal by design; anything not explicitly listed is out of scope and MUST be omitted.

15. Reference pseudocode
    Per-note recipient key (sender view)

Z   := ECDH(k_A, K_B)                                    # 32-byte x-coordinate
H_I := SHA256(canonical_json(invoice))                   # invoice fingerprint

t_i := int( SHA256( Z ∥ H_I ∥ "recv" ∥ LE32(i) ) ) mod n
if t_i = 0:
ctr := 1
repeat:
t_i := int( SHA256( Z ∥ H_I ∥ "recv" ∥ LE32(i) ∥ LE32(ctr) ) ) mod n
ctr := ctr + 1
until t_i ≠ 0

P_Bi   := point_add( B, scalar_mul(t_i, G) )
addrB_i := Base58Check( 0x00 ∥ RIPEMD160( SHA256( serP(P_Bi) ) ) )
Per-note sender change (payer view)

s_i := int( SHA256( Z ∥ H_I ∥ "snd" ∥ LE32(i) ) ) mod n
if s_i = 0:
ctr := 1
repeat:
s_i := int( SHA256( Z ∥ H_I ∥ "snd" ∥ LE32(i) ∥ LE32(ctr) ) ) mod n
ctr := ctr + 1
until s_i ≠ 0

P_Ai    := point_add( A, scalar_mul(s_i, G) )
addrA_i := Base58Check( 0x00 ∥ RIPEMD160( SHA256( serP(P_Ai) ) ) )
Bounded split (exact sum)

S      := SHA256( Z ∥ H_I ∥ "split" )
S_perm := SHA256( S ∥ "permute" )

function next_u64(seed, ctr):
R := SHA256( seed ∥ LE32(ctr) )
return (first 8 bytes of R as uint64), (ctr + 1)

function draw_uniform(seed, ctr, range):                  # unbiased draw in [0, range−1]
M := 2^64; lim := (M ÷ range) × range
loop:
(u, ctr) := next_u64(seed, ctr)
if u < lim: return (u mod range), ctr

Nmin := ceil(T ÷ v_max)
Nmax := floor(T ÷ v_min)
N    := choose_count(S, Nmin, Nmax)                        # deterministic, interior-biased

rem := T
ctr := 0
for i in 0 … N−2:
slots := N−1−i
low   := max( v_min, rem − v_max × slots )
high  := min( v_max, rem − v_min × slots )
(r, ctr) := draw_uniform(S, ctr, high − low + 1)
a[i] := low + r
rem  := rem − a[i]
a[N−1] := rem

# Fisher–Yates permutation to decorrelate indices from sizes
ctrp := 0
for j in (N−1) down to 1:
(r, ctrp) := draw_uniform(S_perm, ctrp, j + 1)
swap a[j] ↔ a[r]
Coin selection with reservation

U := snapshot_available_utxos()           # payer-owned, spendable, filtered
R := {}                                   # reservation table: i ↦ S_i

for i in note_indices_in_fixed_order():   # e.g., by descending a[i], then i
target := a[i]
(S_i, fee, change) := select_inputs_disjoint(U, target, feerate_floor, dust)
R[i] := S_i
U := U \ S_i                           # remove reserved inputs (strict non-overlap)
Change arithmetic and size estimate

# m inputs, n outputs (n ∈ {1,2}); P2PKH sizes
size_bytes(m, n) := 10 + 148×m + 34×n
fee(m, n)        := ceil( feerate_floor × size_bytes(m, n) )

sum_in := Σ value(input ∈ S_i)
target := a[i]

# Try no-change first
fee1 := fee(m=|S_i|, n=1)
if sum_in = target + fee1:
outputs := [ (addrB_i, target) ]                     # exact match, n = 1
else:
fee2   := fee(m=|S_i|, n=2)
change := sum_in − target − fee2
if change ≥ dust:
outputs := [ (addrB_i, target), (addrA_i, change) ]   # n = 2
elif 0 < change < dust:
reseat_inputs()                                   # add/select different inputs; recompute
else:                                                 # change ≤ 0
reseat_inputs()                                   # underfunded; add/select different inputs
16. Worked-through flow (illustrative only)
    Step 0 — Preconditions
    • Alice (payer): identity K_A = (k_A, K_A); sender anchor A = a·G.
    • Bob (payee): identity K_B = (k_B, K_B); recipient anchor B = b·G.
    • All amounts are in the smallest settlement unit. This slice uses N = 7 notes for readability; amounts remain symbolic (a₀…a₆) and are illustrative only.

Step 1 — Policy exchange (Bob → Alice)
Bob sends a canonical Policy JSON; Alice verifies signature and computes H_policy. Example (placeholders only):

{"pk_anchor":"<hex serP(B)>",
"vmin":<v_min>,
"vmax":<v_max>,
"feerate_floor":<floor>,
"expiry":"<ISO-8601 UTC>",
"sig":"<hex by k_B over canonical fields>"}
Alice verifies pk_anchor structure, bounds, feerate_floor, expiry, and sig(K_B).

Step 2 — Invoice issuance (Alice → Bob)
Alice issues a canonical Invoice JSON referencing H_policy; Bob verifies and computes H_I:

{"invoice_number":"<id>",
"terms":"<utf8 terms>",
"unit":"<unit>",
"total":<T>,
"policy_hash":"<hex H_policy>",
"expiry":"<ISO-8601 UTC>",
"sig":"<hex by k_A over canonical fields>"}
Both parties compute the per-invoice scope:
• Z := ECDH(k_A, K_B) = ECDH(k_B, K_A) (32-byte x-coordinate).
• H_I := SHA-256(canonical_json(invoice)).
All subsequent derivations are functions of {Z, H_I}.

Step 3 — Bounded split (deterministic; exact sum)
Seed S := SHA-256( Z ∥ H_I ∥ "split" ). Compute N_min := ⌈T ÷ v_max⌉, N_max := ⌊T ÷ v_min⌋; choose N ∈ [N_min, N_max] deterministically (interior-biased). For this slice, N = 7.
Compute a vector a = (a₀, a₁, …, a₆) with v_min ≤ aᵢ ≤ v_max and Σ aᵢ = T using prefix clamping; then apply a seeded Fisher–Yates permutation with S_perm := H(S ∥ "permute"). Both parties obtain identical (N, a) without exchanging per-note amounts.

Step 4 — Reservation build (disjoint funding)
Alice snapshots her UTXO pool U₀ and constructs a reservation table R with pairwise disjoint input sets Sᵢ. Deterministic ordering: fund larger aᵢ first; UTXOs iterated in fixed (value↑, txid↑, vout↑) order. For illustration:
• S₀ = {u_3, u_9}
• S₁ = {u_1}
• S₂ = {u_5, u_7, u_12}
• S₃ = {u_8}
• S₄ = {u_2, u_10}
• S₅ = {u_4}
• S₆ = {u_6, u_11}
with Sᵢ ∩ Sⱼ = ∅ for all i ≠ j. Exact members and values are determined by the bounded-knapsack policy (§6). Size/fee are computed at feerate_floor; candidates producing dust change are rejected or reseated.

Step 5 — Per-note addresses (recipient and change)
For each index i = 0…6:

Recipient (sender view):
• tᵢ := int( SHA-256( Z ∥ H_I ∥ "recv" ∥ LE32(i) ) ) mod n; if tᵢ = 0, bump ctr deterministically until non-zero.
• P_B,i := B + tᵢ·G; Addr_B,i := Base58Check( 0x00 ∥ H160( serP(P_B,i) ) ).

Sender change (payer view):
• sᵢ := int( SHA-256( Z ∥ H_I ∥ "snd" ∥ LE32(i) ) ) mod n; if sᵢ = 0, bump ctr deterministically until non-zero.
• P_A,i := A + sᵢ·G; Addr_A,i := Base58Check( 0x00 ∥ H160( serP(P_A,i) ) ).

All Addr_B,i are unique per note; all Addr_A,i are unique per note; identity keys never appear on-chain.

Step 6 — Transaction construction (one per note)
For each i:

Inputs: Sᵢ (reserved). Let m = |Sᵢ|, sum_in = Σ value(Sᵢ).
Outputs: primary (Addr_B,i, aᵢ); optional change (Addr_A,i, changeᵢ).

Fee/change arithmetic (deterministic at floor):
• size₁ ≈ 10 + 148·m + 34·1; fee₁ := ceil(floor × size₁). If sum_in = aᵢ + fee₁ → 1-output note (no change).
• Else size₂ ≈ 10 + 148·m + 34·2; fee₂ := ceil(floor × size₂). changeᵢ := sum_in − aᵢ − fee₂; require changeᵢ = 0 or changeᵢ ≥ dust. If 0 < changeᵢ < dust or changeᵢ ≤ 0 → reseat inputs.

Build legacy P2PKH transaction Tᵢ with deterministic input order; sign every input under SIGHASH_ALL. Compute txidᵢ = dSHA256(serialisation).
Record NoteMetaᵢ := {"i": i, "note_id": H(H_I ∥ LE32(i)), "invoice_hash": H_I, "addr": Addr_B,i, "amount": aᵢ, "txid": txidᵢ, …}.

Result: seven independent, fully valid transactions {T₀…T₆}, each paying aᵢ to Addr_B,i and (if present) change to Addr_A,i; no input overlaps; no change overlaps within the invoice.

Step 7 — Either-side broadcast and pacing
Broadcast authority is “either”. Seed S_pace := H( Z ∥ H_I ∥ "pace" ); compute a paced schedule within policy bounds (min/max spacing or bursts). Either party may submit any subset in any order; duplicate submission of identical bytes is benign. Confirmation depth d from policy defines settlement for each note independently.

Step 8 — Receipts and commitment (Merkle root)
For i = 0…6, construct leaves:
• preimageᵢ := "leaf" ∥ LE32(i) ∥ txidᵢ (32 bytes) ∥ amountᵢ (8-byte LE) ∥ addr_payloadᵢ (0x00 ∥ 20-byte H160).
• Lᵢ := SHA-256(preimageᵢ).
Compute M := MerkleRoot([L₀, L₁, …, L₆]) with Bitcoin-style odd-leaf duplication. Persist a manifest:

{"invoice_hash":"<hex H_I>",
"merkle_root":"<hex M>",
"count":7,
"entries":[
{"i":0,"txid":"<hex txid_0>"},
{"i":1,"txid":"<hex txid_1>"},
{"i":2,"txid":"<hex txid_2>"},
{"i":3,"txid":"<hex txid_3>"},
{"i":4,"txid":"<hex txid_4>"},
{"i":5,"txid":"<hex txid_5>"},
{"i":6,"txid":"<hex txid_6>"}
]}
Selective proof example (index 3 only; placeholders):

{"invoice_hash":"<hex H_I>",
"merkle_root":"<hex M>",
"leaf":{"i":3,
"txid":"<hex txid_3>",
"amount":<a_3>,
"addr_payload":"00<20-byte-h160-hex>"},
"path":[
{"pos":"L","hash":"<hex>"},
{"pos":"R","hash":"<hex>"},
{"pos":"R","hash":"<hex>"}
]}
A verifier recomputes L₃ and folds the path to M; no information about i ≠ 3 is revealed.

Step 9 — Reissue before broadcast (fee update example)
Suppose, prior to any broadcast, a higher effective fee is desired for i = 5. Procedure:

Release reservation S₅; select a new disjoint S₅′; recompute fee at the new rate (≥ floor).

Keep i, Addr_B,5, Addr_A,5 unchanged; build and sign T₅′; compute txid₅′.

Mark the old bytes voided_offchain; update NoteMeta₅:

{"i":5,
"note_id":"<hex>",
"invoice_hash":"<hex H_I>",
"version":2,
"supersedes":"<hex txid_5>",
"txid":"<hex txid_5_prime>",
"status":"signed"}
Only the latest version is eligible for broadcast; older txid₅ is not propagated.

Step 10 — Settlement and closure
As notes are announced (by either party) and reach ≥ d confirmations to their respective Addr_B,i, statuses become “confirmed”. Orphaned confirmations (reorg) trigger rebroadcast of the same raw bytes until reconfirmed. When all seven notes are confirmed (or when the invoice expires, cancelling any remaining queued notes), the invoice is closed. The audit trail consists of: the signed Policy and Invoice, H_I, the deterministic split a[·], the reservation table R, per-note NoteMeta with txidᵢ, the Merkle root M and manifest, and any reissue/cancel records. Every note in the slice has a disjoint input set Sᵢ, a unique recipient address Addr_B,i, and—where applicable—a unique sender change address Addr_A,i.

17. Testing and verification
    17.1 Scope
    Verify correctness, determinism, and auditability for a complete invoice lifecycle. All tests operate on canonical UTF-8 JSON, secp256k1 over compressed keys, and the invoice scope {Z, Hᴵ}.

17.2 Required fixtures (deterministic)
• Keys
– Identity: Kₐ = (kₐ, Pₐ), Kᵦ = (kᵦ, Pᵦ).
– Anchors: A = a·G, B = b·G (a ≠ kₐ, b ≠ kᵦ).
• Policy (canonical JSON) with fields per §3.3 and valid ECDSA by kᵦ.
• Invoice (canonical JSON) referencing H_policy, valid ECDSA by kₐ; compute Hᴵ := H(canonical_json(invoice)).
• UTXO snapshots U₀ covering edge cases:
– exact-match inputs;
– “just-over” inputs that yield valid ≥ dust change;
– coarse inputs forcing fan-out;
– conflicting external spend (simulated) on a reserved outpoint.
• Parameters: v_min, v_max, fee_rate_floor, dust, expiry, d (confirm depth).
• Golden PRNG seeds are implicit: derived from {Z, Hᴵ} per spec; no external RNG.

17.3 Property tests (must hold)

P1 — Sums and bounds (split).
For hundreds of randomly chosen feasible triples (T, v_min, v_max):
• Compute N_min := ⌈T/v_max⌉, N_max := ⌊T/v_min⌋; run the split (§5).
• Assert: N_min ≤ N ≤ N_max; ∑ᵢ a[i] = T; ∀i: v_min ≤ a[i] ≤ v_max.
• Re-run: identical a (before permutation) and identical permuted a.

P2 — Address agreement (recipient).
For i = 0…N−1:
• Sender computes Pᴮ,ᵢ, Addrᴮ,ᵢ from {Z, Hᴵ, B, i}.
• Recipient computes kᴮ,ᵢ := (b + tᵢ) mod n; check kᴮ,ᵢ·G = Pᴮ,ᵢ.
• Assert identical Addrᴮ,ᵢ at both ends.

P3 — Disjoint reservations.
Build R from U₀ and a[·] (§6).
• Assert Sᵢ ∩ Sⱼ = ∅ for all i ≠ j;
• Assert every input used appears in exactly one Sᵢ;
• Assert deterministic reproducibility: rebuild(R) equals prior R byte-for-byte.

P4 — Non-overlapping change.
For all notes that produce change:
• Derive Addrᴬ,ᵢ (§7); assert Addrᴬ,ᵢ ≠ Addrᴬ,ⱼ for i ≠ j;
• Assert no change UTXO from note i is admitted to the funding pool while invoice open.
• Assert transactions meet dust and fee-floor rules; otherwise reseat inputs.

P5 — Reissue invariants.
For a pre-broadcast fee update on index i:
• Build Tᵢ, then reissue Tᵢ′ at higher fee.
• Assert: i unchanged; NoteIDᵢ unchanged; Addrᴮ,ᵢ unchanged; Addrᴬ,ᵢ unchanged; txidᵢ ≠ txidᵢ′; prior bytes flagged superseded and never broadcast.

P6 — Receipts.
Construct leaves Lᵢ and root M (§10).
• For random S ⊂ {0…N−1}, produce single-leaf proofs and verify to M.
• If multi-proof implemented, verify shared-sibling structure; otherwise independent proofs suffice.
• Manifest { (i, txidᵢ) } + M must match recomputation.

P7 — Rebuild from logs.
Given only signed logs (policy, invoice, reservations, NoteMeta, receipt manifest):
• Verify signatures, canonical JSON, and hash-chain “prev_hash”.
• Recompute H_policy, Hᴵ, Z.
• Recompute a[·], Addrᴮ,ᵢ, Addrᴬ,ᵢ; rebuild R from the logged U₀ snapshot and parameters;
• Reconstruct or fetch raw Tᵢ, recompute txidᵢ; check equality with NoteMeta;
• Recompute Lᵢ and M; verify equals manifest.merkle_root.
All asserts must pass without external oracles.

17.4 Negative / failure tests (must reject)

N1 — Infeasible invoice.
Choose T, v_min, v_max with ⌈T/v_max⌉ > ⌊T/v_min⌋ → split must fail early.

N2 — Canonicalisation break.
Permute JSON key order or add whitespace → signatures fail; H_policy/Hᴵ differ; reject.

N3 — Scope misuse.
Attempt derivation without {Z, Hᴵ} or with wrong domain label (“recv” vs “snd”) → derived addresses mismatch; reject.

N4 — Zero-scalar forcing.
Artificially search i such that tᵢ = 0 or sᵢ = 0; verify deterministic counter-bump produces non-zero and stable i mapping; log counter used.

N5 — Reservation overlap.
Mutate R to place same outpoint in two Sᵢ → builder must detect and fail.

N6 — Dust/fee violations.
Construct candidates with change ∈ (0, dust) or fee < fee_floor × size → must reseat or fail.

N7 — Conflicting external spend.
Mark a reserved input as spent elsewhere → builder must abort and rebuild R (§11).

N8 — Expiry and stale notes.
Advance clock beyond invoice/policy expiry → queued notes become “cancelled”; no new broadcasts permitted.

17.5 Rebuild procedure from logs (normative)

Inputs: append-only, signed, canonical JSON records per §13 (policy_record, invoice_record, reservations, NoteMeta*, receipt_manifest, event records).

Procedure:

1. Verify hash-chain: for each record R_k, check prev_hash = H(bytes(R_{k−1} \ sigtriplet)).
2. Verify signatures by the stated sig_key over canonical bytes (without sigtriplet).
3. Extract policy → compute H_policy; extract invoice → verify policy_hash and compute H_I.
4. Recompute Z from K_A, K_B.
5. Recompute split a[·] from {Z, H_I, v_min, v_max} (and permutation).
6. Rebuild R deterministically from logged U₀ snapshot and parameters; compare to logged reservations.
7. For each i:
   a. Derive Addr_B,i and Addr_A,i; compare to NoteMeta (if present).
   b. Reconstruct tx template from NoteMeta.inputs/outputs or fetch raw tx; recompute txid_i.
   c. Check lifecycle: supersedes chain, statuses, timers consistent with §9–§11.
8. Recompute leaves L_i and Merkle root M; match receipt_manifest.merkle_root.
9. Emit a verification report listing all assertions; fail on first discrepancy.
   17.6 Golden vectors and cross-impl determinism
   Publish at least two golden invoices (small and large N) with: policy, invoice, H_policy, H_I, Z (hex), a[·], R (outpoints), (Addr_B,i, Addr_A,i), txidᵢ, M, and selective proofs. Independent implementations must reproduce these byte-for-byte.

17.7 Fuzzing and coverage (recommended)
• Fuzz (T, v_min, v_max) under feasibility; run P1–P6.
• Fuzz U₀ distributions (heavy-tail, uniform, clustered).
• Randomly trigger reissue, conflict, expiry.
• Target ≥ 95 % branch coverage across split, reservation, fee/change, and receipt code paths.

17.8 CI gating (pass/fail)
A build is releasable only if: P1–P7 pass; N1–N8 reject as specified; golden vectors match; rebuild-from-logs produces identical outputs including R, addresses, txids, and M.

Subscribe to Craig’s Substack
By Craig Wright · Launched 3 months ago
My personal Substack
1 Like
∙
1 Restack

1


1


