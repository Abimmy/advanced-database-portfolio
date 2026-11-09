// Portfolio 5 - step 7: eventual consistency, observed rather than described.
//
// Run: mongosh --quiet --nodb --file 07_stale_read_delayed_secondary.js    (from this folder; all 3 members must be up)
//
// A secondary normally trails the primary by milliseconds, too little to catch with a read. To SEE the effect, one
// secondary is temporarily configured to apply changes 8 seconds late (secondaryDelaySecs, priority 0), an official
// feature meant for "undo" protection. The delay is an artificial stand-in for a slow or distant replica (for
// example a secondary in another region). The configuration is restored at the end.

load("common.js");
requireHealthyCluster();
let pass = 0, fail = 0;
const check = (id, text, ok, detail) => { print(`${id}  ${ok ? "PASS" : "FAIL"}  ${text}${detail ? "  [" + detail + "]" : ""}`); ok ? pass++ : fail++; };

const DELAY = 8, DBN = "p5_consistency";
const primary = findPrimary();
const delayed = PORTS.find(p => p !== primary.port);
const normal = PORTS.find(p => p !== primary.port && p !== delayed);
print(`primary ${primary.port}; delayed secondary ${delayed} (will apply changes ${DELAY} s late); normal secondary ${normal}\n`);

function reconfigure(mutate) {
  const c = direct(primary.port);
  try {
    const cfg = c.getDB("admin").runCommand({ replSetGetConfig: 1 }).config;
    mutate(cfg.members.find(m => m.host === `127.0.0.1:${delayed}`));
    cfg.version++;
    const r = c.getDB("admin").runCommand({ replSetReconfig: cfg });
    if (!r.ok) throw new Error("replSetReconfig failed: " + r.errmsg);
  } finally { c.close(); }
}

const client = new Mongo(RS_URI);
client.getDB(DBN).dropDatabase();
reconfigure(m => { m.priority = 0; m.secondaryDelaySecs = DELAY; });
print(`reconfigured: member ${delayed} priority 0, secondaryDelaySecs ${DELAY}`);
sleep(3000);

const coll = client.getDB(DBN).balance;
coll.insertOne({ _id: 1, balance: NumberDecimal("100.00") }, { writeConcern: { w: "majority" } });   // the normal secondary + primary = majority
const arrived = waitForCount(delayed, DBN, "balance", 1, (DELAY + 10) * 1000);
check("C0", "the first document reaches the delayed secondary after the delay", arrived >= 0, `${arrived} ms`);

const read = port => { const c = direct(port); try { const d = c.getDB(DBN).balance.findOne({ _id: 1 }); return d ? d.balance.toString() : "(missing)"; } finally { c.close(); } };

print("\n--- the balance is changed from 100.00 to 200.00 on the primary (w:majority is acknowledged)");
const t0 = Date.now();
coll.updateOne({ _id: 1 }, { $set: { balance: NumberDecimal("200.00") } }, { writeConcern: { w: "majority" } });
print(`acknowledged after ${Date.now() - t0} ms; now the same document is read from every member:\n`);
print("  t(ms)   primary   normal-secondary   delayed-secondary");
let firstDelayed = null, freshAt = -1;
const timeline = [];
for (let i = 0; i < 40 && freshAt < 0; i++) {
  const t = Date.now() - t0;
  const row = { t, p: read(primary.port), n: read(normal), d: read(delayed) };
  if (firstDelayed === null) firstDelayed = row;
  if (row.d === "200.00") freshAt = t;
  if (i < 3 || row.d === "200.00" || i % 4 === 0) print(`  ${String(t).padStart(5)}   ${row.p.padEnd(9)} ${row.n.padEnd(18)} ${row.d}`);
  timeline.push(row);
  sleep(500);
}
check("C1", "right after the acknowledged write the primary returns the NEW value", firstDelayed.p === "200.00", firstDelayed.p);
check("C2", "right after the acknowledged write the delayed secondary returns the OLD value (a stale read)", firstDelayed.d === "100.00", firstDelayed.d);
check("C3", "the delayed secondary becomes consistent by itself (eventual consistency)", freshAt >= 0, freshAt >= 0 ? `visible after ${freshAt} ms with a configured delay of ${DELAY * 1000} ms` : "never within 20 s");
check("C4", "the other secondary is not stale in this test", timeline.every((r, i) => i === 0 || r.n === "200.00"), "values after the first sample all 200.00");

print("\n--- restore the normal configuration");
reconfigure(m => { m.priority = 1; m.secondaryDelaySecs = 0; });
sleep(3000);
const c2 = direct(primary.port);
const m2 = c2.getDB("admin").runCommand({ replSetGetConfig: 1 }).config.members.find(m => m.host === `127.0.0.1:${delayed}`);
c2.close();
check("C5", "the delayed member is back to priority 1 and no delay", Number(m2.priority) === 1 && Number(m2.secondaryDelaySecs || 0) === 0, `priority ${m2.priority}, secondaryDelaySecs ${m2.secondaryDelaySecs}`);
memberTable();
client.getDB(DBN).dropDatabase();
print(`\nSummary: ${pass} passed, ${fail} failed`);
if (fail) quit(1);
