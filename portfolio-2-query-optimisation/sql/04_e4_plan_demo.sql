-- =============================================================================
-- MikePay - Portfolio 2: short demo of experiment E4 for a screenshot
-- Same two queries as experiment E4 in 02_experiments.sql. The index on created_at
-- exists in BOTH runs; only the query text changes.
--   baseline : WHERE DATE(created_at) = '2026-03-15'          (function hides the column)
--   optimised: WHERE created_at >= '2026-03-15' AND created_at < '2026-03-16'  (range)
-- ANALYZE actually runs each query and reports real row counts (r_rows) and time (r_total_time_ms).
-- The temporary index is added at the start and removed at the end (the build can take a minute).
-- If the script stops half way, run:  ALTER TABLE transactions DROP INDEX idx_tmp_created;
-- Run:  mysql -u root -vvv < 04_e4_plan_demo.sql
-- =============================================================================
USE mikepay_db;
SELECT NOW() AS run_at, @@version AS server;

ALTER TABLE transactions ADD INDEX idx_tmp_created (created_at);
ANALYZE TABLE transactions;

-- BASELINE: DATE(created_at) = x
ANALYZE SELECT COUNT(*) AS txn_count, SUM(amount) AS total_amount
FROM transactions
WHERE DATE(created_at) = '2026-03-15'\G

-- OPTIMISED: the same question written as a range
ANALYZE SELECT COUNT(*) AS txn_count, SUM(amount) AS total_amount
FROM transactions
WHERE created_at >= '2026-03-15' AND created_at < '2026-03-16'\G

ALTER TABLE transactions DROP INDEX idx_tmp_created;
SHOW INDEX FROM transactions;
