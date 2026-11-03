-- =============================================================================
-- MikePay - Portfolio 1: audit triggers
-- Records every account opening and balance change in audit_log.
-- Run after 01_create_schema.sql.
-- =============================================================================

USE mikepay_db;

DROP TRIGGER IF EXISTS trg_accounts_after_insert;
DROP TRIGGER IF EXISTS trg_accounts_after_update;

DELIMITER $$

CREATE TRIGGER trg_accounts_after_insert
AFTER INSERT ON accounts
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (account_id, action, old_balance, new_balance, changed_by)
    VALUES (NEW.account_id, 'ACCOUNT_OPENED', NULL, NEW.balance, CURRENT_USER());
END$$

CREATE TRIGGER trg_accounts_after_update
AFTER UPDATE ON accounts
FOR EACH ROW
BEGIN
    -- <=> is NULL-safe equality; only log when the balance really changed
    IF NOT (OLD.balance <=> NEW.balance) THEN
        INSERT INTO audit_log (account_id, action, old_balance, new_balance, changed_by)
        VALUES (NEW.account_id, 'BALANCE_CHANGED', OLD.balance, NEW.balance, CURRENT_USER());
    END IF;
END$$

DELIMITER ;
