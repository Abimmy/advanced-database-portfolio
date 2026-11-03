-- =============================================================================
-- MikePay - Portfolio 1: constraint tests
-- Each statement below is EXPECTED TO FAIL. It tries to break one rule, and the
-- database should reject it. Run the client with --force so it continues past
-- each error:  mysql -u root --force -vvv < 05_constraint_tests.sql
-- Run after 03_sample_data.sql. No data is changed if every test is rejected.
-- Note: failed INSERTs still consume AUTO_INCREMENT values in InnoDB, so ids
-- created after this script may skip numbers.
-- =============================================================================

SET SESSION sql_mode = 'STRICT_ALL_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ZERO_IN_DATE,NO_ZERO_DATE,NO_ENGINE_SUBSTITUTION';
USE mikepay_db;

SELECT 'TEST 1: negative balance (CHECK ck_accounts_balance_nonneg)' AS test;
UPDATE accounts SET balance = -1.00 WHERE account_id = 2;

SELECT 'TEST 2: duplicate email (UNIQUE uq_customers_email)' AS test;
INSERT INTO customers (first_name, last_name, email, phone)
VALUES ('Test', 'Duplicate', 'adaeze.okafor@example.com', '08000009999');

SELECT 'TEST 3: account for a customer that does not exist (FOREIGN KEY fk_accounts_customer)' AS test;
INSERT INTO accounts (customer_id, account_number, account_type)
VALUES (9999, '2000000001', 'SAVINGS');

SELECT 'TEST 4: transfer from an account to itself (CHECK ck_transfers_different_accounts)' AS test;
INSERT INTO transfers (reference, source_account_id, destination_account_id, amount)
VALUES ('MPY-TEST-0001', 1, 1, 100.00);

SELECT 'TEST 5: zero-amount transfer (CHECK ck_transfers_amount_positive)' AS test;
INSERT INTO transfers (reference, source_account_id, destination_account_id, amount)
VALUES ('MPY-TEST-0002', 1, 2, 0.00);

SELECT 'TEST 6: failed transfer with no failure reason (CHECK ck_transfers_failure_reason)' AS test;
INSERT INTO transfers (reference, source_account_id, destination_account_id, amount, status)
VALUES ('MPY-TEST-0003', 1, 2, 100.00, 'FAILED');

SELECT 'TEST 7: deposit linked to a transfer (CHECK ck_transactions_transfer_link)' AS test;
INSERT INTO transactions (account_id, transfer_id, transaction_type, amount, balance_after)
VALUES (1, 1, 'DEPOSIT', 100.00, 350100.00);

SELECT 'TEST 8: delete a customer who still has accounts (FOREIGN KEY ON DELETE RESTRICT)' AS test;
DELETE FROM customers WHERE customer_id = 1;

SELECT 'TEST 9: invalid ENUM value (strict mode)' AS test;
INSERT INTO customers (first_name, last_name, email, phone, status)
VALUES ('Test', 'BadStatus', 'bad.status@example.com', '08000009998', 'DELETED');

SELECT 'TEST 10: malformed account number (CHECK ck_accounts_number_format)' AS test;
INSERT INTO accounts (customer_id, account_number, account_type)
VALUES (1, 'ABC123', 'SAVINGS');

SELECT 'TEST 11: balance too large for DECIMAL(15,2)' AS test;
UPDATE accounts SET balance = 100000000000000.00 WHERE account_id = 2;

SELECT 'TEST 12: duplicate beneficiary (UNIQUE uq_beneficiaries_customer_account)' AS test;
INSERT INTO beneficiaries (customer_id, beneficiary_account_id, nickname)
VALUES (1, 3, 'Tunde again');

SELECT 'TEST 13: NULL in a NOT NULL column' AS test;
INSERT INTO customers (first_name, last_name, email, phone)
VALUES ('Test', 'NoEmail', NULL, '08000009997');

SELECT 'AFTER TESTS: row counts must be unchanged (8, 9, 6 transfers)' AS check_name;
SELECT (SELECT COUNT(*) FROM customers) AS customers,
       (SELECT COUNT(*) FROM accounts)  AS accounts,
       (SELECT COUNT(*) FROM transfers) AS transfers,
       (SELECT balance FROM accounts WHERE account_id = 2) AS account_2_balance;
