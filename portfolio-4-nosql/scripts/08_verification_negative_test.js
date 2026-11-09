// Portfolio 4 - step 8: prove that 04_verify_migration.js can actually FAIL.
// A check that has never failed proves little. This script (1) tampers with one balance in the
// sample database, (2) runs the verification (it must report FAIL), (3) restores the value and
// (4) runs the verification again (it must report PASS).
//
// Run: mongosh --file 08_verification_negative_test.js --eval "var DB_NAME='mikepay_nosql_sample', DATA_DIR='../sample-data'"

const dbName = (typeof DB_NAME !== "undefined") ? DB_NAME : "mikepay_nosql_sample";
const d = db.getSiblingDB(dbName);

var NO_QUIT = true;   // lets 04_verify_migration.js report FAIL without ending this script
print("### Step 1: tamper - add 0.01 to the balance of account_id 1 (customer 1)");
d.customers.updateOne({ _id: 1, "accounts.account_id": 1 }, { $inc: { "accounts.$.balance": NumberDecimal("0.01") } });
print("### Step 2: verification must FAIL on the balance total");
load("04_verify_migration.js");
const failedAsExpected = VERIFY_FAILED > 0;

print("\n### Step 3: restore - subtract 0.01 again");
d.customers.updateOne({ _id: 1, "accounts.account_id": 1 }, { $inc: { "accounts.$.balance": NumberDecimal("-0.01") } });
print("### Step 4: verification must PASS again");
load("04_verify_migration.js");
const passedAgain = VERIFY_FAILED === 0;
print(`\nNegative test result: ${failedAsExpected && passedAgain ? "PASS (check detects tampering and passes on clean data)" : "FAIL"}`);
if (!(failedAsExpected && passedAgain)) quit(1);
