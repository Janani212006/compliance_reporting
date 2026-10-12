-- =====================================================================
-- compliance_db  |  MERGED SCHEMA (PDF layout + teammate's improvements)
-- Entity: ENT0091 "Bright Financial Services Ltd"   Report type: STR
-- Target: MySQL 8.0.16+ (CHECK constraints are enforced from 8.0.16)
--
-- HOW TO RUN: open ONE query tab in MySQL Workbench, paste the whole
-- file, run it with the plain lightning bolt (runs everything in one
-- session, which matters because of SET time_zone below).
--
-- WARNING: Section 1 DROPS the five tables if they already exist.
--          Everything in them is lost. That is intended for a fresh start.
--
-- TIME RULES (decided for the whole project):
--   * All times in this script are IST (+05:30).
--   * A reporting period is [period_start, period_end): start INCLUSIVE,
--     end EXCLUSIVE. period_end of one run = period_start of the next.
--     (No more 18:29:59 style ends.)
--   * Daily cut-off used in the seed data: 21:30 IST (as in the PDF
--     sample). The cut-off itself is configuration, not schema.
--   * A period is labelled by the date of its END, e.g. the period
--     2026-09-10 21:30 -> 2026-09-11 21:30 is "2026-09-11".
--   * In Mule, make the JDBC connection use the Asia/Kolkata time zone,
--     otherwise TIMESTAMP values can shift.
-- =====================================================================

SET NAMES utf8mb4;
SET time_zone = '+05:30';

CREATE DATABASE IF NOT EXISTS compliance_db
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE compliance_db;

-- ---------------------------------------------------------------------
-- 1. DROP OLD TABLES (children first)
-- ---------------------------------------------------------------------
SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS transaction_flags;
DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS compliance_report_runs;
DROP TABLE IF EXISTS compliance_report_control;
SET FOREIGN_KEY_CHECKS = 1;

-- ---------------------------------------------------------------------
-- 2. TABLES
-- ---------------------------------------------------------------------

-- 2.1 CONTROL: the "bookmark". One row per entity + report type.
--     last_reported_upto = everything BEFORE this moment is reported.
--     Move it forward only after a fully successful run.
CREATE TABLE compliance_report_control (
  entity_code          VARCHAR(20)  NOT NULL,
  report_type          VARCHAR(20)  NOT NULL,
  entity_name          VARCHAR(100) NOT NULL,
  last_reported_upto   TIMESTAMP    NOT NULL,
  last_successful_run  VARCHAR(64)  NULL,
  last_sequence_number INT          NOT NULL DEFAULT 0,   -- informational only
  updated_at           TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                                    ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (entity_code, report_type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 2.2 RUNS: the audit diary. One row per attempt (success or failure).
--     Insert the row at the START of a run (status RUNNING), update it at the end.
CREATE TABLE compliance_report_runs (
  run_id                   VARCHAR(64)   NOT NULL,
  entity_code              VARCHAR(20)   NOT NULL,
  entity_name              VARCHAR(100)  NOT NULL,
  report_type              VARCHAR(20)   NOT NULL,
  period_start             TIMESTAMP     NOT NULL,   -- inclusive
  period_end               TIMESTAMP     NOT NULL,   -- exclusive
  sequence_number          INT           NOT NULL,   -- 1 = original, 2+ = revision
  is_revision              BOOLEAN       NOT NULL DEFAULT FALSE,
  record_count             INT           NOT NULL DEFAULT 0,
  total_amount             DECIMAL(18,2) NOT NULL DEFAULT 0.00,
  customer_count           INT           NOT NULL DEFAULT 0,
  completeness_result      VARCHAR(20)   NOT NULL DEFAULT 'PENDING',  -- PENDING / PASS / FAIL
  is_nil_report            BOOLEAN       NOT NULL DEFAULT FALSE,
  volume_deviation_percent DECIMAL(7,2)  NULL,       -- vs trailing average, NULL if not computed
  output_file_path         VARCHAR(300)  NULL,
  archive_file_path        VARCHAR(300)  NULL,
  summary_file_path        VARCHAR(300)  NULL,
  file_checksum            CHAR(64)      NULL,       -- SHA-256 of the whole submission file, lowercase hex
  notification_status      VARCHAR(30)   NOT NULL DEFAULT 'PENDING',  -- PENDING / SENT / FAILED
  delivery_method          VARCHAR(20)   NULL,       -- ATTACHMENT / SECURE_LINK
  trigger_source           VARCHAR(20)   NOT NULL DEFAULT 'SCHEDULED',-- SCHEDULED / MANUAL_API
  triggered_by             VARCHAR(60)   NOT NULL,   -- 'SCHEDULER' or the operator's name
  run_status               VARCHAR(30)   NOT NULL DEFAULT 'RUNNING',  -- RUNNING / SUCCESS / FAILED
  error_message            TEXT          NULL,
  correlation_id           VARCHAR(64)   NULL,
  started_at               TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  completed_at             TIMESTAMP     NULL DEFAULT NULL,
  -- Helper column (filled by MySQL itself): the sequence number, but only for
  -- SUCCESSFUL runs. Lets a period have many failed attempts but only ONE
  -- successful report per sequence number.
  success_sequence         INT GENERATED ALWAYS AS
                             (CASE WHEN run_status = 'SUCCESS' THEN sequence_number ELSE NULL END) STORED,
  PRIMARY KEY (run_id),
  UNIQUE KEY uk_report_period_success (entity_code, report_type, period_start, success_sequence),
  KEY idx_runs_period  (entity_code, report_type, period_start, sequence_number),
  KEY idx_runs_history (entity_code, report_type, period_end),
  KEY idx_runs_status  (run_status),
  CONSTRAINT chk_runs_period   CHECK (period_end > period_start),
  CONSTRAINT chk_runs_status   CHECK (run_status IN ('RUNNING','SUCCESS','FAILED')),
  CONSTRAINT chk_runs_complete CHECK (completeness_result IN ('PENDING','PASS','FAIL')),
  CONSTRAINT chk_runs_trigger  CHECK (trigger_source IN ('SCHEDULED','MANUAL_API')),
  CONSTRAINT chk_runs_delivery CHECK (delivery_method IS NULL OR delivery_method IN ('ATTACHMENT','SECURE_LINK')),
  CONSTRAINT chk_runs_revision CHECK (is_revision = (sequence_number > 1)),
  CONSTRAINT chk_runs_checksum CHECK (file_checksum IS NULL OR file_checksum REGEXP '^[0-9a-f]{64}$'),
  -- A SUCCESS run must have passed the completeness check and have a real checksum
  CONSTRAINT chk_runs_success  CHECK (run_status <> 'SUCCESS'
                                      OR (completeness_result = 'PASS' AND file_checksum IS NOT NULL)),
  -- A SUCCESS run with zero records must be marked nil (and the other way round)
  CONSTRAINT chk_runs_nil      CHECK (run_status <> 'SUCCESS' OR ((record_count = 0) = is_nil_report))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 2.3 CUSTOMERS (not defined in the PDF)
CREATE TABLE customers (
  customer_id   VARCHAR(32)  NOT NULL,
  customer_name VARCHAR(200) NOT NULL,
  customer_type VARCHAR(20)  NOT NULL,
  country       CHAR(2)      NULL,
  created_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (customer_id),
  KEY idx_customers_name (customer_name),
  CONSTRAINT chk_customer_type CHECK (customer_type IN ('INDIVIDUAL','CORPORATE'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 2.4 TRANSACTIONS (not defined in the PDF). Column names match the PDF's query.
--     NOTE: deliberately NO foreign key to customers, so that "missing customer
--     record" (negative scenario 9) can really be created and detected.
CREATE TABLE transactions (
  transaction_id       VARCHAR(64)   NOT NULL,
  transaction_datetime TIMESTAMP     NOT NULL,
  account_number       VARCHAR(34)   NOT NULL,   -- text: keeps leading zeros
  customer_id          VARCHAR(32)   NOT NULL,
  transaction_type     VARCHAR(30)   NOT NULL,
  channel              VARCHAR(30)   NOT NULL,
  currency             CHAR(3)       NOT NULL DEFAULT 'INR',
  amount               DECIMAL(18,2) NOT NULL,
  counterparty_name    VARCHAR(200)  NULL,
  counterparty_country CHAR(2)       NULL,
  created_at           TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (transaction_id),
  KEY idx_txn_datetime (transaction_datetime),
  KEY idx_txn_account  (account_number),
  KEY idx_txn_customer (customer_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 2.5 FLAGS: which transactions are flagged, and whether they are reported yet.
--     review_status = the analyst's decision (CONFIRMED...) -> printed in the report
--     report_status = reporting state (PENDING_REPORT / REPORTED) -> used by our logic
CREATE TABLE transaction_flags (
  flag_seq        BIGINT       NOT NULL AUTO_INCREMENT,
  transaction_id  VARCHAR(64)  NOT NULL,
  flag_code       VARCHAR(30)  NOT NULL,
  flag_reason     VARCHAR(255) NOT NULL,
  flagged_at      TIMESTAMP    NOT NULL,
  reviewed_by     VARCHAR(40)  NULL,
  review_status   VARCHAR(20)  NULL,
  report_status   VARCHAR(25)  NOT NULL DEFAULT 'PENDING_REPORT',
  reported_run_id VARCHAR(64)  NULL,
  PRIMARY KEY (flag_seq),
  UNIQUE KEY uk_txn_flag (transaction_id, flag_code),
  KEY idx_flags_status_period (report_status, flagged_at, transaction_id),
  KEY idx_flags_flagged_at (flagged_at),
  KEY idx_flags_reported_run (reported_run_id),
  CONSTRAINT fk_flag_txn FOREIGN KEY (transaction_id) REFERENCES transactions (transaction_id),
  CONSTRAINT chk_flag_report_status CHECK (report_status IN ('PENDING_REPORT','REPORTED')),
  -- reported_run_id must be filled exactly when the flag is REPORTED
  CONSTRAINT chk_flag_reported_run  CHECK ((report_status = 'REPORTED') = (reported_run_id IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- 3. BASE SEED DATA (clean starting state)
-- ---------------------------------------------------------------------

-- 3.1 Bookmark: everything up to 10 Sep 21:30 IST is already reported,
--     so the FIRST run covers the period labelled 2026-09-11.
INSERT INTO compliance_report_control
  (entity_code, report_type, entity_name, last_reported_upto, last_successful_run, last_sequence_number)
VALUES
  ('ENT0091', 'STR', 'Bright Financial Services Ltd', '2026-09-10 21:30:00', 'RUN-HIST-20260910-001', 1);

-- 3.2 Customers (first three are the ones in the PDF sample file)
INSERT INTO customers (customer_id, customer_name, customer_type, country) VALUES
  ('CUST-77219', 'Meena Raghavan',          'INDIVIDUAL', 'IN'),
  ('CUST-81140', 'Ganesh Iyer',             'INDIVIDUAL', 'IN'),
  ('CUST-66207', 'Sunrise Exports Pvt Ltd', 'CORPORATE',  'IN'),
  ('CUST-20001', 'Arjun Mehta',             'INDIVIDUAL', 'IN'),
  ('CUST-20002', 'Lakshmi Textiles Ltd',    'CORPORATE',  'IN');

-- 3.3 Baseline history runs. Used ONLY for the volume-deviation check
--     (counts 5, 6, 2). No real files exist for them; the checksums are
--     placeholders (SHA-256 of the run id), not checksums of real files.
INSERT INTO compliance_report_runs
  (run_id, entity_code, entity_name, report_type, period_start, period_end,
   sequence_number, is_revision, record_count, total_amount, customer_count,
   completeness_result, is_nil_report, file_checksum, notification_status,
   delivery_method, trigger_source, triggered_by, run_status, started_at, completed_at)
VALUES
  ('RUN-HIST-20260908-001', 'ENT0091', 'Bright Financial Services Ltd', 'STR',
   '2026-09-07 21:30:00', '2026-09-08 21:30:00', 1, FALSE, 5, 1200000.00, 4,
   'PASS', FALSE, '61e3c2d1c84b7be915a6bfe2b9272f5743ce83cb8de818c5d1c1c7ea21e66f40', 'SENT',
   'ATTACHMENT', 'SCHEDULED', 'SCHEDULER', 'SUCCESS', '2026-09-08 21:30:00', '2026-09-08 21:32:10'),
  ('RUN-HIST-20260909-001', 'ENT0091', 'Bright Financial Services Ltd', 'STR',
   '2026-09-08 21:30:00', '2026-09-09 21:30:00', 1, FALSE, 6, 1400000.00, 5,
   'PASS', FALSE, 'b83713069db288c21d0d54b9fcc593569cee056da8ef7143565fe2ab23217c72', 'SENT',
   'ATTACHMENT', 'SCHEDULED', 'SCHEDULER', 'SUCCESS', '2026-09-09 21:30:00', '2026-09-09 21:32:15'),
  ('RUN-HIST-20260910-001', 'ENT0091', 'Bright Financial Services Ltd', 'STR',
   '2026-09-09 21:30:00', '2026-09-10 21:30:00', 1, FALSE, 2, 330000.00, 2,
   'PASS', FALSE, '827bc932a7bff0c30b00489b061e604d00f2c4dc8433a163970c19655a992791', 'SENT',
   'ATTACHMENT', 'SCHEDULED', 'SCHEDULER', 'SUCCESS', '2026-09-10 21:30:00', '2026-09-10 21:31:45');

-- 3.4 Transactions: 2 already-reported ones (10 Sep) + the 3 from the PDF sample file (11 Sep)
INSERT INTO transactions
  (transaction_id, transaction_datetime, account_number, customer_id, transaction_type,
   channel, currency, amount, counterparty_name, counterparty_country)
VALUES
  ('TXN-99110001', '2026-09-10 10:00:00', '00198811', 'CUST-20001', 'WIRE_TRANSFER',
   'ONLINE', 'INR',  120000.00, 'Nordic Prime Corp',        'SE'),
  ('TXN-99110002', '2026-09-10 15:30:00', '00198822', 'CUST-20002', 'WIRE_TRANSFER',
   'ONLINE', 'INR',  210000.00, 'London Capital Partners',  'GB'),
  ('TXN-99120455', '2026-09-11 14:22:07', '00214578', 'CUST-77219', 'CARD_PAYMENT',
   'ONLINE', 'INR',  248500.00, 'Global Gadgets Online',    'SG'),
  ('TXN-99120781', '2026-09-11 16:40:55', '00219004', 'CUST-81140', 'WIRE_TRANSFER',
   'BRANCH', 'INR', 1150000.00, 'Orient Trading FZE',       'AE'),
  ('TXN-99121033', '2026-09-11 18:05:12', '00221876', 'CUST-66207', 'CASH_DEPOSIT',
   'BRANCH', 'INR',  980000.00, 'Self',                     'IN');

-- 3.5 Flags: 2 already REPORTED (10 Sep) + 3 PENDING_REPORT (11 Sep)
INSERT INTO transaction_flags
  (transaction_id, flag_code, flag_reason, flagged_at, reviewed_by, review_status,
   report_status, reported_run_id)
VALUES
  ('TXN-99110001', 'FLG-HIGH-VALUE',    'High value offshore transfer',
   '2026-09-10 10:05:00', 'RISK_ANALYST_01', 'CONFIRMED', 'REPORTED', 'RUN-HIST-20260910-001'),
  ('TXN-99110002', 'FLG-CROSS-BORDER',  'Cross border transfer to monitored jurisdiction',
   '2026-09-10 15:35:00', 'RISK_ANALYST_02', 'CONFIRMED', 'REPORTED', 'RUN-HIST-20260910-001'),
  ('TXN-99120455', 'FLG-HIGH-VALUE',    'Amount above reporting threshold',
   '2026-09-11 14:22:09', 'RISK_ANALYST_04', 'CONFIRMED', 'PENDING_REPORT', NULL),
  ('TXN-99120781', 'FLG-CROSS-BORDER',  'Cross border transfer to monitored jurisdiction',
   '2026-09-11 16:41:02', 'RISK_ANALYST_02', 'CONFIRMED', 'PENDING_REPORT', NULL),
  ('TXN-99121033', 'FLG-STRUCTURING',   'Multiple deposits below threshold within 24 hours',
   '2026-09-11 18:05:20', 'RISK_ANALYST_07', 'CONFIRMED', 'PENDING_REPORT', NULL);

-- Period labelled 2026-09-12 has NO flags on purpose -> this is the NIL report test.

-- ---------------------------------------------------------------------
-- 4. QUICK CHECKS (run after the script)
-- ---------------------------------------------------------------------
SHOW TABLES;   -- expect 5 tables

SELECT 'customers' AS tbl, COUNT(*) AS n FROM customers              -- expect 5
UNION ALL SELECT 'transactions', COUNT(*) FROM transactions          -- expect 5
UNION ALL SELECT 'transaction_flags', COUNT(*) FROM transaction_flags -- expect 5
UNION ALL SELECT 'compliance_report_runs', COUNT(*) FROM compliance_report_runs -- expect 3
UNION ALL SELECT 'compliance_report_control', COUNT(*) FROM compliance_report_control; -- expect 1

-- The PDF's extraction query, unchanged except :params -> user variables.
-- Expected: 3 rows, in this order: TXN-99120455, TXN-99120781, TXN-99121033
SET @periodStart = '2026-09-10 21:30:00';
SET @periodEnd   = '2026-09-11 21:30:00';

SELECT t.transaction_id, t.transaction_datetime, t.account_number,
       c.customer_id, c.customer_name, c.customer_type,
       t.transaction_type, t.channel, t.currency, t.amount,
       t.counterparty_name, t.counterparty_country,
       f.flag_code, f.flag_reason, f.flagged_at, f.reviewed_by, f.review_status
FROM transactions t
JOIN transaction_flags f ON f.transaction_id = t.transaction_id
JOIN customers c ON c.customer_id = t.customer_id
WHERE f.flagged_at >= @periodStart
  AND f.flagged_at <  @periodEnd
  AND f.report_status = 'PENDING_REPORT'
ORDER BY f.flagged_at, t.transaction_id;

-- The PDF's independent aggregate. Expected: 3 | 2378500.00 | 3
SELECT COUNT(*) AS record_count,
       SUM(t.amount) AS total_amount,
       COUNT(DISTINCT c.customer_id) AS customer_count
FROM transactions t
JOIN transaction_flags f ON f.transaction_id = t.transaction_id
JOIN customers c ON c.customer_id = t.customer_id
WHERE f.flagged_at >= @periodStart
  AND f.flagged_at <  @periodEnd
  AND f.report_status = 'PENDING_REPORT';
