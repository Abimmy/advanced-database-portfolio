// Portfolio 5 - step 1: turn the three running mongod processes into one replica set and wait for an election.
//
// Run: mongosh --quiet --nodb --file 01_initiate_replica_set.js     (from this folder)
//
// Three voting members is the smallest set that survives the loss of one member: a majority is 2 of 3.

load("common.js");

const cfg = {
  _id: "mikepay-rs",
  members: PORTS.map((p, i) => ({ _id: i + 1, host: `127.0.0.1:${p}` }))   // default: priority 1, 1 vote each
};
const c = direct(27018);
const t0 = Date.now();
const r = c.getDB("admin").runCommand({ replSetInitiate: cfg });
print("replSetInitiate -> " + JSON.stringify({ ok: r.ok, codeName: r.codeName, errmsg: r.errmsg }));
c.close();

const w = waitForPrimary(60000);
if (!w) { print("FAIL: no primary elected within 60 s"); quit(1); }
else {
  print(`primary elected: ${w.primary.host} (${(Date.now() - t0)} ms after replSetInitiate)`);
  sleep(3000);   // let the secondaries finish their initial sync so the table shows them as SECONDARY
  const st = memberTable();
  const conf = direct(w.primary.port).getDB("admin").runCommand({ replSetGetConfig: 1 }).config;
  print(`config: members=${conf.members.length}, votes=${conf.members.map(m => m.votes).join("+")}, ` +
        `heartbeatIntervalMillis=${conf.settings.heartbeatIntervalMillis}, electionTimeoutMillis=${conf.settings.electionTimeoutMillis}, ` +
        `writeConcernMajorityJournalDefault=${conf.writeConcernMajorityJournalDefault}`);
  const states = st.members.map(m => m.stateStr).sort().join(",");
  const ok = states === "PRIMARY,SECONDARY,SECONDARY";
  print(ok ? "PASS: one PRIMARY and two SECONDARY members" : `FAIL: unexpected states ${states}`);
  if (!ok) quit(1);
}
