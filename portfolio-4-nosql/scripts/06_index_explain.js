// Portfolio 4 - step 6: measure what indexes do in MongoDB, using explain("executionStats").
//
// Run: mongosh --file 06_index_explain.js --eval "var DB_NAME='mikepay_nosql'"
//
// For each workload the script (1) makes sure the candidate index does not exist,
// (2) runs explain("executionStats") RUNS times, (3) creates the index, (4) repeats the
// explain RUNS times and (5) prints a before/after table. These are ACTUAL executions
// (executionStats), not estimates (queryPlanner only). Wall-clock numbers depend on this
// laptop, MongoDB's cache state and other load, so the stable evidence is the plan shape and
// the documents/keys examined; milliseconds are reported as median [min-max] of RUNS runs.

const dbName = (typeof DB_NAME !== "undefined") ? DB_NAME : "mikepay_nosql";
const RUNS = (typeof RUN_COUNT !== "undefined") ? RUN_COUNT : 5;
const d = db.getSiblingDB(dbName);

const hi = d.hostInfo();
const ss = d.serverStatus();
print(`Environment: MongoDB ${d.version()} standalone, storage engine ${ss.storageEngine.name}, WiredTiger cache max ${(ss.wiredTiger.cache["maximum bytes configured"] / 1048576).toFixed(0)} MB`);
print(`Host: ${hi.system.cpuArch}, ${hi.system.numCores} cores, ${hi.system.memSizeMB} MB RAM, ${hi.os.name} ${hi.os.version}`);
print(`Data: ${dbName}: customers=${d.customers.countDocuments()}, transactions=${d.transactions.countDocuments()}, audit_events=${d.audit_events.countDocuments()}\n`);

function chain(p) {                        // winning plan as "LIMIT > FETCH > IXSCAN(index)"
  if (!p) return "";
  if (p.queryPlan) p = p.queryPlan;        // newer servers wrap the classic plan
  let s = p.stage + (p.indexName ? `(${p.indexName})` : "");
  if (p.inputStage) s += " > " + chain(p.inputStage);
  if (p.inputStages) s += " > [" + p.inputStages.map(chain).join(" | ") + "]";
  return s;
}
const median = a => { const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)]; };

function measure(makeCursor) {
  const ms = []; let last;
  for (let i = 0; i < RUNS; i++) {
    last = makeCursor().explain("executionStats");
    ms.push(last.executionStats.executionTimeMillis);
  }
  const es = last.executionStats;
  return { plan: chain(last.queryPlanner.winningPlan), keys: es.totalKeysExamined, docs: es.totalDocsExamined, returned: es.nReturned,
           ms: `${median(ms)} [${Math.min(...ms)}-${Math.max(...ms)}]` };
}

// Real parameter values taken from the data so every workload returns rows.
const refDoc = d.transactions.find({ "transfer.reference": { $exists: true } }).sort({ _id: 1 }).limit(1).toArray()[0];   // lowest _id: same value every run
const REF_W2 = refDoc ? refDoc.transfer.reference : "none";
const busy = d.transactions.aggregate([{ $group: { _id: "$account_id", n: { $sum: 1 } } }, { $sort: { n: -1, _id: 1 } }, { $limit: 1 }]).toArray()[0];
const ACC = busy._id;
print(`Parameters: W1/W4 account_id=${ACC} (the account with the most ledger entries: ${busy.n}); W2 reference=${REF_W2}\n`);

const workloads = [
  { id: "W1", text: "last 10 ledger entries for one account (the customer statement screen)",
    coll: "transactions", index: { account_id: 1, created_at: -1 }, name: "ix_txn_account_created", opts: {},
    query: () => d.transactions.find({ account_id: ACC }).sort({ created_at: -1 }).limit(10) },
  { id: "W2", text: "look up the ledger entries of one transfer by its reference (partial index: only rows that have a transfer)",
    coll: "transactions", index: { "transfer.reference": 1 }, name: "ix_txn_transfer_reference",
    opts: { partialFilterExpression: { "transfer.reference": { $exists: true } } },
    query: () => d.transactions.find({ "transfer.reference": REF_W2 }) },
  { id: "W3", text: "customers with a FROZEN account (query into an embedded array -> multikey index)",
    coll: "customers", index: { "accounts.status": 1 }, name: "ix_cust_account_status", opts: {},
    query: () => d.customers.find({ "accounts.status": "FROZEN" }) },
  { id: "W4", text: "audit events for one account in a date range",
    coll: "audit_events", index: { account_id: 1, changed_at: 1 }, name: "ix_audit_account_changed", opts: {},
    query: () => d.audit_events.find({ account_id: ACC, changed_at: { $gte: new Date("2026-11-01T00:00:00Z") } }) },
];

const results = [];
for (const w of workloads) {
  try { d[w.coll].dropIndex(w.name); } catch (e) { /* not present */ }
  const before = measure(w.query);
  const t0 = Date.now();
  d[w.coll].createIndex(w.index, Object.assign({ name: w.name }, w.opts));
  const buildMs = Date.now() - t0;
  const after = measure(w.query);
  results.push({ w, before, after, buildMs });
}

for (const { w, before, after, buildMs } of results) {
  print(`--- ${w.id}: ${w.text}`);
  print(`    index: createIndex(${JSON.stringify(w.index)}${Object.keys(w.opts).length ? ", " + JSON.stringify(w.opts) : ""})  built in ${buildMs} ms`);
  print(`    BEFORE  plan: ${before.plan}`);
  print(`            keysExamined=${before.keys}  docsExamined=${before.docs}  returned=${before.returned}  time ms (median [min-max] of ${RUNS}): ${before.ms}`);
  print(`    AFTER   plan: ${after.plan}`);
  print(`            keysExamined=${after.keys}  docsExamined=${after.docs}  returned=${after.returned}  time ms (median [min-max] of ${RUNS}): ${after.ms}\n`);
}

print("Index storage cost (bytes) after the four indexes:");
for (const c of ["customers", "transactions", "audit_events"]) {
  const st = d[c].stats();
  print(`  ${c.padEnd(13)} data=${st.size}  storage=${st.storageSize}  totalIndexSize=${st.totalIndexSize}  ` + JSON.stringify(st.indexSizes));
}
