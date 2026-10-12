-- =====================================================================
-- compliance_db  |  OPTIONAL SCENARIO DATA + RESET
-- Run AFTER compliance_db_merged.sql. Same rules: one query tab,
-- plain lightning bolt, all times IST. Periods are [start, end) with a
-- 21:30 IST cut-off and are labelled by the date of their END.
--
-- Each section adds rows for ONE negative scenario from the PDF, in its
-- OWN period, so nothing disturbs the clean base data (the 11 Sep
-- period = 3 records, 12 Sep = nil).
-- Run only the sections you need. To undo everything, run
-- compliance_db_reset.sql.
-- =====================================================================

SET NAMES utf8mb4;
SET time_zone = '+05:30';
USE compliance_db;

-- ---------------------------------------------------------------------
-- SECTION 1: Exact-boundary test (scenario 11)
-- Three flags around the 13/14 Sep cut-offs. Expected counts, with
-- end-exclusive periods:
--   period 13 Sep [12 Sep 21:30, 13 Sep 21:30): 1 record (SC-BOUND-1, at 21:29:59)
--   period 14 Sep [13 Sep 21:30, 14 Sep 21:30): 1 record (SC-BOUND-2, at exactly 21:30:00)
--   period 15 Sep [14 Sep 21:30, 15 Sep 21:30): 1 record (SC-BOUND-3, at exactly 21:30:00)
-- Each record must appear in exactly one period.
-- ---------------------------------------------------------------------
INSERT INTO transactions
  (transaction_id, transaction_datetime, account_number, customer_id, transaction_type,
   channel, currency, amount, counterparty_name, counterparty_country)
VALUES
  ('TXN-SC-BOUND-1', '2026-09-13 21:29:50', '00300001', 'CUST-20001', 'WIRE_TRANSFER', 'ONLINE', 'INR', 150000.00, 'Boundary Test Co', 'SG'),
  ('TXN-SC-BOUND-2', '2026-09-13 21:29:55', '00300002', 'CUST-20001', 'WIRE_TRANSFER', 'ONLINE', 'INR', 250000.00, 'Boundary Test Co', 'SG'),
  ('TXN-SC-BOUND-3', '2026-09-14 21:29:55', '00300003', 'CUST-20001', 'WIRE_TRANSFER', 'ONLINE', 'INR', 350000.00, 'Boundary Test Co', 'SG');

INSERT INTO transaction_flags
  (transaction_id, flag_code, flag_reason, flagged_at, reviewed_by, review_status)
VALUES
  ('TXN-SC-BOUND-1', 'FLG-HIGH-VALUE', 'Boundary test: one second before cut-off', '2026-09-13 21:29:59', 'RISK_ANALYST_04', 'CONFIRMED'),
  ('TXN-SC-BOUND-2', 'FLG-HIGH-VALUE', 'Boundary test: exactly at cut-off',        '2026-09-13 21:30:00', 'RISK_ANALYST_04', 'CONFIRMED'),
  ('TXN-SC-BOUND-3', 'FLG-HIGH-VALUE', 'Boundary test: exactly at next cut-off',   '2026-09-14 21:30:00', 'RISK_ANALYST_04', 'CONFIRMED');

-- ---------------------------------------------------------------------
-- SECTION 2: Missing customer record (scenario 9)
-- Period 16 Sep [15 Sep 21:30, 16 Sep 21:30). The flagged transaction
-- points to a customer that does not exist, so the PDF's JOIN silently
-- drops it. Your third check (count of flags with NO joins) must catch it.
-- ---------------------------------------------------------------------
INSERT INTO transactions
  (transaction_id, transaction_datetime, account_number, customer_id, transaction_type,
   channel, currency, amount, counterparty_name, counterparty_country)
VALUES
  ('TXN-SC-ORPHAN-1', '2026-09-16 10:00:00', '00400001', 'CUST-SC-MISSING', 'WIRE_TRANSFER', 'ONLINE', 'INR', 500000.00, 'Orphan Test Ltd', 'AE');

INSERT INTO transaction_flags
  (transaction_id, flag_code, flag_reason, flagged_at, reviewed_by, review_status)
VALUES
  ('TXN-SC-ORPHAN-1', 'FLG-HIGH-VALUE', 'Missing customer test', '2026-09-16 10:05:00', 'RISK_ANALYST_01', 'CONFIRMED');

-- ---------------------------------------------------------------------
-- SECTION 3: Bad data that cannot be rendered (scenario 10)
-- Period 17 Sep [16 Sep 21:30, 17 Sep 21:30).
--   * A customer name containing the pipe character | (breaks the layout)
--   * A negative amount (out of range)
-- Your validation must FAIL the run instead of writing a malformed file.
-- ---------------------------------------------------------------------
INSERT INTO customers (customer_id, customer_name, customer_type, country) VALUES
  ('CUST-SC-BADNAME', 'Bad|Name Pvt Ltd', 'CORPORATE', 'IN');

INSERT INTO transactions
  (transaction_id, transaction_datetime, account_number, customer_id, transaction_type,
   channel, currency, amount, counterparty_name, counterparty_country)
VALUES
  ('TXN-SC-BADNAME-1', '2026-09-17 11:00:00', '00500001', 'CUST-SC-BADNAME', 'WIRE_TRANSFER', 'ONLINE', 'INR',    300000.00, 'Pipe Test Co',     'SG'),
  ('TXN-SC-BADAMT-1',  '2026-09-17 12:00:00', '00500002', 'CUST-20001',      'WIRE_TRANSFER', 'ONLINE', 'INR',       -500.00, 'Negative Test Co', 'SG');

INSERT INTO transaction_flags
  (transaction_id, flag_code, flag_reason, flagged_at, reviewed_by, review_status)
VALUES
  ('TXN-SC-BADNAME-1', 'FLG-HIGH-VALUE', 'Invalid character test', '2026-09-17 11:05:00', 'RISK_ANALYST_01', 'CONFIRMED'),
  ('TXN-SC-BADAMT-1',  'FLG-HIGH-VALUE', 'Negative amount test',   '2026-09-17 12:05:00', 'RISK_ANALYST_01', 'CONFIRMED');

-- ---------------------------------------------------------------------
-- SECTION 4: High volume (scenario 7)
-- Period 18 Sep [17 Sep 21:30, 18 Sep 21:30). Adds 50,000 flagged
-- transactions (change 50000 below for more, e.g. 500000; it takes longer).
-- ---------------------------------------------------------------------
SET SESSION cte_max_recursion_depth = 1000000;

INSERT INTO transactions
  (transaction_id, transaction_datetime, account_number, customer_id, transaction_type,
   channel, currency, amount, counterparty_name, counterparty_country)
WITH RECURSIVE seq (n) AS (
  SELECT 1
  UNION ALL
  SELECT n + 1 FROM seq WHERE n < 50000
)
SELECT CONCAT('TXN-HV-', LPAD(n, 7, '0')),
       TIMESTAMP('2026-09-17 21:30:00') + INTERVAL (n MOD 86000) SECOND,
       LPAD(n MOD 99999, 8, '0'),
       'CUST-77219',
       'WIRE_TRANSFER',
       'ONLINE',
       'INR',
       1000 + (n MOD 997) * 10,
       'High Volume Test Co',
       'SG'
FROM seq;

INSERT INTO transaction_flags
  (transaction_id, flag_code, flag_reason, flagged_at, reviewed_by, review_status)
SELECT transaction_id, 'FLG-HIGH-VALUE', 'High volume test flag',
       transaction_datetime + INTERVAL 2 SECOND, 'RISK_ANALYST_99', 'CONFIRMED'
FROM transactions
WHERE transaction_id LIKE 'TXN-HV-%';

-- ---------------------------------------------------------------------
-- SECTION 5: Volume-deviation test (requirement 11)
-- No extra rows needed. Baseline history is 5, 6, 2 records (average
-- about 4.3). Section 4 (50,000 records) is a huge upward deviation;
-- the nil period (12 Sep, 0 records) is a huge drop.
-- ---------------------------------------------------------------------
