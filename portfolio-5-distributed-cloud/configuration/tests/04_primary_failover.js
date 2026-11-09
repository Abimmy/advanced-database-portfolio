// Portfolio 5 - step 4: crash the PRIMARY and measure what happens.
//
// Run: mongosh --quiet --nodb --file 04_primary_failover.js    (from this folder; all 3 members must be up)
//
// Measured: time until another member becomes primary, time until a client write succeeds again, whether any
// acknowledged (w:majority) write was lost, and whether the crashed member rejoins and catches up.

load("common.js");
requireHealthyCluster();
let pass = 0, fail = 0;
const check = (id, text, ok, detail) => { print(`${id}  ${ok ? "PASS" : "FAIL"}  ${text}${detail ? "  [" + detail + "]" : ""}`); ok ? pass++ : fail++; };

const client = new Mongo(RS_URI);
const DBN = "p5_failover";
client.getDB(DBN).dropDatabase();
const coll = client.getDB(DBN).acked;

const old = findPrimary();
const termOf = port => { const c = direct(port); try { return c.getDB("admin").runCommand({ replSetGetStatus: 1 }).term; } finally { c.close(); } };
const termBefore = termOf(old.port);
print(`primary before the crash: ${old.host} (election term ${termBefore})\n`);

// 50 writes acknowledged with w:majority before the crash: these must all survive.
const acked = [];
for (let i = 1; i <= 50; i++) { coll.insertOne({ _id: i, at: new Date() }, { writeConcern: { w: "majority" } }); acked.push(i); }
print(`wrote and got acknowledgement (w:majority) for ids 1..50`);

print(`\n--- crash the primary on port ${old.port}`);
const t0 = Date.now();
const pid = killNode(old.port);
print(`killed PID ${pid} at t=0`);

const electedAfter = (() => {
  // poll the two surviving members until one reports itself PRIMARY
  const survivors = PORTS.filter(p => p !== old.port);
  while (Date.now() - t0 < 90000) {
    for (const p of survivors) {
      let c; try { c = direct(p); if (c.getDB("admin").hello().isWritablePrimary) return { port: p, ms: Date.now() - t0 }; } catch (e) {} finally { try { c.close(); } catch (_) {} }
    }
    sleep(50);
  }
  return null;
})();
check("F1", "a surviving member is elected PRIMARY", !!electedAfter, electedAfter ? `new primary ${electedAfter.port}, ${electedAfter.ms} ms after the crash` : "no election within 90 s");

// First client write after the crash through the normal replica-set connection (driver re-discovers the primary).
let firstWriteMs = -1, failed = 0, id = 51;
while (Date.now() - t0 < 90000) {
  try { coll.insertOne({ _id: id, at: new Date() }, { writeConcern: { w: "majority", wtimeout: 5000 } }); acked.push(id); firstWriteMs = Date.now() - t0; id++; break; }
  catch (e) { failed++; sleep(250); }
}
check("F2", "client writes succeed again through the same connection string", firstWriteMs >= 0,
      `first successful w:majority write ${firstWriteMs} ms after the crash, ${failed} failed attempt(s) in between`);
for (let k = 0; k < 9; k++) { coll.insertOne({ _id: id, at: new Date() }, { writeConcern: { w: "majority" } }); acked.push(id); id++; }

const newPrimary = findPrimary();
const termAfter = termOf(newPrimary.port);
check("F3", "the election term increased", termAfter > termBefore, `term ${termBefore} -> ${termAfter}`);

const present = new Set(client.getDB(DBN).acked.find({}, { _id: 1 }).toArray().map(d => d._id));
const missing = acked.filter(x => !present.has(x));
check("F4", `none of the ${acked.length} acknowledged writes was lost`, missing.length === 0, missing.length ? `missing ids ${missing.join(",")}` : `ids 1..${acked.length} all present on the new primary`);

print("\n--- write while the old primary is still down (it must catch up with this later)");
for (let k = 0; k < 20; k++) { coll.insertOne({ _id: id, at: new Date() }, { writeConcern: { w: "majority" } }); acked.push(id); id++; }
print(`now ${acked.length} acknowledged documents; old primary ${old.port} is down`);
memberTable();

print(`\n--- restart the crashed member ${old.port}`);
const t1 = Date.now();
startNode(old.port);
const toSecondary = waitForState(old.port, "SECONDARY", 90000);
const caught = waitForCount(old.port, DBN, "acked", acked.length, 60000);
check("F5", "the old primary rejoins as a SECONDARY (it does not take over, no split brain)", toSecondary >= 0, `${toSecondary} ms after the start command`);
check("F6", `it catches up with all ${acked.length} documents`, caught >= 0, `${Date.now() - t1} ms after the start command`);
const hashes = PORTS.map(p => JSON.stringify(hashesOf(p, DBN)));
check("F7", "all three members now have identical collection hashes", hashes.every(h => h === hashes[0]));
memberTable();
client.getDB(DBN).dropDatabase();
print(`\nSummary: ${pass} passed, ${fail} failed`);
if (fail) quit(1);
