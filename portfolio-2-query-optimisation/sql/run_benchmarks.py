"""Run the MikePay query experiments in 02_experiments.sql and record evidence.

For every variant it records:
  - EXPLAIN                (estimated plan; the query is NOT executed)
  - ANALYZE                (actual plan with r_rows; the query IS executed)
  - Handler_read_* status  (rows actually read by the storage engine)
  - 6 timed executions     (server-side r_total_time_ms from ANALYZE FORMAT=JSON):
                           run 1 = first run after the DDL; runs 2-6 = repeat runs
Then it restores the schema and checks the index list matches the original.

Uses only the mysql command-line client (no third-party packages).
Usage:  python -I run_benchmarks.py
"""
import json
import os
import platform
import re
import statistics
import subprocess
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MYSQL = r"C:\xampp\mysql\bin\mysql.exe"
DB = "mikepay_db"
PLAN_DIR = os.path.join(ROOT, "execution-plans")
EVIDENCE_DIR = os.path.join(ROOT, "evidence")
REPEATS = 6
HANDLER_ROWS = ("Handler_read_first", "Handler_read_key", "Handler_read_last",
                "Handler_read_next", "Handler_read_prev", "Handler_read_rnd",
                "Handler_read_rnd_next")


def mysql(sql, flags=("-B",), check=True):
    """Run SQL through the mysql client in ONE session; return stdout text."""
    proc = subprocess.run([MYSQL, "-u", "root", *flags, DB, "-e", sql],
                          capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError(f"mysql failed: {proc.stderr.strip()}\nSQL: {sql[:300]}")
    return proc.stdout


def table(sql):
    """Run a query; return (header, rows) from tab-separated output."""
    lines = [l for l in mysql(sql).splitlines() if l]
    if not lines:
        return [], []
    return lines[0].split("\t"), [l.split("\t") for l in lines[1:]]


def parse_experiments(path):
    experiments, exp, var = [], None, None
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            m = re.match(r"-- @exp (\S+) \| (.*)", line)
            if m:
                exp = {"id": m.group(1), "title": m.group(2), "note": "", "variants": [], "cleanup": []}
                experiments.append(exp)
                var = None
                continue
            if exp is None:
                continue
            if line.startswith("-- @note "):
                exp["note"] = line[len("-- @note "):]
            elif line.startswith("-- @variant "):
                name, _, detail = line[len("-- @variant "):].partition(" | ")
                var = {"name": name.strip(), "detail": detail.strip(), "before": [], "query": []}
                exp["variants"].append(var)
            elif line.startswith("-- @before ") and var is not None:
                var["before"].append(line[len("-- @before "):].rstrip(";"))
            elif line.startswith("-- @cleanup "):
                exp["cleanup"].append(line[len("-- @cleanup "):].rstrip(";"))
            elif line.startswith("--") or not line.strip():
                continue
            elif var is not None:
                var["query"].append(line)
    for e in experiments:
        for v in e["variants"]:
            v["query"] = "\n".join(v["query"]).strip().rstrip(";")
    return experiments


def index_snapshot():
    _, rows = table(
        "SELECT table_name, index_name, non_unique, "
        "GROUP_CONCAT(column_name ORDER BY seq_in_index) "
        f"FROM information_schema.statistics WHERE table_schema = '{DB}' "
        "GROUP BY table_name, index_name, non_unique ORDER BY 1, 2")
    return [tuple(r) for r in rows]


def pick_e5_constants():
    _, rows = table(
        "SELECT source_account_id, destination_account_id, COUNT(*) c FROM transfers "
        "WHERE source_account_id = 1001 GROUP BY 1, 2 ORDER BY c DESC, 2 LIMIT 1")
    return rows[0][0], rows[0][1], rows[0][2]


def environment():
    ver = mysql("SELECT VERSION(), @@innodb_buffer_pool_size/1048576, @@innodb_log_file_size/1048576, "
                "@@sql_mode, @@tx_isolation", ("-N", "-B")).split("\t")
    _, sizes = table(
        "SELECT table_name, table_rows, ROUND(data_length/1048576,1) data_mb, ROUND(index_length/1048576,1) index_mb "
        f"FROM information_schema.tables WHERE table_schema='{DB}' ORDER BY table_name")
    return ver, sizes


def measure(variant):
    q = variant["query"]
    result = {"name": variant["name"], "detail": variant["detail"], "query": q}

    # DDL before the variant (untimed except for index-build time)
    t0 = time.perf_counter()
    for stmt in variant["before"]:
        mysql(stmt)
    result["ddl_seconds"] = round(time.perf_counter() - t0, 2) if variant["before"] else None
    mysql("ANALYZE TABLE transactions, transfers, accounts", ("-B",))   # refresh statistics

    # estimated plan (not executed)
    result["explain_text"] = mysql("EXPLAIN " + q)
    head, rows = table("EXPLAIN " + q)
    result["explain_rows"] = [dict(zip(head, r)) for r in rows]

    # timed executions (server-side time)
    times, r_rows_total = [], None
    for _ in range(REPEATS):
        out = mysql("ANALYZE FORMAT=JSON " + q, ("-N", "-B", "-r"))
        data = json.loads(out)
        times.append(float(data["query_block"]["r_total_time_ms"]))
    result["times_ms"] = times
    result["first_ms"] = times[0]
    result["median_repeat_ms"] = statistics.median(times[1:])

    # actual plan (executed)
    result["analyze_text"] = mysql("ANALYZE " + q)

    # rows actually read by the engine (one session so counters are comparable)
    out = mysql("FLUSH STATUS; " + q + "; SHOW SESSION STATUS LIKE 'Handler_read%';", ("-N", "-B"))
    handlers = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and parts[0] in HANDLER_ROWS:
            handlers[parts[0]] = int(parts[1])
    result["handlers"] = handlers
    result["rows_read"] = sum(handlers.values())
    return result


def fmt_ms(x):
    return f"{x:.3f}" if x < 1 else f"{x:.1f}"


def compare(a, b):
    """Plain-language before/after comparison; no ratios for sub-millisecond times."""
    ra, rb = a["rows_read"], b["rows_read"]
    if rb and ra / rb >= 1.5:
        rows = f"Rows read: {ra:,} -> {rb:,} ({ra / rb:.1f}x fewer)."
    elif rb and 0.67 <= ra / rb < 1.5:
        rows = f"Rows read: {ra:,} -> {rb:,} (about the same)."
    else:
        rows = f"Rows read: {ra:,} -> {rb:,}."
    ta, tb = a["median_repeat_ms"], b["median_repeat_ms"]
    if tb >= 0.5 and ta >= 0.5:
        t = f"Median repeat time: {fmt_ms(ta)} ms -> {fmt_ms(tb)} ms ({ta / tb:.1f}x)."
    else:
        t = (f"Median repeat time: {fmt_ms(ta)} ms -> {fmt_ms(tb)} ms "
             "(at least one is under 0.5 ms, too small for a meaningful ratio).")
    return rows + " " + t


def short_plan(explain_rows):
    parts = []
    for r in explain_rows:
        extra = (r.get("Extra") or "").replace("NULL", "").strip()
        parts.append(f"{r['table']}: type={r['type']}, key={r['key']}, est.rows={r['rows']}"
                     + (f", {extra}" if extra else ""))
    return "<br>".join(parts)


def main():
    os.makedirs(PLAN_DIR, exist_ok=True)
    os.makedirs(EVIDENCE_DIR, exist_ok=True)
    before_indexes = index_snapshot()
    src, dst, pair_count = pick_e5_constants()
    ver, sizes = environment()
    started = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    experiments = parse_experiments(os.path.join(HERE, "02_experiments.sql"))
    for e in experiments:
        for v in e["variants"]:
            v["query"] = v["query"].replace("@@E5_SOURCE@@", str(src)).replace("@@E5_DEST@@", str(dst))

    all_results = []
    for e in experiments:
        print(f"== {e['id']}: {e['title']}", flush=True)
        results = []
        for v in e["variants"]:
            print(f"   - {v['name']} ...", flush=True)
            r = measure(v)
            results.append(r)
            fname = f"{e['id']}_{v['name']}.txt"
            with open(os.path.join(PLAN_DIR, fname), "w", encoding="utf-8", newline="\n") as f:
                f.write(f"{e['id']} - {e['title']}\nVariant: {v['name']} ({v['detail']})\n")
                f.write(f"DDL before variant: {'; '.join(v['before']) or 'none'}\n\n")
                f.write("QUERY\n" + r["query"] + ";\n\n")
                f.write("EXPLAIN (estimated plan, query not executed)\n" + r["explain_text"] + "\n")
                f.write("ANALYZE (actual plan, query executed; r_rows = rows actually read, r_filtered = % kept)\n"
                        + r["analyze_text"] + "\n")
                f.write("HANDLER READ COUNTERS (rows read by the storage engine)\n"
                        + "\n".join(f"{k} = {v_}" for k, v_ in r["handlers"].items())
                        + f"\nTOTAL = {r['rows_read']}\n\n")
                f.write("SERVER-SIDE RUN TIMES, ms (run 1 = first run after DDL; runs 2-6 = repeats)\n"
                        + ", ".join(f"{t:.3f}" for t in r["times_ms"]) + "\n")
        for stmt in e["cleanup"]:
            mysql(stmt, check=False)
        all_results.append({"exp": e, "results": results})

    after_indexes = index_snapshot()
    restored = before_indexes == after_indexes

    with open(os.path.join(EVIDENCE_DIR, "02_benchmark_raw_results.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump([{"id": a["exp"]["id"], "title": a["exp"]["title"], "results": a["results"]}
                   for a in all_results], f, indent=2)

    out = []
    out.append("# Portfolio 2 - benchmark results (generated by sql/run_benchmarks.py)\n")
    out.append(f"Run started: {started}\n")
    out.append("## Test environment\n")
    out.append(f"- Server: MariaDB {ver[0]} (XAMPP), storage engine InnoDB, isolation {ver[4].strip()}")
    out.append(f"- InnoDB buffer pool: {float(ver[1]):.0f} MB (XAMPP default, not changed); redo log file: {float(ver[2]):.0f} MB")
    out.append(f"- Host: {platform.platform()}, Python {platform.python_version()}")
    out.append("- Data: synthetic bulk data from `01_generate_bulk_data.sql` (fixed random seeds)")
    out.append(f"- E5 test pair: source account {src} -> destination {dst} ({pair_count} matching transfer(s))")
    out.append("- Table sizes at test time:\n")
    out.append("| table | est. rows | data MB | index MB |\n|---|---|---|---|")
    for r in sizes:
        out.append(f"| {r[0]} | {r[1]} | {r[2]} | {r[3]} |")
    out.append("\n## Method\n")
    out.append(f"- Each variant is run {REPEATS} times. Times are server-side `r_total_time_ms` from `ANALYZE FORMAT=JSON`. "
               "**First run** = first execution after the index change (data may need reading from disk); "
               f"**median of repeats** = median of runs 2-{REPEATS} (data mostly cached).")
    out.append("- **Rows read** = sum of `Handler_read_*` counters for one execution. It does not depend on machine load, so it is the most reliable comparison.")
    out.append("- For covering (index-only) plans, index entries still count as rows read, but the lookups into the table are skipped, so the time difference is the better indicator there.")
    out.append("- `EXPLAIN` = estimated plan (query not run). `ANALYZE` = actual plan with measured `r_rows`. Raw outputs are in `execution-plans/`.")
    out.append("- The laptop was in normal use during the runs, so small timing differences are noise; large differences and the rows-read counts are what matter.\n")
    out.append("## Results\n")
    for a in all_results:
        e, rs = a["exp"], a["results"]
        out.append(f"### {e['id']} - {e['title']}\n")
        out.append(e["note"] + "\n")
        out.append("| variant | plan (EXPLAIN) | rows read | first run ms | median repeat ms | index build s |\n|---|---|---|---|---|---|")
        for r in rs:
            out.append(f"| {r['name']} ({r['detail']}) | {short_plan(r['explain_rows'])} | {r['rows_read']:,} | "
                       f"{fmt_ms(r['first_ms'])} | {fmt_ms(r['median_repeat_ms'])} | {r['ddl_seconds'] if r['ddl_seconds'] is not None else '-'} |")
        if len(rs) == 2:
            out.append("\n" + compare(rs[0], rs[1]) + "\n")
    out.append(f"## Schema restored\n\nIndex list after the experiments is identical to before: **{'YES' if restored else 'NO - CHECK'}**\n")
    with open(os.path.join(EVIDENCE_DIR, "02_benchmark_summary.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print("Done. Schema restored:", restored)


if __name__ == "__main__":
    main()
