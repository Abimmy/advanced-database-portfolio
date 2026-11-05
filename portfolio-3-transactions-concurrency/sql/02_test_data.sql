-- =============================================================================
-- MikePay - Portfolio 3: synthetic test accounts and a reset procedure
--
-- Portfolio 3 does NOT reset the database. It uses its own accounts with ids
-- 900001-900005 (customers 900001-900002), which sit above every Portfolio 1 and
-- Portfolio 2 id (the largest bulk account id is 81000), so the 780k-row Portfolio 2
-- dataset is left untouched.
--
-- sp_p3_reset_test_data() deletes ONLY rows that belong to those test ids
-- (audit_log, transactions, transfers, accounts, customers) and recreates the
-- accounts in a known state. It is a test helper, not part of the application.
--
--   900001  SAVINGS  ACTIVE  1000.00     \  customer 900001
--   900002  CURRENT  ACTIVE   500.00     /
--   900003  CURRENT  ACTIVE  2000.00     \
--   900004  SAVINGS  ACTIVE   750.00      >  customer 900002
--   900005  CURRENT  FROZEN   100.00     /
--   Total 4350.00
-- All data is synthetic.
-- =============================================================================

USE mikepay_db;

SET SESSION sql_mode = 'STRICT_ALL_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ZERO_IN_DATE,NO_ZERO_DATE,NO_ENGINE_SUBSTITUTION';

DROP PROCEDURE IF EXISTS sp_p3_reset_test_data;

DELIMITER $$

CREATE PROCEDURE sp_p3_reset_test_data()
BEGIN
    -- Children first, because the foreign keys are ON DELETE RESTRICT.
    DELETE FROM audit_log    WHERE account_id BETWEEN 900001 AND 900099;
    DELETE FROM transactions WHERE account_id BETWEEN 900001 AND 900099;
    DELETE FROM transfers    WHERE source_account_id BETWEEN 900001 AND 900099
                                OR destination_account_id BETWEEN 900001 AND 900099;
    DELETE FROM accounts     WHERE account_id  BETWEEN 900001 AND 900099;
    DELETE FROM customers    WHERE customer_id BETWEEN 900001 AND 900099;

    INSERT INTO customers (customer_id, first_name, last_name, email, phone) VALUES
        (900001, 'Testa', 'Alpha', 'p3.alpha@example.test', '09000000001'),
        (900002, 'Testb', 'Beta',  'p3.beta@example.test',  '09000000002');

    INSERT INTO accounts (account_id, customer_id, account_number, account_type, balance, status) VALUES
        (900001, 900001, '9000000001', 'SAVINGS', 1000.00, 'ACTIVE'),
        (900002, 900001, '9000000002', 'CURRENT',  500.00, 'ACTIVE'),
        (900003, 900002, '9000000003', 'CURRENT', 2000.00, 'ACTIVE'),
        (900004, 900002, '9000000004', 'SAVINGS',  750.00, 'ACTIVE'),
        (900005, 900002, '9000000005', 'CURRENT',  100.00, 'FROZEN');
END$$

DELIMITER ;
