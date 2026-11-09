// Portfolio 5 - step 6: the fund transfer that Portfolio 4's standalone MongoDB refused (error 20), now on the replica set.
//
// Run: mongosh --quiet --nodb --file 06_multi_document_transactions.js    (from this folder; replica set up and the
//      mikepay_nosql_rs database loaded, see run_evidence.sh)
//
// A transfer changes TWO customer documents (debit one account, credit another) and adds two ledger documents.
// A multi-document transaction makes those four writes all-or-nothing.
// Uses throw-away customers 900001 and 900002 (ledger _id 9100001+) and removes them at the end.

load("common.js");
requireHealthyCluster();
let pass = 0, fail = 0;
const check = (id, text, ok, detail) => { print(`${id}  ${ok ? "PASS" : "FAIL"}  ${text}${detail ? "  [" + detail + "]" : ""}`); ok ? pass++ : fail++; };

const DBN = "mikepay_nosql_rs";
const client = new Mongo(RS_URI);       // the transactional client
const observer = new Mongo(RS_URI);     // a second, independent client that only reads
const cust = client.getDB(DBN).customers, led = client.getDB(DBN).transactions;
const A = 900001, B = 900002;

const mk = (id, email, accNo, bal) => ({
  _id: id, first_name: "Test", last_name: "Person", email, phone: "08099999999", status: "ACTIVE", created_at: new Date(), beneficiaries: [],
  accounts: [{ account_id: id, account_number: accNo, account_type: "CURRENT", currency: "NGN", balance: NumberDecimal(bal), status: "ACTIVE", opened_at: new Date() }]
});
const cleanup = () => { cust.deleteMany({ _id: { $in: [A, B] } }); led.deleteMany({ _id: { $gte: 9100001 } }); };
const bal = (who, id) => who.getDB(DBN).customers.findOne({ _id: id }).accounts[0].balance.toString();
const total = () => { const a = cust.findOne({ _id: A }).accounts[0].balance, b = cust.findOne({ _id: B }).accounts[0].balance;
  return cust.aggregate([{ $match: { _id: { $in: [A, B] } } }, { $unwind: "$accounts" }, { $group: { _id: null, s: { $sum: "$accounts.balance" } } }]).toArray()[0].s.toString(); };
const legs = () => led.countDocuments({ _id: { $gte: 9100001 } });

cleanup();
cust.insertOne(mk(A, "tx-a@example.com", "9200000001", "1000.00"), { writeConcern: { w: "majority" } });
cust.insertOne(mk(B, "tx-b@example.com", "9200000002", "500.00"), { writeConcern: { w: "majority" } });
print(`start: A=${bal(client, A)}  B=${bal(client, B)}  total=${total()}\n`);

// One transfer = debit A (guarded), credit B, two ledger rows, all inside one transaction.
function transfer(session, amount, ledgerBase, opts) {
  opts = opts || {};
  const sdb = session.getDatabase(DBN), amt = NumberDecimal(amount), neg = NumberDecimal("-" + amount);
  session.startTransaction({ readConcern: { level: "snapshot" }, writeConcern: { w: "majority" } });
  try {
    const d = sdb.customers.updateOne({ _id: A, accounts: { $elemMatch: { account_id: A, status: "ACTIVE", balance: { $gte: amt } } } }, { $inc: { "accounts.$.balance": neg } });
    if (d.modifiedCount !== 1) throw new Error("insufficient funds or inactive account");
    sdb.customers.updateOne({ _id: B, "accounts.account_id": B }, { $inc: { "accounts.$.balance": amt } });
    const balA = sdb.customers.findOne({ _id: A }).accounts[0].balance, balB = sdb.customers.findOne({ _id: B }).accounts[0].balance;
    sdb.transactions.insertOne({ _id: ledgerBase, account_id: A, account_number: "9200000001", customer_id: A, type: "TRANSFER_DEBIT", amount: amt, balance_after: balA, created_at: new Date() });
    sdb.transactions.insertOne({ _id: ledgerBase + 1, account_id: B, account_number: "9200000002", customer_id: B,
                                 type: "TRANSFER_CREDIT", amount: opts.breakLastStep ? NumberDecimal("-1.00") : amt, balance_after: balB, created_at: new Date() });
    if (opts.beforeCommit) opts.beforeCommit();
    session.commitTransaction();
    return "COMMITTED";
  } catch (e) {
    try { session.abortTransaction(); } catch (_) {}
    return "ABORTED: " + String(e.message).split("\n")[0] + (e.code ? ` (code ${e.code})` : "");
  }
}

print("--- X1: a successful transfer of 250.00 (two customer documents + two ledger documents in one transaction)");
let s = client.startSession(), seenMid = null;
let r = transfer(s, "250.00", 9100001, { beforeCommit: () => { seenMid = { A: bal(observer, A), B: bal(observer, B), legs: observer.getDB(DBN).transactions.countDocuments({ _id: { $gte: 9100001 } }) }; } });
s.endSession();
check("X1", "the transaction commits (on the standalone server of Portfolio 4 this was refused with code 20)", r === "COMMITTED", r);
check("X2", "before the commit another client still sees the OLD balances and no ledger rows (isolation)", seenMid.A === "1000.00" && seenMid.B === "500.00" && seenMid.legs === 0, JSON.stringify(seenMid));
check("X3", "after the commit everybody sees A=750.00, B=750.00, two ledger rows", bal(observer, A) === "750.00" && bal(observer, B) === "750.00" && legs() === 2, `A=${bal(observer, A)} B=${bal(observer, B)} ledger=${legs()}`);
check("X4", "money is conserved", total() === "1500.00", `total ${total()}`);

print("\n--- X5: a transfer whose LAST step fails (ledger credit row with a negative amount is rejected by the validator)");
s = client.startSession();
r = transfer(s, "100.00", 9100003, { breakLastStep: true });
s.endSession();
check("X5", "the transaction is aborted", r.startsWith("ABORTED"), r);
check("X6", "debit and credit were both undone: A=750.00, B=750.00, still 2 ledger rows", bal(client, A) === "750.00" && bal(client, B) === "750.00" && legs() === 2, `A=${bal(client, A)} B=${bal(client, B)} ledger=${legs()}`);
check("X7", "money is conserved", total() === "1500.00", `total ${total()}`);

print("\n--- X8: insufficient funds (transfer 5000.00 from A who has 750.00)");
s = client.startSession();
r = transfer(s, "5000.00", 9100005);
s.endSession();
check("X8", "the guarded debit refuses and the whole transaction is aborted", r.startsWith("ABORTED") && /insufficient/i.test(r) && bal(client, A) === "750.00" && bal(client, B) === "750.00", r);

print("\n--- X9: two transactions touch the same customer document at the same time");
const s1 = client.startSession(), s2 = client.startSession();
s1.startTransaction({ writeConcern: { w: "majority" } });
s1.getDatabase(DBN).customers.updateOne({ _id: A }, { $inc: { "accounts.0.balance": NumberDecimal("-10.00") } });
s2.startTransaction({ writeConcern: { w: "majority" } });
let conflict = null;
try { s2.getDatabase(DBN).customers.updateOne({ _id: A }, { $inc: { "accounts.0.balance": NumberDecimal("-20.00") } }); }
catch (e) { conflict = e; }
check("X9", "the second transaction is stopped at once with a WriteConflict (no waiting, no lost update)", !!conflict && conflict.code === 112,
      conflict ? `code ${conflict.code} ${conflict.codeName}; labels ${JSON.stringify(conflict.errorLabels)}` : "no conflict raised");
try { s2.abortTransaction(); } catch (_) {}
s1.commitTransaction();
s2.startTransaction({ writeConcern: { w: "majority" } });
s2.getDatabase(DBN).customers.updateOne({ _id: A }, { $inc: { "accounts.0.balance": NumberDecimal("-20.00") } });
s2.commitTransaction();
check("X10", "after the first commits, the retried second transaction succeeds; balance 750.00 - 10.00 - 20.00 = 720.00", bal(client, A) === "720.00", `A=${bal(client, A)}`);
s1.endSession(); s2.endSession();

cleanup();
print(`\ncleanup done: throw-away customers ${A}, ${B} and ledger rows removed`);
print(`Summary: ${pass} passed, ${fail} failed`);
if (fail) quit(1);
