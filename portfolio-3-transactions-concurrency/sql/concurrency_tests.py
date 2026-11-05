"""
MikePay - Portfolio 3: concurrency and isolation tests.

Opens several REAL database connections (one per simulated user) against mikepay_db and
runs them at the same time, so locking, blocking, deadlocks and isolation behaviour are
observed rather than described. Every statement is logged with a time stamp and its
actual result. Nothing here is simulated or hard-coded: the PASS/FAIL lines at the end are
computed from what the server returned.

Scenarios
  S1  Lost update: unsafe read-modify-write vs atomic UPDATE vs SELECT ... FOR UPDATE
  S2  Concurrent overdraw: two transfers race for the same money
  S3  Deadlock: two sessions lock two accounts in opposite order (InnoDB deadlock detection)
  S4  Deadlock in the transfer procedure: lock-as-given vs lock-in-id-order, then a stress test
  S5  Isolation levels: dirty read, non-repeatable read, phantom read, SERIALIZABLE blocking

Requires: pymysql (pip install pymysql), the Portfolio 1 schema, and files 01, 02 and 04 of
this folder's sql/ directory already loaded (01 and 02 define the procedures, 04 is read here).
Uses ONLY test accounts 900001-900005. Run (from this folder):
    python concurrency_tests.py > ../evidence/03_concurrency_tests_output.txt
Exit code is 0 only if every computed check passed.
"""
import pathlib
import random
import re
import sys
import threading
import time
from decimal import Decimal

import pymysql

HOST, PORT, USER, PASSWORD, DB = "127.0.0.1", 3306, "root", "", "mikepay_db"
STRICT = ("STRICT_ALL_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ZERO_IN_DATE,"
          "NO_ZERO_DATE,NO_ENGINE_SUBSTITUTION")
HERE = pathlib.Path(__file__).resolve().parent
A, B, C, D, FROZEN = 900001, 900002, 900003, 900004, 900005
ACTIVE = [A, B, C, D]
INITIAL_TOTAL = Decimal("4350.00")

T0 = time.perf_counter()
_log_lock = threading.Lock()
CHECKS = []          # (description, passed)


def log(msg=""):
    with _log_lock:
        print(f"[{time.perf_counter() - T0:7.2f}s] {msg}", flush=True)


def heading(text):
    log()
    log("=" * 100)
    log(text)
    log("=" * 100)


def check(description, passed):
    CHECKS.append((description, bool(passed)))
    log(f"CHECK {'PASS' if passed else 'FAIL'}: {description}")


def one_line(sql):
    return " ".join(str(sql).split())


class Res:
    """Result of one statement: rows, or an error number and message."""

    def __init__(self, rows=None, errno=None, msg=None, affected=0):
        self.rows, self.errno, self.msg, self.affected = rows or [], errno, msg, affected

    @property
    def ok(self):
        return self.errno is None

    def value(self):
        return self.rows[0][0] if self.rows else None

    def describe(self):
        if self.errno is not None:
            return f"ERROR {self.errno}: {self.msg}"
        if self.rows:
            if len(self.rows) == 1 and len(self.rows[0]) == 1:
                return f"{self.rows[0][0]}"
            shown = ", ".join(str(tuple(r)) for r in self.rows[:6])
            return shown + (" ..." if len(self.rows) > 6 else "")
        return f"OK, {self.affected} row(s) affected"


class Sess:
    """One database connection = one simulated user session (autocommit on, explicit
    START TRANSACTION / COMMIT / ROLLBACK so every step is visible in the log)."""

    def __init__(self, name, isolation=None, lock_timeout=None, quiet=False):
        self.name, self.quiet = name, quiet
        self.conn = pymysql.connect(host=HOST, port=PORT, user=USER, password=PASSWORD,
                                    database=DB, autocommit=True, charset="utf8mb4",
                                    read_timeout=120,
                                    init_command=f"SET SESSION sql_mode='{STRICT}'")
        self.cur = self.conn.cursor()
        if isolation:
            self.q(f"SET SESSION TRANSACTION ISOLATION LEVEL {isolation}", quiet=True)
        if lock_timeout:
            self.q(f"SET SESSION innodb_lock_wait_timeout = {int(lock_timeout)}", quiet=True)

    def q(self, sql, args=None, quiet=None):
        quiet = self.quiet if quiet is None else quiet
        shown = self.cur.mogrify(sql, args) if args is not None else sql
        t = time.perf_counter()
        try:
            self.cur.execute(sql, args)
            rows = list(self.cur.fetchall()) if self.cur.description else []
            res = Res(rows=rows, affected=self.cur.rowcount)
        except pymysql.err.MySQLError as e:
            errno = e.args[0] if e.args and isinstance(e.args[0], int) else -1
            msg = e.args[1] if len(e.args) > 1 else str(e)
            res = Res(errno=errno, msg=msg)
        took = time.perf_counter() - t
        if not quiet:
            extra = f"   (took {took:.2f}s)" if took >= 0.3 else ""
            log(f"{self.name}> {one_line(shown)}   =>   {res.describe()}{extra}")
        res.took = took
        return res

    def close(self):
        try:
            self.conn.close()
        except Exception:
            pass


def async_q(sess, sql, args=None):
    """Run a statement that is expected to BLOCK in a background thread."""
    box = {}
    log(f"{sess.name}> {one_line(sql)}   ...sent; waiting for the server (not returned yet)")

    def run():
        box["res"] = sess.q(sql, args)

    th = threading.Thread(target=run, daemon=True)
    th.start()
    return th, box


def still_blocked(th, label, wait=0.6):
    time.sleep(wait)
    blocked = th.is_alive()
    log(f"      ({label}: {'still waiting after %.1fs, so it is BLOCKED by a lock' % wait if blocked else 'already returned, NOT blocked'})")
    return blocked


_admin = None


def admin():
    global _admin
    if _admin is None:
        _admin = Sess("admin", quiet=True)
    return _admin


def reset():
    r = admin().q("CALL sp_p3_reset_test_data()")
    assert r.ok, r.describe()


def balance(sess, account):
    return sess.q("SELECT balance FROM accounts WHERE account_id = %s", (account,), quiet=True).value()


def call_transfer(sess, ref, src, dst, amount, ordered=None, pause=None):
    """Call the procedure on this session. ordered/pause are the TEST hooks of sp_transfer_core."""
    if ordered is None:
        sql = "CALL sp_transfer_funds(%s, %s, %s, %s, @st, @msg)"
        args = (ref, src, dst, amount)
    else:
        sql = "CALL sp_transfer_core(%s, %s, %s, %s, %s, %s, @st, @msg)"
        args = (ref, src, dst, amount, ordered, pause or 0)
    r = sess.q(sql, args, quiet=True)
    if not r.ok:
        return "CLIENT_ERROR", f"{r.errno}: {r.msg}"
    out = sess.q("SELECT @st, @msg", quiet=True)
    return out.rows[0][0], out.rows[0][1]


def load_statements(path):
    lines = [ln for ln in path.read_text(encoding="utf-8").splitlines() if not ln.lstrip().startswith("--")]
    stmts = [s.strip() for s in "\n".join(lines).split(";") if s.strip()]
    return [s for s in stmts if not s.upper().startswith("USE ")]


def integrity(label):
    """Run 04_integrity_checks.sql. Returns (total_problems, total_money)."""
    stmts = load_statements(HERE / "04_integrity_checks.sql")
    s = admin()
    checks = s.q(stmts[0], quiet=True)
    total = s.q(stmts[1], quiet=True).value()
    problems = sum(int(r[1]) for r in checks.rows)
    log(f"INTEGRITY ({label}):")
    for name, n in checks.rows:
        log(f"      {name:<58} problems = {n}")
    log(f"      total money in test accounts = {total}   (expected {INITIAL_TOTAL})")
    return problems, total


# =============================================================================
def s1_lost_update():
    heading("S1  LOST UPDATE: two users change the same balance at the same time (isolation: REPEATABLE READ)")
    log("Account 900001 starts at 1000.00. User 1 takes 200.00 and user 2 takes 100.00, so the")
    log("correct final balance is 700.00.")
    s1, s2 = Sess("s1"), Sess("s2")
    log(f"Server default isolation level: {admin().q('SELECT @@tx_isolation', quiet=True).value()}")

    # ---- Part A: unsafe read-modify-write
    log("")
    log("--- S1-A  UNSAFE: the application reads the balance, calculates, then writes back a number")
    reset()
    s1.q("START TRANSACTION")
    b1 = s1.q("SELECT balance FROM accounts WHERE account_id = 900001").value()
    s2.q("START TRANSACTION")
    b2 = s2.q("SELECT balance FROM accounts WHERE account_id = 900001").value()
    s2.q("UPDATE accounts SET balance = %s WHERE account_id = 900001", (b2 - Decimal("100"),))
    s2.q("COMMIT")
    s1.q("UPDATE accounts SET balance = %s WHERE account_id = 900001", (b1 - Decimal("200"),))
    s1.q("COMMIT")
    final_a = balance(admin(), A)
    log(f"Final balance = {final_a}; correct answer = 700.00")
    log("audit_log for the account (written by the trigger):")
    for row in admin().q("SELECT audit_id, old_balance, new_balance FROM audit_log "
                         "WHERE account_id = 900001 AND action = 'BALANCE_CHANGED' ORDER BY audit_id", quiet=True).rows:
        log(f"      {row}")
    check("S1-A unsafe read-modify-write LOSES an update (final balance is not 700.00)", final_a != Decimal("700.00"))

    # ---- Part B: atomic relative update
    log("")
    log("--- S1-B  SAFE: let the database do the arithmetic: UPDATE ... SET balance = balance - x")
    reset()
    s1.q("START TRANSACTION")
    s1.q("UPDATE accounts SET balance = balance - 200 WHERE account_id = 900001")
    s2.q("START TRANSACTION")
    th, box = async_q(s2, "UPDATE accounts SET balance = balance - 100 WHERE account_id = 900001")
    blocked = still_blocked(th, "s2's UPDATE")
    s1.q("COMMIT")
    th.join()
    s2.q("COMMIT")
    final_b = balance(admin(), A)
    log(f"Final balance = {final_b}")
    check("S1-B s2's UPDATE was blocked until s1 committed", blocked)
    check("S1-B atomic relative UPDATE keeps both changes (final balance 700.00)", final_b == Decimal("700.00"))

    # ---- Part C: pessimistic locking
    log("")
    log("--- S1-C  SAFE: lock the row first with SELECT ... FOR UPDATE, then read, calculate, write")
    reset()
    s1.q("START TRANSACTION")
    b1 = s1.q("SELECT balance FROM accounts WHERE account_id = 900001 FOR UPDATE").value()
    s2.q("START TRANSACTION")
    th, box = async_q(s2, "SELECT balance FROM accounts WHERE account_id = 900001 FOR UPDATE")
    blocked = still_blocked(th, "s2's SELECT ... FOR UPDATE")
    s1.q("UPDATE accounts SET balance = %s WHERE account_id = 900001", (b1 - Decimal("200"),))
    s1.q("COMMIT")
    th.join()
    b2 = box["res"].value()
    log(f"s2 finally read {b2}: the NEW balance, not the stale 1000.00")
    s2.q("UPDATE accounts SET balance = %s WHERE account_id = 900001", (b2 - Decimal("100"),))
    s2.q("COMMIT")
    final_c = balance(admin(), A)
    log(f"Final balance = {final_c}")
    check("S1-C locking read made s2 wait, and it then saw the committed balance", blocked and b2 == Decimal("800.00"))
    check("S1-C read-modify-write is safe when the row is locked first (final balance 700.00)", final_c == Decimal("700.00"))
    s1.close(); s2.close()


# =============================================================================
def s2_overdraw():
    heading("S2  CONCURRENT OVERDRAW: two transfers of 700.00 race for an account that holds 1000.00")
    log("Only one of them can be paid. sp_transfer_funds locks the account row before it checks the balance.")
    log("")
    log("--- S2-A  sp_transfer_funds called by two sessions at the same instant, 10 rounds")
    s1, s2 = Sess("s1", quiet=True), Sess("s2", quiet=True)
    good_rounds = 0
    for rnd in range(1, 11):
        reset()
        barrier = threading.Barrier(2)
        out = {}

        def worker(sess, key, dst):
            barrier.wait()
            out[key] = call_transfer(sess, f"P3-S2-{rnd}-{key}", A, dst, Decimal("700.00"))

        ts = [threading.Thread(target=worker, args=(s1, "x", B)), threading.Thread(target=worker, args=(s2, "y", C))]
        [t.start() for t in ts]; [t.join() for t in ts]
        statuses = sorted(v[0] for v in out.values())
        bal = balance(admin(), A)
        ok = statuses == ["COMPLETED", "FAILED"] and bal == Decimal("300.00")
        good_rounds += ok
        log(f"round {rnd:2}: x -> {out['x'][0]} ({out['x'][1]}), y -> {out['y'][0]} ({out['y'][1]}); balance of 900001 = {bal}  {'ok' if ok else 'UNEXPECTED'}")
    problems, total = integrity("after S2-A, last round")
    check("S2-A in all 10 rounds exactly one transfer completed, one failed, balance 300.00", good_rounds == 10)
    check("S2-A integrity checks pass and no money was created or lost", problems == 0 and total == INITIAL_TOTAL)
    s1.close(); s2.close()

    log("")
    log("--- S2-B  NO row lock: both sessions check the balance, then both try to debit 700.00")
    reset()
    s1, s2 = Sess("s1"), Sess("s2")
    s1.q("START TRANSACTION")
    s2.q("START TRANSACTION")
    s1.q("SELECT balance FROM accounts WHERE account_id = 900001")
    s2.q("SELECT balance FROM accounts WHERE account_id = 900001")
    log("      Both sessions saw 1000.00 >= 700.00 and decide to go ahead.")
    s1.q("UPDATE accounts SET balance = balance - 700 WHERE account_id = 900001")
    th, box = async_q(s2, "UPDATE accounts SET balance = balance - 700 WHERE account_id = 900001")
    still_blocked(th, "s2's UPDATE")
    s1.q("COMMIT")
    th.join()
    res = box["res"]
    s2.q("ROLLBACK")
    final = balance(admin(), A)
    log(f"Final balance = {final}")
    log("The CHECK (balance >= 0) constraint stopped the overdraft, but the application only got")
    log("a raw constraint error instead of a clean 'insufficient funds' answer. Locking first is better.")
    check("S2-B without a lock the second debit is stopped only by the CHECK constraint", res.errno is not None and final == Decimal("300.00"))
    s1.close(); s2.close()


# =============================================================================
def s3_deadlock():
    heading("S3  DEADLOCK: two sessions lock the same two accounts in opposite order")
    reset()
    s1, s2 = Sess("s1"), Sess("s2")
    s1.q("START TRANSACTION")
    s2.q("START TRANSACTION")
    s1.q("SELECT balance FROM accounts WHERE account_id = 900001 FOR UPDATE")
    s2.q("SELECT balance FROM accounts WHERE account_id = 900002 FOR UPDATE")
    th, box = async_q(s1, "SELECT balance FROM accounts WHERE account_id = 900002 FOR UPDATE")
    waiting = still_blocked(th, "s1 waiting for account 900002")
    r2 = s2.q("SELECT balance FROM accounts WHERE account_id = 900001 FOR UPDATE")
    th.join()
    r1 = box["res"]
    victims = [name for name, r in (("s1", r1), ("s2", r2)) if r.errno == 1213]
    log(f"InnoDB chose the victim: {victims}")
    for sess, r in ((s1, r1), (s2, r2)):
        if r.errno == 1213:
            log(f"      {sess.name} was rolled back by the server and must retry its whole transaction")
        else:
            sess.q("COMMIT")
    s1.q("ROLLBACK", quiet=True); s2.q("ROLLBACK", quiet=True)
    status = admin().q("SHOW ENGINE INNODB STATUS", quiet=True).rows[0][2]
    start = status.find("LATEST DETECTED DEADLOCK")
    m = re.search(r"-{5,}\s*\nTRANSACTIONS\s*\n-{5,}", status[start:]) if start >= 0 else None
    section = status[start:start + m.start()] if m else status[start:start + 3500]
    log("")
    log("Excerpt of SHOW ENGINE INNODB STATUS, section LATEST DETECTED DEADLOCK")
    log("(the hexadecimal record dumps are omitted; everything else is unedited):")
    if start >= 0:
        for line in section.splitlines():
            if re.match(r"\s*\d+: len \d+; hex", line) or line.startswith("Record lock, heap no"):
                continue
            log("      | " + line)
    check("S3 the server detected the deadlock and aborted exactly one session (error 1213)",
          len(victims) == 1 and waiting)
    s1.close(); s2.close()


# =============================================================================
def run_opposite_rounds(label, ordered, rounds, pause):
    """A->B and B->A at the same instant, `rounds` times. Returns (completed, deadlocks, other)."""
    s1, s2 = Sess("s1", quiet=True), Sess("s2", quiet=True)
    completed = deadlocks = other = 0
    for rnd in range(1, rounds + 1):
        barrier = threading.Barrier(2)
        out = {}

        def worker(sess, key, src, dst):
            barrier.wait()
            out[key] = call_transfer(sess, f"P3-S4-{label}-{rnd}-{key}", src, dst, Decimal("10.00"),
                                     ordered=ordered, pause=pause)

        ts = [threading.Thread(target=worker, args=(s1, "ab", A, B)), threading.Thread(target=worker, args=(s2, "ba", B, A))]
        [t.start() for t in ts]; [t.join() for t in ts]
        for v in out.values():
            if v[0] == "COMPLETED":
                completed += 1
            elif v[0] == "ERROR" and "1213" in v[1]:
                deadlocks += 1
            else:
                other += 1
        log(f"{label} round {rnd:2}: A->B {out['ab'][0]:9} B->A {out['ba'][0]:9} {'<- ' + out['ab'][1][:70] if out['ab'][0] == 'ERROR' else ''}{'<- ' + out['ba'][1][:70] if out['ba'][0] == 'ERROR' else ''}")
    s1.close(); s2.close()
    return completed, deadlocks, other


def s4_procedure_deadlocks():
    heading("S4  DEADLOCKS INSIDE THE TRANSFER PROCEDURE: lock-as-given vs lock-in-id-order")
    log("Each round sends 10.00 from 900001 to 900002 and 10.00 from 900002 to 900001 at the same instant.")
    log("A 0.2 s pause between the two row locks is used in BOTH variants so the overlap is repeatable.")
    log("The only difference is the lock order (p_lock_ordered = 0 or 1).")

    log("")
    log("--- S4-A  p_lock_ordered = 0: lock the source first, then the destination (the naive way)")
    reset()
    c0, d0, o0 = run_opposite_rounds("as-given", 0, 10, 0.2)
    log(f"as-given: completed={c0} deadlock-victims={d0} other={o0} (20 attempts)")
    p0, t0 = integrity("after S4-A (deadlock victims were rolled back whole)")

    log("")
    log("--- S4-B  p_lock_ordered = 1: always lock the lower account id first (what sp_transfer_funds does)")
    reset()
    c1, d1, o1 = run_opposite_rounds("ordered", 1, 10, 0.2)
    log(f"ordered: completed={c1} deadlock-victims={d1} other={o1} (20 attempts)")
    p1, t1 = integrity("after S4-B")

    check("S4-A locking in the order given produced deadlocks (error 1213)", d0 > 0)
    check("S4-A deadlock victims left no half-done transfers (integrity ok, money conserved)", p0 == 0 and t0 == INITIAL_TOTAL)
    check("S4-B locking in id order produced zero deadlocks and all 20 transfers completed", d1 == 0 and c1 == 20 and o1 == 0)
    check("S4-B integrity checks pass and money is conserved", p1 == 0 and t1 == INITIAL_TOTAL)

    log("")
    log("--- S4-C  STRESS TEST: 8 sessions x 30 random transfers (240) among accounts 900001-900004, sp_transfer_funds")
    reset()
    tally, lock = {}, threading.Lock()

    def worker(tid):
        s = Sess(f"w{tid}", quiet=True)
        rng = random.Random(8100 + tid)
        for i in range(30):
            src, dst = rng.sample(ACTIVE, 2)
            st, msg = call_transfer(s, f"P3-ST-{tid}-{i}", src, dst, Decimal(rng.randint(1, 400)))
            key = st if st != "ERROR" else f"ERROR ({msg[:60]})"
            with lock:
                tally[key] = tally.get(key, 0) + 1
        s.close()

    start = time.perf_counter()
    ts = [threading.Thread(target=worker, args=(i,)) for i in range(8)]
    [t.start() for t in ts]; [t.join() for t in ts]
    elapsed = time.perf_counter() - start
    log(f"finished 240 transfers in {elapsed:.2f}s with 8 concurrent sessions")
    for k, v in sorted(tally.items()):
        log(f"      {k}: {v}")
    n_completed = tally.get("COMPLETED", 0)
    legs = admin().q("SELECT COUNT(*) FROM transactions WHERE account_id BETWEEN 900001 AND 900099", quiet=True).value()
    log(f"ledger rows = {legs} (expected 2 x completed = {2 * n_completed})")
    p2, t2 = integrity("after S4-C stress test")
    errors = sum(v for k, v in tally.items() if k.startswith("ERROR"))
    check("S4-C all 240 requests were answered (COMPLETED or FAILED) with no ERROR/deadlock", errors == 0 and sum(tally.values()) == 240)
    check("S4-C ledger has exactly two rows per completed transfer", legs == 2 * n_completed)
    check("S4-C integrity checks pass and total money is unchanged after 240 concurrent transfers", p2 == 0 and t2 == INITIAL_TOTAL)


# =============================================================================
def s5_isolation():
    heading("S5  ISOLATION LEVELS: what a reader sees while a writer is active (account 900001 = 1000.00)")
    log("Each anomaly is tried at every level. A lock wait timeout of 2 s is set on the sessions so that")
    log("a session that is BLOCKED (which happens at SERIALIZABLE) ends the test instead of waiting 50 s.")
    obs = {}
    levels = ["READ UNCOMMITTED", "READ COMMITTED", "REPEATABLE READ", "SERIALIZABLE"]
    BLOCKED = "blocked"

    log("")
    log("--- S5-A  DIRTY READ: can a reader see a change that has not been committed (and may be rolled back)?")
    for lvl in levels:
        reset()
        w, r = Sess("writer"), Sess("reader", isolation=lvl, lock_timeout=2)
        log(f"[reader isolation = {lvl}]")
        w.q("START TRANSACTION")
        w.q("UPDATE accounts SET balance = balance - 100 WHERE account_id = 900001")
        r.q("START TRANSACTION")
        res = r.q("SELECT balance FROM accounts WHERE account_id = 900001")
        w.q("ROLLBACK")
        if res.errno == 1205:
            obs[("dirty", lvl)] = BLOCKED
            log("      the reader's SELECT was blocked by the writer's uncommitted change and timed out")
            r.q("ROLLBACK")
        else:
            after = r.q("SELECT balance FROM accounts WHERE account_id = 900001").value()
            r.q("COMMIT")
            obs[("dirty", lvl)] = res.value() != Decimal("1000.00")
            log(f"      reader saw {res.value()} while the change was uncommitted; after the writer's ROLLBACK it sees {after}")
        w.close(); r.close()

    log("")
    log("--- S5-B  NON-REPEATABLE READ: does the same SELECT inside one transaction return a different value?")
    for lvl in levels:
        reset()
        w, r = Sess("writer", lock_timeout=2), Sess("reader", isolation=lvl, lock_timeout=2)
        log(f"[reader isolation = {lvl}]")
        r.q("START TRANSACTION")
        first = r.q("SELECT balance FROM accounts WHERE account_id = 900001").value()
        wres = w.q("UPDATE accounts SET balance = balance - 100 WHERE account_id = 900001")   # autocommit: committed at once
        second = r.q("SELECT balance FROM accounts WHERE account_id = 900001").value()
        r.q("COMMIT")
        if wres.errno == 1205:
            obs[("nonrep", lvl)] = BLOCKED
            log(f"      the writer was blocked by the reader's lock, so the reader's two reads were {first} and {second}")
        else:
            obs[("nonrep", lvl)] = first != second
            log(f"      first read {first}, second read {second} inside the same transaction")
        w.close(); r.close()

    log("")
    log("--- S5-C  PHANTOM READ: does a repeated range query inside one transaction gain a new row?")
    for lvl in levels:
        reset()
        w, r = Sess("writer", lock_timeout=2), Sess("reader", isolation=lvl, lock_timeout=2)
        log(f"[reader isolation = {lvl}]")
        r.q("START TRANSACTION")
        c1 = r.q("SELECT COUNT(*) FROM transfers WHERE source_account_id = 900001").value()
        wres = w.q("INSERT INTO transfers (reference, source_account_id, destination_account_id, amount, status, failure_reason) "
                   "VALUES (%s, 900001, 900002, 10.00, 'FAILED', 'phantom demo')", (f"P3-PH-{lvl.replace(' ', '')}",))
        c2 = r.q("SELECT COUNT(*) FROM transfers WHERE source_account_id = 900001").value()
        c3 = r.q("SELECT COUNT(*) FROM transfers WHERE source_account_id = 900001 FOR UPDATE").value()
        r.q("COMMIT")
        if wres.errno == 1205:
            obs[("phantom", lvl)] = BLOCKED
            log(f"      the writer's INSERT was blocked by the reader's range lock, so the reader saw {c1} then {c2}")
        else:
            obs[("phantom", lvl)] = c1 != c2
            obs[("phantom_locking", lvl)] = c1 != c3
            log(f"      plain SELECT: {c1} then {c2}; locking read (FOR UPDATE, a 'current read'): {c3}")
        w.close(); r.close()

    log("")
    log("--- S5-D  BLOCKING: does an open reader make a writer wait? (shows the cost of SERIALIZABLE)")
    for lvl in ["REPEATABLE READ", "SERIALIZABLE"]:
        reset()
        w = Sess("writer", lock_timeout=3)
        r = Sess("reader", isolation=lvl)
        log(f"[reader isolation = {lvl}]")
        r.q("START TRANSACTION")
        r.q("SELECT balance FROM accounts WHERE account_id = 900001")
        res = w.q("UPDATE accounts SET balance = balance - 100 WHERE account_id = 900001")
        obs[("block", lvl)] = res.errno == 1205
        r.q("COMMIT")
        if res.errno == 1205:
            res2 = w.q("UPDATE accounts SET balance = balance - 100 WHERE account_id = 900001")
            log(f"      after the reader committed, the same UPDATE ran at once: {res2.describe()}")
        w.close(); r.close()

    # ---- summary table built only from the observations above
    def cell(v):
        return "no (blocked)" if v == BLOCKED else ("YES" if v else "no")

    log("")
    log("RESULT (observed in this run, MariaDB 10.4.32 InnoDB; 'no (blocked)' = the other session had to wait and timed out):")
    log(f"{'isolation level':<20}{'dirty read':<16}{'non-repeatable read':<24}{'phantom (plain SELECT)'}")
    for lvl in levels:
        log(f"{lvl:<20}{cell(obs[('dirty', lvl)]):<16}{cell(obs[('nonrep', lvl)]):<24}{cell(obs[('phantom', lvl)])}")
    log(f"{'writer blocked by an open reader?':<34}" + ", ".join(
        f"{lvl}: {'YES' if obs[('block', lvl)] else 'no'}" for lvl in ["REPEATABLE READ", "SERIALIZABLE"]))

    ser = [obs[(k, "SERIALIZABLE")] for k in ("dirty", "nonrep", "phantom")]
    check("S5-A READ UNCOMMITTED shows a dirty read; READ COMMITTED and REPEATABLE READ do not",
          obs[("dirty", "READ UNCOMMITTED")] is True and obs[("dirty", "READ COMMITTED")] is False
          and obs[("dirty", "REPEATABLE READ")] is False)
    check("S5-B READ COMMITTED gives a non-repeatable read; REPEATABLE READ does not",
          obs[("nonrep", "READ COMMITTED")] is True and obs[("nonrep", "REPEATABLE READ")] is False)
    check("S5-C READ COMMITTED shows the phantom row to a plain SELECT; REPEATABLE READ hides it from a plain SELECT",
          obs[("phantom", "READ COMMITTED")] is True and obs[("phantom", "REPEATABLE READ")] is False)
    check("S5-C at REPEATABLE READ a locking read (FOR UPDATE) DOES see the new row (current read)",
          obs[("phantom_locking", "REPEATABLE READ")] is True)
    check("S5-D SERIALIZABLE: none of the three anomalies occurred, and at least one was prevented by blocking",
          all(v is not True for v in ser) and any(v == BLOCKED for v in ser))
    check("S5-D SERIALIZABLE reader blocks a writer (lock wait timeout 1205); REPEATABLE READ reader does not",
          obs[("block", "SERIALIZABLE")] is True and obs[("block", "REPEATABLE READ")] is False)


# =============================================================================
def main():
    heading("MikePay Portfolio 3 - concurrency test run")
    a = admin()
    log(f"Server: {a.q('SELECT VERSION()', quiet=True).value()}")
    log(f"Default isolation: {a.q('SELECT @@tx_isolation', quiet=True).value()}; "
        f"innodb_lock_wait_timeout = {a.q('SELECT @@innodb_lock_wait_timeout', quiet=True).value()} s; "
        f"innodb_deadlock_detect = {a.q('SELECT @@innodb_deadlock_detect', quiet=True).value()}")
    log(f"Test data: accounts 900001-900005 only; Portfolio 2 bulk data is not touched.")
    s1_lost_update()
    s2_overdraw()
    s3_deadlock()
    s4_procedure_deadlocks()
    s5_isolation()

    reset()
    log("")
    log("Test accounts reset to their starting state.")
    heading("SUMMARY OF COMPUTED CHECKS")
    for desc, ok in CHECKS:
        log(f"{'PASS' if ok else 'FAIL'}  {desc}")
    failed = [d for d, ok in CHECKS if not ok]
    log(f"{len(CHECKS) - len(failed)} of {len(CHECKS)} checks passed.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
