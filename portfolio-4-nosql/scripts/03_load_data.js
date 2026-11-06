// Portfolio 4 - step 3: load the exported documents into MongoDB.
//
// Run (sample):  mongosh --file 03_load_data.js --eval "var DB_NAME='mikepay_nosql_sample', DATA_DIR='../sample-data'"
// Run (bulk):    mongosh --file 03_load_data.js --eval "var DB_NAME='mikepay_nosql', DATA_DIR='../bulk-data'"
//
// Every line of each *.json file is one MongoDB Extended JSON document. EJSON.parse turns
// {"$numberDecimal": ...} into Decimal128 and {"$date": ...} into Date, so the types
// required by the validators in 02_create_collections.js are preserved. Inserts go through
// the validators: a bad document would make the load fail rather than slip in.

const fs = require("fs");
const dbName = (typeof DB_NAME !== "undefined") ? DB_NAME : "mikepay_nosql";
const dir = (typeof DATA_DIR !== "undefined") ? DATA_DIR : "../sample-data";
const d = db.getSiblingDB(dbName);
const BATCH = 5000;

print(`Loading ${dir} into database ${dbName}`);
const started = Date.now();
for (const name of ["customers", "transfers", "transactions", "audit_events"]) {
  const t0 = Date.now();
  const lines = fs.readFileSync(`${dir}/${name}.json`, "utf8").split("\n");
  let batch = [], total = 0;
  for (const line of lines) {
    if (!line) continue;
    batch.push(EJSON.parse(line));
    if (batch.length === BATCH) { d[name].insertMany(batch, { ordered: true }); total += batch.length; batch = []; }
  }
  if (batch.length) { d[name].insertMany(batch, { ordered: true }); total += batch.length; }
  print(`  ${name.padEnd(13)} ${String(total).padStart(8)} documents inserted in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
}
print(`Load finished in ${((Date.now() - started) / 1000).toFixed(1)} s`);
