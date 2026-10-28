# Architecture Brief: A Self-Certifying, Federated, Post-Quantum Network

**Status:** Conceptual architecture, October 28, 2026  
**Purpose:** Preserve the design discussion and provide an engineering agent with the context necessary to develop, critique, formalize, and eventually implement the system.

## 1. Fundamental Vision

Build a new decentralized networking, naming, identity, and trust architecture that eliminates dependence on conventional X.509 certificate authorities and centralized DNS governance.

The system should provide:

1. **Self-certifying addresses** that cryptographically identify their destination.
2. **Post-quantum authentication** using hash-based signatures and appropriate post-quantum key exchange.
3. **Hierarchical but rootless naming**, where identities can have arbitrarily many ancestors and descendants.
4. **Downward-only trust propagation**, with no implicit trust of ancestors.
5. **Locally controlled trust anchors**, including anchors distributed with the client and anchors acquired through invites.
6. **Full cryptographic auditability** of changes to namespaces and identities.
7. **Merkle Mountain Range histories** committed to by authorized signing keys.
8. **Federated infrastructure** with decentralized discovery using a DHT.
9. **Push-based cache invalidation**, supplemented by TTL-based expiration.
10. **Sybil and eclipse resistance** using diversified routing, peer management, and economic rate-limiting.
11. **Independent bootstrap and recovery mechanisms** that avoid circular infrastructure dependencies.
12. **Identity recovery and key rotation** without unnecessarily breaking long-lived identities.

The design should be permissionless, federated, user-sovereign, and implementable without a global blockchain.

The project originated in the design of a fully self-hosted Discord replacement, but the naming and networking architecture is potentially general-purpose.

### Guiding philosophy

Separate five concepts that conventional systems frequently conflate:

- **Identity:** Which cryptographic principal is this?
- **Authority:** What is that principal authorized to control?
- **Naming:** How do users refer to that principal?
- **Location:** Where can that principal currently be contacted?
- **Discovery:** How can clients find the relevant records?

Each concept should be independently auditable and replaceable.

The networking infrastructure must not become an implicit source of naming or authentication authority.

---

## 2. Fundamental Address Format

The desired address format is conceptually:

`IP:port:protocol_magic:merkle_root_of_PQ_public_keys`

The components are:

| Component | Purpose |
|---|---|
| IP | Current network location |
| Port | Transport endpoint |
| Protocol magic | Identifies the intended protocol/network |
| Merkle root | Cryptographic commitment to the destination's post-quantum identity keys |

The address must be self-certifying.

When connecting, the remote endpoint must prove that it controls keys authorized under the committed identity.

The client must not require a certificate authority to establish authenticity.

### Why a Merkle root instead of a raw public key?

A Merkle commitment can support:

- Multiple authorized public keys.
- Different signing and recovery roles.
- Threshold authorization policies.
- Membership proofs for individual keys.
- A compact identifier committing to a larger key manifest.

The precise manifest representation remains to be designed.

### Critical design issue: identity stability

If the address contains the Merkle root of the *current* public keys, rotating those keys necessarily changes the root.

Therefore, a recommended refinement is:

**Make the address commit to a stable genesis identity manifest, not the mutable set of current operational keys.**

The genesis manifest can specify authorized recovery policies and mechanisms for updating the active key set.

The identity commitment remains stable while operational keys change.

A possible conceptual model:

- Stable identity: Merkle root of genesis identity manifest.
- Current authorization: Versioned, signed key-policy records.
- Current location: Versioned, signed endpoint records.
- Historical state: Append-only MMR.
- Current state: Authenticated state commitment.

If the genesis commitment itself must change, that is an **identity migration**, not an ordinary operational-key rotation.

A compromised genesis recovery authority cannot be repaired through cryptography alone without introducing some independently established recovery authority.

### Transport requirements

The transport handshake should authenticate the committed identity and bind:

- Protocol magic.
- Protocol version.
- Identity commitment.
- Negotiated cryptographic algorithms.
- Ephemeral key-exchange transcript.
- Intended endpoint role.

This prevents cross-protocol confusion and identity misbinding.

The textual address needs an unambiguous encoding, particularly for IPv6.

The system should also eventually support multiple endpoints per identity, including IPv4, IPv6, and alternative transports.

**Important:** This address authenticates the endpoint but cannot authenticate the provenance of the address itself. If an attacker substitutes an entirely different address in an invite, the substituted endpoint may still authenticate successfully.

---

## 3. The Trust Model

The system uses locally selected trust anchors rather than a globally mandatory trust root.

### 3.1 Trust On First Use

When a client encounters a server outside its existing trusted namespaces, it can establish a new local trust anchor.

For example:

1. A user receives a server invitation.
2. The invitation includes an IP, port, protocol magic, and identity commitment.
3. The client connects.
4. The server cryptographically proves possession of an authorized identity key.
5. The client pins the identity commitment.
6. Subsequent connections must authenticate against the pinned identity or its authorized key transitions.

Strictly speaking, when an invitation already contains the identity commitment, this is **key pinning**, not ordinary TOFU.

The first-use security assumption shifts to the integrity of the invitation.

If the first contact supplies the key rather than an authenticated invitation, it is conventional TOFU.

### 3.2 Make TOFU indistinguishable from ordinary usage

The desired user experience is that encountering an unfamiliar server works naturally.

There should not be a need to understand certificate authorities, TLS, or complex trust-management procedures.

A client application can ship with a default collection of trust anchors.

These behave similarly to a conventional operating-system or browser root store, except:

- The application controls its own trust configuration.
- The user can inspect every anchor.
- The user can add and remove anchors.
- Anchors need not have universal authority.
- Trust is scoped to individual namespaces or identities.
- New independently trusted identities can be introduced through invites.
- Trust decisions can be exported, imported, and audited.

A bundled anchor is technically software-distributor trust, rather than cryptographic TOFU. The interface can nevertheless unify both mechanisms in one local trust store.

**The objective is not to eliminate all initial trust assumptions. It is to make them explicit, scoped, inspectable, and user-controlled.**

### 3.3 Downward-only trust propagation

This is a central design rule.

If a user trusts identity `A`, and `A` signs a valid delegation to `B`, the client may accept `B` as authorized within the delegated namespace.

If `B` delegates to `C`, trust can propagate to `C`.

Conceptually:

`A → B → C → D → ...`

Trust propagates downward through valid delegations, subject to their constraints.

It does **not** propagate upward.

If the user independently trusts `C`, this does not imply trust in `B` or `A`.

The distinction matters because ancestors may possess authority to rename or redirect descendants within their namespaces.

A user who directly pins `C` must not silently surrender that pinned identity to an untrusted ancestor.

### 3.4 Authorization is not universal trust

Accepting a signed delegation means accepting the delegated claim within its authorized scope.

It does not mean:

- Trusting the delegate's software.
- Trusting the delegate with private data.
- Trusting all claims made by the delegate.
- Granting permissions outside the delegated namespace.
- Allowing the delegate to override independently pinned identities.

Trust must be interpreted as scoped cryptographic authority, not general interpersonal trust.

---

## 4. Rootless, Infinitely Extensible Naming

The namespace is hierarchical but does not require a universally privileged root.

An identity can exist before having a parent.

A parent can adopt an existing identity by issuing a signed delegation.

An identity can acquire new parents after it has already accumulated descendants.

The namespace can therefore grow both downward and upward.

### 4.1 Child creation

Suppose identity `B` exists independently.

Identity `A` can publish a signed delegation:

`A / community → B`

A client trusting `A` can resolve `community` to `B`.

`B` retains its independent cryptographic identity.

### 4.2 Adding a parent later

Suppose:

`B / chat → C`

Later, `A` adopts `B`.

Now clients trusting `A` can resolve:

`A / community / chat → C`

Neither `B` nor `C` must change identity.

Their histories remain intact.

### 4.3 Multiple parents

The same identity can be delegated to by multiple parents.

For example:

`A / forum → C`

`B / community → C`

Both paths can identify the same cryptographic principal.

This supports:

- Aliases.
- Organizations.
- Federation.
- Cross-namespace references.
- Organizational restructuring.
- Discovery through different trust networks.

It also means the topology is fundamentally a **directed graph**, not necessarily a tree.

### 4.4 Cycles

The system need not prohibit cyclic delegation globally.

However, recursive resolution must detect cycles.

Resolvers should maintain visited identity/path states and enforce explicit limits on:

- Traversal depth.
- Number of visited nodes.
- Total proof size.
- Processing time.
- Concurrent lookups.

**Unlimited namespace extensibility does not imply unlimited work for a single resolution.**

### 4.5 Name uniqueness

There is no guarantee that human-readable names are globally unique.

Different parents may define identical labels.

Names are therefore relative to trust anchors.

A globally unambiguous reference includes the identity commitment or an equivalent cryptographically anchored namespace reference.

Human-friendly aliases can be maintained locally.

There is no requirement for a blockchain, auction, registrar, or central allocation authority to decide who owns an arbitrary name globally.

### 4.6 Name normalization

The implementation needs deterministic name encoding and normalization rules.

Unicode confusables, visually similar names, case normalization, and ambiguous path encodings require explicit treatment.

Cryptographic correctness does not prevent deceptive human-readable names.

---

## 5. Scoped Delegation and Capabilities

A useful extension is to make delegations more expressive than simple parent-child assignments.

A parent could authorize a child to manage:

- One particular name.
- An entire namespace subtree.
- A restricted class of records.
- Additional child delegations.
- A limited validity period.
- Specific service protocols.

A delegation record could conceptually contain:

| Field | Meaning |
|---|---|
| Parent identity | Authority issuing the delegation |
| Child label | Name assigned within parent namespace |
| Child identity | Cryptographic identity being delegated to |
| Permissions | Authorized record types and operations |
| Subdelegation policy | Whether and how authority may be delegated further |
| Validity | Effective and expiration conditions |
| Sequence/version | Ordering within the parent's history |
| Signature | Authorization by the parent |

Delegations must be signed by the actual authority granting them.

A child cannot grant itself a trusted parent.

An outsider can claim to be somebody's parent, but this has no effect on that parent's namespace without the parent's authorized signature.

### Directly pinned identities

A locally pinned identity is authoritative for its own identity.

Its parent might be authorized to change a *name mapping*, but should not thereby gain the ability to rewrite the child's cryptographic identity history.

This separation is essential for safe reparenting and recovery.

---

## 6. Merkle Mountain Range Histories

A central architectural choice is to maintain auditable histories using **Merkle Mountain Ranges (MMRs)**.

The intention is that namespace modifications should not merely overwrite old records.

Instead, updates are appended to an authenticated history.

### 6.1 What gets logged?

Potential entries include:

- Creation of identities.
- Delegation creation.
- Delegation modification.
- Delegation revocation.
- Endpoint additions and removals.
- Operational-key rotation.
- Recovery-policy changes.
- Identity migration.
- Service metadata changes.
- Other authority-bearing record modifications.

Every entry should have an unambiguous canonical representation.

### 6.2 Signed checkpoints

Each namespace authority periodically or immediately publishes a signed checkpoint committing to its history.

Conceptual checkpoint:

| Field | Meaning |
|---|---|
| Identity | Namespace authority |
| Sequence | Monotonic checkpoint version |
| MMR size | Number of committed history entries |
| MMR root | Commitment to historical entries |
| Current-state root | Commitment to present namespace state |
| Previous checkpoint | Link to an earlier checkpoint |
| Validity metadata | Expiration and timing information |
| Signatures | Authorization under the identity's current signing policy |

The MMR supports efficient inclusion proofs and consistency proofs between append-only checkpoints.

A client can establish that a new checkpoint extends an earlier history.

### 6.3 Merkle root versus Merkle Mountain Range

The system uses Merkle commitments for different purposes.

**Identity Merkle commitment:**
Identifies the genesis key manifest and its associated identity.

**Historical MMR:**
Commits to append-only changes over time.

**Authenticated current-state map:**
Commits to currently valid records.

These structures should not be conflated.

### 6.4 Authenticated current state

An MMR efficiently proves that an event occurred in an append-only history.

It is less suitable for proving that a particular name currently resolves to one value, or that no such name exists.

Therefore, pair the MMR with an authenticated dictionary, such as a sparse Merkle tree or another suitable authenticated map.

A checkpoint commits to both:

1. The complete historical state transition log.
2. The current materialized state.

The current-state root must be derived deterministically from the history, with enough authenticated information for clients or auditors to verify that relationship.

A current-state proof alone does not prove that the map was correctly derived.

---

## 7. Transparency, Witnessing, and Equivocation

A self-signed append-only log does **not** automatically guarantee one universal, tamper-proof history.

This is an essential limitation.

An authority with access to the signing keys can publish two incompatible histories to different observers.

Both can have valid signatures.

This is called **equivocation**.

### 7.1 Witnesses

Use independent witnesses to observe signed checkpoints.

Witnesses retain checkpoint history and can issue attestations stating which checkpoints they observed.

Clients may select witness policies based on:

- Independent network operators.
- Geographic and ASN diversity.
- Explicitly trusted witness keys.
- Minimum witness quorum.
- Independent gossip paths.

This should be decentralized and configurable.

No mandatory global witness authority is needed.

### 7.2 Checkpoint gossip

Clients, federation servers, and DHT nodes can exchange signed checkpoints.

If two incompatible checkpoints are observed for the same identity and historical position, the client obtains cryptographic evidence of equivocation.

The system should preserve and propagate that evidence.

### 7.3 Limits of transparency

Witnessing improves detection, but not everything can be guaranteed.

A newly connected client may still encounter a split view if it cannot reach independent witnesses.

Signatures do not prove truthful timestamps.

An MMR commitment does not guarantee that the underlying historical data remains available.

An authority might withhold updates before they become widely witnessed.

Therefore, the design needs explicit assumptions concerning:

- Freshness.
- Availability.
- Witness independence.
- Historical retention.
- Recovery from conflicting histories.

**Target property:** Undetected rewriting and equivocation should become increasingly difficult as independent clients and witnesses observe the history.

It cannot be made categorically impossible in a fully asynchronous, permissionless network without additional assumptions.

---

## 8. DHT-Based Discovery

Use a Distributed Hash Table for decentralized discovery and distribution.

Kademlia is the leading candidate for the routing architecture.

The DHT should help clients locate:

- Peer endpoints.
- Signed mutable namespace heads.
- Signed endpoint records.
- Current MMR checkpoints.
- Immutable history fragments.
- Historical checkpoint proofs.
- Replicas and federation servers.

### 8.1 Fundamental separation

**The DHT is responsible for finding data, not deciding whether it is authoritative.**

A DHT node can return malicious, outdated, incomplete, or contradictory data.

Clients must independently verify:

- Cryptographic signatures.
- Identity commitments.
- Delegation paths.
- Policy constraints.
- Checkpoint consistency.
- Freshness requirements.

DHT responses should be treated as untrusted transport data.

### 8.2 Mutable records

An identity can publish a signed mutable record describing its latest known checkpoint.

Conceptually:

`identity_commitment → signed_latest_checkpoint`

The checkpoint can reference immutable records by content hash.

The mapping should include a monotonically increasing version or sequence number.

This limits ordinary replay and rollback when a client has already observed a newer version.

However, a brand-new client cannot infer the globally latest version from signatures alone.

Witnesses, independent retrieval, and freshness limits help address this.

### 8.3 Immutable history

Historical entries or chunks can be content-addressed.

DHT nodes can distribute these chunks independently of the authority that created them.

This makes history replication inexpensive to verify.

Broadly replicate compact checkpoints.

Replicate full histories according to explicit storage policies.

Do not require every DHT node to retain every historical byte forever.

---

## 9. DHT Nodes Use the Same Networking Layer

The DHT should dogfood the same self-certifying transport used by applications.

DHT node addresses use:

`IP:port:protocol_magic:identity_commitment`

Connections authenticate the peer's committed identity.

There is no separate certificate hierarchy for infrastructure nodes.

### 9.1 Avoid circular dependencies

A DHT node must not require a successful DHT lookup before establishing its first peer connection.

Bootstrapping should use independently obtained peer addresses.

Potential sources:

- Peer addresses bundled with the application.
- Previously successful peers cached on disk.
- Manually supplied addresses.
- Peer addresses obtained from invitations.
- Addresses exchanged over already-established connections.
- Independently distributed recovery/bootstrap manifests.

Once connected, the node can discover additional peers through the DHT.

### 9.2 Facebook-style failure concern

The design was motivated partly by infrastructure failures in which one distributed system becomes dependent on another unavailable system.

The important invariant is:

**Failure of the naming system must not make the naming system's own transport impossible to bootstrap.**

Persist peer endpoints and authenticated identities locally.

Keep bootstrap mechanisms independent of recursive name resolution.

### 9.3 Underlying network dependence

Avoiding DNS circularity does not eliminate dependence on IP routing.

BGP failures, ISP outages, NAT restrictions, or physical network partitions remain possible.

Multiple independent bootstrap sources, dual-stack support, and network diversity improve resilience.

The DHT cannot repair a disconnected underlying internet.

---

## 10. Sybil and Eclipse Resistance

The system must assume that attackers can cheaply generate arbitrarily many cryptographic identities.

Public-key identities are not naturally scarce.

This creates two separate problems:

1. **Routing capture:** Attacker identities surround or isolate an honest node.
2. **Resource exhaustion:** Attacker identities publish enough records to overwhelm distributed storage.

These require different defenses.

### 10.1 Kademlia routing

Use a Kademlia-style DHT with cryptographically derived node identifiers.

Node identifiers should be bound to the corresponding authenticated peer identities.

Routing tables organize peers according to XOR distance.

The design should examine identity grinding attacks, where attackers search for keys producing favorable locations in the identifier space.

### 10.2 ASN diversity

Use Autonomous System Number diversity in routing tables.

Limit the concentration of peers controlled by the same ASN.

Apply diversity rules to individual routing buckets as well as aggregate connections.

Also consider:

- IPv4 prefix diversity.
- IPv6 prefix diversity.
- Independent network providers.
- Connection age.
- Peer reachability.
- Historical reliability.

ASN diversity is a heuristic, not a cryptographic guarantee.

### 10.3 Proof-of-work for DHT participation

Require a modest, verifiable computational cost for admission as a DHT routing/storage node.

A candidate node identity may need a proof tied to:

- Its public key.
- Network identity.
- Protocol version.
- An epoch or challenge.
- A nonce.

This increases the cost of producing many routing identities.

It should not require ordinary chat users or domain owners to mine merely to possess identities.

Proof-of-work does not eliminate Sybil attacks, but makes large-scale identity grinding more expensive.

The admission mechanism must not unintentionally privilege specialized hardware or enable easy proof reuse.

### 10.4 Bitcoin-inspired peer management

Adopt ideas from Bitcoin's peer-management architecture.

**Separate verified and unverified peers.**

Newly advertised addresses should not automatically displace established connections.

**Persist known-good peers.**

The application should survive restarts with a cache of authenticated, previously reachable endpoints.

**Anchor outbound connections.**

Maintain a limited set of stable, independently selected peers across restarts.

**Test before eviction.**

Avoid accepting a flood of attacker-controlled peers at the expense of healthy existing connections.

**Use randomized, locally unpredictable peer selection.**

Prevent attackers from easily predicting every peer-selection decision.

### 10.5 Independent retrieval

Use multiple independent lookup paths for important records.

Query peers from different routing regions and network operators.

Compare signed checkpoints.

A single malicious DHT neighborhood should not determine the client's complete view of an identity.

### 10.6 Routing versus storage security

ASN diversity, connection anchoring, and identity proof-of-work primarily protect routing and peer selection.

They do not necessarily prevent an attacker from creating millions of perfectly valid signed child records.

Storage defenses are also required.

---

## 11. DHT Storage Economics and Resource Limits

The naming architecture permits unlimited logical creation of children.

That does not imply an obligation for every DHT node to store unlimited data.

Attackers can generate arbitrary identities, delegations, and MMR histories.

Signatures demonstrate authorization, not entitlement to network resources.

### Recommended defenses

**Bounded record sizes:** Apply explicit limits to individual records, proofs, and checkpoint representations.

**Expiration:** Require records to have finite advertised storage lifetimes.

**Quotas:** Enforce storage and bandwidth budgets.

**Admission costs:** Consider proof-of-work, resource pricing, or other bounded-cost mechanisms for expensive publication.

**Chunking:** Store large historical data as independently retrievable immutable chunks.

**Checkpoint prioritization:** Prefer distributing small, recent, authenticated summaries over unlimited archival copies.

**Garbage collection:** Evict expired or low-priority data according to documented policies.

**Rate limiting:** Restrict publication and update rates, including repeated invalidation events.

**Replication diversity:** Replicate valuable data across independently selected peers rather than simply concentrating it near one routing neighborhood.

### Important limitation

Per-public-key quotas alone are ineffective because attackers can create new keys.

Parent-based quotas alone are also insufficient if attackers can generate new parents.

The protocol needs a resource-allocation policy that accounts for the fundamental absence of scarce identities.

It may be impossible to simultaneously guarantee unrestricted anonymous publication, free unlimited storage, and robust protection against resource exhaustion.

The design must make this tradeoff explicit.

---

## 12. TTL + Purge: Decentralized Cache Invalidation

The desired caching model is not merely conventional TTL expiration.

It should combine:

**TTL + authenticated push-based purge notifications.**

TTL bounds how long stale data may be reused.

Purge notifications attempt to invalidate stale data immediately when changes occur.

### 12.1 The subscriber-list problem

If an authority changes a record, how does it know which caches currently hold that record?

A global subscriber list would create centralization, scalability, and privacy problems.

Therefore, do not require one global subscriber registry.

### 12.2 Distributed subscription trees

Use distributed notification relays.

Each relay tracks only its immediate subscribers.

Conceptually:

`Authority → Relay → Relay → Cache → Client`

The authority does not need to know every downstream client.

Caches do not need to register directly with the original publisher.

Subscriptions are renewable and expire automatically when abandoned.

### 12.3 Discovery of notification relays

Use the DHT to find notification relays associated with an identity or record.

A cache retrieving a record can also discover suitable relays and subscribe to future updates.

Prefer network-diverse relays and redundant subscriptions for important names.

Popular namespaces can distribute notification traffic across multiple relay trees or shards.

### 12.4 Authenticated notifications

A notification should carry, or refer to:

- The affected identity or namespace.
- The new signed checkpoint.
- The checkpoint sequence number.
- Evidence needed to verify the transition.
- The affected record or dependency scope.

Relays do not need to be trusted.

Clients verify the authority signatures and history consistency independently.

A relay cannot forge an authorized update.

It can, however, delay, suppress, replay, or refuse to forward notifications.

### 12.5 Dependency invalidation

A cached descendant depends on its entire delegation path.

Suppose:

`A → B → C`

A client cached a resolution for `C`.

If `A` changes the delegation to `B`, the cached resolution might no longer be valid under `A`.

Therefore, caching needs dependency tracking.

A cache entry should record the relevant delegation authorities and versions.

Changes affecting any required dependency invalidate or trigger revalidation of the derived result.

A reverse-dependency index can make this efficient.

Subtree or namespace-prefix invalidation may help avoid tracking every descendant separately.

### 12.6 Missed notifications

A client might be offline.

A relay might crash.

An adversary might suppress updates.

Therefore, the system also needs:

- TTL-based expiration.
- Subscription leases.
- Sequence-number tracking.
- Reconnection synchronization.
- Checkpoint comparison.
- Periodic refresh where necessary.

On reconnect, a client provides the last observed checkpoint and requests any missed changes.

MMR consistency proofs help verify continuation.

### 12.7 Limits of immediate revocation

Instantaneous global purge cannot be guaranteed under network partitions or malicious relay censorship.

The achievable guarantee is closer to:

**Best-effort immediate invalidation, with cryptographically authenticated updates and bounded offline staleness under stated network and clock assumptions.**

Security-sensitive records may require fresh verification rather than relying on a cached TTL alone.

### 12.8 Subscription privacy

Subscription metadata can reveal which namespaces users follow.

Possible mitigations include:

- Relay indirection.
- Aggregated subscriptions.
- Prefix-level subscriptions.
- Proxying.
- Optional privacy-preserving retrieval mechanisms.

This is a separate threat model from cryptographic authenticity.

---

## 13. Key Rotation, Revocation, and Recovery

The system should support changes to endpoint addresses and cryptographic keys without unnecessary loss of identity continuity.

These operations must be distinguished.

### 13.1 Endpoint rotation

An authority changes its IP address or port.

It publishes a new signed endpoint record.

The signed checkpoint advances.

The DHT distributes the new record.

Notification relays send invalidation events.

Clients reconnect using the new endpoint and verify the same stable identity.

This is the simplest case.

### 13.2 Operational-key rotation

An authority changes active signing or communication keys.

The genesis identity commitment remains stable.

A previously authorized key policy or recovery policy authorizes the transition.

Clients verify the transition and update their active-key records.

### 13.3 Compromised operational key

An attacker may use an exfiltrated operational key to publish apparently authorized records.

Recovery requires an independently protected authority with sufficient power to revoke that key.

This could use:

- Offline recovery keys.
- Multiple independent recovery keys.
- Threshold authorization.
- Recovery policies committed to by the genesis identity.

Recovery must not depend exclusively on a key that the attacker already possesses.

### 13.4 Parent-directed child replacement

A parent may update its own delegation from one child identity to another.

That changes the meaning of the name within the parent's namespace.

It does not automatically change an independently pinned child identity.

This distinction prevents untrusted ancestors from hijacking directly trusted identities.

### 13.5 Recovery-policy changes

Changing recovery policies is particularly sensitive.

A routine operational key should not automatically be able to replace the higher-privilege recovery authority.

Consider separate authorization requirements for changing recovery policy.

### 13.6 Irrecoverable compromise

If every authority capable of authorizing recovery is compromised, the system cannot cryptographically distinguish the rightful owner from the attacker.

Recovery then requires a new identity and an out-of-band reestablishment of trust.

Do not silently promise recovery that the cryptographic design cannot guarantee.

### 13.7 Starting policy: rotate records only

The first version has no revoke records, only rotate records, and only the recovery key may sign one. See section 26.

---

## 14. Proof-Carrying Invitations and Resolution

An especially useful extension is to make invitations carry enough cryptographic information to authenticate a destination before relying on the DHT.

An invitation could include:

- Destination address.
- Stable identity commitment.
- Optional human-readable namespace path.
- Signed delegation chain.
- Relevant key-policy records.
- Latest known signed checkpoint.
- MMR consistency information.
- Optional witness attestations.
- Expiration or freshness metadata.

This could support immediate onboarding with minimal lookup dependency.

### Client behavior

When opening an invitation:

1. Parse and validate the canonical address.
2. Determine whether the identity is already trusted.
3. If the invitation includes a delegation path from a trusted anchor, verify it.
4. Otherwise, establish a new locally pinned identity according to the application's first-use policy.
5. Authenticate the destination's key possession.
6. Verify applicable policy constraints.
7. Connect.
8. Synchronize newer signed records and checkpoints when available.

The interface should reveal whether an identity is:

- Directly pinned.
- Derived from a trusted delegation.
- Newly encountered.
- Recovered or rotated under an existing identity policy.
- Associated with conflicting historical evidence.

These distinctions should remain inspectable without making ordinary navigation cumbersome.

A proof-carrying invitation improves independence from infrastructure but does not guarantee that the invitation contains the latest state.

---

## 15. Federation Architecture

The system should support independent self-hosted servers without giving any server universal authority.

Separate the following roles:

### Namespace authority

Controls authorized namespace state and signs updates.

### Service host

Runs an application service, such as chat.

### DHT peer

Participates in distributed lookup and record replication.

### Notification relay

Distributes updates and purge notifications.

### Witness

Observes and attests to signed histories.

### Archival replica

Retains historical data for audits and recovery.

One physical server may implement several roles.

Different organizations may operate them independently.

The security model should not require all roles to be colocated.

A namespace could move between service hosts while preserving its identity.

A service host could be discoverable through several independent namespace paths.

A malicious storage replica should not be able to alter valid signed records.

However, storage or network operators can still attack availability.

The architecture needs an explicit distinction between authoritative writers and non-authoritative replicas.

Multiple simultaneous authorized writers require a separately defined concurrency and conflict-resolution policy; an MMR alone does not provide this.

---

## 16. Post-Quantum Cryptographic Design

The earlier messaging-system discussion selected the following provisional primitives.

| Purpose | Preferred primitive |
|---|---|
| General hashing | BLAKE3 |
| Merkle structures | BLAKE3 |
| Symmetric authenticated encryption | ChaCha20-Poly1305 |
| Session establishment | PQXDH |
| Identity signatures | SLH-DSA |
| HMAC | HMAC-SHA-256 |
| Pairwise messaging | Signal-style ratcheting |
| Group messaging | MLS-style group key management |

### 16.1 SLH-DSA

SLH-DSA is a hash-based post-quantum signature scheme.

It fits the intention to avoid relying entirely on lattice-based cryptography for identity authentication.

However, SLH-DSA signatures are comparatively large and signing can be expensive.

The design should account for the costs of signing large numbers of checkpoints and delegation changes.

Possible optimizations include batching changes into checkpoints and separating high-frequency transport authentication from expensive long-term identity authorization.

Any such separation must preserve the required security properties.

### 16.2 PQXDH

PQXDH was selected as the preferred initial key agreement architecture.

Earlier alternatives considered included HQC and hybridizing different post-quantum KEMs.

The working preference was to avoid unnecessary custom cryptographic constructions.

**Important:** Using SLH-DSA for some identity signatures does not automatically make every authentication step in an otherwise standard PQXDH implementation post-quantum secure.

The protocol must explicitly define how post-quantum identity authentication binds to session establishment.

### 16.3 Ratcheting

The earlier chat-system concept involved the Signal Double Ratchet.

The protocol should distinguish initial key establishment from subsequent message-key evolution.

If adopting existing Signal constructions, examine the current post-quantum ratcheting design rather than assuming the original classical Double Ratchet provides post-quantum security.

### 16.4 Group messaging

A custom MLS-like group protocol was considered.

However, this remains a proposal, not a completed design decision.

Established MLS constructions should be studied before attempting to implement equivalent group-key management from scratch.

### 16.5 Domain separation and serialization

All signed records, hashes, and transcript commitments need unambiguous domain separation.

Use canonical serialization.

Specify algorithm identifiers, record versions, and protocol identifiers.

Do not assume that substituting BLAKE3 or another primitive into an established protocol preserves its security analysis.

### 16.6 Hash security

BLAKE3 provides 256-bit hash outputs, but post-quantum security margins must be considered separately for collision and preimage resistance.

The system should explicitly document the required security levels for different commitments.

---

## 17. The Original Self-Hosted Chat Application

The broader project originated as a custom Discord replacement.

The intended characteristics were:

- Fully self-hosted servers.
- Federated discovery and connectivity.
- End-to-end encrypted messaging.
- Persistent messages and reactions.
- Minimal external runtime dependencies.
- A strongly auditable networking and identity foundation.

### Database architecture

The original proposal specified:

- SQLite as the server state database.
- Vendored SQLite amalgamation (`sqlite.c`).
- One logical SQLite database per server.
- WAL mode.
- `synchronous=FULL`.
- Immediate durable commits for messages, reactions, and other important state changes.

The intention is to avoid complex distributed database dependencies.

A practical clarification: SQLite WAL mode can create separate WAL and shared-memory sidecar files while the database operates. Therefore, the architecture is one logical SQLite database, not necessarily literally one physical filesystem file at every instant.

Transaction boundaries, acknowledgement semantics, checkpointing, backup, and crash recovery need explicit design.

### Application data versus public identity history

The namespace MMR should not automatically contain every chat message.

Separate:

**Public authority history:** Delegations, identity changes, endpoints, policies, and associated audit metadata.

**Application state:** Encrypted messages, reactions, room state, attachments, and user data.

These may require different storage, retention, privacy, and replication policies.

In particular, permanently publishing sensitive message histories to a public DHT could conflict with end-to-end encryption metadata privacy and deletion requirements.

### Additional unresolved chat questions

- Message ordering and conflict resolution.
- Multi-device identities.
- Server and room membership.
- Group-key updates.
- Encrypted history synchronization.
- Offline delivery.
- Moderation under end-to-end encryption.
- Backup and recovery.
- Federation between independently administered chat servers.

The naming network should provide reusable primitives without unnecessarily dictating these application policies.

---

## 18. Operational Scenarios

### Scenario A: First contact with a server

A user opens an invitation containing a self-certifying address.

The client verifies the endpoint's identity.

If the identity is already known through a valid delegation chain, the client uses that chain.

Otherwise, it pins the new identity according to its first-use policy.

The user can subsequently inspect the identity and its history.

### Scenario B: A trusted server creates a child

The server generates or adopts a child identity.

It appends a signed delegation to its authority history.

The new checkpoint is published.

DHT nodes distribute the updated record.

Notification relays invalidate affected caches.

Clients trusting the parent can resolve the child.

### Scenario C: A child receives a new parent

An existing identity has its own descendants and historical records.

A new parent signs a delegation to that identity.

Clients trusting the new parent can reach the existing descendant graph.

Existing direct trust in the child remains unchanged.

### Scenario D: A server changes IP addresses

The authority signs an endpoint update.

The new record is appended to the MMR history.

The current-state commitment advances.

The latest signed checkpoint propagates through the DHT and notification relays.

Clients update cached endpoints and reconnect.

The server's cryptographic identity remains the same.

### Scenario E: An operational signing key is compromised

The attacker attempts to issue malicious records.

An independently protected recovery authority signs a revocation and replacement policy.

Clients verify the recovery authorization and reject further use of the compromised operational key according to the protocol's defined transition rules.

Witnesses and checkpoint gossip help identify conflicting histories.

Previously observed checkpoints help prevent silent rollback.

### Scenario F: DHT eclipse attempt

An attacker creates thousands of identities and attempts to dominate a victim's routing table.

Mitigations include:

- Proof-of-work for DHT-node admission.
- ASN and IP-prefix diversity.
- Persistent outbound anchor peers.
- Randomized peer selection.
- Verified-versus-unverified peer separation.
- Parallel, independent lookups.
- Signed checkpoint comparison.
- Witness gossip.

The attack can still cause disruption, especially with substantial network resources or control over connectivity.

### Scenario G: A purge notification is missed

A client is offline when a parent delegation changes.

Its subscription expires.

Upon reconnecting, it reestablishes subscriptions and fetches newer checkpoints.

MMR consistency proofs verify append-only progression from its previously observed state.

The cached resolution remains unusable after its permitted freshness interval until the client refreshes or otherwise obtains sufficient authentication.

### Scenario H: A publisher equivocates

A publisher signs two incompatible checkpoint histories.

Independent witnesses observe different branches.

Checkpoint gossip eventually exposes the conflict when observations meet.

Clients can preserve cryptographic evidence and apply a configurable policy:

- Reject the identity temporarily.
- Require manual intervention.
- Accept only a recovery-authorized continuation.
- Require additional witness attestations.

The protocol must define what happens rather than automatically choosing the numerically highest checkpoint.

---

## 19. Key Architectural Invariants

These properties should guide the formal design.

**Invariant 1: Self-certifying identity**

Network endpoints are authenticated against a cryptographic identity commitment, not merely their IP addresses or names.

**Invariant 2: Local trust sovereignty**

Users can manage their own trust anchors independently of operating-system certificate stores.

**Invariant 3: Directional delegation**

Trust in a parent may authorize scoped descendants, but trust in a child never automatically authorizes ancestors.

**Invariant 4: Identity independent of location**

Changing an IP address does not change cryptographic identity.

**Invariant 5: Identity independent of namespace position**

Adding or removing a parent does not necessarily change the child's identity.

**Invariant 6: Discovery is not authority**

DHT responses are untrusted until independently verified.

**Invariant 7: No circular bootstrap dependency**

Connecting to a bootstrap peer must not require a successful lookup through the DHT being bootstrapped.

**Invariant 8: Auditable changes**

Authority-bearing changes must be represented through authenticated history and state commitments.

**Invariant 9: Explicit equivocation assumptions**

A valid signature alone cannot establish a globally unique history.

**Invariant 10: Recoverability is defined cryptographically**

The recovery mechanism must identify who can replace compromised keys without depending solely on those compromised keys.

**Invariant 11: Bounded resource consumption**

Logical namespace extensibility cannot entail unlimited resolver, routing, storage, or notification work.

**Invariant 12: Fail-safe cache freshness**

Push notifications accelerate invalidation, but security must not depend on perfect notification delivery.

**Invariant 13: Federation without universal authority**

Independent infrastructure operators can exchange and replicate verifiable data without becoming universal sources of trust.

**Invariant 14: Cryptographic scope separation**

Identity authorization, namespace delegation, session authentication, and application permissions must not be accidentally interchangeable.

---

## 20. Open Architectural Decisions

The following remain unresolved and should not be represented as final choices.

### Identity representation

- Exact genesis Merkle manifest encoding.
- Which public keys belong in the stable identity commitment.
- How recovery-policy updates work.
- Whether long-lived identities require threshold recovery.
- How new identity commitments supersede old ones.

### Naming

- Exact name grammar.
- Namespace aliasing.
- Handling multiple parents.
- Delegation policy language.
- Resolution of ambiguous names.
- Local alias and default-root behavior.
- Cycle and traversal limits.

### MMR design

- Exact entry format.
- Checkpoint frequency.
- Current-state authenticated-map structure.
- Historical retention obligations.
- Witness selection and quorum rules.
- Equivocation evidence format.
- Multi-writer authority support, if any.

### DHT design

- Exact Kademlia variant.
- Node-ID derivation.
- Identity proof-of-work difficulty.
- Routing-bucket diversity constraints.
- Replica placement.
- Record admission and eviction policy.
- Lookup concurrency.
- Bootstrap distribution and recovery.

### Notifications

- Relay discovery.
- Subscription sharding.
- Dependency tracking.
- Signed invalidation format.
- Replay protection.
- Freshness semantics.
- Reconnection reconciliation.
- Privacy leakage from subscriptions.
- Notification-flood resistance.

### Security and cryptography

- SLH-DSA parameter selection.
- Exact PQ-authenticated handshake.
- Recovery-signature policies.
- Post-quantum group messaging.
- Algorithm agility.
- Key and checkpoint expiration.
- Clock assumptions.
- Anti-downgrade rules.

### Application design

- The precise boundary between the naming layer and chat application.
- Chat federation and replication.
- Durable encrypted message storage.
- Group membership and device management.
- History synchronization.
- Application-level authorization.

These questions require deliberate engineering choices rather than assumptions inferred from the high-level architecture.

---

## 21. Recommended Implementation Sequence

The following is a proposed sequence, not an established project schedule.

### Phase 1: Specify identity and trust

Define:

- Canonical identity commitment.
- Genesis key manifest.
- Public-key membership proofs.
- Endpoint authentication.
- Direct trust pinning.
- Delegation verification.
- Downward-only trust semantics.
- Identity recovery policy.

This provides a minimal system for authenticating servers without a conventional CA hierarchy.

### Phase 2: Implement historical authority records

Add:

- Append-only MMR records.
- Signed checkpoints.
- Authenticated current-state maps.
- Inclusion and consistency proofs.
- Key rotation and delegation revocation.
- Persistent client checkpoint state.

Test conflicting checkpoint histories explicitly.

### Phase 3: Implement decentralized discovery

Add:

- Authenticated DHT peers.
- Direct-address bootstrapping.
- Kademlia routing.
- Signed mutable records.
- Immutable history retrieval.
- Persistent peer caches.
- Independent lookups.

Initially test correctness before adding sophisticated anti-Sybil admission controls.

### Phase 4: Harden routing and storage

Add:

- ASN and network-prefix diversity.
- Outbound peer anchoring.
- Identity proof-of-work.
- Peer admission policies.
- Record quotas.
- Storage expiration.
- Replication diversity.
- Eclipse-attack simulation.

### Phase 5: Implement TTL + purge

Add:

- Distributed subscription relays.
- Signed update notifications.
- Dependency tracking.
- Redundant subscriptions.
- Durable update-sequence reconciliation.
- Expiration fallback.
- Offline recovery.

Test arbitrary notification loss and relay failures.

### Phase 6: Witnessed transparency

Add:

- Independent checkpoint witnesses.
- Checkpoint gossip.
- Equivocation detection.
- Conflict evidence.
- Recovery-aware fork handling.
- Client-side audit interfaces.

### Phase 7: Integrate the chat application

Implement the self-hosted chat system using the established networking, identity, and naming primitives.

Keep application-level encryption and membership management separate from the public naming history.

---

## 22. Existing Systems Worth Studying

The architecture combines ideas from several existing systems.

| System | Relevant idea |
|---|---|
| GNU Name System (GNS) | Rootless naming, cryptographic namespace delegation, local trust anchors |
| SDSI/SPKI | Local names, public-key principals, delegated authorization |
| IPFS / libp2p | Content addressing, authenticated peers, decentralized networking |
| IPNS | Signed mutable records |
| Kademlia | XOR-distance DHT routing |
| Bitcoin AddrMan | Durable peer discovery, diversified peer management |
| Certificate Transparency | Auditable histories, consistency proofs, equivocation detection |
| Merkle Mountain Ranges | Efficient append-only authenticated histories |
| DNS Push Notifications | Subscription-driven DNS cache updates |
| Signal | Ratcheted end-to-end messaging |
| MLS | Authenticated group key management |

The strongest conceptual resemblance is to **GNS with IPFS-like discovery and Certificate-Transparency-like history auditing**, extended with recovery-capable post-quantum identity commitments and federated notification delivery.

The system is not simply a replacement for DNS.

It is an attempt to unify authenticated identities, decentralized naming, mutable records, transparency, recovery, and cache coherence into one cryptographic architecture.

---

## 23. Important Security Corrections

A future engineering agent should explicitly avoid the following incorrect assumptions.

1. **A signed MMR is not automatically globally consistent.** Equivocation remains possible.

2. **A Merkle root of mutable keys is not a stable identity.** Stable identities require appropriate commitment and recovery semantics.

3. **TOFU does not authenticate initial identity provenance.** A malicious initial invitation can install an attacker's key.

4. **Bundled roots reproduce some root-store governance risks.** Their advantage comes from explicit scope, user control, and auditability.

5. **A DHT cannot establish authoritative freshness by itself.** A malicious neighborhood can return old but correctly signed records.

6. **Parent-directed naming authority must not override direct identity pins.** Otherwise upward authority can be introduced indirectly.

7. **Post-quantum signatures do not automatically secure every layer of a hybrid handshake.** Authentication binding must be explicitly defined.

8. **Proof-of-work does not eliminate Sybil attacks.** It merely imposes an economic cost.

9. **ASN diversity does not guarantee independent control.** An attacker can operate across many networks.

10. **Notification delivery cannot be guaranteed under arbitrary network partitions.** TTL and freshness policies remain necessary.

11. **Public append-only logs have privacy consequences.** Publicly available historical data may be impossible to retract.

12. **A single logical SQLite database in WAL mode is not necessarily one physical file at runtime.**

13. **An MMR alone does not solve multi-writer consensus.** Concurrent authority requires explicit serialization or conflict resolution.

14. **Cryptographic naming does not prevent censorship, denial of service, or loss of connectivity.** Authentication and availability are distinct properties.

These should be treated as core constraints rather than implementation afterthoughts.

---

## 24. Further Extrapolation

The following extensions are consistent with the design philosophy but remain proposals.

### 24.1 Portable trust profiles

A user's trust store could itself be an authenticated, versioned object.

This would allow:

- Reproducible trust configuration.
- Secure migration between devices.
- Inspection of historical trust changes.
- Independent trust profiles for different applications.
- Explicit trust-anchor provenance.

Trust profiles should avoid exposing private social or organizational relationships unnecessarily.

### 24.2 Cryptographically portable services

A service identity could move between hosts, hosting providers, geographic regions, and transport protocols without changing its identity.

Clients would care about the stable identity commitment, not the provider currently hosting it.

### 24.3 Delegation proofs as portable credentials

A valid scoped delegation chain could serve as a portable proof of namespace authority.

Applications could verify such proofs without contacting the issuer on every request, subject to freshness and revocation constraints.

This resembles capability-based authorization, though naming delegation and application permission delegation should remain distinguishable.

### 24.4 Independent history archives

Any interested operator could preserve MMR history fragments.

Clients could audit historical changes using competing archives.

Archives need not be trusted for integrity, although their willingness to retain and serve data affects availability.

### 24.5 Application-specific trust policies

Different applications could use different witness requirements, permitted delegation scopes, and freshness limits while sharing the same cryptographic identities.

The network layer would expose verifiable facts.

Application policy would decide how much assurance is sufficient.

### 24.6 Offline-verifiable proofs

A client could receive a bundled authority proof and verify it without immediate DHT access.

This enables local-first applications and disconnected verification.

Offline verification proves authenticity relative to the supplied evidence, not necessarily current validity or freshness.

### 24.7 Explicit security modes

A client could distinguish ordinary first-use onboarding from high-assurance operation.

For example, high-assurance mode could require:

- Independently verified trust anchors.
- Multiple witness attestations.
- Very recent checkpoints.
- A complete verified delegation chain.
- Strict rejection of unresolved conflicts.

This allows a usable default without pretending all first-use connections have equivalent security guarantees.

---

## 25. Final Architectural Synthesis

The intended architecture can be summarized as follows.

**Identity layer:** Stable self-certifying Merkle commitments to post-quantum identity and recovery policies.

**Transport layer:** Direct IP/port connections authenticated against those commitments, with protocol-magic and transcript binding.

**Trust layer:** Locally controlled trust anchors, first-use pinning, and downward-only scoped delegation.

**Naming layer:** Rootless, recursively extensible namespace graphs supporting arbitrary ancestry, descendants, aliases, and reparenting.

**History layer:** Signed MMR checkpoints plus authenticated current-state commitments.

**Transparency layer:** Independent witnesses, checkpoint gossip, equivocation evidence, and historical archives.

**Discovery layer:** A Kademlia-like DHT serving signed mutable heads and content-addressed immutable records.

**Networking resilience:** Direct bootstrap addresses, persistent peers, outbound anchoring, ASN diversity, diversified queries, and optional node-admission proof-of-work.

**Cache layer:** TTL expiration combined with authenticated push invalidation through federated subscription relays.

**Recovery layer:** Explicit, higher-authority recovery policies allowing operational-key revocation and rotation.

**Application layer:** Self-hosted, end-to-end encrypted services, initially a Discord-like chat platform using SQLite for persistent state.

The central principle is:

**Trust and identity are cryptographically established by the user and delegated authorities. Networks merely transport and replicate evidence.**

No DHT operator, hosting provider, cache, DNS authority, or globally designated certificate authority should become an implicit universal source of truth.

The system's goal is not to abolish trust but to make trust **local, explicit, directional, inspectable, portable, recoverable, and cryptographically auditable**.

### Instructions for an engineering agent

Treat this document as a conceptual architecture, not a completed wire-protocol specification.

Preserve the established design intentions, but challenge assumptions that undermine their actual security properties.

Prioritize rigorous definitions of identity, authorization, freshness, recovery, and equivocation before implementing distributed infrastructure.

Separate security claims that can be proved cryptographically from properties dependent on networking, clocks, availability, witnesses, or economic assumptions.

Prefer well-studied cryptographic constructions and existing protocol components over custom replacements.

Avoid introducing a blockchain, global consensus mechanism, mandatory central authority, or operating-system certificate-store dependency unless a specific requirement demonstrably cannot be satisfied otherwise.

Maintain clear boundaries between the naming protocol and the application-layer encrypted chat system.

For every major mechanism, specify its threat model, trust assumptions, failure cases, resource bounds, and interaction with the rest of the architecture.

**The eventual objective is a protocol whose correctness and trust relationships can be independently verified, rather than a protocol whose safety depends on the reputation of its infrastructure operators.**

---

## 26. Starting UX for User Keys

These notes, from October 28, 2026, set how keys work for users at first, before the federated infrastructure exists. Self-hosting ships first; the PKI plugs in later.

### 26.1 Keypairs are accounts

- At startup, the client generates a keypair if it has none.
- Joining a self-hosted server sends the user's public key along with the invite code. That uses up the invite code, and the key becomes the account on that server. There are no passwords.
- If the user already has a keypair, joining reuses it rather than generating a new one.
- Users can manage their keypairs from the menu and from settings.

### 26.2 Durable keys

- Generated keys are very durable. Neither fastcord bugs nor deleting settings files or folders should easily delete or corrupt them.
- Still to work out: easy syncing of keypairs between devices.
- Possibly: good integration with password managers, and passkey support. Passkeys are P-256, classical and usually non-exportable, so they can serve as an extra login key but not as the identity.

### 26.3 Recovery through the server admin

- Server admins can see and manage the public keys of their server's members. They never see members' private keys.
- A user who loses a private key generates a new keypair and contacts the server admin out of band. The admin may grant the new key the permissions of the old, lost one. The user then regains access to their old messages, to edit or delete them, and to the same channels.
- This happens only if the admin decides to do it, and the admin can revoke it later.
- There seems to be no way around this. It also means an admin can link any key to any account on their server, which is the same trust the host already holds by reading server channels. End-to-end encrypted DMs are unaffected: the peer still sees the root-changed warning.

### 26.4 No self-rotation and no revoke records

- An everyday private key cannot sign a rotate record. Otherwise a thief who stole it could rotate the user's keys on every server at once. Only the recovery key signs rotations.
- There are no revoke records, only rotate records.
- Open question: should a private key be able to revoke itself? That would let users kill a stolen key everywhere at once. It would also let a thief who exfiltrated the key deny the user service. A thief holding the key can already impersonate the user, so self-revocation adds little to what the attacker can do. PGP's revocation certificates are the precedent for allowing it. Undecided.