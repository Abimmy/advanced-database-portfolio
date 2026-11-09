// Portfolio 5 - step 3: what write concern means when one member is down.
//
// Run: mongosh --quiet --nodb --file 03_write_concern_one_node_down.js    (from this folder; all 3 members must be up)
//
// w:1        acknowledged by the primary alone (fast, but a primary crash right afterwards can lose the write)
// w:majority acknowledged once 2 of 3 members have it (survives the loss of any one member)
// w:3        acknowledged only when ALL members have it (cannot be met while a member is down)

load("common.js");
requireHealthyCluster();
let pass = 0, fail = 0;
const check = (id, text, ok, detail) => { print(`${id}  ${ok ? "PASS" : "FAIL"}  ${text}${detail ? "  [" + detail + "]" : ""}`); ok ? pass++ : fail++; };

const client = new Mongo(RS_URI);
const coll = client.getDB("p5_wc").ledger;
client.getDB("p5_wc").dropDatabase();
const primary = findPrimary();
const victim = PORTS.find(p => p !== primary.port);
const other = PORTS.find(p => p !== primary.port && p !== victim);
print(`primary ${primary.port}; the secondary that will be crashed: ${victim}; the secondary that stays up: ${other}\n`);

function timedInsert(id, wc) {
  const t = Date.now();
  try { const r = coll.insertOne({ _id: id, note: `w=${wc.w}` }, { writeConcern: wc }); return { ok: true, ms: Date.now() - t, r }; }
  catch (e) { return { ok: false, ms: Date.now() - t, err: e }; }
}

print("--- all three members up");
let r = timedInsert(1, { w: "majority", wtimeout: 5000 });  check("W1", "w:majority acknowledged", r.ok, `${r.ms} ms`);
r = timedInsert(2, { w: 3, wtimeout: 5000 });               check("W2", "w:3 (every member) acknowledged", r.ok, `${r.ms} ms`);

print(`\n--- crash secondary ${victim} (taskkill /F, no shutdown work)`);
const pid = killNode(victim);
print(`killed PID ${pid}`);
sleep(12000);   // the heartbeat timeout is 10 s (electionTimeoutMillis); after that the primary marks the member as down
memberTable();

print("\n--- one member down");
r = timedInsert(3, { w: 1 });                                  check("W3", "w:1 acknowledged", r.ok, `${r.ms} ms`);
r = timedInsert(4, { w: "majority", wtimeout: 5000 });         check("W4", "w:majority still acknowledged (primary + the other secondary = 2 of 3)", r.ok, `${r.ms} ms`);
r = timedInsert(5, { w: 3, wtimeout: 3000 });
const wcErr = !r.ok && (r.err.code === 64 || /waiting for replication timed out|WriteConcern/i.test(String(r.err.message)));
check("W5", "w:3 cannot be met and times out", wcErr, `${r.ms} ms; code ${r.err && r.err.code}: ${r.err && String(r.err.message).split("\n")[0]}`);
const onPrimary = direct(primary.port).getDB("p5_wc").ledger.countDocuments({ _id: 5 });
check("W6", "the timed-out w:3 write IS nevertheless applied on the primary (a write-concern error is not a rollback)", onPrimary === 1, `documents with _id 5 on the primary: ${onPrimary}`);
const readOther = direct(other).getDB("p5_wc").ledger.countDocuments();
check("W7", "the surviving secondary still serves reads", readOther >= 4, `${readOther} documents visible there`);

print(`\n--- restart secondary ${victim}`);
const t0 = Date.now();
startNode(victim);
const toSecondary = waitForState(victim, "SECONDARY", 90000);
const caught = waitForCount(victim, "p5_wc", "ledger", 5, 60000);
check("W8", "the restarted member rejoins as SECONDARY and catches up with every write made while it was down", toSecondary >= 0 && caught >= 0,
      `SECONDARY after ${toSecondary} ms, all 5 documents present ${Date.now() - t0} ms after the restart command`);
const hp = JSON.stringify(hashesOf(primary.port, "p5_wc")), hv = JSON.stringify(hashesOf(victim, "p5_wc"));
check("W9", "collection hash on the restarted member equals the primary's", hp === hv);
memberTable();
client.getDB("p5_wc").dropDatabase();
print(`\nSummary: ${pass} passed, ${fail} failed`);
if (fail) quit(1);
