-- =============================================================================
-- MikePay - Portfolio 1: verification queries
-- Read-only. Shows the implemented structure and checks data integrity.
-- Run after 03_sample_data.sql.
-- =============================================================================

USE mikepay_db;

SELECT '--- 1. Tables and row counts ---' AS section;
SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM customers
UNION ALL SELECT 'accounts',      COUNT(*) FROM accounts
UNION ALL SELECT 'transfers',     COUNT(*) FROM transfers
UNION ALL SELECT 'transactions',  COUNT(*) FROM transactions
UNION ALL SELECT 'beneficiaries', COUNT(*) FROM beneficiaries
UNION ALL SELECT 'audit_log',     COUNT(*) FROM audit_log;

SELECT '--- 2. Primary key, unique and foreign key constraints ---' AS section;
SELECT table_name, constraint_name, constraint_type
FROM information_schema.table_constraints
WHERE table_schema = 'mikepay_db'
ORDER BY table_name, FIELD(constraint_type, 'PRIMARY KEY', 'UNIQUE', 'FOREIGN KEY', 'CHECK'), constraint_name;

SELECT '--- 3. Foreign keys: referenced table and delete/update rules ---' AS section;
SELECT rc.table_name, rc.constraint_name, k.column_name,
       rc.referenced_table_name, k.referenced_column_name,
       rc.delete_rule, rc.update_rule
FROM information_schema.referential_constraints rc
JOIN information_schema.key_column_usage k
  ON k.constraint_schema = rc.constraint_schema
 AND k.constraint_name   = rc.constraint_name
 AND k.table_name        = rc.table_name
WHERE rc.constraint_schema = 'mikepay_db'
ORDER BY rc.table_name, rc.constraint_name;

SELECT '--- 4. CHECK constraints ---' AS section;
SELECT table_name, constraint_name, check_clause
FROM information_schema.check_constraints
WHERE constraint_schema = 'mikepay_db'
ORDER BY table_name, constraint_name;

SELECT '--- 5. Indexes ---' AS section;
SELECT table_name, index_name, non_unique,
       GROUP_CONCAT(column_name ORDER BY seq_in_index) AS columns_in_index
FROM information_schema.statistics
WHERE table_schema = 'mikepay_db'
GROUP BY table_name, index_name, non_unique
ORDER BY table_name, index_name;

SELECT '--- 6. Integrity: account balance must equal the sum of its ledger rows ---' AS section;
SELECT account_id, account_number, balance, ledger_balance,
       IF(balance = ledger_balance, 'OK', 'MISMATCH') AS result
FROM (
    SELECT a.account_id, a.account_number, a.balance,
           COALESCE(SUM(CASE WHEN t.transaction_type IN ('DEPOSIT','TRANSFER_CREDIT')
                             THEN t.amount ELSE -t.amount END), 0) AS ledger_balance
    FROM accounts a
    LEFT JOIN transactions t ON t.account_id = a.account_id
    GROUP BY a.account_id, a.account_number, a.balance
) x
ORDER BY account_id;

SELECT '--- 7. Integrity: latest balance_after must equal the account balance ---' AS section;
SELECT a.account_id, a.balance, t.balance_after AS last_balance_after,
       IF(a.balance = t.balance_after, 'OK', 'MISMATCH') AS result
FROM accounts a
JOIN transactions t ON t.account_id = a.account_id
WHERE t.transaction_id = (SELECT MAX(t2.transaction_id)
                          FROM transactions t2
                          WHERE t2.account_id = a.account_id
                            AND t2.created_at = (SELECT MAX(t3.created_at)
                                                 FROM transactions t3
                                                 WHERE t3.account_id = a.account_id))
ORDER BY a.account_id;

SELECT '--- 8. Integrity: every transfer leaves a consistent ledger ---' AS section;
SELECT tr.transfer_id, tr.status, tr.amount,
       COALESCE(SUM(t.transaction_type = 'TRANSFER_DEBIT'), 0)  AS debit_legs,
       COALESCE(SUM(t.transaction_type = 'TRANSFER_CREDIT'), 0) AS credit_legs,
       COALESCE(SUM(CASE WHEN t.transaction_type = 'TRANSFER_CREDIT' THEN t.amount ELSE -t.amount END), 0) AS net_movement,
       CASE
         WHEN tr.status = 'COMPLETED'
              AND SUM(t.transaction_type = 'TRANSFER_DEBIT') = 1
              AND SUM(t.transaction_type = 'TRANSFER_CREDIT') = 1
              AND SUM(CASE WHEN t.transaction_type = 'TRANSFER_CREDIT' THEN t.amount ELSE -t.amount END) = 0
              THEN 'OK'
         WHEN tr.status = 'FAILED' AND COUNT(t.transaction_id) = 0 THEN 'OK'
         ELSE 'CHECK'
       END AS result
FROM transfers tr
LEFT JOIN transactions t ON t.transfer_id = tr.transfer_id
GROUP BY tr.transfer_id, tr.status, tr.amount
ORDER BY tr.transfer_id;

SELECT '--- 9. Audit trail (filled by triggers) ---' AS section;
SELECT audit_id, account_id, action, old_balance, new_balance, changed_by
FROM audit_log
ORDER BY audit_id;

SELECT '--- 10. Sample business query: customers with their accounts and balances ---' AS section;
SELECT c.customer_id, CONCAT(c.first_name, ' ', c.last_name) AS customer, c.status AS customer_status,
       a.account_number, a.account_type, a.status AS account_status, a.balance
FROM customers c
JOIN accounts a ON a.customer_id = c.customer_id
ORDER BY c.customer_id, a.account_id;
