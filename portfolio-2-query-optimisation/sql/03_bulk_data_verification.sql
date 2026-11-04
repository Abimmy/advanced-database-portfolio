-- =============================================================================
-- MikePay - Portfolio 2: verify the bulk data is consistent before benchmarking
-- Read-only. Every "problem rows" figure must be 0.
-- =============================================================================

USE mikepay_db;

SELECT '--- 1. Row counts (Portfolio 1 rows + bulk rows) ---' AS section;
SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM customers
UNION ALL SELECT 'accounts',      COUNT(*) FROM accounts
UNION ALL SELECT 'transfers',     COUNT(*) FROM transfers
UNION ALL SELECT 'transactions',  COUNT(*) FROM transactions
UNION ALL SELECT 'audit_log',     COUNT(*) FROM audit_log;

SELECT '--- 2. Accounts whose balance differs from the sum of their ledger rows ---' AS section;
SELECT COUNT(*) AS problem_rows
FROM accounts a
LEFT JOIN (SELECT account_id,
                  SUM(IF(transaction_type IN ('DEPOSIT','TRANSFER_CREDIT'), amount, -amount)) AS ledger_balance
           FROM transactions GROUP BY account_id) l ON l.account_id = a.account_id
WHERE a.balance <> COALESCE(l.ledger_balance, 0);

SELECT '--- 3. Completed transfers that do not have exactly one debit and one credit ---' AS section;
SELECT COUNT(*) AS problem_rows
FROM transfers t
LEFT JOIN (SELECT transfer_id,
                  SUM(transaction_type = 'TRANSFER_DEBIT')  AS debits,
                  SUM(transaction_type = 'TRANSFER_CREDIT') AS credits,
                  SUM(IF(transaction_type = 'TRANSFER_CREDIT', amount, -amount)) AS net
           FROM transactions WHERE transfer_id IS NOT NULL GROUP BY transfer_id) l ON l.transfer_id = t.transfer_id
WHERE t.status = 'COMPLETED'
  AND NOT (COALESCE(l.debits, 0) = 1 AND COALESCE(l.credits, 0) = 1 AND COALESCE(l.net, 0) = 0);

SELECT '--- 4. Failed transfers that have ledger rows ---' AS section;
SELECT COUNT(*) AS problem_rows
FROM transfers t JOIN transactions x ON x.transfer_id = t.transfer_id
WHERE t.status = 'FAILED';

SELECT '--- 5. Accounts with no ACCOUNT_OPENED audit row ---' AS section;
SELECT COUNT(*) AS problem_rows
FROM accounts a
WHERE NOT EXISTS (SELECT 1 FROM audit_log l WHERE l.account_id = a.account_id AND l.action = 'ACCOUNT_OPENED');

SELECT '--- 6. Accounts whose latest audit new_balance differs from the account balance ---' AS section;
SELECT COUNT(*) AS problem_rows
FROM accounts a
JOIN audit_log l ON l.account_id = a.account_id
WHERE l.audit_id = (SELECT MAX(l2.audit_id) FROM audit_log l2 WHERE l2.account_id = a.account_id)
  AND l.new_balance <> a.balance;

SELECT '--- 7. Data shape the experiments depend on ---' AS section;
SELECT 'transactions per account: min / max' AS metric,
       MIN(c) AS min_value, MAX(c) AS max_value
FROM (SELECT account_id, COUNT(*) AS c FROM transactions GROUP BY account_id) x;
SELECT 'ledger rows for busy account 1001' AS metric, COUNT(*) AS value FROM transactions WHERE account_id = 1001;
SELECT 'ledger date range' AS metric, MIN(created_at) AS first_row, MAX(created_at) AS last_row FROM transactions;
SELECT status, COUNT(*) AS transfers FROM transfers GROUP BY status;
