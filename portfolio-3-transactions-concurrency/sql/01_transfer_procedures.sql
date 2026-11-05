-- =============================================================================
-- MikePay - Portfolio 3: fund-transfer stored procedures
-- Target: MariaDB 10.4.32 (XAMPP), InnoDB. Run after the Portfolio 1 schema exists.
--
-- sp_transfer_funds  - the procedure the application calls. Safe.
-- sp_transfer_core   - the implementation. It has two extra TEST parameters:
--                        p_lock_ordered : 1 = lock the two accounts in ascending id order (safe)
--                                         0 = lock them in the order given (source first),
--                                             used ONLY to demonstrate deadlocks
--                        p_pause_secs   : sleep between the two locks, ONLY to widen the
--                                         timing window so the deadlock demo is repeatable
--                     Real callers never use sp_transfer_core directly.
--
-- How a failed transfer cannot leave balances inconsistent:
--   1. Everything that changes data happens inside ONE transaction.
--   2. Both account rows are locked (SELECT ... FOR UPDATE) BEFORE the balance is checked,
--      so nobody else can change them between the check and the update.
--   3. Business rules (active, same currency, enough money) are checked BEFORE any write,
--      so a rule failure has nothing to undo; it only records a FAILED transfer for audit.
--   4. If any SQL error happens after the writes start (duplicate reference, deadlock,
--      constraint violation), the EXIT HANDLER issues ROLLBACK, which undoes the debit,
--      the credit, the transfer row and the ledger rows together.
--   5. The CHECK (balance >= 0) constraint is a last line of defence in the database itself.
--
-- Limitation: START TRANSACTION inside the procedure implicitly commits any transaction the
-- caller already had open, so callers must call it with no open transaction.
-- =============================================================================

USE mikepay_db;

-- Procedures remember the sql_mode they were created with, so create them in strict mode.
SET SESSION sql_mode = 'STRICT_ALL_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ZERO_IN_DATE,NO_ZERO_DATE,NO_ENGINE_SUBSTITUTION';

DROP PROCEDURE IF EXISTS sp_transfer_funds;
DROP PROCEDURE IF EXISTS sp_transfer_core;

DELIMITER $$

CREATE PROCEDURE sp_transfer_core(
    IN  p_reference     VARCHAR(30),
    IN  p_source_id     INT UNSIGNED,
    IN  p_dest_id       INT UNSIGNED,
    IN  p_amount        DECIMAL(15,2),
    IN  p_lock_ordered  TINYINT,
    IN  p_pause_secs    DECIMAL(4,2),
    OUT p_status        VARCHAR(10),    -- COMPLETED | FAILED | REJECTED | ERROR
    OUT p_message       VARCHAR(255)
)
BEGIN
    DECLARE v_first_id      INT UNSIGNED;
    DECLARE v_second_id     INT UNSIGNED;
    DECLARE v_first_bal     DECIMAL(15,2);
    DECLARE v_second_bal    DECIMAL(15,2);
    DECLARE v_first_status  VARCHAR(10);
    DECLARE v_second_status VARCHAR(10);
    DECLARE v_first_cur     CHAR(3);
    DECLARE v_second_cur    CHAR(3);
    DECLARE v_src_bal       DECIMAL(15,2);
    DECLARE v_dst_bal       DECIMAL(15,2);
    DECLARE v_src_status    VARCHAR(10);
    DECLARE v_dst_status    VARCHAR(10);
    DECLARE v_src_cur       CHAR(3);
    DECLARE v_dst_cur       CHAR(3);
    DECLARE v_reason        VARCHAR(255);
    DECLARE v_transfer_id   BIGINT UNSIGNED;

    -- Any unexpected SQL error: undo everything this call did, then report it.
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        DECLARE v_errno INT;
        DECLARE v_text  VARCHAR(200);
        GET DIAGNOSTICS CONDITION 1 v_errno = MYSQL_ERRNO, v_text = MESSAGE_TEXT;
        ROLLBACK;
        SET p_status  = 'ERROR';
        SET p_message = CONCAT('Rolled back. MariaDB error ', v_errno, ': ', v_text);
    END;

    SET p_status  = NULL;
    SET p_message = NULL;

    -- Checks that need no locks and no data: rejected outright, nothing recorded.
    IF p_amount IS NULL OR p_amount <= 0 THEN
        SET p_status  = 'REJECTED';
        SET p_message = 'Amount must be greater than zero';
    ELSEIF p_source_id = p_dest_id THEN
        SET p_status  = 'REJECTED';
        SET p_message = 'Source and destination accounts must differ';
    ELSE
        START TRANSACTION;

        -- Lock both account rows. Ascending id order means two opposite transfers
        -- (A->B and B->A) queue behind each other instead of deadlocking.
        IF p_lock_ordered = 1 THEN
            SET v_first_id  = LEAST(p_source_id, p_dest_id);
            SET v_second_id = GREATEST(p_source_id, p_dest_id);
        ELSE
            SET v_first_id  = p_source_id;
            SET v_second_id = p_dest_id;
        END IF;

        SELECT balance, status, currency
          INTO v_first_bal, v_first_status, v_first_cur
          FROM accounts WHERE account_id = v_first_id FOR UPDATE;

        IF p_pause_secs > 0 THEN
            DO SLEEP(p_pause_secs);
        END IF;

        SELECT balance, status, currency
          INTO v_second_bal, v_second_status, v_second_cur
          FROM accounts WHERE account_id = v_second_id FOR UPDATE;

        IF v_first_id = p_source_id THEN
            SET v_src_bal = v_first_bal, v_src_status = v_first_status, v_src_cur = v_first_cur,
                v_dst_bal = v_second_bal, v_dst_status = v_second_status, v_dst_cur = v_second_cur;
        ELSE
            SET v_src_bal = v_second_bal, v_src_status = v_second_status, v_src_cur = v_second_cur,
                v_dst_bal = v_first_bal, v_dst_status = v_first_status, v_dst_cur = v_first_cur;
        END IF;

        IF v_src_bal IS NULL OR v_dst_bal IS NULL THEN
            -- balance is NOT NULL, so NULL means the account row does not exist.
            -- A FAILED transfer row cannot be stored for a missing account (foreign key).
            ROLLBACK;
            SET p_status  = 'REJECTED';
            SET p_message = 'Source or destination account does not exist';
        ELSE
            SET v_reason = CASE
                WHEN v_src_status <> 'ACTIVE' THEN 'Source account is not active'
                WHEN v_dst_status <> 'ACTIVE' THEN 'Destination account is not active'
                WHEN v_src_cur <> v_dst_cur   THEN 'Currency mismatch'
                WHEN v_src_bal < p_amount     THEN 'Insufficient funds'
                ELSE NULL
            END;

            IF v_reason IS NOT NULL THEN
                -- Rule failure. No balance has been touched, so there is nothing to undo.
                -- Keep a FAILED transfer row as an audit trail, then release the locks.
                INSERT INTO transfers (reference, source_account_id, destination_account_id,
                                       amount, status, failure_reason)
                VALUES (p_reference, p_source_id, p_dest_id, p_amount, 'FAILED', v_reason);
                COMMIT;
                SET p_status  = 'FAILED';
                SET p_message = v_reason;
            ELSE
                -- Relative updates (balance = balance - x), never "write back a value read earlier".
                UPDATE accounts SET balance = balance - p_amount WHERE account_id = p_source_id;
                UPDATE accounts SET balance = balance + p_amount WHERE account_id = p_dest_id;

                INSERT INTO transfers (reference, source_account_id, destination_account_id,
                                       amount, status, completed_at)
                VALUES (p_reference, p_source_id, p_dest_id, p_amount, 'COMPLETED', NOW());
                SET v_transfer_id = LAST_INSERT_ID();

                INSERT INTO transactions (account_id, transfer_id, transaction_type, amount,
                                          balance_after, description)
                VALUES (p_source_id, v_transfer_id, 'TRANSFER_DEBIT',  p_amount,
                        v_src_bal - p_amount, CONCAT('Transfer ', p_reference, ' to account ', p_dest_id)),
                       (p_dest_id,   v_transfer_id, 'TRANSFER_CREDIT', p_amount,
                        v_dst_bal + p_amount, CONCAT('Transfer ', p_reference, ' from account ', p_source_id));

                COMMIT;
                SET p_status  = 'COMPLETED';
                SET p_message = 'Transfer completed';
            END IF;
        END IF;
    END IF;
END$$

CREATE PROCEDURE sp_transfer_funds(
    IN  p_reference  VARCHAR(30),
    IN  p_source_id  INT UNSIGNED,
    IN  p_dest_id    INT UNSIGNED,
    IN  p_amount     DECIMAL(15,2),
    OUT p_status     VARCHAR(10),
    OUT p_message    VARCHAR(255)
)
BEGIN
    -- Safe configuration: ordered locking, no artificial pause.
    CALL sp_transfer_core(p_reference, p_source_id, p_dest_id, p_amount, 1, 0, p_status, p_message);
END$$

DELIMITER ;
