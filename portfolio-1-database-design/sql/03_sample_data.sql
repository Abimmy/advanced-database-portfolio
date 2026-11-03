-- =============================================================================
-- MikePay - Portfolio 1: synthetic sample data
-- All names, emails, phone numbers and account numbers are invented (example.com
-- addresses, 0800000xxxx numbers). No real customer or banking data.
-- Run after 01_create_schema.sql and 02_triggers.sql.
--
-- Accounts are opened with a zero balance, then every balance change is paired
-- with a ledger row in `transactions`. The triggers write audit_log rows for
-- each balance change. The whole load is one transaction.
-- =============================================================================

SET SESSION sql_mode = 'STRICT_ALL_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ZERO_IN_DATE,NO_ZERO_DATE,NO_ENGINE_SUBSTITUTION';
USE mikepay_db;

START TRANSACTION;

INSERT INTO customers (customer_id, first_name, last_name, email, phone, status) VALUES
(1, 'Adaeze',  'Okafor',  'adaeze.okafor@example.com',  '08000000001', 'ACTIVE'),
(2, 'Tunde',   'Bello',   'tunde.bello@example.com',    '08000000002', 'ACTIVE'),
(3, 'Chioma',  'Eze',     'chioma.eze@example.com',     '08000000003', 'ACTIVE'),
(4, 'Ibrahim', 'Musa',    'ibrahim.musa@example.com',   '08000000004', 'ACTIVE'),
(5, 'Funke',   'Adeyemi', 'funke.adeyemi@example.com',  '08000000005', 'ACTIVE'),
(6, 'Emeka',   'Nwosu',   'emeka.nwosu@example.com',    '08000000006', 'ACTIVE'),
(7, 'Zainab',  'Lawal',   'zainab.lawal@example.com',   '08000000007', 'SUSPENDED'),
(8, 'David',   'Okoro',   'david.okoro@example.com',    '08000000008', 'ACTIVE');

INSERT INTO accounts (account_id, customer_id, account_number, account_type, status) VALUES
(1, 1, '1000000001', 'SAVINGS', 'ACTIVE'),
(2, 1, '1000000002', 'CURRENT', 'ACTIVE'),
(3, 2, '1000000003', 'CURRENT', 'ACTIVE'),
(4, 3, '1000000004', 'SAVINGS', 'ACTIVE'),
(5, 4, '1000000005', 'CURRENT', 'ACTIVE'),
(6, 5, '1000000006', 'SAVINGS', 'ACTIVE'),
(7, 6, '1000000007', 'CURRENT', 'ACTIVE'),
(8, 7, '1000000008', 'SAVINGS', 'FROZEN'),   -- owner is suspended
(9, 8, '1000000009', 'CURRENT', 'ACTIVE');

-- Beneficiaries (saved payees, MikePay accounts only)
INSERT INTO beneficiaries (customer_id, beneficiary_account_id, nickname) VALUES
(1, 3, 'Tunde'),
(1, 5, 'Ibrahim rent'),
(2, 5, 'Ibrahim'),
(5, 4, 'Chioma'),
(8, 7, 'Emeka');

-- ---- Deposits (one per account) -------------------------------------------
INSERT INTO transactions (account_id, transaction_type, amount, balance_after, description, created_at) VALUES
(1, 'DEPOSIT', 500000.00, 500000.00, 'Initial deposit', '2026-10-01 09:00:00'),
(2, 'DEPOSIT', 150000.00, 150000.00, 'Initial deposit', '2026-10-01 09:05:00'),
(3, 'DEPOSIT', 300000.00, 300000.00, 'Initial deposit', '2026-10-01 09:10:00'),
(4, 'DEPOSIT', 250000.00, 250000.00, 'Initial deposit', '2026-10-01 09:15:00'),
(5, 'DEPOSIT',  80000.00,  80000.00, 'Initial deposit', '2026-10-01 09:20:00'),
(6, 'DEPOSIT', 400000.00, 400000.00, 'Initial deposit', '2026-10-01 09:25:00'),
(7, 'DEPOSIT', 120000.00, 120000.00, 'Initial deposit', '2026-10-01 09:30:00'),
(8, 'DEPOSIT',  50000.00,  50000.00, 'Initial deposit', '2026-10-01 09:35:00'),
(9, 'DEPOSIT', 200000.00, 200000.00, 'Initial deposit', '2026-10-01 09:40:00');

UPDATE accounts SET balance = 500000.00 WHERE account_id = 1;
UPDATE accounts SET balance = 150000.00 WHERE account_id = 2;
UPDATE accounts SET balance = 300000.00 WHERE account_id = 3;
UPDATE accounts SET balance = 250000.00 WHERE account_id = 4;
UPDATE accounts SET balance =  80000.00 WHERE account_id = 5;
UPDATE accounts SET balance = 400000.00 WHERE account_id = 6;
UPDATE accounts SET balance = 120000.00 WHERE account_id = 7;
UPDATE accounts SET balance =  50000.00 WHERE account_id = 8;
UPDATE accounts SET balance = 200000.00 WHERE account_id = 9;

-- ---- Withdrawals ----------------------------------------------------------
INSERT INTO transactions (account_id, transaction_type, amount, balance_after, description, created_at) VALUES
(1, 'WITHDRAWAL', 50000.00,  450000.00, 'ATM withdrawal',  '2026-10-02 10:00:00'),
(3, 'WITHDRAWAL', 20000.50,  279999.50, 'POS purchase',    '2026-10-02 11:30:00'),
(5, 'WITHDRAWAL', 10000.00,   70000.00, 'ATM withdrawal',  '2026-10-03 08:45:00');

UPDATE accounts SET balance = 450000.00 WHERE account_id = 1;
UPDATE accounts SET balance = 279999.50 WHERE account_id = 3;
UPDATE accounts SET balance =  70000.00 WHERE account_id = 5;

-- ---- Completed transfers (each = 1 transfer row + debit leg + credit leg) --
INSERT INTO transfers (transfer_id, reference, source_account_id, destination_account_id, amount, status, created_at, completed_at) VALUES
(1, 'MPY-20261005-0001', 1, 3, 100000.00, 'COMPLETED', '2026-10-05 14:00:00', '2026-10-05 14:00:01'),
(2, 'MPY-20261006-0002', 3, 5,  45000.00, 'COMPLETED', '2026-10-06 09:10:00', '2026-10-06 09:10:01'),
(3, 'MPY-20261007-0003', 6, 4,  75000.25, 'COMPLETED', '2026-10-07 16:20:00', '2026-10-07 16:20:01'),
(4, 'MPY-20261008-0004', 9, 7,  30000.00, 'COMPLETED', '2026-10-08 12:00:00', '2026-10-08 12:00:01');

INSERT INTO transactions (account_id, transfer_id, transaction_type, amount, balance_after, description, created_at) VALUES
(1, 1, 'TRANSFER_DEBIT',  100000.00, 350000.00, 'Transfer MPY-20261005-0001', '2026-10-05 14:00:01'),
(3, 1, 'TRANSFER_CREDIT', 100000.00, 379999.50, 'Transfer MPY-20261005-0001', '2026-10-05 14:00:01'),
(3, 2, 'TRANSFER_DEBIT',   45000.00, 334999.50, 'Transfer MPY-20261006-0002', '2026-10-06 09:10:01'),
(5, 2, 'TRANSFER_CREDIT',  45000.00, 115000.00, 'Transfer MPY-20261006-0002', '2026-10-06 09:10:01'),
(6, 3, 'TRANSFER_DEBIT',   75000.25, 324999.75, 'Transfer MPY-20261007-0003', '2026-10-07 16:20:01'),
(4, 3, 'TRANSFER_CREDIT',  75000.25, 325000.25, 'Transfer MPY-20261007-0003', '2026-10-07 16:20:01'),
(9, 4, 'TRANSFER_DEBIT',   30000.00, 170000.00, 'Transfer MPY-20261008-0004', '2026-10-08 12:00:01'),
(7, 4, 'TRANSFER_CREDIT',  30000.00, 150000.00, 'Transfer MPY-20261008-0004', '2026-10-08 12:00:01');

UPDATE accounts SET balance = 350000.00 WHERE account_id = 1;
UPDATE accounts SET balance = 334999.50 WHERE account_id = 3;
UPDATE accounts SET balance = 115000.00 WHERE account_id = 5;
UPDATE accounts SET balance = 324999.75 WHERE account_id = 6;
UPDATE accounts SET balance = 325000.25 WHERE account_id = 4;
UPDATE accounts SET balance = 170000.00 WHERE account_id = 9;
UPDATE accounts SET balance = 150000.00 WHERE account_id = 7;

-- ---- Failed transfers: recorded, but no ledger rows and no balance change ---
INSERT INTO transfers (transfer_id, reference, source_account_id, destination_account_id, amount, status, failure_reason, created_at) VALUES
(5, 'MPY-20261009-0005', 5, 1, 5000000.00, 'FAILED', 'Insufficient funds',          '2026-10-09 10:00:00'),
(6, 'MPY-20261009-0006', 2, 8,   10000.00, 'FAILED', 'Destination account frozen',  '2026-10-09 11:00:00');

COMMIT;
