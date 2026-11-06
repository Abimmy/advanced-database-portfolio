# Portfolio 4 — NoSQL and Advanced Data Models (7 marks)

**Status:** Implemented and tested on a local MongoDB 9.0.4 (standalone). Data is migrated from the Portfolio 1–2 MariaDB database; 9 captured evidence files; every check passed in the captured runs. Screenshots are not included yet (Compass screenshots can be added to `evidence/` by the student).

## Objective
Model part of MikePay in a **document database**, load it with the same synthetic data as the relational database, prove nothing was lost, and show where a document model helps (flexible shapes, one-read profiles, embedded arrays, simple indexes) and where it does not (money transfers between two customers).

## Test environment
| Item | Value |
|---|---|
| NoSQL server | MongoDB Community **9.0.4**, WiredTiger, **standalone** (not a replica set), Windows service on `127.0.0.1:27017`, **no authentication** (local coursework only) |
| Client | `mongosh` 2.14.1; Python 3.14 + `pymysql` for the export; Compass 1.41.0 installed |
| Source | `mikepay_db` on MariaDB 10.4.32 (Portfolios 1–2), read with SELECT only |
| Host | 12 cores, 32 GB RAM, Windows 11. WiredTiger cache limit 15,714 MB, so the whole dataset fits in memory (see limitations) |
| Databases | `mikepay_nosql` (bulk slice) and `mikepay_nosql_sample` (the 8 hand-built customers) |
| Data | Synthetic only. Slice = customers with `customer_id <= 10000` (9,008 customers) |

## The NoSQL model: document store
MikePay is mapped to **four collections**. The rule used for each choice: *embed what is read together and stays small; reference what grows without limit or is shared.*

| Collection | Source tables | Shape | Why |
|---|---|---|---|
| `customers` | customers + accounts + beneficiaries | One document per customer with `accounts[]` and `beneficiaries[]` **embedded** | A customer has few accounts and beneficiaries (measured maximum: 2 and 2; largest document 783 bytes) and the app screen shows them together. One read returns the whole profile. Beneficiaries also carry the holder's name and account number copied in (denormalised) so no second lookup is needed |
| `transactions` | transactions (+ transfer reference) | One document per ledger row, **referencing** `account_id` and carrying `customer_id` / `account_number` copies. Transfer legs embed `transfer{transfer_id, reference, counterparty_account_number}` | The ledger grows without limit (the busiest account has 2,218 rows). Embedding it in the customer would make that document grow every day |
| `transfers` | transfers | One document per transfer with `source{}` and `destination{}` embedded | A transfer is read as one unit, including failed ones (which have no ledger rows) |
| `audit_events` | audit_log | One document per audit row | Append-only event log, never updated |

The relational → document mapping is therefore: 3 tables → 1 collection (customers/accounts/beneficiaries); the other three map one-to-one.

**Money is stored as BSON `Decimal128`**, the counterpart of `DECIMAL(15,2)`. The validators reject a floating-point balance (test V1). Dates are BSON `Date` (MariaDB DATETIME values have no time zone and are written as UTC).

**Synthetic extension — `metadata` on ledger rows.** MariaDB has no channel/device information. To demonstrate the flexible-schema benefit, the exporter adds a `metadata` sub-document that is **generated deterministically from the transaction id** (same id → same value). Its fields depend on the type: deposits have `channel` plus `branch_code` or `agent_code`; ATM withdrawals have `atm_id`; POS withdrawals have `merchant_category`; transfers have `device`. These values do **not** come from the relational data and carry no real information.

## Implementation steps and scripts
| Step | File | What it does |
|---|---|---|
| 1 | [scripts/01_export_from_mariadb.py](scripts/01_export_from_mariadb.py) | Reads MariaDB, writes Extended-JSON files and a `manifest.json` of counts/totals computed with **separate** SQL queries |
| 2 | [scripts/02_create_collections.js](scripts/02_create_collections.js) | Creates collections with `$jsonSchema` validators (strict, `validationAction: error`) and the unique indexes (e-mail, account number, transfer reference) |
| 3 | [scripts/03_load_data.js](scripts/03_load_data.js) | Loads the files with `insertMany` (every document passes through the validator) |
| 4 | [scripts/04_verify_migration.js](scripts/04_verify_migration.js) | Recomputes counts and Decimal128 totals inside MongoDB and compares them with the manifest |
| 5 | [scripts/05_queries_and_aggregations.js](scripts/05_queries_and_aggregations.js) | Nine queries/aggregations (point read, array query, `$unwind`/`$group`, `$lookup`, date grouping) |
| 6 | [scripts/06_index_explain.js](scripts/06_index_explain.js) | Four workloads measured with `explain("executionStats")` before and after an index |
| 7 | [scripts/07_validation_and_atomicity_tests.js](scripts/07_validation_and_atomicity_tests.js) | 14 checks: validation, uniqueness, flexible fields, guarded atomic debit, multi-document transaction |
| 8 | [scripts/08_verification_negative_test.js](scripts/08_verification_negative_test.js) | Tampers with a balance to prove step 4 can fail, then restores it |
| 9 | [scripts/09_concurrent_debits.sh](scripts/09_concurrent_debits.sh) | 10 separate client processes debit one account at the same moment |
| - | [scripts/run_evidence.sh](scripts/run_evidence.sh) | Runs the stages and saves each output (with date, command, MongoDB version, exit code) into `evidence/` |

Committed sample data: [sample-data/](sample-data/) holds the 8 hand-built customers (8 customers, 20 ledger rows, 6 transfers, 28 audit events). The 10,000-customer slice (~120 MB) is regenerated by step 1 and is git-ignored (`bulk-data/`).

## How to run
```bash
# prerequisites: MongoDB service running, mongosh on PATH, XAMPP MariaDB running with mikepay_db, pip install --user pymysql
cd portfolio-4-nosql/scripts
python 01_export_from_mariadb.py --max-customer-id 8     --out ../sample-data     # seconds
python 01_export_from_mariadb.py --max-customer-id 10000 --out ../bulk-data       # ~4 minutes
bash run_evidence.sh all        # sample stage + bulk stage, writes ../evidence/*.txt (about 6 minutes)
```
Individual scripts take the target through `--eval "var DB_NAME='mikepay_nosql', DATA_DIR='../bulk-data'"`, for example `mongosh --file 04_verify_migration.js --eval "..."`.

## Results

### 1. Migration is complete and exact
Output: [evidence/03_bulk_create_load_verify.txt](evidence/03_bulk_create_load_verify.txt) (bulk) and [evidence/02_sample_create_load_verify.txt](evidence/02_sample_create_load_verify.txt) (sample).

| Check (bulk slice) | MongoDB | MariaDB manifest | Result |
|---|---|---|---|
| customers / embedded accounts | 9,008 / 18,009 | 9,008 / 18,009 | PASS |
| transactions / transfers / audit events | 282,620 / 58,995 / 36,028 | same | PASS |
| SUM of account balances | 9,714,925,267.87 | 9,714,925,267.87 | PASS |
| SUM of transaction amounts | 10,425,839,691.91 | 10,425,839,691.91 | PASS |
| SUM of transfer amounts | 152,809,409.64 | 152,809,409.64 | PASS |
| ledger rows pointing at a missing account | 0 | - | PASS |

Totals are compared as exact strings (Decimal128 sums are exact; no rounding tolerance). The check is shown to be capable of failing: [evidence/08_negative_verification_output.txt](evidence/08_negative_verification_output.txt) adds 0.01 to one balance, the balance total check reports **FAIL** (1969999.51 vs 1969999.50), then after restoring the value everything passes again. Load time in the captured run was 166.6 s (an earlier, uncaptured run took 62.9 s on the same data, so treat load times as indicative only).

### 2. Queries and aggregations
Output: [evidence/04_queries_and_aggregations_output.txt](evidence/04_queries_and_aggregations_output.txt).

| Query | What it shows |
|---|---|
| Q1 `findOne({_id: 1})` | The full customer profile (2 accounts, 2 beneficiaries with names) comes back in **one read**. The relational equivalent needs customers + accounts + beneficiaries + a join to resolve beneficiary names |
| Q2 / Q3 | Lookup by unique e-mail; last 5 ledger entries of one account |
| Q4 `{"accounts.status": "FROZEN"}` | Queries *into* the embedded array: 631 customers have a frozen account |
| Q5 group by `type` + `metadata.channel` | Ledger rows have different fields by type: 33,557 of 33,557 ATM withdrawals carry `atm_id`; 0 deposits do. No empty columns, no `ALTER TABLE` |
| Q6 monthly deposits vs withdrawals | `$match` → `$group` on `$dateToString` → `$sort`, with exact Decimal128 sums |
| Q7 top 5 customers by total balance | `$unwind` the accounts array, `$group`, `$sort`, `$limit` |
| Q8 `$lookup` | MongoDB's join. 1,317 failed transfers have a source customer **outside the exported slice**, so the lookup finds nothing for them; they are in the data only because their destination customer is in the slice |
| Q9 | Failed transfers by reason: Destination account frozen 1,810; Daily limit exceeded 1,792; Insufficient funds 1,774 |

### 3. Indexes (actual executions, `explain("executionStats")`)
Output: [evidence/05_index_explain_output.txt](evidence/05_index_explain_output.txt). Each workload was run 5 times before and after the index; times are median [min–max] in ms. The ratios of **documents examined** are exact and repeatable; the milliseconds depend on this laptop, a warm cache (all data fits in RAM) and other load, so use them only as a rough guide.

| Workload | Index created | Plan before → after | Docs examined | Time ms (before → after) |
|---|---|---|---|---|
| W1 last 10 ledger rows of account 1001 (2,218 rows) | `{account_id:1, created_at:-1}` | `SORT > COLLSCAN` → `LIMIT > FETCH > IXSCAN` (the in-memory sort disappears because the index is already ordered) | 282,620 → 10 | 2101 [1735–2309] → 0 [0–11] |
| W2 ledger rows of one transfer reference | `{"transfer.reference":1}` **partial** (only rows that have a transfer) | `COLLSCAN` → `FETCH > IXSCAN` | 282,620 → 2 | 1941 [1487–2548] → 1 [0–7] |
| W3 customers with a FROZEN account | `{"accounts.status":1}` (multikey, indexes the array) | `COLLSCAN` → `FETCH > IXSCAN` | 9,008 → 631 | 118 [108–247] → 7 [4–10] |
| W4 audit events of one account since a date | `{account_id:1, changed_at:1}` | `COLLSCAN` → `FETCH > IXSCAN` | 36,028 → 2 | 182 [139–248] → 1 [1–4] |

Cost of the indexes (same file): `ix_txn_account_created` 3.6 MB and `ix_txn_transfer_reference` 0.77 MB on a 70.8 MB collection; the first index took 11 s to build. Every insert now also has to update these indexes. W3 benefits less because the collection is small and 631 of 9,008 customers match (7% of the collection), so the index saves less than for the highly selective W1, W2 and W4.

### 4. Validation, uniqueness, flexibility, atomic updates
Output: [evidence/06_validation_and_atomicity_output.txt](evidence/06_validation_and_atomicity_output.txt): **14 of 14 checks passed.**

| Test | Result |
|---|---|
| V1–V7 | Rejected with error 121 (document failed validation): floating-point balance, missing e-mail, account status `DORMANT`, bad account number, ledger amount negative or zero, unknown type `REFUND` |
| U1, U2 | Duplicate e-mail and duplicate account number rejected with error 11000 |
| F1 | A ledger row with a brand-new nested field `metadata.fraud_score` is accepted with no schema change |
| A1, A2 | A guarded atomic debit (`updateOne` with `balance >= amount` inside the filter and `$inc`) takes 300.00 from 1000.00, then refuses a 900.00 debit against 700.00 (matched = 0, balance unchanged) |
| T1 | A multi-document transaction is refused by this deployment: **code 20 `IllegalOperation` — "Transaction numbers are only allowed on a replica set member or mongos"** |

Concurrency: [evidence/07_concurrent_debits_output.txt](evidence/07_concurrent_debits_output.txt). Ten separate client processes each tried to debit 300.00 from a 1000.00 account at the same moment (start offsets 0–37 ms). Exactly **3 were debited, 7 were refused, the final balance was 100.00** and never went negative. This works because the check and the change happen inside one atomic single-document update; it is the same lost-update problem shown for MariaDB in Portfolio 3, solved by a different mechanism.

## Why a document model suits MikePay — and where it does not
**Suits:**
- **Customer profile and dashboard reads.** One document holds the customer, accounts and beneficiaries (Q1).
- **Variable attributes.** Ledger rows differ by channel and type; new attributes (device, fraud score) need no migration (Q5, F1).
- **Event and audit streams.** Append-only documents, simple range indexes (W4).
- **Analytics-style aggregations** over nested arrays (Q4, Q6, Q7).

**Does not suit (and stays in MariaDB):**
- **Fund transfers.** A transfer changes two accounts, usually in two different customer documents. MongoDB only guarantees atomicity inside **one** document; spanning two needs a multi-document transaction, which this standalone server refuses (T1). It would require a replica set. MariaDB's `sp_transfer_funds` (Portfolio 3) already does this safely, so the design keeps money movement in the relational system and uses MongoDB for reading and analysis.
- **Many-to-many relationships and ad-hoc joins.** `$lookup` works (Q8) but is less natural than SQL joins, and the copied fields (beneficiary names, `account_number` on ledger rows) can go stale if the source changes.
- **Strict global constraints.** Validators and unique indexes cover a lot, but cross-document rules such as "the two legs of a transfer sum to zero" are not enforced by the database.

**Not claimed:** no performance comparison between MariaDB and MongoDB was made, so this document does not say either is faster.

## Limitations
- **Standalone MongoDB, no replication and no authentication.** Replication and high availability are the subject of Portfolio 5. A replica set would also enable multi-document transactions.
- **A snapshot, not a live sync.** The documents are a copy exported at one moment; later changes in MariaDB are not propagated. Real systems would use change-data-capture or dual writes.
- **Slice of the data.** Only customers with id ≤ 10000 are exported, so transfers whose other side is outside the slice have unresolved references (Q8: 1,317).
- **Warm cache, one machine.** All data fits in the 15.7 GB WiredTiger cache and server and client share one laptop; cold-disk or network latency would change the milliseconds, not the plan shapes.
- **Timings vary between runs** (index build times and load times differed noticeably between runs); the explain tables report median and range for that reason.
- **Synthetic `metadata`** is generated, not real.
- **Concurrency test** uses 10 clients on one machine, not a production workload.
- **No screenshots yet.** Evidence is captured command output. Compass screenshots of the `customers` document and the explain plan can be added by the student.

## Evidence files
| File | Content |
|---|---|
| [00_bulk_export_output.txt](evidence/00_bulk_export_output.txt) | Export of the 10,000-customer slice (started 10:01:12, finished 10:05:15): 9,008 / 282,620 / 58,995 / 36,028 documents, "exported counts equal independent SQL counts" |
| [01_sample_export_output.txt](evidence/01_sample_export_output.txt) | Export of the 8-customer sample, with counts checked against SQL |
| [02_sample_create_load_verify.txt](evidence/02_sample_create_load_verify.txt) | Collections, validators, load and verification of the sample |
| [03_bulk_create_load_verify.txt](evidence/03_bulk_create_load_verify.txt) | Same for the 9,008-customer slice |
| [04_queries_and_aggregations_output.txt](evidence/04_queries_and_aggregations_output.txt) | Q1–Q9 on the slice |
| [05_index_explain_output.txt](evidence/05_index_explain_output.txt) | Environment, before/after plans, index sizes |
| [06_validation_and_atomicity_output.txt](evidence/06_validation_and_atomicity_output.txt) | 14 validation/atomicity checks |
| [07_concurrent_debits_output.txt](evidence/07_concurrent_debits_output.txt) | 10 concurrent clients |
| [08_negative_verification_output.txt](evidence/08_negative_verification_output.txt) | Tamper test of the verification |

## Issues met while building
- The first bulk export used one `ORDER BY` + multi-way join over the 780k ledger rows and ran for more than 7 minutes before I stopped it. It now scans each table by primary-key range and resolves accounts and transfers from in-memory lookups; the sample output was byte-identical before and after the change.
- `explain` script crashed on `tojson`, which does not exist in `mongosh` script mode (`JSON.stringify` is used).
- The first multi-document transaction test was refused by the *driver* (retryable-writes message) rather than by the server; reading a document first inside the transaction gets the server's own error, code 20.
- The first concurrency run started the clients up to 8 seconds apart (mongosh start-up is slow); the start time was moved 20 seconds ahead so all clients are connected first. The captured run shows start offsets of 0–37 ms.
- The chosen W2 reference differed between two runs because an unsorted `findOne` follows whichever index exists; it now takes the lowest `_id`.

## What you should be able to explain at technical verification
1. **Embed vs reference:** why accounts and beneficiaries are embedded in `customers` but ledger rows are not (bounded vs unbounded growth, read together, 16 MB document limit).
2. **Denormalisation trade-off:** copied fields speed reads but can become stale; what would you do to keep them in sync?
3. **Decimal128 vs double:** why money must not be a floating-point type (test V1).
4. **`$jsonSchema` validation** and what it can and cannot enforce compared with SQL constraints.
5. **Atomicity in MongoDB:** single-document operations are atomic; the guarded `updateOne` is the pattern that stops overdrafts; why transfers between customers need multi-document transactions and therefore a replica set (T1).
6. **Reading an explain plan:** COLLSCAN vs IXSCAN, `SORT` stage, keys/docs examined, why docs examined is more reliable than milliseconds, partial and multikey indexes, the write/storage cost of indexes.
7. **Why verification compares exact totals** and how the negative test shows the check works.
8. **Why transfers stay in MariaDB** and MongoDB is used for profiles, events and analytics (polyglot persistence).
