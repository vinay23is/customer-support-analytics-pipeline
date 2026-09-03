-- ============================================================================
-- 04 - FACT table + post-load validation
-- Grain: one row per case. case_id is the business key.
-- Surrogate keys for customer/agent so dimension changes don't break history.
-- region and team are denormalized in to avoid joins on the common queries.
-- All DQ flags are carried through from staging so KPIs can filter on them.
--
-- Note on PRIMARY KEY: Snowflake standard tables do NOT enforce PK uniqueness -
-- the constraint is informational (useful for BI tools and readers). Uniqueness
-- here is guaranteed by the MERGE keying on case_id, not by the engine.
-- ============================================================================
USE DATABASE DEMO_DB;

CREATE TABLE IF NOT EXISTS facts.fact_cases (
    case_id                     VARCHAR(10)  NOT NULL,
    sk_customer                 INTEGER,
    sk_agent                    INTEGER,
    created_date_key            INTEGER,
    closed_date_key             INTEGER,
    status                      VARCHAR(20),
    priority                    VARCHAR(20),
    category                    VARCHAR(50),
    created_at                  TIMESTAMP_NTZ,
    closed_at                   TIMESTAMP_NTZ,
    resolution_hours            NUMBER(10,2),
    resolution_bucket           VARCHAR(20),
    is_resolved                 BOOLEAN,
    customer_name               VARCHAR(100),
    region                      VARCHAR(50),
    agent_name                  VARCHAR(100),
    team                        VARCHAR(50),
    dq_flag_closed_no_timestamp BOOLEAN DEFAULT FALSE,
    dq_flag_status_ts_mismatch  BOOLEAN DEFAULT FALSE,
    dq_flag_invalid_created_at  BOOLEAN DEFAULT FALSE,
    dq_flag_orphan_customer     BOOLEAN DEFAULT FALSE,
    dq_flag_orphan_agent        BOOLEAN DEFAULT FALSE,
    has_any_dq_flag             BOOLEAN DEFAULT FALSE,
    _loaded_at                  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _updated_at                 TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_fact_cases PRIMARY KEY (case_id)
);


-- fact merge
-- Joins to current dim rows only (is_current = TRUE) to pick up the right surrogate keys.
-- On a match we refresh every mutable column. An earlier version only checked a subset
-- (status, closed_at, resolution_hours, keys) in WHEN MATCHED AND (...), which meant a
-- change to priority, category, created_at or a DQ flag would be silently missed on rerun.
-- At this scale, refreshing all columns is the correct, simplest behaviour.
-- DQ-flagged rows are loaded too; KPIs filter them out with has_any_dq_flag = FALSE.
MERGE INTO facts.fact_cases AS tgt
USING (
    SELECT
        sc.case_id,
        dc.sk_customer,
        da.sk_agent,
        TO_NUMBER(TO_CHAR(sc.created_at::DATE, 'YYYYMMDD'))    AS created_date_key,
        CASE
            WHEN sc.closed_at IS NOT NULL
            THEN TO_NUMBER(TO_CHAR(sc.closed_at::DATE, 'YYYYMMDD'))
            ELSE NULL
        END                                                     AS closed_date_key,
        sc.status,
        sc.priority,
        sc.category,
        sc.created_at,
        sc.closed_at,
        sc.resolution_hours,
        sc.resolution_bucket,
        (sc.status = 'Closed')                                  AS is_resolved,
        dc.customer_name,
        dc.region,
        da.agent_name,
        da.team,
        sc.dq_flag_closed_no_timestamp,
        sc.dq_flag_status_ts_mismatch,
        sc.dq_flag_invalid_created_at,
        sc.dq_flag_orphan_customer,
        sc.dq_flag_orphan_agent,
        sc.has_any_dq_flag
    FROM stg.stg_cases sc
    LEFT JOIN dim.dim_customer dc ON dc.customer_id = sc.customer_id AND dc.is_current = TRUE
    LEFT JOIN dim.dim_agent    da ON da.agent_id    = sc.agent_id    AND da.is_current = TRUE
) AS src
ON tgt.case_id = src.case_id
WHEN MATCHED THEN UPDATE SET
    tgt.sk_customer                     = src.sk_customer,
    tgt.sk_agent                        = src.sk_agent,
    tgt.created_date_key                = src.created_date_key,
    tgt.closed_date_key                 = src.closed_date_key,
    tgt.status                          = src.status,
    tgt.priority                        = src.priority,
    tgt.category                        = src.category,
    tgt.created_at                      = src.created_at,
    tgt.closed_at                       = src.closed_at,
    tgt.resolution_hours                = src.resolution_hours,
    tgt.resolution_bucket               = src.resolution_bucket,
    tgt.is_resolved                     = src.is_resolved,
    tgt.customer_name                   = src.customer_name,
    tgt.region                          = src.region,
    tgt.agent_name                      = src.agent_name,
    tgt.team                            = src.team,
    tgt.dq_flag_closed_no_timestamp     = src.dq_flag_closed_no_timestamp,
    tgt.dq_flag_status_ts_mismatch      = src.dq_flag_status_ts_mismatch,
    tgt.dq_flag_invalid_created_at      = src.dq_flag_invalid_created_at,
    tgt.dq_flag_orphan_customer         = src.dq_flag_orphan_customer,
    tgt.dq_flag_orphan_agent            = src.dq_flag_orphan_agent,
    tgt.has_any_dq_flag                 = src.has_any_dq_flag,
    tgt._updated_at                     = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    case_id, sk_customer, sk_agent,
    created_date_key, closed_date_key,
    status, priority, category,
    created_at, closed_at,
    resolution_hours, resolution_bucket, is_resolved,
    customer_name, region, agent_name, team,
    dq_flag_closed_no_timestamp, dq_flag_status_ts_mismatch,
    dq_flag_invalid_created_at, dq_flag_orphan_customer, dq_flag_orphan_agent,
    has_any_dq_flag,
    _loaded_at, _updated_at
) VALUES (
    src.case_id, src.sk_customer, src.sk_agent,
    src.created_date_key, src.closed_date_key,
    src.status, src.priority, src.category,
    src.created_at, src.closed_at,
    src.resolution_hours, src.resolution_bucket, src.is_resolved,
    src.customer_name, src.region, src.agent_name, src.team,
    src.dq_flag_closed_no_timestamp, src.dq_flag_status_ts_mismatch,
    src.dq_flag_invalid_created_at, src.dq_flag_orphan_customer, src.dq_flag_orphan_agent,
    src.has_any_dq_flag,
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
);


-- ----------------------------------------------------------------------------
-- Post-load validation. Run after every load; in production these become
-- automated tests that alert on failure. Expected results are noted per check.
-- ----------------------------------------------------------------------------

-- check 1: something actually loaded (expected: 200)
SELECT COUNT(*) AS fact_row_count FROM facts.fact_cases;

-- check 2: DQ flag counts (expected: closed_no_ts=9, status_ts_mismatch=123,
--          orphans=0, total_dq_flagged=132, i.e. 66% of 200)
SELECT
    SUM(CASE WHEN dq_flag_closed_no_timestamp THEN 1 ELSE 0 END) AS closed_no_ts,
    SUM(CASE WHEN dq_flag_status_ts_mismatch  THEN 1 ELSE 0 END) AS status_ts_mismatch,
    SUM(CASE WHEN dq_flag_orphan_customer     THEN 1 ELSE 0 END) AS orphan_customer,
    SUM(CASE WHEN dq_flag_orphan_agent        THEN 1 ELSE 0 END) AS orphan_agent,
    SUM(CASE WHEN has_any_dq_flag             THEN 1 ELSE 0 END) AS total_dq_flagged,
    COUNT(*)                                                       AS total_rows,
    ROUND(SUM(CASE WHEN has_any_dq_flag THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS dq_flag_pct
FROM facts.fact_cases;

-- check 3: no negative resolution times (expected: 0)
SELECT COUNT(*) AS negative_resolution_rows
FROM facts.fact_cases
WHERE resolution_hours < 0;

-- check 4: Closed cases with no resolution time (expected: 9 - the closed_no_timestamp rows)
SELECT COUNT(*) AS closed_missing_resolution
FROM facts.fact_cases
WHERE status = 'Closed'
  AND resolution_hours IS NULL;

-- check 5: orphan surrogate keys (expected: 0 for both)
SELECT COUNT(*) AS unmatched_customers FROM facts.fact_cases WHERE sk_customer IS NULL;
SELECT COUNT(*) AS unmatched_agents    FROM facts.fact_cases WHERE sk_agent    IS NULL;

-- check 6: sanity check - avg resolution by priority
-- Population: clean + resolved only. resolution_hours is non-null only for clean
-- Closed rows, so AVG already excludes flagged/unresolved cases; is_resolved count
-- is shown alongside. (expected order slowest->fastest: Low, Medium, Urgent, High)
SELECT
    priority,
    COUNT(*)                                     AS clean_cases,
    SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END) AS resolved_cases,
    ROUND(AVG(resolution_hours), 1)              AS avg_resolution_hours,
    MIN(resolution_hours)                        AS min_hours,
    MAX(resolution_hours)                        AS max_hours
FROM facts.fact_cases
WHERE has_any_dq_flag = FALSE
GROUP BY priority
ORDER BY avg_resolution_hours DESC;


-- spot check and ddl
SELECT * FROM facts.fact_cases LIMIT 10;
SELECT GET_DDL('table', 'facts.fact_cases');