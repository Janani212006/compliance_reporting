-- =====================================================================
-- compliance_db  |  RESET to the clean base state
-- Removes every scenario row and every test run, puts the 3 sample flags
-- back to PENDING_REPORT and moves the bookmark back to just before the
-- 11 Sep period. Safe to run any time. One query tab, plain lightning bolt.
-- =====================================================================

SET NAMES utf8mb4;
SET time_zone = '+05:30';
USE compliance_db;

SET SQL_SAFE_UPDATES = 0;

DELETE FROM compliance_report_runs WHERE run_id NOT LIKE 'RUN-HIST-%';

DELETE FROM transaction_flags
 WHERE transaction_id LIKE 'TXN-SC-%' OR transaction_id LIKE 'TXN-HV-%';
DELETE FROM transactions
 WHERE transaction_id LIKE 'TXN-SC-%' OR transaction_id LIKE 'TXN-HV-%';
DELETE FROM customers WHERE customer_id LIKE 'CUST-SC-%';

-- put the 3 sample flags (11 Sep) back to pending
UPDATE transaction_flags
   SET report_status = 'PENDING_REPORT', reported_run_id = NULL
 WHERE transaction_id IN ('TXN-99120455', 'TXN-99120781', 'TXN-99121033');

-- put the bookmark back to just before the 11 Sep period
UPDATE compliance_report_control
   SET last_reported_upto = '2026-09-10 21:30:00',
       last_successful_run = 'RUN-HIST-20260910-001',
       last_sequence_number = 1
 WHERE entity_code = 'ENT0091' AND report_type = 'STR';

SET SQL_SAFE_UPDATES = 1;

-- Check: expect customers 5, transactions 5, flags 5 (3 pending), runs 3, control 1
SELECT 'customers' AS tbl, COUNT(*) AS n FROM customers
UNION ALL SELECT 'transactions', COUNT(*) FROM transactions
UNION ALL SELECT 'flags', COUNT(*) FROM transaction_flags
UNION ALL SELECT 'flags pending', COUNT(*) FROM transaction_flags WHERE report_status = 'PENDING_REPORT'
UNION ALL SELECT 'runs', COUNT(*) FROM compliance_report_runs
UNION ALL SELECT 'control', COUNT(*) FROM compliance_report_control;
