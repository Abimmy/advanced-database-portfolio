// Portfolio 4 - step 4: prove the MongoDB data matches MariaDB.
//
// The manifest.json written by 01_export_from_mariadb.py holds counts and totals taken with
// SEPARATE SQL queries. Here the same figures are recomputed INSIDE MongoDB (aggregation) and
// compared. Decimal128 sums are exact, so the comparison is string-exact, not "close enough".
//
// Run: mongosh --file 04_verify_migration.js --eval "var DB_NAME='mikepay_nosql', DATA_DIR='../bulk-data'"

const fs = require("fs");
const dbName = (typeof DB_NAME !== "undefined") ? DB_NAME : "mikepay_nosql";
const dir = (typeof DATA_DIR !== "undefined") ? DATA_DIR : "../sample-data";
const d = db.getSiblingDB(dbName);
const m = JSON.parse(fs.readFileSync(`${dir}/manifest.json`, "utf8"));
print(`Manifest: ${m.source}, customer_id <= ${m.max_customer_id}, exported ${m.exported_at_utc}\n`);

const sumOf = (coll, field) => { const r = d[coll].aggregate([{ $group: { _id: null, s: { $sum: field } } }]).toArray(); return r.length ? r[0].s.toString() : "0"; };
const money = s => { const [i, f = ""] = String(s).split("."); return f ? `${i}.${(f + "00").slice(0, 2)}` : `${i}.00`; };

const checks = [
  ["customers count",            d.customers.countDocuments(),    m.sql_customers],
  ["accounts (embedded) count",  d.customers.aggregate([{ $unwind: "$accounts" }, { $count: "n" }]).toArray()[0].n, m.sql_accounts],
  ["transactions count",         d.transactions.countDocuments(), m.sql_transactions],
  ["transfers count",            d.transfers.countDocuments(),    m.sql_transfers],
  ["audit_events count",         d.audit_events.countDocuments(), m.sql_audit_events],
  ["SUM(account balances)",      money(d.customers.aggregate([{ $unwind: "$accounts" }, { $group: { _id: null, s: { $sum: "$accounts.balance" } } }]).toArray()[0].s.toString()), m.sql_total_balance],
  ["SUM(transaction amounts)",   money(sumOf("transactions", "$amount")), m.sql_total_txn_amount],
  ["SUM(transfer amounts)",      money(sumOf("transfers", "$amount")),    m.sql_total_transfer_amount],
];

let failed = 0;
print("check".padEnd(30) + "MongoDB".padStart(20) + "MariaDB (manifest)".padStart(22) + "  result");
for (const [name, got, want] of checks) {
  const ok = String(got) === String(want);
  if (!ok) failed++;
  print(name.padEnd(30) + String(got).padStart(20) + String(want).padStart(22) + (ok ? "  PASS" : "  FAIL"));
}

// Structural check: no ledger row may point at an account that no customer document contains.
const accIds = new Set(d.customers.aggregate([{ $unwind: "$accounts" }, { $project: { _id: 0, id: "$accounts.account_id" } }]).toArray().map(x => x.id));
const orphans = d.transactions.aggregate([{ $group: { _id: "$account_id" } }]).toArray().filter(x => !accIds.has(x._id)).length;
print("orphan transactions (account_id not embedded in any customer)".padEnd(62) + String(orphans).padStart(6) + (orphans === 0 ? "  PASS" : "  FAIL"));
if (orphans) failed++;

print(failed === 0 ? "\nALL CHECKS PASSED" : `\n${failed} CHECK(S) FAILED`);
// mongosh ignores process.exitCode, so quit(1) is what gives a non-zero exit status. 08_verification_negative_test.js
// loads this file on purpose with NO_QUIT set and reads VERIFY_FAILED instead.
var VERIFY_FAILED = failed;
if (failed && typeof NO_QUIT === "undefined") quit(1);
