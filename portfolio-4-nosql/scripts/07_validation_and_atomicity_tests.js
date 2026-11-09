// Portfolio 4 - step 7: validation, uniqueness, atomic single-document updates and the
// multi-document transaction limitation. Every result below is read from the server's reply.
//
// Run: mongosh --file 07_validation_and_atomicity_tests.js --eval "var DB_NAME='mikepay_nosql_sample'"
// It creates and removes its own throw-away documents (customer _id 900001, 900002, ledger _id 9000001).

const dbName = (typeof DB_NAME !== "undefined") ? DB_NAME : "mikepay_nosql_sample";
const d = db.getSiblingDB(dbName);
print(`Database: ${dbName}   MongoDB ${d.version()}\n`);

const goodCustomer = (id, email, accNo) => ({
  _id: id, first_name: "Test", last_name: "Person", email, phone: "08099999999", status: "ACTIVE",
  created_at: new Date(), beneficiaries: [],
  accounts: [{ account_id: id, account_number: accNo, account_type: "CURRENT", currency: "NGN",
               balance: NumberDecimal("1000.00"), status: "ACTIVE", opened_at: new Date() }]
});
const goodTxn = () => ({ _id: 9000001, account_id: 1, account_number: "1000000001", customer_id: 1, type: "DEPOSIT",
                         amount: NumberDecimal("10.00"), balance_after: NumberDecimal("10.00"), created_at: new Date() });

let pass = 0, fail = 0;
function expectReject(id, text, fn, wantCode) {
  try { fn(); print(`${id}  FAIL  ${text}: the insert was ACCEPTED`); fail++; }
  catch (e) {
    const ok = e.code === wantCode;
    print(`${id}  ${ok ? "PASS" : "FAIL"}  ${text}\n        -> rejected: code ${e.code} ${e.codeName || ""} - ${String(e.message).split("\n")[0]}`);
    ok ? pass++ : fail++;
  }
}
function expectAccept(id, text, fn) {
  try { fn(); print(`${id}  PASS  ${text}: accepted`); pass++; }
  catch (e) { print(`${id}  FAIL  ${text}: rejected - ${e.message}`); fail++; }
}

// clean up leftovers from an earlier run
d.customers.deleteMany({ _id: { $gte: 900001 } });
d.transactions.deleteMany({ _id: { $gte: 9000001 } });

print("--- Schema validation ($jsonSchema, code 121 = DocumentValidationFailure)");
let bad = goodCustomer(900001, "v1@example.com", "9100000001"); bad.accounts[0].balance = 1000.5;           // a JavaScript double
expectReject("V1", "balance stored as a floating-point double instead of Decimal128", () => d.customers.insertOne(bad), 121);
bad = goodCustomer(900001, "v2@example.com", "9100000001"); delete bad.email;
expectReject("V2", "required field `email` missing", () => d.customers.insertOne(bad), 121);
bad = goodCustomer(900001, "v3@example.com", "9100000001"); bad.accounts[0].status = "DORMANT";
expectReject("V3", "account status outside ACTIVE/FROZEN/CLOSED", () => d.customers.insertOne(bad), 121);
bad = goodCustomer(900001, "v4@example.com", "91-bad");
expectReject("V4", "account number is not 10 digits", () => d.customers.insertOne(bad), 121);
bad = goodTxn(); bad.amount = NumberDecimal("-5.00");
expectReject("V5", "ledger amount is negative (minimum 0.01)", () => d.transactions.insertOne(bad), 121);
bad = goodTxn(); bad.amount = NumberDecimal("0.00");
expectReject("V6", "ledger amount is zero", () => d.transactions.insertOne(bad), 121);
bad = goodTxn(); bad.type = "REFUND";
expectReject("V7", "unknown ledger type", () => d.transactions.insertOne(bad), 121);

print("\n--- Uniqueness (code 11000 = duplicate key)");
expectAccept("U0", "a valid new customer 900001", () => d.customers.insertOne(goodCustomer(900001, "t900001@example.com", "9100000001")));
expectReject("U1", "second customer with the same e-mail", () => d.customers.insertOne(goodCustomer(900002, "t900001@example.com", "9100000002")), 11000);
expectReject("U2", "second customer with the same account number", () => d.customers.insertOne(goodCustomer(900002, "t900002@example.com", "9100000001")), 11000);

print("\n--- Flexible schema");
expectAccept("F1", "ledger row with a brand-new nested field metadata.fraud_score (no ALTER TABLE, no migration)",
  () => d.transactions.insertOne(Object.assign(goodTxn(), { metadata: { channel: "WEB", fraud_score: 0.07, device: { browser: "EDGE" } } })));

print("\n--- Atomic single-document update (debit on customer 900001's account, balance 1000.00)");
const debit = amt => d.customers.updateOne(
  { _id: 900001, accounts: { $elemMatch: { account_id: 900001, status: "ACTIVE", balance: { $gte: NumberDecimal(amt) } } } },
  { $inc: { "accounts.$.balance": NumberDecimal("-" + amt) } });
const bal = () => d.customers.findOne({ _id: 900001 }).accounts[0].balance.toString();
let r = debit("300.00");
print(`A1  debit 300.00 -> matched=${r.matchedCount} modified=${r.modifiedCount}, balance now ${bal()}  ${r.modifiedCount === 1 && bal() === "700.00" ? "PASS" : "FAIL"}`);
(r.modifiedCount === 1 && bal() === "700.00") ? pass++ : fail++;
r = debit("900.00");
print(`A2  debit 900.00 -> matched=${r.matchedCount} modified=${r.modifiedCount}, balance still ${bal()}  ${r.matchedCount === 0 && bal() === "700.00" ? "PASS" : "FAIL"} (the guard in the filter refused it: insufficient funds)`);
(r.matchedCount === 0 && bal() === "700.00") ? pass++ : fail++;

// Concurrent clients are tested separately in 09_concurrent_debits.sh (10 parallel mongosh processes).

print("\n--- Multi-document transaction on this deployment (needed to move money between TWO customer documents)");
// The first read inside the transaction (read the balance, then write it) is what the server refuses.
const session = db.getMongo().startSession();
try {
  session.startTransaction();
  const sc = session.getDatabase(dbName).customers;
  sc.findOne({ _id: 900001 });
  sc.updateOne({ _id: 900001 }, { $inc: { "accounts.0.balance": NumberDecimal("-10.00") } });
  session.commitTransaction();
  print("T1  FAIL  the transaction was accepted (unexpected on a standalone server)"); fail++;
} catch (e) {
  const ok = e.code === 20;   // 20 = IllegalOperation
  print(`T1  ${ok ? "PASS" : "FAIL"}  multi-document transaction refused: code ${e.code} ${e.codeName || ""} - ${String(e.message).split("\n")[0]}`);
  ok ? pass++ : fail++;
  try { session.abortTransaction(); } catch (_) {}
} finally { session.endSession(); }
print(`    balance after the refused transaction: ${bal()} (unchanged)`);

d.customers.deleteMany({ _id: { $gte: 900001 } });
d.transactions.deleteMany({ _id: { $gte: 9000001 } });
print(`\nSummary: ${pass} passed, ${fail} failed`);
if (fail) quit(1);   // mongosh ignores process.exitCode
