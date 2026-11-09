# MikePay — sharding, MariaDB replication and cloud deployment (CONCEPTUAL DESIGN)

> **Status: conceptual. Nothing in this document was implemented, except the one data analysis marked below.**
> No sharded cluster was built, no MariaDB replication was configured and no cloud account or cloud resource was used.
> What *was* implemented and tested is the three-member MongoDB replica set described in [../README.md](../README.md).

## 1. What is real and what is only design

| Topic | Status | Where the evidence is |
|---|---|---|
| MongoDB replica set (3 members), failover, write concern, transactions, stale reads | **Implemented and tested** on one laptop | [../evidence/](../evidence/) files 00–07 |
| Shard-key **analysis** on the existing 282,620-row ledger | **Implemented**: it only counts how documents *would* be spread over 4 hypothetical shards | [../evidence/08_shard_key_analysis.txt](../evidence/08_shard_key_analysis.txt) |
| MongoDB **sharded cluster** (config servers, shards, `mongos`) | **Not implemented** (design only, section 2) | none |
| MariaDB **replication** | **Not implemented** (design only, section 3). The XAMPP MariaDB 10.4.32 here has the binary log off | none |
| **Cloud** deployment | **Not implemented** (design only, section 4) | none |

## 2. Sharding MikePay (design)

**Is it needed?** Not at the current size. The Portfolio 4 slice is 9,008 customers and 282,620 ledger documents (about 71 MB), which one replica set holds easily. Sharding adds operational cost (config servers, routers, rebalancing), so it only pays off when data or write rate outgrows one replica set. This section shows how it would be done and, more importantly, how to choose the key.

**What would be sharded.** The ledger (`transactions`) and `audit_events` grow without limit, so they are the candidates. `customers` is small and read by `_id`; it would stay unsharded (or hashed on `_id`).

**Shard-key candidates, measured on the real documents** (counting only; [evidence 08](../evidence/08_shard_key_analysis.txt)):

| Key | Spread of all 282,620 documents over 4 hypothetical shards | Where the newest 30 days of writes (11,924 documents) would land | Verdict |
|---|---|---|---|
| **hashed `account_id`** | 24.7 / 25.1 / 25.6 / 24.7 % (busiest 25.6%) | 24.4 / 24.6 / 26.3 / 24.7 % (busiest 26.3%) | **Recommended for the ledger** |
| range on `created_at` | 29.7 / 23.5 / 23.5 / 23.3 % | **100% on one shard** | Rejected: a time key always sends new writes to the newest range, so one shard takes the whole write load (a "hot shard") |
| range on `account_id` | 78.3% on one shard, 21.7% on another, two shards empty | not measured | Rejected for this data. Part of the skew comes from how this exported slice numbers its accounts (ids 1..10,000 and 51,001..60,000, checked against the data), so it shows the *risk* rather than a general rule |

**Consequences of the recommended key (hashed `account_id`):**
- *Good:* "last 10 entries of one account" has an equality on the shard key, so a `mongos` router sends it to **one** shard. Writes for different accounts spread evenly. The busiest single account (id 1001) has 2,218 documents, about 0.53 MB (evidence 08), far below the default 128 MB chunk size, so one customer cannot create an unsplittable chunk.
- *Cost:* queries without the key, such as "monthly deposit totals for everybody" (Q6 in Portfolio 4), must ask **every** shard and merge the answers (scatter-gather). Range queries on `account_id` can no longer be answered from one shard.
- *Not measured:* the speed of any of this. No sharded cluster exists, so no claim about query speed or rebalancing is made.

**Money transfers and sharding.** A transfer touches two accounts that usually hash to different shards. MongoDB supports transactions across shards, but they need distributed coordination and are slower than single-shard ones. This is another reason the design keeps fund transfers in MariaDB (Portfolio 3) and uses MongoDB for reading, events and analytics.

**What a real deployment would need (not built):** a config-server replica set (3 members), two or more shards that are each a 3-member replica set, and at least two `mongos` routers; then `sh.enableSharding("mikepay")` and `sh.shardCollection("mikepay.transactions", { account_id: "hashed" })`. That is roughly 12 `mongod` processes plus routers, which is why it was not attempted on one laptop.

## 3. Scaling and protecting the relational data: MariaDB replication (design)

**Current state:** one MariaDB 10.4.32 server, binary log off, so there is no replication, no point-in-time recovery and no failover. Every MikePay relational test ran on that single server.

**Design (asynchronous primary → replica):**
1. On the primary: `server_id=1`, `log_bin=mysql-bin`, `binlog_format=ROW`; a dedicated replication account with only the replication privilege.
2. On each replica: unique `server_id`, `read_only=1`; point it at the primary with `CHANGE MASTER TO … MASTER_USE_GTID=slave_pos` and `START SLAVE`.
3. Reads such as statements and reports can go to replicas; **all balance-changing transfers stay on the primary**.

**Consistency effect:** replication is asynchronous, so a replica can lag. A customer who transfers money and then immediately opens the balance screen could read an old balance from a lagging replica ("read your own writes" problem), the same effect measured with the delayed MongoDB member in evidence 07. Mitigations: read balances from the primary, or use semi-synchronous replication (the primary waits for at least one replica to receive the change before it acknowledges the commit), which narrows but does not remove the window and adds commit latency.

**Failover:** MariaDB does not elect a primary by itself. Promotion is manual or done by external tooling (for example MaxScale or an orchestrator), which means a longer, less predictable recovery than a MongoDB replica set election (evidence 04). This is a design observation, not a measurement: it was not tested.

## 4. Cloud deployment (design)

**Proposed topology:** a 3-member MongoDB replica set with each member in a different availability zone of one region, so the loss of one zone leaves a majority (2 of 3), exactly the situation tested in evidence 03 and 04. The MariaDB primary with a replica in a second zone follows the same pattern.

**Self-managed vs managed:** running `mongod` on virtual machines gives control but makes the operator responsible for patching, backups and failover drills; a managed service (for example MongoDB Atlas) provides replica sets, backups and monitoring as part of the service. For a small team the managed option reduces operational risk; the choice would also depend on cost and on where regulators allow customer data to be stored.

**Security that the local lab deliberately does not have:** authentication (SCRAM users with least privilege), authentication between members (key file or x.509), TLS for every connection, private networking only (no public IP, security groups limited to the application tier), encryption at rest with managed keys, and auditing. The local nodes have **none of these** (no authentication, no TLS, `127.0.0.1` only).

**Backups and recovery:** regular snapshots plus oplog-based point-in-time recovery, and, importantly, *restore drills*; a backup that was never restored is untested. Replication is not a backup: a wrong delete is replicated to every member immediately (the delayed member in evidence 07 is the idea behind "delayed replicas" used as a safety net).

**Availability targets, tied to what was measured locally** (one machine, no network latency, so only indicative):
- *Recovery point:* with `w:"majority"` no acknowledged write was lost when the primary was killed (evidence 04), so the recovery point for a single-node failure is zero; with `w:1` a crash right after an acknowledgement could lose the write (not demonstrated here).
- *Recovery time:* the new primary was elected 15.1 seconds after the crash with default timeouts in the captured run (evidence 04; an earlier, uncaptured run took 12.3 s, so expect 10 to 15 s). In a cloud the network adds a few milliseconds between zones; the timeouts could be tuned, but shorter timeouts risk needless elections during short network hiccups.
- *Second region:* a member in another region would protect against the loss of a whole region, but every `w:"majority"` write would then pay inter-region latency, or that member would be set to priority 0 and used only for disaster recovery, accepting that it may be behind (the stale-read effect of evidence 07).

**Monitoring to add:** replication lag, election events, disk and memory, slow queries, connection counts, and backup success, each with an alert.

**Compliance:** MikePay is a simulated platform with synthetic data. A real fintech would have to confirm data-residency, retention and security requirements with its regulator before choosing a region. That was **not researched** for this coursework, and no regulatory claim is made.

## 5. How the tested behaviours map to the theory

| Experiment | What it showed | Concept |
|---|---|---|
| 02 | identical collection hashes on 3 members; secondaries refuse writes | replication, single writer |
| 03 | `w:majority` works with one member down, `w:3` times out but the write is kept on the primary | write concern, durability vs availability |
| 04 | primary killed → new primary, no acknowledged write lost, old primary rejoins as secondary | automatic failover, no split brain |
| 05 | two of three members down → the survivor steps down and refuses writes | consistency chosen over availability (CP behaviour) |
| 06 | transfer across two customer documents is all-or-nothing; concurrent writers get `WriteConflict` | multi-document ACID transactions |
| 07 | a delayed secondary returns the old balance, then catches up | eventual consistency, read preference |

## 6. Limitations of this document
- Sections 2 to 4 are design reasoning, supported only where an evidence file is cited.
- No performance, cost or regulatory claim is made for sharding, MariaDB replication or any cloud product.
- Vendor feature names are used from general knowledge of the products and were not re-checked against current vendor documentation for this submission.
