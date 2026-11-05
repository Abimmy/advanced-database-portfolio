-- =============================================================================
-- MikePay - Portfolio 3: integrity checks for the test accounts (ids 900001-900099)
-- Statement 1: every row must show problems = 0.
-- Statement 2: total money held by the test accounts (a transfer must never change it).
-- Also executed by concurrency_tests.py after the concurrent scenarios.
-- Keep this file free of semicolons inside comments and strings (the Python runner
-- splits statements on semicolons).
-- =============================================================================

USE mikepay_db;

SELECT 'negative balances' AS check_name, COUNT(*) AS problems
FROM accounts
WHERE account_id BETWEEN 900001 AND 900099 AND balance < 0
UNION ALL
SELECT 'balance differs from latest ledger balance_after', COUNT(*)
FROM accounts a
JOIN transactions t ON t.account_id = a.account_id
WHERE a.account_id BETWEEN 900001 AND 900099
  AND t.transaction_id = (SELECT MAX(x.transaction_id) FROM transactions x WHERE x.account_id = a.account_id)
  AND a.balance <> t.balance_after
UNION ALL
SELECT 'completed transfer without exactly 2 ledger legs', COUNT(*)
FROM transfers tr
WHERE tr.status = 'COMPLETED'
  AND tr.source_account_id BETWEEN 900001 AND 900099
  AND (SELECT COUNT(*) FROM transactions x WHERE x.transfer_id = tr.transfer_id) <> 2
UNION ALL
SELECT 'ledger leg amount or account differs from its transfer', COUNT(*)
FROM transactions x
JOIN transfers tr ON tr.transfer_id = x.transfer_id
WHERE tr.source_account_id BETWEEN 900001 AND 900099
  AND (x.amount <> tr.amount
       OR (x.transaction_type = 'TRANSFER_DEBIT'  AND x.account_id <> tr.source_account_id)
       OR (x.transaction_type = 'TRANSFER_CREDIT' AND x.account_id <> tr.destination_account_id))
UNION ALL
SELECT 'failed or pending transfer that has ledger rows', COUNT(*)
FROM transfers tr
JOIN transactions x ON x.transfer_id = tr.transfer_id
WHERE tr.source_account_id BETWEEN 900001 AND 900099
  AND tr.status <> 'COMPLETED';

SELECT SUM(balance) AS total_money_in_test_accounts
FROM accounts
WHERE account_id BETWEEN 900001 AND 900099;
