#!/usr/bin/env bash
# Portfolio 5 - rebuild the local replica set from nothing, run every experiment and save its real output in ../evidence/.
#
# Prerequisites: MongoDB 9.0 binaries installed (C:\Program Files\MongoDB\Server\9.0), mongosh on PATH, Windows PowerShell,
# the Portfolio 4 database mikepay_nosql on the original service (port 27017) for step 08, and the Portfolio 4
# sample data files in ../../portfolio-4-nosql/sample-data.
#
# Usage (Git Bash, from this folder):   bash run_evidence.sh
# WARNING: this stops the three replica-set members and DELETES ../mongo-data (their data folders, git-ignored)
# before starting again from scratch. The original MongoDB service on port 27017 is not touched.
# Takes about 6-8 minutes (the failover and lost-majority tests wait for real elections).

cd "$(dirname "$0")" || exit 1
EV=../evidence
mkdir -p "$EV"
CTRL="powershell.exe -NoProfile -File ./node-control.ps1"

capture() {                       # capture <file> <command...>
  local file="$1"; shift
  {
    echo "# $file"
    echo "# Run:     $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "# Command: $*"
    echo "# MongoDB: $(mongosh --quiet --nodb --eval 'print("mongosh " + version())') / mongod $("/c/Program Files/MongoDB/Server/9.0/bin/mongod.exe" --version | head -1)"
    echo
    "$@"
    RC=$?
    echo
    echo "# exit code: $RC"
  } > "$EV/$file" 2>&1
  echo "wrote $EV/$file"
}

mongosh_test() { ( cd tests && mongosh --quiet --nodb --file "$1" ); }

setup_environment() {
  echo "--- stopping any running members and deleting ../mongo-data"
  $CTRL -Action stop
  rm -rf ../mongo-data
  echo "--- starting the three members"
  $CTRL -Action start
  sleep 8
  $CTRL -Action status
  echo
  echo "--- host"
  powershell.exe -NoProfile -Command "\$o = Get-CimInstance Win32_OperatingSystem; \$c = Get-CimInstance Win32_Processor | Select-Object -First 1; 'OS: ' + \$o.Caption + ' ' + \$o.Version; 'CPU: ' + \$c.Name + ', ' + \$c.NumberOfLogicalProcessors + ' logical processors'; 'RAM: ' + [math]::Round(\$o.TotalVisibleMemorySize/1MB, 1) + ' GB'"
  echo
  for n in 1 2 3; do echo "--- mongod-node$n.conf"; cat mongod-node$n.conf; echo; done
}

load_data() {
  local URI="mongodb://127.0.0.1:27018,127.0.0.1:27019,127.0.0.1:27020/?replicaSet=mikepay-rs"
  local V="var DB_NAME='mikepay_nosql_rs', DATA_DIR='../sample-data'"
  ( cd ../../portfolio-4-nosql/scripts \
    && mongosh --quiet "$URI" --file 02_create_collections.js --eval "$V" | tail -6 \
    && mongosh --quiet "$URI" --file 03_load_data.js --eval "$V" \
    && mongosh --quiet "$URI" --file 04_verify_migration.js --eval "$V" ) || return 1
  echo
  mongosh_test 02_replication_and_reads.js
}

capture 00_environment_and_setup.txt setup_environment
capture 01_initiate_replica_set.txt mongosh_test 01_initiate_replica_set.js
capture 02_load_data_and_replication_checks.txt load_data
capture 03_write_concern_one_node_down.txt mongosh_test 03_write_concern_one_node_down.js
capture 04_primary_failover.txt mongosh_test 04_primary_failover.js
capture 05_no_majority_two_nodes_down.txt mongosh_test 05_no_majority_two_nodes_down.js
capture 06_multi_document_transactions.txt mongosh_test 06_multi_document_transactions.js
capture 07_stale_read_delayed_secondary.txt mongosh_test 07_stale_read_delayed_secondary.js
capture 08_shard_key_analysis.txt mongosh_test 08_shard_key_analysis.js

echo; echo "exit codes recorded:"; grep -H "# exit code" "$EV"/*.txt
