#!/usr/bin/env bash
# Portfolio 4 - step 9: concurrent clients against one customer document.
#
# 10 separate mongosh processes (10 independent client connections) start at the same moment and
# each tries to debit 300.00 from one account holding 1000.00, using the guarded atomic update from
# 07_validation_and_atomicity_tests.js. Only 3 debits fit (1000 -> 700 -> 400 -> 100); the other 7
# must be refused. If the update were NOT atomic (read balance, compute in the client, write back)
# several clients could read the same balance and the account could go wrong - the same lost-update
# problem demonstrated for MariaDB in Portfolio 3.
#
# Run (Git Bash):  bash 09_concurrent_debits.sh [database]      default database: mikepay_nosql_sample
# Expects mongosh on PATH.

DB="${1:-mikepay_nosql_sample}"
N=10
OUT="$(mktemp -d)"
echo "Database: $DB   clients: $N   debit each: 300.00   opening balance: 1000.00"

mongosh --quiet --eval "
const d = db.getSiblingDB('$DB'); d.customers.deleteMany({_id: 900001});
d.customers.insertOne({_id: 900001, first_name: 'Test', last_name: 'Person', email: 'concurrent@example.com', phone: '08099999999',
  status: 'ACTIVE', created_at: new Date(), beneficiaries: [],
  accounts: [{account_id: 900001, account_number: '9100000001', account_type: 'CURRENT', currency: 'NGN',
              balance: NumberDecimal('1000.00'), status: 'ACTIVE', opened_at: new Date()}]});
print('setup done: balance ' + d.customers.findOne({_id: 900001}).accounts[0].balance);"

# Each client first connects and waits until the shared start time, so the updates really overlap.
START=$(( $(date +%s) + 20 ))   # long enough for all 10 mongosh processes to start and connect first
for i in $(seq 1 $N); do
  mongosh --quiet --eval "
    while (Date.now() < $START * 1000) {}                       // busy-wait until the common start second
    const t0 = Date.now();
    const r = db.getSiblingDB('$DB').customers.updateOne(
      {_id: 900001, accounts: {\$elemMatch: {account_id: 900001, status: 'ACTIVE', balance: {\$gte: NumberDecimal('300.00')}}}},
      {\$inc: {'accounts.\$.balance': NumberDecimal('-300.00')}});
    print('client $i: ' + (r.modifiedCount === 1 ? 'DEBITED ' : 'REFUSED ') + '(matched=' + r.matchedCount + ') at +' + (t0 - $START * 1000) + ' ms');" > "$OUT/c$i.txt" 2>&1 &
done
wait

cat "$OUT"/c*.txt | sort -V
OK=$(cat "$OUT"/c*.txt | grep -c DEBITED)
FINAL=$(mongosh --quiet --eval "print(db.getSiblingDB('$DB').customers.findOne({_id: 900001}).accounts[0].balance.toString())")
echo "debited: $OK   refused: $((N - OK))   final balance: $FINAL"
mongosh --quiet --eval "db.getSiblingDB('$DB').customers.deleteMany({_id: 900001})" > /dev/null
rm -rf "$OUT"

if [ "$OK" -eq 3 ] && [ "$FINAL" = "100.00" ]; then echo "RESULT: PASS (exactly 3 debits, balance 100.00, never negative)"; exit 0
else echo "RESULT: FAIL"; exit 1; fi
