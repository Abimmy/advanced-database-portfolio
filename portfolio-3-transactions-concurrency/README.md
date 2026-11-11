# Portfolio 3 — Transactions and Concurrency (7 marks)

**Status:** Implemented and tested on MariaDB 10.4.32 (InnoDB). 7 single-session transaction tests and 5 multi-session concurrency scenarios; 22 of 22 computed checks passed in the captured run.

## Objective
Show that a MikePay fund transfer either happens completely or not at all, and show what goes wrong, and what stops it, when several users work on the same accounts at the same time.

## Test environment
| Item | Value |
|---|---|
| Server | MariaDB 10.4.32 (XAMPP), InnoDB, default isolation REPEATABLE-READ, `innodb_lock_wait_timeout` 50 s, deadlock detection ON |
| Client | `mysql` command line for the single-session tests; Python 3.14 + `pymysql` for the multi-session tests (each simulated user is a separate real connection) |
| Data | Five synthetic **test accounts, ids 900001–900005** (two customers). The Portfolio 2 bulk data (80,009 accounts, ~780k ledger rows) was **not reset or modified**. |
| Host | Single Windows 11 laptop, server and clients on `127.0.0.1` |

The test accounts start as: 900001 = 1000.00, 900002 = 500.00, 900003 = 2000.00, 900004 = 750.00, 900005 = 100.00 (**FROZEN**). Total 4350.00. `sp_p3_reset_test_data()` deletes only rows with these ids and recreates them, so every scenario starts from a known state.

## How a failed transfer cannot leave balances inconsistent
`sp_transfer_funds` ([sql/01_transfer_procedures.sql](sql/01_transfer_procedures.sql)) does this, in order:

1. **One transaction** (`START TRANSACTION` … `COMMIT`) wraps every change: debit, credit, transfer row, two ledger rows. They become visible together or not at all.
2. **Lock first, then check.** Both account rows are locked with `SELECT … FOR UPDATE`, in ascending account-id order, *before* the balance is read. Nobody can change those balances between the check and the update.
3. **Validate before writing.** Active status, same currency and sufficient funds are checked before any `UPDATE`. A rule failure therefore has nothing to undo; it commits a `FAILED` transfer row (with the reason) so there is an audit trail and no balance or ledger row changes. Malformed requests (amount ≤ 0, same account, unknown account) are `REJECTED` and nothing is stored.
4. **Relative updates.** `SET balance = balance - x`, never "write back a number I read earlier" (see S1).
5. **`EXIT HANDLER FOR SQLEXCEPTION` → `ROLLBACK`.** Any unexpected error after the writes start (duplicate reference, deadlock, constraint violation) undoes the debit, the credit and the inserts together (see T5, S4).
6. **`CHECK (balance >= 0)`** in the table is the last line of defence if application logic ever fails (see S2-B).

`sp_transfer_core` is the shared implementation. It has two **test-only** parameters (lock order and a pause between the two locks) that exist so the deadlock demonstration can be repeated. `sp_transfer_funds`, the procedure an application would call, always uses the safe settings.

## Results: single-session tests (COMMIT / ROLLBACK)
Source: [sql/03_commit_rollback_tests.sql](sql/03_commit_rollback_tests.sql). Output: [evidence/02_commit_rollback_tests_output.txt](evidence/02_commit_rollback_tests_output.txt).

| Test | What was done | Observed result |
|---|---|---|
| T1 | Transfer 250.00 from 900001 to 900002 | `COMPLETED`. Balances 750.00 / 750.00, one `COMPLETED` transfer row, two ledger legs (debit and credit, `balance_after` 750.00 each), two `BALANCE_CHANGED` audit rows |
| T2 | 99,999.00 from an account that has 750.00 | `FAILED: Insufficient funds`. Balances unchanged, a `FAILED` transfer row with its reason, **0** ledger rows |
| T3 | Transfer to the FROZEN account 900005 | `FAILED: Destination account is not active`. Balances unchanged |
| T4 | Negative amount, same account, unknown account | All three `REJECTED`. **0** transfer rows stored |
| T5 | Reuse reference `P3-T1` (violates the UNIQUE key *after* both `UPDATE`s ran) | `ERROR … 1062 Duplicate entry`, "Rolled back". Balances still 750.00 / 750.00 and the ledger still has 2 rows, so the handler's `ROLLBACK` undid the debit and credit. Integrity check after T1–T5: 0 problems, total 4350.00 |
| T6a | Manual transaction: debit 100.00, then a credit step that fails (foreign key error), then `ROLLBACK` | Inside the transaction the balance read 1900.00. After the failed statement it was **still** 1900.00 (a failed statement undoes only itself, the transaction stays open). After `ROLLBACK`: 2000.00 |
| T7 | `SAVEPOINT`: move 30.00, savepoint, move 50.00, `ROLLBACK TO SAVEPOINT`, `COMMIT` | 900003 = 1970.00, 900004 = 780.00: only the first move survived |
| T6b | The **same** failure with no transaction (autocommit on) | The debit was permanent. Total money fell from 4350.00 to **4250.00**; 100.00 vanished, and the audit trail shows the balance change. This is what the transaction prevents |

## Results: multi-session concurrency tests
Source: [sql/concurrency_tests.py](sql/concurrency_tests.py). Output (every statement with its time stamp and real result): [evidence/03_concurrency_tests_output.txt](evidence/03_concurrency_tests_output.txt). The PASS/FAIL lines at the end are *computed from what the server returned*, not written in advance.

| Scenario | Question | Observed result |
|---|---|---|
| S1-A | Two users each read 1000.00, compute their own new balance and write it back (take 100 and 200) | **Lost update.** Final balance 800.00; correct is 700.00. One user's change was silently overwritten. This happens at the default REPEATABLE READ too |
| S1-B | Same, but `UPDATE … SET balance = balance - x` | Second `UPDATE` was **blocked** until the first committed, then applied. Final 700.00 |
| S1-C | Same, but `SELECT … FOR UPDATE` first | Second session **waited**, then read the *new* balance 800.00 (not the stale 1000.00). Final 700.00 |
| S2-A | Two transfers of 700.00 race for an account holding 1000.00; `sp_transfer_funds`, 10 rounds | In all 10 rounds exactly one `COMPLETED` and one `FAILED: Insufficient funds`; balance 300.00; integrity checks 0 problems |
| S2-B | Same race with no row lock (check, then debit) | Second debit blocked, then rejected by the table's `CHECK (balance >= 0)` (error 4025). The database stopped the overdraft, but the application got a raw constraint error, not a clean answer |
| S3 | Two sessions lock accounts 900001 and 900002 in opposite order | **Deadlock.** InnoDB detected it at once and rolled back one session with error 1213. The excerpt from `SHOW ENGINE INNODB STATUS` is in the evidence file |
| S4-A | `A→B` and `B→A` at the same instant, locks taken in the order given (source first), 10 rounds | **10 of 20** attempts were deadlock victims (error 1213), the other 10 completed. Integrity checks 0 problems and total money unchanged: a victim's partial work is rolled back whole |
| S4-B | Same, locks taken in ascending id order | **0 deadlocks, 20 of 20 completed.** Same pause in both variants, so lock order is the only difference |
| S4-C | Stress: 8 sessions × 30 random transfers (240), `sp_transfer_funds` | 240 of 240 answered with no errors or deadlocks: 204 `COMPLETED`, 36 `FAILED` (insufficient funds). Ledger has exactly 2 rows per completed transfer; integrity checks 0 problems; total money exactly 4350.00. *The split between COMPLETED and FAILED varies between runs because the interleaving varies; the other facts held in every run I made* |
| S5 | Dirty read, non-repeatable read, phantom read at each isolation level | See the table below |

### S5: isolation levels, as observed
| Isolation level | Dirty read | Non-repeatable read | Phantom (plain `SELECT`) |
|---|---|---|---|
| READ UNCOMMITTED | YES | YES | YES |
| READ COMMITTED | no | YES | YES |
| REPEATABLE READ (MariaDB default) | no | no | no |
| SERIALIZABLE | no (blocked) | no (blocked) | no (blocked) |

"no (blocked)" means the other session did not get a stale or changed value; it had to **wait** and hit the lock wait timeout (error 1205). Also observed:

- At REPEATABLE READ a plain `SELECT` kept its snapshot (count 0, then 0 after another session inserted a row), but a *locking* read (`SELECT … FOR UPDATE`, a "current read") in the same transaction saw the new row (count 1). The "no" in the phantom column applies to plain `SELECT`s only.
- An open REPEATABLE READ reader did **not** block a writer. An open SERIALIZABLE reader **did**: the writer's `UPDATE` failed with error 1205 and succeeded immediately after the reader committed.

## What the results mean for MikePay
- Transactions give atomicity: T5 and T6a show partial work being undone, T6b shows the damage when there is no transaction.
- Isolation levels alone do not make a read-then-write safe. S1-A lost an update under the default level. Safety came from atomic `UPDATE`s or from locking the row first (S1-B, S1-C).
- Lock ordering is a design decision, and it mattered measurably: 10 deadlocks in 20 attempts without it, 0 with it (S4).
- Even with correct locking, a caller must be ready to **retry** after error 1213 (deadlock) or 1205 (lock wait timeout). The procedure reports them as `ERROR` after rolling back, and the retry itself is left to the caller.

## Files
| File | What it does |
|---|---|
| [sql/01_transfer_procedures.sql](sql/01_transfer_procedures.sql) | `sp_transfer_funds` (safe) and `sp_transfer_core` (shared implementation with test hooks) |
| [sql/02_test_data.sql](sql/02_test_data.sql) | `sp_p3_reset_test_data()`: recreates test accounts 900001–900005, touching only those ids |
| [sql/03_commit_rollback_tests.sql](sql/03_commit_rollback_tests.sql) | T1–T7, run with the `mysql` client |
| [sql/04_integrity_checks.sql](sql/04_integrity_checks.sql) | Five reconciliation checks plus total money; also run by the Python tests |
| [sql/concurrency_tests.py](sql/concurrency_tests.py) | S1–S5 with real parallel sessions |
| [requirements.txt](requirements.txt) | `pymysql` |

## How to run
Requires the Portfolio 1 schema and triggers. From the `sql/` folder in Git Bash:

```bash
MYSQL=/c/xampp/mysql/bin/mysql.exe
$MYSQL -u root < 01_transfer_procedures.sql
$MYSQL -u root < 02_test_data.sql
$MYSQL -u root -n -t -vvv --force < 03_commit_rollback_tests.sql      # a few seconds
$MYSQL -u root -t < 04_integrity_checks.sql                           # optional, any time
pip install -r ../requirements.txt
PYTHONIOENCODING=utf-8 python concurrency_tests.py > ../evidence/03_concurrency_tests_output.txt   # about 45 seconds
```
`--force` is needed only because T6a and T6b are *meant* to hit an error. The Python script exits with 0 only if every computed check passed.

## Evidence (captured from real runs, 2026-11-05)
| File | Shows |
|---|---|
| [evidence/01_install_procedures_and_test_data.txt](evidence/01_install_procedures_and_test_data.txt) | Procedures created, with the strict `sql_mode` they were created under |
| [evidence/02_commit_rollback_tests_output.txt](evidence/02_commit_rollback_tests_output.txt) | T1–T7 with every statement and result |
| [evidence/03_concurrency_tests_output.txt](evidence/03_concurrency_tests_output.txt) | S1–S5 time-stamped log, deadlock report, isolation table, 22 computed checks |

The text files are command-line outputs. One screenshot was added from a repeat run on 2026-11-11:

| File | Shows |
|---|---|
| [04_concurrency_summary_terminal.png](evidence/04_concurrency_summary_terminal.png) | The last 30 lines of a repeat run of `concurrency_tests.py` (output piped through `Select-Object -Last 30`): the summary of computed checks and "22 of 22 checks passed". The repeat run took 27 s against 41 s in the captured log, because timings vary between runs; the full time-stamped log is `03_concurrency_tests_output.txt` |

## Limitations
- **Not a load test.** One laptop, the server and clients on the same machine, 8 sessions and 240 transfers in the stress test. It shows correctness under contention on a few hot rows, not performance at scale.
- **Timing demonstrations depend on timing.** "Blocked" is judged by a statement still waiting after 0.6 s, and the deadlock demo uses a 0.2 s pause between the two locks. A lock wait timeout configured as 2–3 s actually fired after 2.7–3.8 s in my run, so I treat those numbers as approximate.
- **Ordered locking is not a general guarantee.** It removes the deadlock between two transfers on the same pair of accounts, as tested. Other access patterns (for example a batch job touching accounts in another order) could still deadlock, so callers need retry logic, which is **not implemented** here.
- **The procedure reports `ERROR` and stops; it does not retry.** A client that sends the same reference after an `ERROR` is safe, because the whole attempt was rolled back and the reference is free again. I did not build an idempotency scheme beyond the UNIQUE reference.
- **Only REPEATABLE READ is used by the procedure.** I did not measure whether another level would perform differently.
- **InnoDB-specific behaviour.** The REPEATABLE READ results (no phantoms for plain `SELECT`s, "current reads" seeing new rows) are InnoDB's behaviour on this version, not a statement about the SQL standard.
- **Test hooks live in `sp_transfer_core`.** In production they would be removed; the safe wrapper never uses them.
- **Test helper credentials.** The Python script connects as `root` with an empty password because that is the XAMPP default on this laptop. It is for local use only.
- **Left behind:** the five test accounts, two test customers and their audit rows stay in `mikepay_db` after the run (as the reset procedure leaves them). Re-running Portfolio 1 scripts 01–03 removes them.
- Evidence is captured command output, not screenshots.

## Issues met along the way
- No MySQL driver was installed for Python, so I installed `pymysql` (pure Python) and listed it in `requirements.txt`.
- My first version of the isolation summary had the SERIALIZABLE row typed in by hand rather than observed. I replaced it by running the same three anomaly tests at SERIALIZABLE, which is why the table shows "(blocked)" and is backed by timeout errors in the log.
- The first deadlock excerpt ran on past its section and included hex dumps. I trimmed it to the deadlock section and removed only the hex record dumps (stated in the log).
- MariaDB prints a client error line before the text of the statement that caused it, so in the evidence file the two `ERROR 1452` lines appear just above their `INSERT`.

## What I should be able to explain in verification
- What atomicity means, and why T6a needed an explicit `ROLLBACK` even though the failed statement had already been undone.
- Why T6b loses money and T6a does not. The effect of autocommit.
- Why `SELECT … FOR UPDATE` must come *before* the balance check, and why relative `UPDATE`s are safer than writing back a value read earlier (S1).
- What a lost update, dirty read, non-repeatable read and phantom read are, and which level of this server prevents which (the S5 table), including the difference between a plain `SELECT` and a locking read at REPEATABLE READ.
- What a deadlock is, how InnoDB resolves it (rolls back one victim, error 1213), and why locking accounts in id order prevents the A↔B deadlock.
- Why the procedure does not `ROLLBACK` on a business-rule failure but does in the error handler, and what the `FAILED` transfer row is for.
- Why the `CHECK` constraint is still worth having when the procedure already checks the balance.
- What the tests do **not** show (see Limitations).
