#!/usr/bin/env python3
"""
Portfolio 4 - step 1: export a slice of the MikePay relational data as MongoDB documents.

Reads mikepay_db (MariaDB, read-only SELECTs) and writes four collections as
newline-delimited MongoDB Extended JSON, one document per line:

    customers.json      customer + embedded accounts[] + embedded beneficiaries[]
    transactions.json   one document per ledger row (referenced by account_id / customer_id)
    transfers.json      one document per transfer (source / destination embedded)
    audit_events.json   one document per audit_log row
    manifest.json       counts and totals taken with SEPARATE SQL queries, used by
                        04_verify_migration.js to prove nothing was lost or altered

Usage:
    python 01_export_from_mariadb.py --max-customer-id 8     --out ../sample-data
    python 01_export_from_mariadb.py --max-customer-id 10000 --out ../bulk-data

Money is written as {"$numberDecimal": "..."} (BSON Decimal128), never as a float.
DATETIME values are stored without a time zone in MariaDB; they are written as UTC.

SYNTHETIC EXTENSION: transactions get a `metadata` sub-document (channel, ATM id,
device ...) that does NOT exist in MariaDB. It is generated deterministically from the
transaction id (same input -> same output) purely to show a flexible, per-type shape.

Test accounts used by Portfolio 3 (ids >= 900001) are never exported.
"""
import argparse
import json
import random
import sys
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

import pymysql

HOST, PORT, USER, PASSWORD, DB = "127.0.0.1", 3306, "root", "", "mikepay_db"   # XAMPP default, synthetic data only


def dec(v):
    return None if v is None else {"$numberDecimal": format(Decimal(v), "f")}


def dt(v):
    return None if v is None else {"$date": v.strftime("%Y-%m-%dT%H:%M:%SZ")}


def metadata_for(txn_id, txn_type):
    """Synthetic, deterministic, type-specific attributes (not present in MariaDB)."""
    r = random.Random(txn_id)
    if txn_type == "DEPOSIT":
        ch = r.choice(["BRANCH", "MOBILE_APP", "USSD", "AGENT"])
        m = {"channel": ch}
        if ch == "BRANCH":
            m["branch_code"] = f"BR{r.randint(1, 40):02d}"
        elif ch == "AGENT":
            m["agent_code"] = f"AG{r.randint(1, 9999):04d}"
        return m
    if txn_type == "WITHDRAWAL":
        ch = r.choice(["ATM", "POS", "BRANCH"])
        m = {"channel": ch}
        if ch == "ATM":
            m["atm_id"] = f"ATM{r.randint(1, 500):03d}"
        elif ch == "POS":
            m["merchant_category"] = r.choice(["GROCERY", "FUEL", "RESTAURANT", "TRANSPORT"])
        else:
            m["branch_code"] = f"BR{r.randint(1, 40):02d}"
        return m
    ch = r.choice(["MOBILE_APP", "WEB", "USSD"])
    m = {"channel": ch}
    if ch == "MOBILE_APP":
        m["device"] = {"os": r.choice(["ANDROID", "IOS"]), "app_version": f"{r.randint(3, 5)}.{r.randint(0, 9)}.{r.randint(0, 9)}"}
    elif ch == "WEB":
        m["device"] = {"browser": r.choice(["CHROME", "FIREFOX", "EDGE", "SAFARI"])}
    return m


def connect():
    return pymysql.connect(host=HOST, port=PORT, user=USER, password=PASSWORD, database=DB,
                           charset="utf8mb4", cursorclass=pymysql.cursors.SSDictCursor)


def stream(conn, sql, args):
    cur = conn.cursor()
    cur.execute(sql, args)
    for row in cur:
        yield row
    cur.close()


def pk_chunks(conn, table, pk, size=100000):
    """Yield every row of `table` in primary-key order, one id range at a time (no big sort)."""
    cur = conn.cursor(pymysql.cursors.DictCursor)   # buffered; one chunk is at most `size` rows
    cur.execute(f"SELECT MAX({pk}) AS m FROM {table}")
    top = cur.fetchone()["m"] or 0
    for lo in range(0, top, size):
        cur.execute(f"SELECT * FROM {table} WHERE {pk} > %s AND {pk} <= %s ORDER BY {pk}", (lo, lo + size))
        yield from cur.fetchall()
    cur.close()


def write_lines(path, docs):
    n = 0
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for d in docs:
            f.write(json.dumps(d, ensure_ascii=False, separators=(",", ":")) + "\n")
            n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-customer-id", type=int, required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    N = a.max_customer_id
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    conn = connect()
    print(f"Exporting customers with customer_id <= {N} from {DB} to {out}", flush=True)

    # ---- customers (accounts + beneficiaries embedded) -------------------------------------
    accounts, beneficiaries = {}, {}
    for r in stream(conn, "SELECT * FROM accounts WHERE customer_id <= %s ORDER BY account_id", (N,)):
        accounts.setdefault(r["customer_id"], []).append({
            "account_id": r["account_id"], "account_number": r["account_number"],
            "account_type": r["account_type"], "currency": r["currency"],
            "balance": dec(r["balance"]), "status": r["status"], "opened_at": dt(r["opened_at"])})
    for r in stream(conn, """SELECT b.*, a.account_number, c.first_name, c.last_name
                             FROM beneficiaries b
                             JOIN accounts a  ON a.account_id  = b.beneficiary_account_id
                             JOIN customers c ON c.customer_id = a.customer_id
                             WHERE b.customer_id <= %s ORDER BY b.beneficiary_id""", (N,)):
        beneficiaries.setdefault(r["customer_id"], []).append({
            "beneficiary_id": r["beneficiary_id"], "nickname": r["nickname"],
            "account_number": r["account_number"],
            "account_holder": f'{r["first_name"]} {r["last_name"]}', "added_at": dt(r["created_at"])})

    def customer_docs():
        for r in stream(conn, "SELECT * FROM customers WHERE customer_id <= %s ORDER BY customer_id", (N,)):
            yield {"_id": r["customer_id"], "first_name": r["first_name"], "last_name": r["last_name"],
                   "email": r["email"], "phone": r["phone"], "status": r["status"],
                   "created_at": dt(r["created_at"]),
                   "accounts": accounts.get(r["customer_id"], []),
                   "beneficiaries": beneficiaries.get(r["customer_id"], [])}
    n_cust = write_lines(out / "customers.json", customer_docs())
    print(f"  customers.json     {n_cust:>8}", flush=True)

    # ---- transactions ----------------------------------------------------------------------
    # The big tables are scanned by primary-key range and resolved against these in-memory lookups.
    # (A single ORDER BY + multi-way join over the 780k ledger rows ran for more than 7 minutes
    # against the 16 MB buffer pool and was abandoned.)
    acct = {r["account_id"]: (r["account_number"], r["customer_id"])
            for r in stream(conn, "SELECT account_id, account_number, customer_id FROM accounts", ())}
    xfer = {r["transfer_id"]: (r["reference"], r["source_account_id"], r["destination_account_id"])
            for r in stream(conn, "SELECT transfer_id, reference, source_account_id, destination_account_id FROM transfers", ())}

    def txn_docs():
        for r in pk_chunks(conn, "transactions", "transaction_id"):
            a = acct.get(r["account_id"])
            if a is None or a[1] > N:
                continue
            d = {"_id": r["transaction_id"], "account_id": r["account_id"],
                 "account_number": a[0], "customer_id": a[1],
                 "type": r["transaction_type"], "amount": dec(r["amount"]),
                 "balance_after": dec(r["balance_after"])}
            if r["description"] is not None:
                d["description"] = r["description"]
            d["created_at"] = dt(r["created_at"])
            if r["transfer_id"] is not None:
                ref, src, dst = xfer[r["transfer_id"]]
                counterparty = acct[dst][0] if r["transaction_type"] == "TRANSFER_DEBIT" else acct[src][0]
                d["transfer"] = {"transfer_id": r["transfer_id"], "reference": ref,
                                 "counterparty_account_number": counterparty}
            d["metadata"] = metadata_for(r["transaction_id"], r["transaction_type"])
            yield d
    n_txn = write_lines(out / "transactions.json", txn_docs())
    print(f"  transactions.json  {n_txn:>8}", flush=True)

    # ---- transfers -------------------------------------------------------------------------
    def transfer_docs():
        for r in pk_chunks(conn, "transfers", "transfer_id"):
            s, t = acct[r["source_account_id"]], acct[r["destination_account_id"]]
            if s[1] > N and t[1] > N:
                continue
            d = {"_id": r["transfer_id"], "reference": r["reference"],
                 "source": {"account_id": r["source_account_id"], "account_number": s[0], "customer_id": s[1]},
                 "destination": {"account_id": r["destination_account_id"], "account_number": t[0], "customer_id": t[1]},
                 "amount": dec(r["amount"]), "status": r["status"]}
            if r["failure_reason"] is not None:
                d["failure_reason"] = r["failure_reason"]
            d["created_at"] = dt(r["created_at"])
            if r["completed_at"] is not None:
                d["completed_at"] = dt(r["completed_at"])
            yield d
    n_tr = write_lines(out / "transfers.json", transfer_docs())
    print(f"  transfers.json     {n_tr:>8}", flush=True)

    # ---- audit events ----------------------------------------------------------------------
    def audit_docs():
        for r in pk_chunks(conn, "audit_log", "audit_id"):
            a = acct.get(r["account_id"])
            if a is None or a[1] > N:
                continue
            d = {"_id": r["audit_id"], "account_id": r["account_id"], "account_number": a[0],
                 "customer_id": a[1], "action": r["action"]}
            if r["old_balance"] is not None:
                d["old_balance"] = dec(r["old_balance"])
            d.update({"new_balance": dec(r["new_balance"]), "changed_by": r["changed_by"],
                      "changed_at": dt(r["changed_at"])})
            yield d
    n_aud = write_lines(out / "audit_events.json", audit_docs())
    print(f"  audit_events.json  {n_aud:>8}", flush=True)

    # ---- manifest: independent SQL totals, compared later inside MongoDB --------------------
    cur = conn.cursor(pymysql.cursors.DictCursor)   # buffered: the streaming cursors above are exhausted
    def one(sql, args):
        cur.execute(sql, args)
        return cur.fetchone()
    s = lambda v: format(Decimal(v), "f") if v is not None else "0"
    manifest = {
        "max_customer_id": N,
        "exported_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": f"MariaDB {one('SELECT VERSION() v', ())['v']} / {DB}",
        "counts": {"customers": n_cust, "transactions": n_txn, "transfers": n_tr, "audit_events": n_aud},
        "sql_customers": one("SELECT COUNT(*) n FROM customers WHERE customer_id <= %s", (N,))["n"],
        "sql_accounts": one("SELECT COUNT(*) n FROM accounts WHERE customer_id <= %s", (N,))["n"],
        "sql_transactions": one("SELECT COUNT(*) n FROM transactions t JOIN accounts a USING(account_id) WHERE a.customer_id <= %s", (N,))["n"],
        "sql_transfers": one("""SELECT COUNT(*) n FROM transfers t JOIN accounts sa ON sa.account_id=t.source_account_id
                                JOIN accounts da ON da.account_id=t.destination_account_id
                                WHERE sa.customer_id <= %s OR da.customer_id <= %s""", (N, N))["n"],
        "sql_audit_events": one("SELECT COUNT(*) n FROM audit_log l JOIN accounts a USING(account_id) WHERE a.customer_id <= %s", (N,))["n"],
        "sql_total_balance": s(one("SELECT SUM(balance) v FROM accounts WHERE customer_id <= %s", (N,))["v"]),
        "sql_total_txn_amount": s(one("SELECT SUM(t.amount) v FROM transactions t JOIN accounts a USING(account_id) WHERE a.customer_id <= %s", (N,))["v"]),
        "sql_total_transfer_amount": s(one("""SELECT SUM(t.amount) v FROM transfers t JOIN accounts sa ON sa.account_id=t.source_account_id
                                JOIN accounts da ON da.account_id=t.destination_account_id
                                WHERE sa.customer_id <= %s OR da.customer_id <= %s""", (N, N))["v"]),
    }
    with open(out / "manifest.json", "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print("  manifest.json written", flush=True)
    for k in ("customers", "transactions", "transfers", "audit_events"):
        sql_n = manifest["sql_" + (k if k != "audit_events" else "audit_events")]
        if manifest["counts"][k] != sql_n:
            print(f"MISMATCH {k}: exported {manifest['counts'][k]} vs SQL count {sql_n}", file=sys.stderr)
            sys.exit(1)
    conn.close()
    print("Export complete; exported counts equal independent SQL counts.")


if __name__ == "__main__":
    main()
