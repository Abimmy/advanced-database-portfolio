# Portfolio 5 — Distributed and Cloud Database Exercise (6 marks)

**Status:** A three-member **MongoDB replica set was genuinely built and tested** on one laptop (replication, failover, write concern, lost majority, multi-document transactions, stale reads). **Sharding, MariaDB replication and cloud deployment are NOT implemented**; they are covered by a clearly labelled conceptual design, plus one real data analysis. Evidence is captured command output; no screenshots yet.

## Objective
Show, with something that really runs, how MikePay's data can be replicated for availability and what that does to consistency; and discuss, honestly labelled as design, what sharding and a cloud deployment would add.

## Implemented vs conceptual (read this first)
| Topic | Status | Evidence |
|---|---|---|
| 3-member MongoDB replica set `mikepay-rs` (ports 27018–27020, one machine) | **Implemented and tested** | [evidence/00](evidence/00_environment_and_setup.txt), [01](evidence/01_initiate_replica_set.txt) |
| Replication correctness, secondaries read-only, replication lag | **Implemented and tested** | [evidence/02](evidence/02_load_data_and_replication_checks.txt) |
| Write concern with a member down | **Implemented and tested** | [evidence/03](evidence/03_write_concern_one_node_down.txt) |
| Primary crash → election → rejoin | **Implemented and tested** | [evidence/04](evidence/04_primary_failover.txt) |
| Lost majority (2 of 3 down) | **Implemented and tested** | [evidence/05](evidence/05_no_majority_two_nodes_down.txt) |
| Multi-document transactions (the transfer Portfolio 4 could not run) | **Implemented and tested** | [evidence/06](evidence/06_multi_document_transactions.txt) |
| Stale reads / eventual consistency | **Implemented and tested** (the delay is artificial) | [evidence/07](evidence/07_stale_read_delayed_secondary.txt) |
| Shard-key **analysis** | **Real counts on real data**, but **no sharded cluster exists** | [evidence/08](evidence/08_shard_key_analysis.txt) |
| Sharded cluster, MariaDB replication, cloud deployment | **Conceptual only, not built** | [documentation/](documentation/sharding_mariadb_replication_and_cloud_design.md) |

## Environment
| Item | Value |
|---|---|
| Database | MongoDB Community 9.0.4, three separate `mongod` processes started by [configuration/node-control.ps1](configuration/node-control.ps1) from [mongod-node1.conf](configuration/mongod-node1.conf), [node2](configuration/mongod-node2.conf), [node3](configuration/mongod-node3.conf) |
| Members | `127.0.0.1:27018`, `:27019`, `:27020`; replica set name `mikepay-rs`; 1 vote each; WiredTiger cache 1 GB each; oplog 256 MB each |
| Original service | The Portfolio 4 MongoDB service on port 27017 is untouched (the shard analysis reads it) |
| Host | Windows 11 Pro, Intel Core i7-1265U (12 logical processors), 31.7 GB RAM ([evidence/00](evidence/00_environment_and_setup.txt)) |
| Data | The 8-customer Portfolio 4 sample (synthetic) loaded into `mikepay_nosql_rs` through the replica-set connection string; throw-away documents for the experiments |
| Security | **None**: no authentication, no TLS, `127.0.0.1` only. Acceptable for a local lab, not for production |

**Important limitation: all three members share one machine and one disk.** The experiments show the *software behaviour* (elections, write concern, recovery). They do not give protection against losing the machine, and there is **no network latency or network partition**; "failure" means killing a process.

## How to run
```bash
cd portfolio-5-distributed-cloud/configuration
bash run_evidence.sh      # WARNING: deletes ../mongo-data and rebuilds the three members; about 8 minutes
```
Or step by step: `powershell -File node-control.ps1 -Action start`, then from `tests/`: `mongosh --nodb --file 01_initiate_replica_set.js`, then `02_…` to `08_…`. `-Action kill -Node 1` crashes a member, `stop` shuts it down cleanly, `status` lists them. The three members are left running after the evidence run; stop them with `-Action stop`.

## Results

### 1. The replica set forms ([evidence 01](evidence/01_initiate_replica_set.txt))
After `replSetInitiate` one member became PRIMARY and two SECONDARY, 12,059 ms later (the first election waits for the 10 s election timeout). Defaults: heartbeat 2 s, election timeout 10 s, majority = 2 of 3.

### 2. Replication and reads ([evidence 02](evidence/02_load_data_and_replication_checks.txt))
| Check | Result |
|---|---|
| R1 `dbHash` (MD5 of each collection, computed by each member separately) | All four collections have **identical hashes on all three members**; counts and the balance total (1969999.50, the MariaDB figure) match |
| R2 insert on a secondary | Refused: code 10107 `NotWritablePrimary` |
| R3 20,000-document burst with `w:1` | Primary acknowledged in 1,500 ms; the secondaries held all 20,000 documents 41 ms and 64 ms after the last acknowledgement (measured by polling every ~20 ms, so ±30 ms) |

### 3. Write concern with one member crashed ([evidence 03](evidence/03_write_concern_one_node_down.txt))
| Test | Result |
|---|---|
| All members up | `w:majority` 51 ms, `w:3` (all members) 18 ms |
| One secondary killed | `w:1` 5 ms; **`w:majority` still acknowledged** (6 ms: primary + the other secondary = 2 of 3) |
| `w:3` with a member down | Times out after 3,022 ms with code 64. **The document was nevertheless written on the primary**, so a write-concern error does *not* mean the write was rolled back |
| Reads | The surviving secondary still serves reads |
| Restart | The member rejoined as SECONDARY in 1,703 ms and had every missed write 4,679 ms after the start command; collection hash equal to the primary's |

### 4. Primary crash ([evidence 04](evidence/04_primary_failover.txt))
| Measurement | Result (one captured run) |
|---|---|
| Time until another member was PRIMARY | **15,052 ms** after the kill (an earlier, uncaptured run: 12.3 s). Cause: members only declare the primary dead after the 10 s election timeout, then vote |
| First successful `w:majority` write from a client using the same connection string | 15,100 ms after the kill, 0 failed attempts (the driver waited for the new primary) |
| Election term | 1 → 2 |
| **Acknowledged writes lost** | **0** of 60 (ids 1–60 all on the new primary) |
| Old primary restarted | Rejoined as **SECONDARY** after 1,533 ms (it does not take over: no split brain), had all 80 documents after 4,653 ms; collection hashes identical on all three |

### 5. Losing the majority ([evidence 05](evidence/05_no_majority_two_nodes_down.txt))
Both secondaries were killed. The remaining member **stepped down from PRIMARY after 10,810 ms** because it could no longer see a majority. Writes were refused (code 10107, and through the replica-set connection string the client failed with `MongoServerSelectionError` after 5,028 ms); reads still worked but could be stale. After the two members were restarted a primary was elected again (6,034 ms later); the earlier acknowledged document was present and the refused writes never appeared. This is the *consistency over availability* choice: the cluster stops accepting writes rather than risk two diverging copies.

### 6. Multi-document transactions ([evidence 06](evidence/06_multi_document_transactions.txt))
In Portfolio 4 a transaction was refused on the standalone server (code 20). On the replica set, a transfer of 250.00 between two **customer documents** plus two ledger documents is one transaction:
- Commits; before the commit another client still saw the old balances (1000.00 / 500.00) and no ledger rows, after it 750.00 / 750.00 and 2 rows. Total money 1500.00 both times.
- **Failing last step** (ledger credit with a negative amount rejected by the validator, code 121): the whole transaction aborted; debit and credit were both undone; money conserved.
- **Insufficient funds** (5,000.00 from a 750.00 account): the guarded debit refuses and the transaction aborts.
- **Concurrency:** a second transaction writing the same document got `WriteConflict` (code 112, label `TransientTransactionError`) immediately; after the first committed, the retry succeeded (750.00 − 10.00 − 20.00 = 720.00).

### 7. Stale reads ([evidence 07](evidence/07_stale_read_delayed_secondary.txt))
A secondary is normally only milliseconds behind, which is too little to observe. To *see* eventual consistency one member was temporarily set to **apply changes 8 s late** (`secondaryDelaySecs: 8`, priority 0). This delay is an artificial stand-in for a slow or distant replica. After the balance was changed from 100.00 to 200.00 with `w:majority`: primary and normal secondary returned 200.00 immediately; the delayed member returned the **old value 100.00 until 8,389 ms** later, then 200.00. The configuration was restored (priority 1, no delay) and checked.

### 8. Shard-key analysis ([evidence 08](evidence/08_shard_key_analysis.txt)) — analysis only
Counting the 282,620 existing ledger documents over 4 *hypothetical* shards: hashed `account_id` gives 24.7–25.6% per shard (and 24.4–26.3% for the newest 30 days of writes); range on `created_at` puts **100%** of the newest 30 days of writes on one shard; range on `account_id` puts 78.3% on one shard (partly an artefact of this slice's account numbering, ids 1–10,000 and 51,001–60,000). No sharded cluster was created.

## Why it matters for MikePay
- **Availability:** with 3 members the service survives one member failure with no data loss for `w:majority` writes; recovery took 15 s here, mostly the election timeout. In production an application must tolerate that pause (retry).
- **Durability vs speed:** `w:1` is fastest but a crash right after the acknowledgement could lose the write (not demonstrated here); `w:majority` costs one replication round trip; `w:all` makes the system unavailable for writes as soon as one member is down (evidence 03).
- **Consistency:** reading from a secondary can return old data (evidence 07), so balances must be read from the primary; reading from secondaries suits reports and dashboards.
- **Where money moves:** a replica set makes MongoDB transfers safe (evidence 06), but the project still performs transfers in MariaDB (Portfolio 3), which is the tested and authoritative implementation; MariaDB itself has **no replication** in this lab.

## Conceptual part (not implemented)
[documentation/sharding_mariadb_replication_and_cloud_design.md](documentation/sharding_mariadb_replication_and_cloud_design.md) covers: when and how to shard MikePay and why hashed `account_id` would be chosen (with the evidence 08 counts); how MariaDB primary–replica replication would be set up and what replica lag would mean for balances; and a cloud topology (three availability zones, managed vs self-managed, security, backups, recovery targets). It is labelled **conceptual** throughout; no cloud resources were used and no performance or regulatory claim is made.

## Limitations
- **Single machine, no network.** No latency, packet loss or network partition was tested; "crash" = `taskkill /F` on a process. A real zone or network failure behaves differently.
- **No authentication or TLS** (documented as deliberately absent).
- **Timings vary between runs** (failover 12.3 s in an uncaptured run, 15.1 s captured; initial election 12.2 s and 12.1 s). Each number is one captured run, not an average.
- **Replication lag figures** are polled at ~20 ms granularity and use a tiny 20,000-document burst; they say nothing about real production load.
- **Small data.** The replicated data is the 8-customer sample plus test documents.
- **The stale read is engineered** with a configured delay.
- **Sharding, MariaDB replication and cloud deployment were not built.** Their section is a design discussion.
- **Evidence is output text; no screenshots.**

## Issues met while building
- A Windows path in the helper (`..\node-control.ps1`) lost its backslash inside a template string, so the first restart failed and left a node down; it now uses forward slashes. The experiment was re-run from a healthy state.
- The first status table showed a killed member as healthy because only 4 s had passed and the primary's heartbeat timeout is 10 s; the wait is now 12 s. The `uptime` column was removed because it is measured by the answering member and resets on reconnection.
- A write through the replica-set connection string while no primary exists fails while *connecting* (before any `insert`), which the first version of the script did not catch.
- **`mongosh` ignores `process.exitCode`.** A failing check printed "1 failed" but exited 0. All scripts here use `quit(1)`; the Portfolio 4 scripts were fixed the same way (see that README). The exit codes in the captured evidence files for this portfolio are therefore meaningful (all 0, and no FAIL line appears in any file).
- A check of mine wrongly compared a `Long` zero as truthy (C5 failed in one ad-hoc run although the printed values were right); fixed, and the full evidence was then re-captured from a clean rebuild.

## What you should be able to explain at technical verification
1. What a **replica set** is: primary, secondaries, oplog, heartbeat, election, majority (2 of 3) and why an odd number of voting members is used.
2. **Write concern** `w:1` / `w:"majority"` / `w:3`: what each guarantees, why `w:3` blocks when a member is down, and why a write-concern timeout is not a rollback (evidence 03).
3. The **failover sequence** and why it took 10–15 s (election timeout), why no acknowledged `w:majority` write was lost, and why the old primary rejoins as a secondary.
4. **Why the survivor steps down** with two members lost: preventing split brain; the CAP trade-off (consistency over availability).
5. **Eventual consistency** and stale reads from secondaries; which reads must go to the primary.
6. **Multi-document transactions**: why a replica set is required, snapshot isolation, `WriteConflict` and retry, and why the transfer design still keeps MariaDB as the authoritative ledger.
7. **Sharding** (shard key, hashed vs ranged, hot shard, scatter-gather) and why it is **conceptual** here.
8. The honest limits: one machine, no network failure, no authentication, and which parts are implemented versus design only.
