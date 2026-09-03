-- ============================================================================
-- 05 - ANALYTICS queries (the business questions from the brief)
-- Execution context: run against DEMO_DB.
-- ============================================================================
USE DATABASE DEMO_DB;

-- Two populations are used deliberately, and each query says which one:
--   * ALL CASES              - volume and status-based closure metrics. Status is
--                              the source of truth, so every case counts.
--   * CLEAN + RESOLVED ONLY  - resolution-time metrics. Requires has_any_dq_flag =
--                              FALSE, status = Closed, and a valid resolution_hours.
-- resolution_hours is non-null only for clean Closed rows, so filtering on it (or on
-- has_any_dq_flag) is what separates trustworthy duration metrics from raw counts.

-- Preview
SELECT * FROM facts.fact_cases LIMIT 20;


-- ============================================================================
-- A. RESOLUTION TIME   (Population: CLEAN + RESOLVED ONLY)
-- ============================================================================

-- Overall average resolution (expected: 96.8 h / ~4.0 days over 38 resolved cases)
SELECT
    ROUND(AVG(resolution_hours), 1)      AS avg_resolution_hours,
    ROUND(AVG(resolution_hours) / 24, 2) AS avg_resolution_days,
    COUNT(*)                             AS resolved_cases
FROM facts.fact_cases
WHERE has_any_dq_flag = FALSE
  AND is_resolved = TRUE
  AND resolution_hours IS NOT NULL;


-- By priority (expected slowest->fastest: Low 126.3, Medium 113.5, Urgent 94.8, High 53.7)
SELECT
    priority,
    COUNT(*)                           AS resolved_cases,
    ROUND(AVG(resolution_hours), 1)    AS avg_resolution_hours,
    ROUND(MEDIAN(resolution_hours), 1) AS median_resolution_hours,
    ROUND(MIN(resolution_hours), 1)    AS min_hours,
    ROUND(MAX(resolution_hours), 1)    AS max_hours
FROM facts.fact_cases
WHERE has_any_dq_flag = FALSE
  AND is_resolved = TRUE
  AND resolution_hours IS NOT NULL
GROUP BY priority
ORDER BY avg_resolution_hours ASC;


-- By category
SELECT
    category,
    COUNT(*)                           AS resolved_cases,
    ROUND(AVG(resolution_hours), 1)    AS avg_resolution_hours,
    ROUND(MEDIAN(resolution_hours), 1) AS median_resolution_hours
FROM facts.fact_cases
WHERE has_any_dq_flag = FALSE
  AND is_resolved = TRUE
  AND resolution_hours IS NOT NULL
GROUP BY category
ORDER BY avg_resolution_hours ASC;


-- By team (expected best->worst: Tier 2 60.9, Billing 107.5, Escalations 121.8, Tier 1 147.6)
SELECT
    team,
    COUNT(*)                           AS resolved_cases,
    ROUND(AVG(resolution_hours), 1)    AS avg_resolution_hours,
    ROUND(MEDIAN(resolution_hours), 1) AS median_resolution_hours
FROM facts.fact_cases
WHERE has_any_dq_flag = FALSE
  AND is_resolved = TRUE
  AND resolution_hours IS NOT NULL
GROUP BY team
ORDER BY avg_resolution_hours ASC;


-- Resolution-time distribution.
-- pct is share of RESOLVED cases (denominator = resolved cases only), so unresolved
-- clean rows with a NULL bucket are excluded - otherwise the percentages would be off.
SELECT
    resolution_bucket,
    COUNT(*)                                          AS resolved_cases,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct_of_resolved
FROM facts.fact_cases
WHERE has_any_dq_flag = FALSE
  AND is_resolved = TRUE
  AND resolution_hours IS NOT NULL
GROUP BY resolution_bucket
ORDER BY resolved_cases DESC;


-- ============================================================================
-- B. VOLUME AND CLOSURE   (Population: ALL CASES; closure = status is source of truth)
-- ============================================================================
-- closure_rate_pct = share of cases whose status is Closed. It is a status metric,
-- NOT a statement that resolution time is known for those cases (see section A).

-- By category
SELECT
    category,
    COUNT(*)                                                  AS total_cases,
    SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END)              AS resolved_cases,
    ROUND(SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS closure_rate_pct
FROM facts.fact_cases
GROUP BY category
ORDER BY total_cases DESC;

-- By priority (expected: Urgent has the lowest closure rate, ~14.6%)
SELECT
    priority,
    COUNT(*)                                                  AS total_cases,
    SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END)              AS resolved_cases,
    ROUND(SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS closure_rate_pct
FROM facts.fact_cases
GROUP BY priority
ORDER BY total_cases DESC;

-- By status
SELECT
    status,
    COUNT(*)                                          AS total_cases,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct_of_total
FROM facts.fact_cases
GROUP BY status
ORDER BY total_cases DESC;

-- Category x Priority x Status slice, drilled into one segment
WITH breakdown AS (
    SELECT
        category,
        priority,
        status,
        COUNT(*)                                                  AS total_cases,
        SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END)              AS resolved_cases,
        ROUND(SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS closure_rate_pct
    FROM facts.fact_cases
    GROUP BY category, priority, status
)
SELECT *
FROM breakdown
WHERE category = 'Account'
  AND priority = 'Urgent'
ORDER BY total_cases DESC;

-- Category x Status pivot
SELECT
    category,
    SUM(CASE WHEN status = 'Closed'      THEN 1 ELSE 0 END) AS closed,
    SUM(CASE WHEN status = 'In Progress' THEN 1 ELSE 0 END) AS in_progress,
    SUM(CASE WHEN status = 'On Hold'     THEN 1 ELSE 0 END) AS on_hold,
    SUM(CASE WHEN status = 'Open'        THEN 1 ELSE 0 END) AS open_cases,
    COUNT(*)                                                AS total_cases
FROM facts.fact_cases
GROUP BY category
ORDER BY total_cases DESC;

-- Priority x Status pivot
SELECT
    priority,
    SUM(CASE WHEN status = 'Closed'      THEN 1 ELSE 0 END) AS closed,
    SUM(CASE WHEN status = 'In Progress' THEN 1 ELSE 0 END) AS in_progress,
    SUM(CASE WHEN status = 'On Hold'     THEN 1 ELSE 0 END) AS on_hold,
    SUM(CASE WHEN status = 'Open'        THEN 1 ELSE 0 END) AS open_cases,
    COUNT(*)                                                AS total_cases
FROM facts.fact_cases
GROUP BY priority
ORDER BY total_cases DESC;


-- ============================================================================
-- C. AGENT AND TEAM PERFORMANCE
-- Mixed populations on purpose (labelled): counts and closure use ALL CASES;
-- avg/median resolution use RESOLVED cases only via CASE WHEN is_resolved.
-- ============================================================================

-- Agent scorecard
SELECT
    agent_name,
    team,
    COUNT(*)                                                        AS total_cases,          -- all cases
    SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END)                    AS resolved_cases,       -- all cases
    ROUND(SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS closure_rate_pct,
    ROUND(AVG(CASE WHEN is_resolved THEN resolution_hours END), 1)  AS avg_resolution_hours, -- resolved only
    ROUND(MEDIAN(CASE WHEN is_resolved THEN resolution_hours END), 1) AS median_resolution_hours,
    SUM(CASE WHEN status = 'On Hold' THEN 1 ELSE 0 END)             AS on_hold_cases,
    SUM(CASE WHEN has_any_dq_flag    THEN 1 ELSE 0 END)             AS dq_flagged_cases
FROM facts.fact_cases
GROUP BY agent_name, team
ORDER BY closure_rate_pct DESC, total_cases DESC;

-- Team rollup
SELECT
    team,
    COUNT(*)                                                        AS total_cases,
    SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END)                    AS resolved_cases,
    ROUND(SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS closure_rate_pct,
    ROUND(AVG(CASE WHEN is_resolved THEN resolution_hours END), 1)  AS avg_resolution_hours,
    COUNT(DISTINCT agent_name)                                      AS agent_count,
    ROUND(COUNT(*) / COUNT(DISTINCT agent_name), 1)                 AS cases_per_agent
FROM facts.fact_cases
GROUP BY team
ORDER BY avg_resolution_hours ASC;

-- Top 3 agents per team by average resolution time (resolved cases)
SELECT
    agent_name,
    team,
    total_cases,
    resolved_cases,
    avg_resolution_hours,
    closure_rate_pct,
    RANK() OVER (PARTITION BY team ORDER BY avg_resolution_hours ASC) AS rank_in_team
FROM (
    SELECT
        agent_name,
        team,
        COUNT(*)                                                       AS total_cases,
        SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END)                   AS resolved_cases,
        ROUND(AVG(CASE WHEN is_resolved THEN resolution_hours END), 1) AS avg_resolution_hours,
        ROUND(SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS closure_rate_pct
    FROM facts.fact_cases
    GROUP BY agent_name, team
) t
QUALIFY rank_in_team <= 3
ORDER BY team, rank_in_team;


-- ============================================================================
-- D. CUSTOMER AND REGION TRENDS
-- counts/closure = ALL CASES; avg_resolution_hours = RESOLVED cases only.
-- ============================================================================

-- By region (expected: LATAM highest volume at 62 cases)
SELECT
    region,
    COUNT(*)                                                        AS total_cases,
    SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END)                    AS resolved_cases,
    ROUND(SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS closure_rate_pct,
    ROUND(AVG(CASE WHEN is_resolved THEN resolution_hours END), 1)  AS avg_resolution_hours,
    SUM(CASE WHEN status = 'On Hold' THEN 1 ELSE 0 END)             AS on_hold_cases,
    SUM(CASE WHEN status = 'Open'    THEN 1 ELSE 0 END)             AS open_cases
FROM facts.fact_cases
GROUP BY region
ORDER BY total_cases DESC;

-- Region x Category
SELECT
    region,
    category,
    COUNT(*)                                                        AS total_cases,
    ROUND(AVG(CASE WHEN is_resolved THEN resolution_hours END), 1)  AS avg_resolution_hours
FROM facts.fact_cases
GROUP BY region, category
ORDER BY region, total_cases DESC;

-- Top 10 customers by case volume
SELECT
    customer_name,
    region,
    COUNT(*)                                                        AS total_cases,
    SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END)                    AS resolved_cases,
    ROUND(AVG(CASE WHEN is_resolved THEN resolution_hours END), 1)  AS avg_resolution_hours,
    SUM(CASE WHEN priority = 'Urgent' THEN 1 ELSE 0 END)           AS urgent_cases
FROM facts.fact_cases
GROUP BY customer_name, region
ORDER BY total_cases DESC
LIMIT 10;

-- Monthly volume trend
SELECT
    DATE_TRUNC('month', created_at)                                AS month,
    COUNT(*)                                                        AS total_cases,
    SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END)                    AS resolved_cases,
    ROUND(AVG(CASE WHEN is_resolved THEN resolution_hours END), 1)  AS avg_resolution_hours
FROM facts.fact_cases
GROUP BY DATE_TRUNC('month', created_at)
ORDER BY month ASC;

-- Region trend by quarter
SELECT
    region,
    DATE_TRUNC('quarter', created_at)                              AS quarter,
    COUNT(*)                                                        AS total_cases,
    ROUND(AVG(CASE WHEN is_resolved THEN resolution_hours END), 1)  AS avg_resolution_hours
FROM facts.fact_cases
GROUP BY region, DATE_TRUNC('quarter', created_at)
ORDER BY quarter ASC, region;
