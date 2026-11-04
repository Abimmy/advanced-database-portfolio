-- =============================================================================
-- MikePay - Portfolio 2: bulk synthetic data for query-performance testing
-- Target: MariaDB 10.4.32. Adds to the Portfolio 1 data (ids 1-9 are untouched);
-- all bulk rows use ids from 1001 upward, so the script is re-runnable: it
-- deletes any previous bulk rows first. To return to the small Portfolio 1
-- dataset, re-run portfolio-1-database-design/sql/01..03 instead.
--
-- Volumes: 50,000 customers; 80,000 accounts; ~780,000 ledger rows;
--          110,000 transfers (100,000 completed + 10,000 failed).
-- Reproducible: every RAND() uses a fixed seed. No real data of any kind.
-- Skew: account choice uses POW(RAND(), 2), so low-numbered accounts are busier.
-- =============================================================================

SET SESSION sql_mode = 'STRICT_ALL_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ZERO_IN_DATE,NO_ZERO_DATE,NO_ENGINE_SUBSTITUTION';
USE mikepay_db;

SELECT NOW() AS started_at;

-- ---- 0. Remove any previous bulk rows (reverse dependency order) -------------
DROP TABLE IF EXISTS perf_stage_ledger;
DROP TABLE IF EXISTS perf_plan_transfers;
DELETE FROM audit_log     WHERE account_id  > 1000;
DELETE FROM transactions  WHERE account_id  > 1000;
DELETE FROM transfers     WHERE transfer_id > 1000;
DELETE FROM beneficiaries WHERE customer_id > 1000;
DELETE FROM accounts      WHERE account_id  > 1000;
DELETE FROM customers     WHERE customer_id > 1000;

-- ---- 1. Customers: 50,000 ------------------------------------------------------
INSERT INTO customers (customer_id, first_name, last_name, email, phone, status, created_at)
SELECT 1000 + n,
       ELT(1 + FLOOR(RAND(11) * 10), 'Adaeze','Tunde','Chioma','Ibrahim','Funke','Emeka','Zainab','David','Ngozi','Bayo'),
       ELT(1 + FLOOR(RAND(12) * 10), 'Okafor','Bello','Eze','Musa','Adeyemi','Nwosu','Lawal','Okoro','Balogun','Umar'),
       CONCAT('bulk.customer', n, '@example.com'),
       CONCAT('0901', LPAD(n, 7, '0')),
       IF(MOD(n, 50) = 0, 'SUSPENDED', 'ACTIVE'),
       TIMESTAMP('2024-11-15 00:00:00') + INTERVAL FLOOR(RAND(13) * 30 * 86400) SECOND
FROM (SELECT seq AS n FROM seq_1_to_50000) AS nums;

-- ---- 2. Accounts: 80,000 (opened with zero balance; set from the ledger later) --
INSERT INTO accounts (account_id, customer_id, account_number, account_type, currency, balance, status, opened_at)
SELECT 1000 + n,
       1001 + MOD(n - 1, 50000),
       CONCAT('2', LPAD(n, 9, '0')),
       IF(RAND(22) < 0.6, 'SAVINGS', 'CURRENT'),
       'NGN',
       0.00,
       CASE WHEN MOD(n, 100) < 90 THEN 'ACTIVE' WHEN MOD(n, 100) < 97 THEN 'FROZEN' ELSE 'CLOSED' END,
       TIMESTAMP('2024-12-01 00:00:00') + INTERVAL FLOOR(RAND(21) * 30 * 86400) SECOND
FROM (SELECT seq AS n FROM seq_1_to_80000) AS nums;

-- ---- 3. Transfer plan: 110,000 rows (n > 100000 are failed transfers) ----------
-- A plan table is used so source and destination are each computed exactly once.
CREATE TABLE perf_plan_transfers (
    n          INT          NOT NULL PRIMARY KEY,
    src_idx    INT          NOT NULL,
    dst_idx    INT          NULL,
    amount     DECIMAL(15,2) NOT NULL,
    created_at DATETIME     NOT NULL
) ENGINE=InnoDB;

INSERT INTO perf_plan_transfers (n, src_idx, dst_idx, amount, created_at)
SELECT n,
       1 + FLOOR(80000 * POW(RAND(31), 2)),
       NULL,
       ROUND(1 + RAND(33) * 4999, 2),
       TIMESTAMP('2025-01-01 00:00:00') + INTERVAL FLOOR(RAND(34) * 668 * 86400) SECOND
FROM (SELECT seq AS n FROM seq_1_to_110000) AS nums;

-- destination = any account other than the source (offset 1..79999 around the ring)
UPDATE perf_plan_transfers
SET dst_idx = MOD(src_idx - 1 + 1 + FLOOR(RAND(32) * 79999), 80000) + 1;

INSERT INTO transfers (transfer_id, reference, source_account_id, destination_account_id, amount,
                       status, failure_reason, created_at, completed_at)
SELECT 1000 + n,
       CONCAT('MPB-', LPAD(n, 8, '0')),
       1000 + src_idx,
       1000 + dst_idx,
       amount,
       IF(n <= 100000, 'COMPLETED', 'FAILED'),
       IF(n <= 100000, NULL, ELT(1 + MOD(n, 3), 'Insufficient funds', 'Destination account frozen', 'Daily limit exceeded')),
       created_at,
       IF(n <= 100000, created_at + INTERVAL 1 SECOND, NULL)
FROM perf_plan_transfers;

-- ---- 4. Ledger staging (balance_after is computed before the final insert) ------
CREATE TABLE perf_stage_ledger (
    seq           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    account_id    INT UNSIGNED    NOT NULL,
    transfer_id   BIGINT UNSIGNED NULL,
    ttype         ENUM('DEPOSIT','WITHDRAWAL','TRANSFER_DEBIT','TRANSFER_CREDIT') NOT NULL,
    amount        DECIMAL(15,2)   NOT NULL,
    created_at    DATETIME        NOT NULL,
    balance_after DECIMAL(15,2)   NULL,
    KEY idx_stage_account (account_id, created_at, seq),
    KEY idx_stage_created (created_at, seq)
) ENGINE=InnoDB;

-- opening deposit for every bulk account (large enough that balances never go negative)
INSERT INTO perf_stage_ledger (account_id, transfer_id, ttype, amount, created_at)
SELECT 1000 + n, NULL, 'DEPOSIT', 500000.00, TIMESTAMP('2024-12-31 12:00:00')
FROM (SELECT seq AS n FROM seq_1_to_80000) AS nums;

-- 250,000 ordinary deposits
INSERT INTO perf_stage_ledger (account_id, transfer_id, ttype, amount, created_at)
SELECT 1001 + FLOOR(80000 * POW(RAND(41), 2)), NULL, 'DEPOSIT',
       ROUND(100 + RAND(42) * 19900, 2),
       TIMESTAMP('2025-01-01 00:00:00') + INTERVAL FLOOR(RAND(43) * 668 * 86400) SECOND
FROM seq_1_to_250000;

-- 250,000 withdrawals
INSERT INTO perf_stage_ledger (account_id, transfer_id, ttype, amount, created_at)
SELECT 1001 + FLOOR(80000 * POW(RAND(51), 2)), NULL, 'WITHDRAWAL',
       ROUND(50 + RAND(52) * 4950, 2),
       TIMESTAMP('2025-01-01 00:00:00') + INTERVAL FLOOR(RAND(53) * 668 * 86400) SECOND
FROM seq_1_to_250000;

-- two legs for every completed transfer
INSERT INTO perf_stage_ledger (account_id, transfer_id, ttype, amount, created_at)
SELECT 1000 + src_idx, 1000 + n, 'TRANSFER_DEBIT', amount, created_at + INTERVAL 1 SECOND
FROM perf_plan_transfers WHERE n <= 100000;

INSERT INTO perf_stage_ledger (account_id, transfer_id, ttype, amount, created_at)
SELECT 1000 + dst_idx, 1000 + n, 'TRANSFER_CREDIT', amount, created_at + INTERVAL 1 SECOND
FROM perf_plan_transfers WHERE n <= 100000;

SELECT COUNT(*) AS staged_ledger_rows FROM perf_stage_ledger;

-- ---- 5. Running balances, final ledger insert and account balances (in chunks) --
DELIMITER $$

DROP PROCEDURE IF EXISTS perf_finish_load$$
CREATE PROCEDURE perf_finish_load()
BEGIN
    DECLARE lo INT;
    DECLARE m  DATETIME;

    -- running balance per account (window function), 10,000 accounts at a time
    SET lo = 1001;
    WHILE lo <= 81000 DO
        UPDATE perf_stage_ledger s
        JOIN (SELECT seq,
                     SUM(IF(ttype IN ('DEPOSIT','TRANSFER_CREDIT'), amount, -amount))
                         OVER (PARTITION BY account_id ORDER BY created_at, seq) AS running_balance
              FROM perf_stage_ledger
              WHERE account_id BETWEEN lo AND lo + 9999) w ON w.seq = s.seq
        SET s.balance_after = w.running_balance
        WHERE s.account_id BETWEEN lo AND lo + 9999;
        SET lo = lo + 10000;
    END WHILE;

    -- final ledger insert, one month at a time, in time order so ids follow time
    SET m = TIMESTAMP('2024-12-01 00:00:00');
    WHILE m < TIMESTAMP('2026-11-01 00:00:00') DO
        INSERT INTO transactions (account_id, transfer_id, transaction_type, amount, balance_after, created_at)
        SELECT account_id, transfer_id, ttype, amount, balance_after, created_at
        FROM perf_stage_ledger
        WHERE created_at >= m AND created_at < m + INTERVAL 1 MONTH
        ORDER BY created_at, seq;
        SET m = m + INTERVAL 1 MONTH;
    END WHILE;

    -- account balances = closing ledger balance (audit triggers log each change)
    SET lo = 1001;
    WHILE lo <= 81000 DO
        UPDATE accounts a
        JOIN (SELECT account_id,
                     SUM(IF(ttype IN ('DEPOSIT','TRANSFER_CREDIT'), amount, -amount)) AS closing_balance
              FROM perf_stage_ledger
              WHERE account_id BETWEEN lo AND lo + 9999
              GROUP BY account_id) s ON s.account_id = a.account_id
        SET a.balance = s.closing_balance;
        SET lo = lo + 10000;
    END WHILE;
END$$

DELIMITER ;

CALL perf_finish_load();
DROP PROCEDURE perf_finish_load;

-- ---- 6. Clean up helper tables and refresh optimiser statistics -----------------
DROP TABLE perf_stage_ledger;
DROP TABLE perf_plan_transfers;
ANALYZE TABLE customers, accounts, transfers, transactions, beneficiaries, audit_log;

SELECT NOW() AS finished_at;
