#!/usr/bin/env bash
# Portfolio 4 - run every stage and save its real output under ../evidence/.
#
# Prerequisites: MongoDB service running on 127.0.0.1:27017, mongosh on PATH, XAMPP MariaDB running
# with mikepay_db loaded (Portfolios 1-2), `pip install --user pymysql`.
#
# Usage (Git Bash, from this folder):   bash run_evidence.sh [sample|bulk|all]
#   sample : export + create/load/verify the 8-customer sample, validation, concurrency, negative test
#   bulk   : create/load/verify the 10,000-customer slice (needs ../bulk-data from 01_export_from_mariadb.py),
#            queries and index/explain experiments
# The bulk export itself takes about 4 minutes; run it once with:
#   python 01_export_from_mariadb.py --max-customer-id 10000 --out ../bulk-data
#
# Each evidence file starts with the date, the command and the MongoDB version and ends with the exit code.

cd "$(dirname "$0")" || exit 1
EV=../evidence
mkdir -p "$EV"
MODE="${1:-all}"

capture() {                       # capture <file> <command...>
  local file="$1"; shift
  {
    echo "# $file"
    echo "# Run:     $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "# Command: $*"
    echo "# MongoDB: $(mongosh --quiet --eval 'db.version()')"
    echo
    "$@"
    RC=$?
    echo
    echo "# exit code: $RC"
  } > "$EV/$file" 2>&1
  echo "wrote $EV/$file"
}

SAMPLE="var DB_NAME='mikepay_nosql_sample', DATA_DIR='../sample-data'"
BULK="var DB_NAME='mikepay_nosql', DATA_DIR='../bulk-data'"
m() { local vars="$1" script="$2"; mongosh --quiet --file "$script" --eval "$vars"; }

stage_sample() {
  capture 01_sample_export_output.txt python 01_export_from_mariadb.py --max-customer-id 8 --out ../sample-data
  capture 02_sample_create_load_verify.txt bash -c "$(declare -f m); m \"$SAMPLE\" 02_create_collections.js; m \"$SAMPLE\" 03_load_data.js; m \"$SAMPLE\" 04_verify_migration.js"
  capture 06_validation_and_atomicity_output.txt m "$SAMPLE" 07_validation_and_atomicity_tests.js
  capture 07_concurrent_debits_output.txt bash 09_concurrent_debits.sh mikepay_nosql_sample
  capture 08_negative_verification_output.txt m "$SAMPLE" 08_verification_negative_test.js
}

stage_bulk() {
  capture 03_bulk_create_load_verify.txt bash -c "$(declare -f m); m \"$BULK\" 02_create_collections.js; m \"$BULK\" 03_load_data.js; m \"$BULK\" 04_verify_migration.js"
  capture 04_queries_and_aggregations_output.txt m "$BULK" 05_queries_and_aggregations.js
  capture 05_index_explain_output.txt m "$BULK" 06_index_explain.js
}

case "$MODE" in
  sample) stage_sample ;;
  bulk)   stage_bulk ;;
  all)    stage_sample; stage_bulk ;;
  *) echo "usage: bash run_evidence.sh [sample|bulk|all]"; exit 1 ;;
esac
