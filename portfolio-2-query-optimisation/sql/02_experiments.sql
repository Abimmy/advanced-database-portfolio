-- =============================================================================
-- MikePay - Portfolio 2: query experiments (baseline vs optimised)
-- Read by sql/run_benchmarks.py, which executes each variant, records EXPLAIN,
-- ANALYZE, handler (rows-read) counters and run times, and restores the schema.
-- Marker lines:
--   -- @exp ID | title            starts an experiment
--   -- @note text                 what is being tested
--   -- @variant name | detail     starts a variant (baseline / optimised)
--   -- @before <statement>        DDL run (untimed) before the variant
--   -- @cleanup <statement>       DDL run after the experiment to restore the schema
-- Everything else up to the next marker is the single query that is measured.
-- Requires the bulk data from 01_generate_bulk_data.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- @exp E1 | Account lookup by account number
-- @note Point lookup. The Portfolio 1 schema has a UNIQUE index on account_number; the baseline drops it for the test.
-- @variant baseline | no index on account_number
-- @before ALTER TABLE accounts DROP INDEX uq_accounts_number;
SELECT account_id, customer_id, account_type, balance, status
FROM accounts
WHERE account_number = '2000040000';
-- @variant optimised | UNIQUE index on account_number restored
-- @before ALTER TABLE accounts ADD CONSTRAINT uq_accounts_number UNIQUE (account_number);
SELECT account_id, customer_id, account_type, balance, status
FROM accounts
WHERE account_number = '2000040000';
-- @cleanup ALTER TABLE accounts ADD CONSTRAINT uq_accounts_number UNIQUE (account_number);

-- -----------------------------------------------------------------------------
-- @exp E2 | Account statement: latest 20 transactions of a busy account
-- @note Baseline has only a single-column index on account_id (what indexing "just the foreign key" gives). The composite index (account_id, created_at) lets MariaDB read the newest rows in order and stop after 20.
-- @variant baseline | index on account_id only
-- @before ALTER TABLE transactions DROP INDEX idx_transactions_account_created, ADD INDEX idx_tmp_account (account_id);
SELECT transaction_id, transaction_type, amount, balance_after, created_at
FROM transactions
WHERE account_id = 1001
ORDER BY created_at DESC
LIMIT 20;
-- @variant optimised | composite index (account_id, created_at)
-- @before ALTER TABLE transactions DROP INDEX idx_tmp_account, ADD INDEX idx_transactions_account_created (account_id, created_at);
SELECT transaction_id, transaction_type, amount, balance_after, created_at
FROM transactions
WHERE account_id = 1001
ORDER BY created_at DESC
LIMIT 20;
-- @cleanup ALTER TABLE transactions DROP INDEX idx_tmp_account;

-- -----------------------------------------------------------------------------
-- @exp E3 | Monthly volume report (range filter + aggregate)
-- @note transactions has no index on created_at in the Portfolio 1 schema, so the baseline scans the whole ledger. The optimised variant adds a covering index, so the query is answered from the index alone.
-- @variant baseline | no index that starts with created_at
SELECT transaction_type, COUNT(*) AS txn_count, SUM(amount) AS total_amount
FROM transactions
WHERE created_at >= '2026-03-01' AND created_at < '2026-04-01'
GROUP BY transaction_type;
-- @variant optimised | covering index (created_at, transaction_type, amount)
-- @before ALTER TABLE transactions ADD INDEX idx_transactions_created_cover (created_at, transaction_type, amount);
SELECT transaction_type, COUNT(*) AS txn_count, SUM(amount) AS total_amount
FROM transactions
WHERE created_at >= '2026-03-01' AND created_at < '2026-04-01'
GROUP BY transaction_type;
-- @cleanup ALTER TABLE transactions DROP INDEX idx_transactions_created_cover;

-- -----------------------------------------------------------------------------
-- @exp E4 | Single-day report: wrapping the column in a function vs a range
-- @note Same index in both variants (created_at). Only the query text changes. DATE(created_at) = ... hides the column from the index; the range form lets it be used.
-- @variant baseline | WHERE DATE(created_at) = '2026-03-15'
-- @before ALTER TABLE transactions ADD INDEX idx_tmp_created (created_at);
SELECT COUNT(*) AS txn_count, SUM(amount) AS total_amount
FROM transactions
WHERE DATE(created_at) = '2026-03-15';
-- @variant optimised | range: created_at >= '2026-03-15' AND created_at < '2026-03-16'
SELECT COUNT(*) AS txn_count, SUM(amount) AS total_amount
FROM transactions
WHERE created_at >= '2026-03-15' AND created_at < '2026-03-16';
-- @cleanup ALTER TABLE transactions DROP INDEX idx_tmp_created;

-- -----------------------------------------------------------------------------
-- @exp E5 | Transfers between a specific pair of accounts
-- @note Hypothesis: a composite index on the (source, destination) pair beats the Portfolio 1 indexes, because (source_account_id, created_at) would have to read every transfer from the busy source account. This experiment tests that hypothesis; the result is reported as measured.
-- @variant baseline | Portfolio 1 indexes only
SELECT transfer_id, amount, status, created_at
FROM transfers
WHERE source_account_id = @@E5_SOURCE@@ AND destination_account_id = @@E5_DEST@@;
-- @variant optimised | new index (source_account_id, destination_account_id)
-- @before ALTER TABLE transfers ADD INDEX idx_transfers_pair (source_account_id, destination_account_id);
SELECT transfer_id, amount, status, created_at
FROM transfers
WHERE source_account_id = @@E5_SOURCE@@ AND destination_account_id = @@E5_DEST@@;
-- @cleanup ALTER TABLE transfers DROP INDEX idx_transfers_pair;

-- -----------------------------------------------------------------------------
-- @exp E6 | Top 10 senders by completed transfer value in Q1 2026 (join + aggregate)
-- @note The Portfolio 1 index (status, created_at) finds the right transfers but must fetch each row for source_account_id and amount. The optimised covering index holds every column the query needs.
-- @variant baseline | existing index (status, created_at)
SELECT a.account_number, SUM(t.amount) AS total_sent, COUNT(*) AS transfer_count
FROM transfers t
JOIN accounts a ON a.account_id = t.source_account_id
WHERE t.status = 'COMPLETED' AND t.created_at >= '2026-01-01' AND t.created_at < '2026-04-01'
GROUP BY t.source_account_id, a.account_number
ORDER BY total_sent DESC
LIMIT 10;
-- @variant optimised | covering index (status, created_at, source_account_id, amount)
-- @before ALTER TABLE transfers ADD INDEX idx_transfers_status_created_cover (status, created_at, source_account_id, amount);
SELECT a.account_number, SUM(t.amount) AS total_sent, COUNT(*) AS transfer_count
FROM transfers t
JOIN accounts a ON a.account_id = t.source_account_id
WHERE t.status = 'COMPLETED' AND t.created_at >= '2026-01-01' AND t.created_at < '2026-04-01'
GROUP BY t.source_account_id, a.account_number
ORDER BY total_sent DESC
LIMIT 10;
-- @cleanup ALTER TABLE transfers DROP INDEX idx_transfers_status_created_cover;
