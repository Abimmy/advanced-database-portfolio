// Portfolio 4 - step 5: queries and aggregation pipelines over the MikePay documents.
//
// Run: mongosh --file 05_queries_and_aggregations.js --eval "var DB_NAME='mikepay_nosql'"
//
// Each block prints the question, the MongoDB operation and the result, and notes what the
// relational equivalent would need. Results are real output; nothing here is typed by hand.

const dbName = (typeof DB_NAME !== "undefined") ? DB_NAME : "mikepay_nosql";
const d = db.getSiblingDB(dbName);
const head = (id, text) => print(`\n=== ${id}: ${text}`);
print(`Database: ${dbName}   (customers=${d.customers.estimatedDocumentCount()}, transactions=${d.transactions.estimatedDocumentCount()}, transfers=${d.transfers.estimatedDocumentCount()}, audit_events=${d.audit_events.estimatedDocumentCount()})`);

head("Q1", "Customer 1 with accounts and beneficiaries in ONE read (SQL: customers + accounts + beneficiaries + a join to resolve beneficiary names)");
print("db.customers.findOne({_id: 1})");
printjson(d.customers.findOne({ _id: 1 }));

head("Q2", "Find a customer by e-mail (served by the unique index uq_customers_email)");
print('db.customers.find({email: "tunde.bello@example.com"}, {first_name:1, last_name:1, "accounts.account_number":1})');
printjson(d.customers.find({ email: "tunde.bello@example.com" }, { first_name: 1, last_name: 1, "accounts.account_number": 1 }).toArray());

head("Q3", "Five most recent ledger entries for account 1000000001 (compound index added in step 6)");
print('db.transactions.find({account_number: "1000000001"}).sort({created_at: -1}).limit(5)');
d.transactions.find({ account_number: "1000000001" }, { type: 1, amount: 1, balance_after: 1, created_at: 1, "transfer.reference": 1, metadata: 1 })
  .sort({ created_at: -1 }).limit(5).forEach(x => printjson(x));

head("Q4", "Customers that own at least one FROZEN account (query INTO the embedded accounts array)");
print('db.customers.find({"accounts.status": "FROZEN"})');
printjson({ count: d.customers.countDocuments({ "accounts.status": "FROZEN" }),
            first_three: d.customers.find({ "accounts.status": "FROZEN" }, { first_name: 1, last_name: 1, "accounts.account_number": 1, "accounts.status": 1 }).limit(3).toArray() });

head("Q5", "Flexible schema: ledger rows grouped by type and channel; fields differ by type (atm_id only exists on ATM withdrawals)");
d.transactions.aggregate([
  { $group: { _id: { type: "$type", channel: "$metadata.channel" }, entries: { $sum: 1 }, total: { $sum: "$amount" } } },
  { $sort: { "_id.type": 1, "_id.channel": 1 } }
]).forEach(x => print(`  ${x._id.type.padEnd(16)} ${String(x._id.channel).padEnd(11)} entries=${String(x.entries).padStart(7)}  total=${x.total}`));
print('  ATM withdrawals that carry an atm_id: ' + d.transactions.countDocuments({ type: "WITHDRAWAL", "metadata.atm_id": { $exists: true } }) +
      ' of ' + d.transactions.countDocuments({ type: "WITHDRAWAL", "metadata.channel": "ATM" }) + ' ATM withdrawals');
print('  Deposits that carry an atm_id (should be 0): ' + d.transactions.countDocuments({ type: "DEPOSIT", "metadata.atm_id": { $exists: true } }));

head("Q6", "Monthly deposits vs withdrawals (aggregation: $match -> $group on year-month -> $sort). Decimal128 sums are exact");
d.transactions.aggregate([
  { $match: { type: { $in: ["DEPOSIT", "WITHDRAWAL"] } } },
  { $group: { _id: { month: { $dateToString: { format: "%Y-%m", date: "$created_at" } }, type: "$type" }, entries: { $sum: 1 }, total: { $sum: "$amount" } } },
  { $sort: { "_id.month": 1, "_id.type": 1 } }
]).forEach(x => print(`  ${x._id.month}  ${x._id.type.padEnd(11)} entries=${String(x.entries).padStart(7)}  total=${x.total}`));

head("Q7", "Top 5 customers by total balance across their accounts ($unwind the embedded array, $group, $sort, $limit)");
d.customers.aggregate([
  { $unwind: "$accounts" },
  { $group: { _id: "$_id", name: { $first: { $concat: ["$first_name", " ", "$last_name"] } }, accounts: { $sum: 1 }, total_balance: { $sum: "$accounts.balance" } } },
  { $sort: { total_balance: -1 } },
  { $limit: 5 }
]).forEach(x => print(`  customer ${String(x._id).padStart(5)}  ${x.name.padEnd(22)} accounts=${x.accounts}  total_balance=${x.total_balance}`));

head("Q8", "Failed transfers with the source customer's name ($lookup = the document-database equivalent of a JOIN)");
const failedWithSource = [
  { $match: { status: "FAILED" } },
  { $lookup: { from: "customers", localField: "source.customer_id", foreignField: "_id", as: "src" } }
];
d.transfers.aggregate([
  ...failedWithSource,
  { $match: { "src.0": { $exists: true } } },      // keep rows whose source customer is inside this data slice
  { $sort: { _id: 1 } },
  { $limit: 5 },
  { $project: { reference: 1, amount: 1, failure_reason: 1, source_customer: { $concat: [{ $arrayElemAt: ["$src.first_name", 0] }, " ", { $arrayElemAt: ["$src.last_name", 0] }] } } }
]).forEach(x => printjson(x));
const unresolved = d.transfers.aggregate([...failedWithSource, { $match: { "src.0": { $exists: false } } }, { $count: "n" }]).toArray();
print(`  (failed transfers whose SOURCE customer is outside the exported slice, so $lookup finds nothing: ${unresolved.length ? unresolved[0].n : 0};`);
print("   they are present only because their DESTINATION customer is in the slice - a limit of exporting a slice, not of MongoDB)");

head("Q9", "Failed-transfer reasons, counted");
d.transfers.aggregate([{ $match: { status: "FAILED" } }, { $group: { _id: "$failure_reason", n: { $sum: 1 } } }, { $sort: { n: -1 } }])
  .forEach(x => print(`  ${String(x._id).padEnd(32)} ${x.n}`));
