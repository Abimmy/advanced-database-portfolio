// Portfolio 5 - step 2: is the data on every member identical, can secondaries be written to, how far behind are they?
//
// Precondition: the Portfolio 4 sample data is loaded into database mikepay_nosql_rs through the replica-set URI
// (run_evidence.sh does this with the Portfolio 4 scripts 02_create_collections.js and 03_load_data.js).
// Run: mongosh --quiet --nodb --file 02_replication_and_reads.js

load("common.js");
requireHealthyCluster();
const DBN = "mikepay_nosql_rs";
let pass = 0, fail = 0;
const check = (id, text, ok, detail) => { print(`${id}  ${ok ? "PASS" : "FAIL"}  ${text}${detail ? "  [" + detail + "]" : ""}`); ok ? pass++ : fail++; };

const primary = findPrimary();
print(`primary: ${primary.host}\n`);
memberTable();

print("\n--- R1: every member holds the same data (dbHash = an MD5 of each collection, computed on each member separately)");
const perNode = {};
for (const p of PORTS) {
  const c = direct(p);
  const d = c.getDB(DBN);
  const h = d.runCommand({ dbHash: 1 });
  const counts = {};
  for (const name of ["customers", "transactions", "transfers", "audit_events"]) counts[name] = d[name].countDocuments();
  const bal = d.customers.aggregate([{ $unwind: "$accounts" }, { $group: { _id: null, s: { $sum: "$accounts.balance" } } }]).toArray()[0].s.toString();
  perNode[p] = { hashes: h.collections, counts, bal };
  print(`  node ${p}: counts ${JSON.stringify(counts)}  total balance ${bal}`);
  for (const name of Object.keys(h.collections).sort()) print(`           md5 ${name.padEnd(13)} ${h.collections[name]}`);
  c.close();
}
const ref = perNode[PORTS[0]];
for (const p of PORTS.slice(1)) {
  check("R1", `node ${p} collection hashes equal node ${PORTS[0]}`, JSON.stringify(perNode[p].hashes) === JSON.stringify(ref.hashes));
  check("R1", `node ${p} counts and balance total equal node ${PORTS[0]}`, JSON.stringify(perNode[p].counts) === JSON.stringify(ref.counts) && perNode[p].bal === ref.bal);
}
check("R1", "customer balance total equals the Portfolio 4 sample figure from MariaDB (1969999.50)", ref.bal === "1969999.50", ref.bal);

print("\n--- R2: secondaries refuse writes (only the primary accepts them)");
const sec = PORTS.find(p => p !== primary.port);
const sc = direct(sec);
try { sc.getDB(DBN).customers.insertOne({ _id: 999999 }); check("R2", `insert on secondary ${sec}`, false, "was accepted"); }
catch (e) { check("R2", `insert on secondary ${sec} is refused`, e.code === 10107, `code ${e.code} ${e.codeName}: ${String(e.message).split("\n")[0]}`); }
sc.close();

print("\n--- R3: replication lag under a write burst (20,000 documents, w:1 = acknowledged by the primary only)");
const client = new Mongo(RS_URI);
const coll = client.getDB("p5_lag").burst;
coll.drop();
const N = 20000, BATCH = 1000, pad = "x".repeat(100);
const t0 = Date.now();
for (let i = 0; i < N; i += BATCH) {
  const docs = []; for (let j = i; j < i + BATCH; j++) docs.push({ _id: j, payload: pad, n: j });
  coll.insertMany(docs, { writeConcern: { w: 1 } });
}
const tAck = Date.now();
print(`  primary acknowledged ${N} documents in ${tAck - t0} ms`);
const secondaries = PORTS.filter(p => p !== primary.port);
let maxLag = 0;
for (const p of secondaries) {
  const c = direct(p);
  const cnt = () => c.getDB("p5_lag").burst.countDocuments();
  let n = cnt();
  while (n < N && Date.now() - tAck < 60000) { sleep(20); n = cnt(); }
  const lag = Date.now() - tAck;
  if (n === N) maxLag = Math.max(maxLag, lag);
  print(`  secondary ${p}: ${n} of ${N} documents visible, ${n === N ? "complete" : "NOT complete"} ${lag} ms after the last acknowledgement (poll granularity about 20-30 ms)`);
  c.close();
  check("R3", `secondary ${p} received all ${N} documents`, n === N);
}
const info = client.getDB("admin").runCommand({ replSetGetStatus: 1 });
print("  member optimes after the burst: " + info.members.map(m => `${m.name}=${m.optimeDate.toISOString()}`).join("  "));
client.getDB("p5_lag").dropDatabase();

print(`\nSummary: ${pass} passed, ${fail} failed`);
if (fail) quit(1);
