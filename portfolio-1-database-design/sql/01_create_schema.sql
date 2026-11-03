-- =============================================================================
-- MikePay (simulated fintech) - Portfolio 1: schema
-- Target: MariaDB 10.4.32 (XAMPP), InnoDB
-- Re-runnable: drops and recreates the six MikePay tables in mikepay_db.
-- All data in this project is synthetic.
-- =============================================================================

-- XAMPP's default sql_mode is not strict, so invalid ENUM values or out-of-range
-- numbers would be silently altered. Force strict mode for this session.
SET SESSION sql_mode = 'STRICT_ALL_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ZERO_IN_DATE,NO_ZERO_DATE,NO_ENGINE_SUBSTITUTION';

CREATE DATABASE IF NOT EXISTS mikepay_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE mikepay_db;

-- Drop in reverse dependency order so foreign keys do not block the drops.
DROP TABLE IF EXISTS audit_log;
DROP TABLE IF EXISTS beneficiaries;
DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS transfers;
DROP TABLE IF EXISTS accounts;
DROP TABLE IF EXISTS customers;

-- -----------------------------------------------------------------------------
-- customers: people who hold MikePay accounts
-- -----------------------------------------------------------------------------
CREATE TABLE customers (
    customer_id  INT UNSIGNED  NOT NULL AUTO_INCREMENT,
    first_name   VARCHAR(50)   NOT NULL,
    last_name    VARCHAR(50)   NOT NULL,
    email        VARCHAR(100)  NOT NULL,
    phone        VARCHAR(20)   NOT NULL,
    status       ENUM('ACTIVE','SUSPENDED','CLOSED') NOT NULL DEFAULT 'ACTIVE',
    created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (customer_id),
    CONSTRAINT uq_customers_email UNIQUE (email),
    CONSTRAINT uq_customers_phone UNIQUE (phone)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- accounts: a customer can hold several accounts
-- balance uses DECIMAL (exact fixed-point), never FLOAT/DOUBLE, for money.
-- -----------------------------------------------------------------------------
CREATE TABLE accounts (
    account_id      INT UNSIGNED   NOT NULL AUTO_INCREMENT,
    customer_id     INT UNSIGNED   NOT NULL,
    account_number  CHAR(10)       NOT NULL,
    account_type    ENUM('SAVINGS','CURRENT') NOT NULL,
    currency        CHAR(3)        NOT NULL DEFAULT 'NGN',
    balance         DECIMAL(15,2)  NOT NULL DEFAULT 0.00,
    status          ENUM('ACTIVE','FROZEN','CLOSED') NOT NULL DEFAULT 'ACTIVE',
    opened_at       DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (account_id),
    CONSTRAINT uq_accounts_number UNIQUE (account_number),
    CONSTRAINT fk_accounts_customer FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT ck_accounts_balance_nonneg CHECK (balance >= 0),
    CONSTRAINT ck_accounts_number_format CHECK (account_number REGEXP '^[0-9]{10}$'),
    INDEX idx_accounts_customer (customer_id)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- transfers: one row per fund-transfer request between two MikePay accounts
-- A failed transfer must record why it failed.
-- -----------------------------------------------------------------------------
CREATE TABLE transfers (
    transfer_id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    reference               VARCHAR(30)     NOT NULL,
    source_account_id       INT UNSIGNED    NOT NULL,
    destination_account_id  INT UNSIGNED    NOT NULL,
    amount                  DECIMAL(15,2)   NOT NULL,
    status                  ENUM('PENDING','COMPLETED','FAILED','REVERSED') NOT NULL DEFAULT 'PENDING',
    failure_reason          VARCHAR(255)    NULL,
    created_at              DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at            DATETIME        NULL,
    PRIMARY KEY (transfer_id),
    CONSTRAINT uq_transfers_reference UNIQUE (reference),
    CONSTRAINT fk_transfers_source FOREIGN KEY (source_account_id)
        REFERENCES accounts (account_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_transfers_destination FOREIGN KEY (destination_account_id)
        REFERENCES accounts (account_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT ck_transfers_amount_positive CHECK (amount > 0),
    CONSTRAINT ck_transfers_different_accounts CHECK (source_account_id <> destination_account_id),
    CONSTRAINT ck_transfers_failure_reason CHECK (status <> 'FAILED' OR failure_reason IS NOT NULL),
    INDEX idx_transfers_source_created (source_account_id, created_at),
    INDEX idx_transfers_destination (destination_account_id),
    INDEX idx_transfers_status_created (status, created_at)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- transactions: the ledger. Every balance movement on an account is one row.
-- A transfer produces two rows (TRANSFER_DEBIT and TRANSFER_CREDIT).
-- balance_after is a deliberate, documented denormalisation kept for audit.
-- -----------------------------------------------------------------------------
CREATE TABLE transactions (
    transaction_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    account_id        INT UNSIGNED    NOT NULL,
    transfer_id       BIGINT UNSIGNED NULL,
    transaction_type  ENUM('DEPOSIT','WITHDRAWAL','TRANSFER_DEBIT','TRANSFER_CREDIT') NOT NULL,
    amount            DECIMAL(15,2)   NOT NULL,
    balance_after     DECIMAL(15,2)   NOT NULL,
    description       VARCHAR(255)    NULL,
    created_at        DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (transaction_id),
    CONSTRAINT fk_transactions_account FOREIGN KEY (account_id)
        REFERENCES accounts (account_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_transactions_transfer FOREIGN KEY (transfer_id)
        REFERENCES transfers (transfer_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT ck_transactions_amount_positive CHECK (amount > 0),
    CONSTRAINT ck_transactions_balance_nonneg CHECK (balance_after >= 0),
    -- transfer legs must reference a transfer; deposits/withdrawals must not
    CONSTRAINT ck_transactions_transfer_link CHECK (
        (transaction_type IN ('TRANSFER_DEBIT','TRANSFER_CREDIT')) = (transfer_id IS NOT NULL)
    ),
    INDEX idx_transactions_account_created (account_id, created_at),
    INDEX idx_transactions_transfer (transfer_id)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- beneficiaries: saved payees. Limitation: only MikePay accounts (no external banks).
-- -----------------------------------------------------------------------------
CREATE TABLE beneficiaries (
    beneficiary_id          INT UNSIGNED NOT NULL AUTO_INCREMENT,
    customer_id             INT UNSIGNED NOT NULL,
    beneficiary_account_id  INT UNSIGNED NOT NULL,
    nickname                VARCHAR(50)  NOT NULL,
    created_at              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (beneficiary_id),
    CONSTRAINT uq_beneficiaries_customer_account UNIQUE (customer_id, beneficiary_account_id),
    CONSTRAINT fk_beneficiaries_customer FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_beneficiaries_account FOREIGN KEY (beneficiary_account_id)
        REFERENCES accounts (account_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    INDEX idx_beneficiaries_account (beneficiary_account_id)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
-- audit_log: append-only history of account balance changes (filled by triggers
-- in 02_triggers.sql).
-- -----------------------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    account_id   INT UNSIGNED    NOT NULL,
    action       ENUM('ACCOUNT_OPENED','BALANCE_CHANGED') NOT NULL,
    old_balance  DECIMAL(15,2)   NULL,
    new_balance  DECIMAL(15,2)   NOT NULL,
    changed_by   VARCHAR(100)    NOT NULL,
    changed_at   DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (audit_id),
    CONSTRAINT fk_audit_log_account FOREIGN KEY (account_id)
        REFERENCES accounts (account_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    INDEX idx_audit_log_account_changed (account_id, changed_at)
) ENGINE=InnoDB;
