-- =============================================================================
-- MikePay - Portfolio 3: COMMIT / ROLLBACK demonstrations (single session)
-- Run with:  mysql -u root -n -t -vvv --force < 03_commit_rollback_tests.sql
-- (--force lets the script continue past the errors that T6a and T6b are MEANT to cause)
-- Requires 01_transfer_procedures.sql and 02_test_data.sql to have been run.
-- Uses only test accounts 900001-900005. Total money at the start is 4350.00.
-- =============================================================================

USE mikepay_db;
SET SESSION sql_mode = 'STRICT_ALL_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ZERO_IN_DATE,NO_ZERO_DATE,NO_ENGINE_SUBSTITUTION';

CALL sp_p3_reset_test_data();

SELECT '=== Starting state ===' AS step;
SELECT account_id, balance, status FROM accounts WHERE account_id BETWEEN 900001 AND 900099 ORDER BY account_id;

-- -----------------------------------------------------------------------------
SELECT '=== T1: successful transfer, 250.00 from 900001 to 900002 (COMMIT) ===' AS step;
CALL sp_transfer_funds('P3-T1', 900001, 900002, 250.00, @status, @message);
SELECT @status AS status, @message AS message;
SELECT account_id, balance FROM accounts WHERE account_id IN (900001, 900002) ORDER BY account_id;
SELECT transfer_id, reference, source_account_id, destination_account_id, amount, status, failure_reason
FROM transfers WHERE reference = 'P3-T1';
SELECT account_id, transfer_id, transaction_type, amount, balance_after
FROM transactions WHERE account_id BETWEEN 900001 AND 900099 ORDER BY transaction_id;
SELECT account_id, action, old_balance, new_balance FROM audit_log
WHERE account_id IN (900001, 900002) AND action = 'BALANCE_CHANGED' ORDER BY audit_id;

-- -----------------------------------------------------------------------------
SELECT '=== T2: insufficient funds, 99999.00 from 900002 to 900001 ===' AS step;
CALL sp_transfer_funds('P3-T2', 900002, 900001, 99999.00, @status, @message);
SELECT @status AS status, @message AS message;
SELECT account_id, balance FROM accounts WHERE account_id IN (900001, 900002) ORDER BY account_id;
SELECT reference, status, failure_reason FROM transfers WHERE reference = 'P3-T2';
SELECT COUNT(*) AS ledger_rows_for_this_transfer
FROM transactions x JOIN transfers t ON t.transfer_id = x.transfer_id WHERE t.reference = 'P3-T2';

-- -----------------------------------------------------------------------------
SELECT '=== T3: destination account is FROZEN (900005) ===' AS step;
CALL sp_transfer_funds('P3-T3', 900001, 900005, 10.00, @status, @message);
SELECT @status AS status, @message AS message;
SELECT account_id, balance, status FROM accounts WHERE account_id IN (900001, 900005) ORDER BY account_id;

-- -----------------------------------------------------------------------------
SELECT '=== T4: invalid requests are rejected and nothing is recorded ===' AS step;
CALL sp_transfer_funds('P3-T4a', 900001, 900002, -5.00, @status, @message);
SELECT 'negative amount' AS request, @status AS status, @message AS message;
CALL sp_transfer_funds('P3-T4b', 900001, 900001, 5.00, @status, @message);
SELECT 'same account' AS request, @status AS status, @message AS message;
CALL sp_transfer_funds('P3-T4c', 900001, 987654, 5.00, @status, @message);
SELECT 'unknown destination' AS request, @status AS status, @message AS message;
SELECT COUNT(*) AS transfer_rows_for_T4 FROM transfers WHERE reference LIKE 'P3-T4%';

-- -----------------------------------------------------------------------------
SELECT '=== T5: error AFTER the balances were updated: ROLLBACK inside the procedure ===' AS step;
-- Reusing reference P3-T1 breaks the UNIQUE constraint on transfers.reference. By then the
-- procedure has already run both UPDATE accounts statements, so this proves they are undone.
SELECT account_id, balance FROM accounts WHERE account_id IN (900001, 900002) ORDER BY account_id;
CALL sp_transfer_funds('P3-T1', 900001, 900002, 10.00, @status, @message);
SELECT @status AS status, @message AS message;
SELECT account_id, balance FROM accounts WHERE account_id IN (900001, 900002) ORDER BY account_id;
SELECT COUNT(*) AS ledger_rows_total FROM transactions WHERE account_id BETWEEN 900001 AND 900099;

SELECT '=== Integrity check after T1-T5 (all problems must be 0, total must be 4350.00) ===' AS step;
SELECT 'balance differs from latest ledger balance_after' AS check_name, COUNT(*) AS problems
FROM accounts a JOIN transactions t ON t.account_id = a.account_id
WHERE a.account_id BETWEEN 900001 AND 900099
  AND t.transaction_id = (SELECT MAX(x.transaction_id) FROM transactions x WHERE x.account_id = a.account_id)
  AND a.balance <> t.balance_after;
SELECT SUM(balance) AS total_money FROM accounts WHERE account_id BETWEEN 900001 AND 900099;

-- -----------------------------------------------------------------------------
SELECT '=== T6a: manual transaction. Debit succeeds, credit step fails, ROLLBACK ===' AS step;
SELECT account_id, balance FROM accounts WHERE account_id = 900003;
START TRANSACTION;
UPDATE accounts SET balance = balance - 100.00 WHERE account_id = 900003;
SELECT 'inside the open transaction' AS where_we_are, balance FROM accounts WHERE account_id = 900003;
-- The "credit" step fails: the ledger row points at an account that does not exist (foreign key).
INSERT INTO transactions (account_id, transfer_id, transaction_type, amount, balance_after, description)
VALUES (999999999, NULL, 'DEPOSIT', 100.00, 100.00, 'credit leg that cannot succeed');
-- The failed INSERT undid only itself. The debit is still pending in the open transaction.
SELECT 'after the failed statement, before ROLLBACK' AS where_we_are, balance FROM accounts WHERE account_id = 900003;
ROLLBACK;
SELECT 'after ROLLBACK' AS where_we_are, balance FROM accounts WHERE account_id = 900003;

-- -----------------------------------------------------------------------------
SELECT '=== T7: SAVEPOINT: roll back part of a transaction, commit the rest ===' AS step;
SELECT account_id, balance FROM accounts WHERE account_id IN (900003, 900004) ORDER BY account_id;
START TRANSACTION;
-- step 1: move 30.00 (debit + credit)
UPDATE accounts SET balance = balance - 30.00 WHERE account_id = 900003;
UPDATE accounts SET balance = balance + 30.00 WHERE account_id = 900004;
SAVEPOINT after_first_step;
-- step 2: move 50.00 (debit + credit), which we then decide to cancel
UPDATE accounts SET balance = balance - 50.00 WHERE account_id = 900003;
UPDATE accounts SET balance = balance + 50.00 WHERE account_id = 900004;
SELECT 'before ROLLBACK TO SAVEPOINT' AS where_we_are, account_id, balance
FROM accounts WHERE account_id IN (900003, 900004) ORDER BY account_id;
ROLLBACK TO SAVEPOINT after_first_step;
COMMIT;
SELECT 'after ROLLBACK TO SAVEPOINT and COMMIT' AS where_we_are, account_id, balance
FROM accounts WHERE account_id IN (900003, 900004) ORDER BY account_id;

-- -----------------------------------------------------------------------------
SELECT '=== T6b: the SAME failure WITHOUT a transaction (autocommit on). Money is lost. ===' AS step;
SELECT @@autocommit AS autocommit;
SELECT SUM(balance) AS total_money_before FROM accounts WHERE account_id BETWEEN 900001 AND 900099;
UPDATE accounts SET balance = balance - 100.00 WHERE account_id = 900003;
INSERT INTO transactions (account_id, transfer_id, transaction_type, amount, balance_after, description)
VALUES (999999999, NULL, 'DEPOSIT', 100.00, 100.00, 'credit leg that cannot succeed');
-- No ROLLBACK is possible: the debit was committed the moment it ran.
SELECT SUM(balance) AS total_money_after FROM accounts WHERE account_id BETWEEN 900001 AND 900099;
SELECT account_id, action, old_balance, new_balance FROM audit_log
WHERE account_id = 900003 AND action = 'BALANCE_CHANGED' ORDER BY audit_id;

-- Put the test accounts back to the known state.
CALL sp_p3_reset_test_data();
SELECT '=== Reset: test accounts restored ===' AS step;
SELECT SUM(balance) AS total_money FROM accounts WHERE account_id BETWEEN 900001 AND 900099;
