-- ============================================================================
-- 06 - REPORTING layer (BI-facing views + data-quality monitor)
--
-- 04/05 build and query the fact table. This layer sits on top of it and gives
-- BI tools and analysts *stable, named* objects instead of ad-hoc SQL:
--   * a governed set of KPI views (agent scorecard, region summary, SLA, trend)
--   * one enriched view that actually exercises the role-playing dim_date
--   * a single-row data-quality monitor a scheduled Task can alert on
--
-- Every object is CREATE OR REPLACE, so this file is idempotent and safe to rerun.
-- Population rules are inherited from the fact table and repeated per view:
--   resolution-time KPIs use clean + resolved rows; volume/closure use all cases.
-- ============================================================================
USE DATABASE DEMO_DB;

CREATE SCHEMA IF NOT EXISTS rpt;


-- ----------------------------------------------------------------------------
-- SLA policy — a small reference table mapping priority -> target resolution.
-- Targets are ILLUSTRATIVE (business-defined in reality); kept in a table, not
-- hard-coded in a CASE, so the SLA can change without touching view logic.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE dim.dim_sla_policy (
    priority              VARCHAR(20) NOT NULL,
    target_resolution_hrs NUMBER(10,1) NOT NULL
);

INSERT INTO dim.dim_sla_policy (priority, target_resolution_hrs) VALUES
    ('Urgent',   8.0),
    ('High',    24.0),
    ('Medium',  72.0),
    ('Low',    120.0);


-- ----------------------------------------------------------------------------
-- rpt.case_enriched — the analytics base view.
-- Joins the fact to dim_date TWICE (created + closed) — the role-playing
-- dimension in action — and to the SLA policy. Everything downstream reads this
-- so calendar logic and SLA rules are defined in exactly one place.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt.case_enriched AS
SELECT
    f.case_id,
    f.status,
    f.priority,
    f.category,
    f.region,
    f.team,
    f.agent_name,
    f.customer_name,
    f.created_at,
    f.closed_at,
    f.resolution_hours,
    f.resolution_bucket,
    f.is_resolved,
    f.has_any_dq_flag,

    -- role-playing dim_date: "created" role
    cd.full_date        AS created_date,
    cd.year_num         AS created_year,
    cd.quarter_label    AS created_quarter,
    cd.month_name       AS created_month,
    cd.is_weekend       AS created_on_weekend,

    -- role-playing dim_date: "closed" role (NULL for open cases)
    xd.full_date        AS closed_date,
    xd.quarter_label    AS closed_quarter,

    -- SLA evaluation — only meaningful for a clean, resolved case
    sla.target_resolution_hrs,
    CASE
        WHEN f.has_any_dq_flag = FALSE AND f.is_resolved AND f.resolution_hours IS NOT NULL
        THEN (f.resolution_hours <= sla.target_resolution_hrs)
        ELSE NULL
    END                 AS sla_met
FROM facts.fact_cases f
LEFT JOIN dim.dim_date       cd  ON f.created_date_key = cd.date_key
LEFT JOIN dim.dim_date       xd  ON f.closed_date_key  = xd.date_key
LEFT JOIN dim.dim_sla_policy sla ON f.priority         = sla.priority;


-- ----------------------------------------------------------------------------
-- rpt.agent_scorecard — one row per agent. Counts/closure = all cases;
-- resolution time = resolved cases only (labelled inline).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt.agent_scorecard AS
SELECT
    agent_name,
    team,
    COUNT(*)                                                          AS total_cases,       -- all
    SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END)                      AS resolved_cases,    -- all
    ROUND(SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS closure_rate_pct,
    ROUND(AVG(CASE WHEN is_resolved THEN resolution_hours END), 1)    AS avg_resolution_hours, -- resolved
    ROUND(MEDIAN(CASE WHEN is_resolved THEN resolution_hours END), 1) AS median_resolution_hours,
    SUM(CASE WHEN has_any_dq_flag THEN 1 ELSE 0 END)                  AS dq_flagged_cases
FROM facts.fact_cases
GROUP BY agent_name, team;


-- ----------------------------------------------------------------------------
-- rpt.region_summary — volume, closure, and resolution by region.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt.region_summary AS
SELECT
    region,
    COUNT(*)                                                          AS total_cases,
    SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END)                      AS resolved_cases,
    ROUND(SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS closure_rate_pct,
    ROUND(AVG(CASE WHEN is_resolved THEN resolution_hours END), 1)    AS avg_resolution_hours,
    SUM(CASE WHEN status = 'Open'    THEN 1 ELSE 0 END)               AS open_cases,
    SUM(CASE WHEN status = 'On Hold' THEN 1 ELSE 0 END)               AS on_hold_cases
FROM facts.fact_cases
GROUP BY region;


-- ----------------------------------------------------------------------------
-- rpt.priority_sla — SLA attainment by priority (clean + resolved population).
-- Turns the "Urgent is mishandled" narrative into a governed KPI: Urgent has a
-- tight 8h target, so its breach rate makes the routing problem measurable.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt.priority_sla AS
SELECT
    priority,
    target_resolution_hrs,
    COUNT(*)                                              AS resolved_clean_cases,
    ROUND(AVG(resolution_hours), 1)                       AS avg_resolution_hours,
    SUM(CASE WHEN sla_met THEN 1 ELSE 0 END)              AS met_sla,
    SUM(CASE WHEN sla_met = FALSE THEN 1 ELSE 0 END)      AS breached_sla,
    ROUND(SUM(CASE WHEN sla_met THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS sla_attainment_pct
FROM rpt.case_enriched
WHERE has_any_dq_flag = FALSE
  AND is_resolved = TRUE
  AND resolution_hours IS NOT NULL
GROUP BY priority, target_resolution_hrs
ORDER BY target_resolution_hrs;


-- ----------------------------------------------------------------------------
-- rpt.monthly_trend — created-case volume + resolution by calendar month,
-- via the dim_date "created" role (not raw DATE_TRUNC), so BI slicers line up.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt.monthly_trend AS
SELECT
    created_year,
    created_month,
    COUNT(*)                                                       AS total_cases,
    SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END)                   AS resolved_cases,
    ROUND(AVG(CASE WHEN is_resolved THEN resolution_hours END), 1) AS avg_resolution_hours
FROM rpt.case_enriched
GROUP BY created_year, created_month;


-- ----------------------------------------------------------------------------
-- rpt.data_quality_monitor — ONE row, one column per health check, plus an
-- overall pipeline_healthy flag. A scheduled Task can `SELECT ... WHERE
-- pipeline_healthy = FALSE` and alert *before* dashboards refresh.
-- This is the "monitoring" story from the README, made queryable.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW rpt.data_quality_monitor AS
WITH checks AS (
    SELECT
        COUNT(*)                                                       AS fact_rows,
        SUM(CASE WHEN has_any_dq_flag THEN 1 ELSE 0 END)               AS dq_flagged,
        ROUND(SUM(CASE WHEN has_any_dq_flag THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) AS dq_flag_pct,
        SUM(CASE WHEN resolution_hours < 0 THEN 1 ELSE 0 END)          AS negative_resolution_rows,
        SUM(CASE WHEN sk_customer IS NULL THEN 1 ELSE 0 END)           AS orphan_customers,
        SUM(CASE WHEN sk_agent   IS NULL THEN 1 ELSE 0 END)            AS orphan_agents,
        SUM(CASE WHEN status = 'Closed' AND resolution_hours IS NULL THEN 1 ELSE 0 END) AS closed_missing_resolution
    FROM facts.fact_cases
)
SELECT
    CURRENT_TIMESTAMP()                                                AS checked_at,
    fact_rows,
    dq_flagged,
    dq_flag_pct,
    negative_resolution_rows,
    orphan_customers,
    orphan_agents,
    closed_missing_resolution,
    -- overall health: hard failures should never be non-zero
    (fact_rows > 0
     AND negative_resolution_rows = 0
     AND orphan_customers = 0
     AND orphan_agents = 0)                                            AS pipeline_healthy
FROM checks;


-- spot checks
SELECT * FROM rpt.priority_sla;
SELECT * FROM rpt.data_quality_monitor;
SELECT * FROM rpt.agent_scorecard ORDER BY closure_rate_pct DESC LIMIT 10;
