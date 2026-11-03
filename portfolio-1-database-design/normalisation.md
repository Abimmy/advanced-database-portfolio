# MikePay — Normalisation Explanation

Normalisation removes redundancy so that each fact is stored once. This avoids update, insert and delete anomalies. The MikePay schema was reached by starting from one wide "everything in one table" design and normalising it step by step.

## Starting point: one wide table (unnormalised)

| customer_name | customer_email | customer_phone | account_numbers | account_type | balance | txn_type | amount | counterparty_account | transfer_status |
|---|---|---|---|---|---|---|---|---|---|
| Adaeze Okafor | adaeze.okafor@example.com | 08000000001 | 1000000001, 1000000002 | SAVINGS | 350000.00 | TRANSFER_DEBIT | 100000.00 | 1000000003 | COMPLETED |

Problems with this design:
- `account_numbers` holds a list, so a value is not atomic and the column cannot be searched or constrained properly.
- The customer's name, email and phone are repeated on every transaction row. Changing a phone number means editing many rows, and missing one makes the data inconsistent (**update anomaly**).
- A customer cannot be stored until they have a transaction (**insert anomaly**).
- Deleting a customer's last transaction also deletes the only record of the customer (**delete anomaly**).

## First normal form (1NF): atomic values, no repeating groups
Rule: every column holds a single value and there are no repeating groups.

Fix: split `account_numbers` so each row has exactly one account number. The key becomes the composite **(account_number, transaction_no)**.

## Second normal form (2NF): no partial dependencies
Rule: in 1NF, and every non-key column depends on the whole key, not part of it.

With the composite key (account_number, transaction_no):
- `account_type`, `balance`, `customer_name`, `customer_email` and `customer_phone` depend only on `account_number` (part of the key). These are partial dependencies.
- `txn_type`, `amount` and the counterparty depend on the whole key.

Fix: move the account-level and customer-level columns into their own table, keyed by `account_number`. The ledger rows stay in `transactions`. This gives the **accounts** and **transactions** tables.

## Third normal form (3NF): no transitive dependencies
Rule: in 2NF, and no non-key column depends on another non-key column.

In the accounts table, `customer_name` and `customer_phone` depend on `customer_email`, which depends on `account_number`. That is a transitive dependency (`account_number → customer → name/phone`), so a customer with two accounts would still repeat their details.

Fix: move customer details into **customers** and keep only a `customer_id` foreign key in `accounts`.

A transfer is a separate real-world fact with its own status and failure reason. It is held in **transfers**, and each completed transfer produces two ledger rows. Saved payees and the audit history follow the same rule and live in **beneficiaries** and **audit_log**.

## Result
| Table | Functional dependency (determinant → dependants) | Candidate keys |
|---|---|---|
| customers | customer_id → name, email, phone, status | customer_id, email, phone |
| accounts | account_id → customer_id, account_number, type, currency, balance, status | account_id, account_number |
| transfers | transfer_id → reference, source, destination, amount, status, reason | transfer_id, reference |
| transactions | transaction_id → account_id, transfer_id, type, amount, balance_after | transaction_id |
| beneficiaries | beneficiary_id → customer_id, beneficiary_account_id, nickname | beneficiary_id, (customer_id, beneficiary_account_id) |
| audit_log | audit_id → account_id, action, old/new balance, user, time | audit_id |

In every table each determinant is a candidate key, so the design also satisfies **Boyce-Codd normal form (BCNF)**.

## Deliberate denormalisation (stated openly)
Some stored values could in theory be computed from other tables. They are kept on purpose, and the trade-offs are:

| Stored value | Why it is kept | How consistency is protected |
|---|---|---|
| `accounts.balance` (equals the sum of the account's ledger rows) | Reading a balance should be one row lookup, not a scan of the whole ledger | Integrity query 6 in `sql/04_verification_queries.sql` compares it with the ledger. It is **checked, not enforced** by a constraint. |
| `transactions.balance_after` | Gives an audit snapshot at the time of each movement | Integrity query 7 compares the latest value with the account balance. |
| Transfer leg `amount` equals `transfers.amount` | Each leg is a ledger row in its own right | Integrity query 8 checks that the legs net to zero. Not enforced by a constraint. |

The balance-update logic that keeps these values in step is built in **Portfolio 3** using transactions.

## Limitations
- Balance and ledger agreement is verified by queries, not guaranteed by a constraint. A buggy update could break it, so Portfolio 3 will do transfers inside transactions.
- A customer can currently save their own account as a beneficiary. A cross-table rule like that cannot be a `CHECK` constraint and would need a trigger.
- `currency` is stored per account, but nothing stops a transfer between accounts of different currencies. All sample data is NGN.
