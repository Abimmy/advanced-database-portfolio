// Portfolio 5 - step 5: lose the MAJORITY (two of three members). Consistency is chosen over availability.
//
// Run: mongosh --quiet --nodb --file 05_no_majority_two_nodes_down.js    (from this folder; all 3 members must be up)
//
// With one member left it cannot prove it has the latest data, so it must not accept writes. Otherwise two
// halves of a split cluster could both accept writes and diverge ("split brain").

load("common.js");
requireHealthyCluster();
let pass = 0, fail = 0;
const check = (id, text, ok, detail) => { print(`${id}  ${ok ? "PASS" : "FAIL"}  ${text}${detail ? "  [" + detail + "]" : ""}`); ok ? pass++ : fail++; };

const DBN = "p5_nomajority";
const primary = findPrimary();
const secondaries = PORTS.filter(p => p !== primary.port);
const client = new Mongo(RS_URI);
client.getDB(DBN).dropDatabase();
client.getDB(DBN).ledger.insertOne({ _id: 1, note: "written while all members were up" }, { writeConcern: { w: "majority" } });
print(`primary ${primary.port}; both secondaries (${secondaries.join(", ")}) will be crashed\n`);

const t0 = Date.now();
for (const p of secondaries) print(`killed PID ${killNode(p)} (port ${p})`);

// The primary notices it can no longer see a majority and steps down by itself.
let stepDownMs = -1;
while (Date.now() - t0 < 60000) {
  const c = direct(primary.port);
  try { const h = c.getDB("admin").hello(); if (!h.isWritablePrimary) { stepDownMs = Date.now() - t0; break; } } finally { c.close(); }
  sleep(250);
}
check("N1", "the remaining member steps down from PRIMARY because it can no longer reach a majority", stepDownMs >= 0, `${stepDownMs} ms after the crashes`);

const sv = direct(primary.port);
try { sv.getDB(DBN).ledger.insertOne({ _id: 2, note: "must be refused" }); check("N2", "write to the surviving member is refused", false, "was accepted"); }
catch (e) { check("N2", "write to the surviving member is refused", e.code === 10107, `code ${e.code} ${e.codeName}: ${String(e.message).split("\n")[0]}`); }

const t2 = Date.now();
try {
  const viaRs = new Mongo(RS_URI.replace("?", "?serverSelectionTimeoutMS=5000&"));   // may already fail while connecting: no primary
  viaRs.getDB(DBN).ledger.insertOne({ _id: 3, note: "must be refused" }, { writeConcern: { w: "majority", wtimeout: 3000 } });
  check("N3", "write through the replica-set connection string fails", false, "was accepted");
} catch (e) {
  check("N3", "write through the replica-set connection string fails (no primary to send it to)", true, `${Date.now() - t2} ms; ${e.name || ""}: ${String(e.message).split("\n")[0].slice(0, 110)}`);
}

let readable = -1;
try { readable = sv.getDB(DBN).ledger.countDocuments(); } catch (e) { readable = -1; }
check("N4", "reads are still possible on the surviving member (they may be stale: it cannot confirm it is current)", readable === 1, `${readable} document(s) visible`);
sv.close();
memberTable();

print("\n--- restart both members");
const t1 = Date.now();
for (const p of secondaries) startNode(p);
const w = waitForPrimary(90000);
check("N5", "a primary is elected again once a majority is back", !!w, w ? `new primary ${w.primary.port}, ${Date.now() - t1} ms after the restart commands` : "none within 90 s");
for (const p of secondaries) waitForState(p, "SECONDARY", 90000) >= 0 || waitForState(p, "PRIMARY", 1);
const back = new Mongo(RS_URI);
back.getDB(DBN).ledger.insertOne({ _id: 4, note: "after recovery" }, { writeConcern: { w: "majority" } });
const ids = back.getDB(DBN).ledger.find({}, { _id: 1 }).sort({ _id: 1 }).toArray().map(d => d._id);
check("N6", "document 1 survived, the refused writes (2, 3) never appeared, and a new write works", JSON.stringify(ids) === "[1,4]", `ids present: ${JSON.stringify(ids)}`);
sleep(3000);
memberTable();
back.getDB(DBN).dropDatabase();
print(`\nSummary: ${pass} passed, ${fail} failed`);
if (fail) quit(1);
