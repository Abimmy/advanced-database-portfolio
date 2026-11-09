// Shared helpers for the Portfolio 5 replica-set scripts. Loaded with load("common.js") from this folder.
// Members: 127.0.0.1:27018, 27019, 27020 (replica set "mikepay-rs").

var PORTS = [27018, 27019, 27020];
var RS_URI = "mongodb://127.0.0.1:27018,127.0.0.1:27019,127.0.0.1:27020/?replicaSet=mikepay-rs";

// A connection to ONE member only (no discovery), so a stopped member cannot hang the script.
function direct(port) {
  return new Mongo(`mongodb://127.0.0.1:${port}/?directConnection=true&serverSelectionTimeoutMS=2000&connectTimeoutMS=2000`);
}

function findPrimary() {
  for (const p of PORTS) {
    let c;
    try { c = direct(p); const h = c.getDB("admin").hello(); if (h.isWritablePrimary) return { port: p, host: h.me }; }
    catch (e) { /* member down or unreachable */ }
    finally { try { c.close(); } catch (_) {} }
  }
  return null;
}

// Polls every member until one reports itself primary; returns {primary, ms} or null on timeout.
function waitForPrimary(timeoutMs) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    const p = findPrimary();
    if (p) return { primary: p, ms: Date.now() - t0 };
    sleep(100);
  }
  return null;
}

// Prints the replSetGetStatus member table from the first member that answers.
function memberTable() {
  for (const p of PORTS) {
    let c;
    try {
      c = direct(p);
      const st = c.getDB("admin").runCommand({ replSetGetStatus: 1 });
      if (!st.ok) continue;
      print(`replica set ${st.set}, answered by ${st.members.find(m => m.self).name}, date ${st.date.toISOString()}`);
      print("  member           state       health  optime(ts)");
      for (const m of st.members) {
        const ot = m.optimeDate ? m.optimeDate.toISOString() : "-";
        print(`  ${m.name.padEnd(16)} ${String(m.stateStr).padEnd(11)} ${String(m.health).padEnd(7)} ${ot}`);
      }
      return st;
    } catch (e) { /* try the next member */ }
    finally { try { c.close(); } catch (_) {} }
  }
  print("no member answered replSetGetStatus");
  return null;
}

// ---- process control (Windows) -------------------------------------------------------------------------
// Scripts run with this folder as the working directory, so the control script is one level up.
var _cp = require("child_process");

function pidOf(port) {
  const c = direct(port);
  try { return c.getDB("admin").serverStatus().pid; } finally { c.close(); }
}

// Abrupt crash: the process is killed without any shutdown work (like a power cut or an OS kill).
function killNode(port) {
  const pid = pidOf(port);
  _cp.execSync(`taskkill /F /PID ${pid}`, { stdio: "ignore" });
  return pid;
}

function startNode(port) {
  _cp.execSync(`powershell -NoProfile -File "../node-control.ps1" -Action start -Node ${port - 27017}`, { stdio: "ignore" });
}

// Waits until the member on `port` reports the wanted state ("SECONDARY" / "PRIMARY"); returns elapsed ms or -1.
function waitForState(port, wanted, timeoutMs) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    let c;
    try { c = direct(port); const h = c.getDB("admin").hello(); if ((wanted === "PRIMARY" && h.isWritablePrimary) || (wanted === "SECONDARY" && h.secondary)) return Date.now() - t0; }
    catch (e) { /* still starting */ }
    finally { try { c.close(); } catch (_) {} }
    sleep(200);
  }
  return -1;
}

// Waits until a member holds `expected` documents in db.coll (read directly from that member).
function waitForCount(port, dbName, collName, expected, timeoutMs) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    let c;
    try { c = direct(port); if (c.getDB(dbName)[collName].countDocuments() === expected) return Date.now() - t0; }
    catch (e) { /* not ready */ }
    finally { try { c.close(); } catch (_) {} }
    sleep(200);
  }
  return -1;
}

// MD5 per collection of one database, computed by one member (compare across members to prove identical data).
function hashesOf(port, dbName) {
  const c = direct(port);
  try { return c.getDB(dbName).runCommand({ dbHash: 1 }).collections; } finally { c.close(); }
}

// Precondition for the experiments: all three members up, one PRIMARY, two SECONDARY. Waits up to 90 s, else stops the script.
function requireHealthyCluster() {
  const t0 = Date.now();
  while (Date.now() - t0 < 90000) {
    const p = findPrimary();
    if (p) {
      const c = direct(p.port);
      try {
        const st = c.getDB("admin").runCommand({ replSetGetStatus: 1 });
        const states = st.members.map(m => (m.health === 1 ? m.stateStr : "DOWN")).sort().join(",");
        if (states === "PRIMARY,SECONDARY,SECONDARY") return;
      } finally { c.close(); }
    }
    sleep(500);
  }
  print("PRECONDITION FAILED: the replica set is not healthy (need 1 PRIMARY + 2 SECONDARY)");
  quit(1);
}
