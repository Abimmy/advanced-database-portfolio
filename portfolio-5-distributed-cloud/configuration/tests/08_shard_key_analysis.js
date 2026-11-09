// Portfolio 5 - step 8: SHARD-KEY ANALYSIS ON EXISTING DATA. This is an analysis, NOT a sharded cluster.
//
// Run: mongosh --quiet --nodb --file 08_shard_key_analysis.js    (read-only; uses the Portfolio 4 database on the original
//      MongoDB service, port 27017, which holds the 282,620-row ledger)
//
// No shards, config servers or mongos router were created. The script only COUNTS how the existing documents would be
// spread over 4 hypothetical shards if different shard keys were chosen, to show why the key matters.

const c = new Mongo("mongodb://127.0.0.1:27017/?directConnection=true");
const t = c.getDB("mikepay_nosql").transactions;
const B = 4;
const total = t.countDocuments();
print(`ledger documents analysed: ${total}; hypothetical shards: ${B}\n`);

const spread = (title, pipelineGroupExpr, filter) => {
  const rows = t.aggregate([{ $match: filter || {} }, { $group: { _id: pipelineGroupExpr, n: { $sum: 1 } } }, { $sort: { _id: 1 } }]).toArray();
  const sum = rows.reduce((a, r) => a + r.n, 0), max = Math.max(...rows.map(r => r.n)), min = Math.min(...rows.map(r => r.n));
  print(`${title}`);
  for (const r of rows) print(`  shard ${r._id}: ${String(r.n).padStart(7)} documents (${(100 * r.n / sum).toFixed(1)}%)  ${"#".repeat(Math.round(40 * r.n / sum))}`);
  print(`  busiest shard holds ${(100 * max / sum).toFixed(1)}% of ${sum} documents (even split would be ${(100 / B).toFixed(1)}%); smallest ${(100 * min / sum).toFixed(1)}%\n`);
  return { max: max / sum, rows: rows.length };
};

// Key 1: hashed(account_id) - the hash value is spread evenly across the 4 hypothetical shards.
const hashed = { $mod: [{ $abs: { $toHashedIndexKey: "$account_id" } }, B] };
const k1 = spread("K1  hashed account_id (all documents)", hashed);

// Key 2: range on account_id - 4 equal-width ranges of the id space.
const idr = t.aggregate([{ $group: { _id: null, lo: { $min: "$account_id" }, hi: { $max: "$account_id" } } }]).toArray()[0];
const idw = (idr.hi - idr.lo + 1) / B;
const k2 = spread(`K2  range on account_id (id space ${idr.lo}..${idr.hi}, equal-width ranges)`,
  { $min: [B - 1, { $floor: { $divide: [{ $subtract: ["$account_id", idr.lo] }, idw] } }] });

// Key 3: range on created_at - equal-width time ranges over the whole history.
const tr = t.aggregate([{ $group: { _id: null, lo: { $min: "$created_at" }, hi: { $max: "$created_at" } } }]).toArray()[0];
const tw = (tr.hi - tr.lo) / B;
const timeBucket = { $min: [B - 1, { $floor: { $divide: [{ $subtract: ["$created_at", tr.lo] }, tw] } }] };
print(`History runs ${tr.lo.toISOString().slice(0, 10)} .. ${tr.hi.toISOString().slice(0, 10)}`);
const k3 = spread("K3  range on created_at (all documents)", timeBucket);

// WRITES arrive at the newest end of time. Where would the most recent 30 days of ledger rows (= today's write load) go?
const since = new Date(tr.hi.getTime() - 30 * 86400000);
print(`Write-load view: only the newest 30 days (created_at >= ${since.toISOString().slice(0, 10)}), i.e. where NEW writes land\n`);
const w1 = spread("K1w hashed account_id, newest 30 days", hashed, { created_at: { $gte: since } });
const w3 = spread("K3w range on created_at, newest 30 days", timeBucket, { created_at: { $gte: since } });

// One customer's data: the busiest account.
const busy = t.aggregate([{ $group: { _id: "$account_id", n: { $sum: 1 } } }, { $sort: { n: -1, _id: 1 } }, { $limit: 1 }]).toArray()[0];
const avg = t.aggregate([{ $group: { _id: null, b: { $avg: { $bsonSize: "$$ROOT" } } } }]).toArray()[0].b;
print(`Busiest account ${busy._id}: ${busy.n} ledger documents = ${(100 * busy.n / total).toFixed(2)}% of the collection, about ${(busy.n * avg / 1048576).toFixed(2)} MB ` +
      `(average document ${avg.toFixed(0)} bytes). Default maximum chunk size is 128 MB, so one account cannot form an unsplittable "jumbo" chunk.\n`);

let pass = 0, fail = 0;
const check = (id, text, ok, detail) => { print(`${id}  ${ok ? "PASS" : "FAIL"}  ${text}${detail ? "  [" + detail + "]" : ""}`); ok ? pass++ : fail++; };
check("S1", "hashed account_id spreads all data evenly (busiest shard below 30%)", k1.max < 0.30, `${(100 * k1.max).toFixed(1)}%`);
check("S2", "hashed account_id also spreads the newest 30 days of writes evenly (busiest shard below 30%)", w1.max < 0.30, `${(100 * w1.max).toFixed(1)}%`);
check("S3", "range on created_at sends the newest 30 days of writes to ONE shard (hot spot: more than 90%)", w3.max > 0.90, `${(100 * w3.max).toFixed(1)}%`);
print(`\nSummary: ${pass} passed, ${fail} failed`);
if (fail) quit(1);
