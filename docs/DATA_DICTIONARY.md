# Data Dictionary

Column-level reference for the analytics-ready objects. Layers upstream of the fact
(`raw.*`, `stg.*`) mirror the source columns as strings/typed staging and are omitted
here for brevity — see [`All_SQL/`](../All_SQL). Grain and population rules are stated
per object because they determine which rows a metric may legitimately use.

---

## `facts.fact_cases`

**Grain:** one row per support case. **Business key:** `case_id`. All 200 cases are
loaded, flagged or not (flag-don't-delete).

| Column | Type | Description |
|--------|------|-------------|
| `case_id` | VARCHAR | Business key. Unique (guaranteed by the MERGE, not the engine). |
| `sk_customer` | INTEGER | Surrogate FK → `dim_customer.sk_customer` (current row). |
| `sk_agent` | INTEGER | Surrogate FK → `dim_agent.sk_agent` (current row). |
| `created_date_key` | INTEGER | FK → `dim_date.date_key`, "created" role (`YYYYMMDD`). |
| `closed_date_key` | INTEGER | FK → `dim_date.date_key`, "closed" role. NULL when open. |
| `status` | VARCHAR | Open / Closed / In Progress / On Hold. **Source of truth for closure.** |
| `priority` | VARCHAR | Low / Medium / High / Urgent. |
| `category` | VARCHAR | Technical / Account / Billing / Other. |
| `created_at` | TIMESTAMP_NTZ | Parsed creation timestamp. |
| `closed_at` | TIMESTAMP_NTZ | Parsed close timestamp; NULL when open/unknown. |
| `resolution_hours` | NUMBER(10,2) | Hours from create → close. **Non-null only for clean, Closed cases with `closed_at > created_at`.** The KPI measure. |
| `resolution_bucket` | VARCHAR | `<24h` / `1-3 days` / `>3 days`; NULL when unresolved. |
| `is_resolved` | BOOLEAN | `status = 'Closed'`. |
| `customer_name`, `region` | VARCHAR | Denormalised from `dim_customer` to avoid query-time joins. |
| `agent_name`, `team` | VARCHAR | Denormalised from `dim_agent`. |
| `dq_flag_closed_no_timestamp` | BOOLEAN | Closed but no `closed_at` (9 rows). |
| `dq_flag_status_ts_mismatch` | BOOLEAN | Non-closed status but a `closed_at` present (123 rows). |
| `dq_flag_invalid_created_at` | BOOLEAN | `created_at` unparseable (0 rows). |
| `dq_flag_orphan_customer` | BOOLEAN | `customer_id` not in `dim_customer` (0 rows). |
| `dq_flag_orphan_agent` | BOOLEAN | `agent_id` not in `dim_agent` (0 rows). |
| `has_any_dq_flag` | BOOLEAN | OR of the five flags (132 rows). **Filter `FALSE` for resolution-time KPIs.** |
| `_loaded_at`, `_updated_at` | TIMESTAMP_NTZ | Load / last-merge audit timestamps. |

**Population rules**
- *Resolution-time KPIs* → `has_any_dq_flag = FALSE AND is_resolved AND resolution_hours IS NOT NULL` (38 rows).
- *Volume & closure* → all 200 rows; `status` is authoritative.

---

## `dim.dim_customer` / `dim.dim_agent` (SCD Type 2 ready)

| Column | Type | Description |
|--------|------|-------------|
| `sk_customer` / `sk_agent` | INTEGER | Surrogate PK (`AUTOINCREMENT`). |
| `customer_id` / `agent_id` | VARCHAR | Natural key from source. |
| `customer_name` / `agent_name` | VARCHAR | Descriptive attribute. |
| `region` (cust.) / `team` (agent) | VARCHAR | Slicing attribute. |
| `signup_date` (cust.) | DATE | Parsed signup date. |
| `valid_from` | DATE | SCD2 effective-from (`CURRENT_DATE` on insert). |
| `valid_to` | DATE | SCD2 effective-to (`9999-12-31` while current). |
| `is_current` | BOOLEAN | TRUE for the live version; the fact joins on this. |
| `_loaded_at` | TIMESTAMP_NTZ | Load audit timestamp. |

Current load is a first-time insert; the expire-and-insert logic is present so history
can be turned on without a schema redesign.

## `dim.dim_date`

Generated 2020-01-01 → 2030-12-31 (4,018 rows). Role-playing: joined to the fact as
both "created" and "closed". Key columns: `date_key` (PK, `YYYYMMDD`), `full_date`,
`day_of_week`, `month_num`/`month_name`, `quarter_num`/`quarter_label`, `year_num`,
`is_weekend`/`is_weekday`.

## `dim.dim_sla_policy` (reference)

`priority` → `target_resolution_hrs`. Illustrative SLA targets (Urgent 8h, High 24h,
Medium 72h, Low 120h), kept in a table so the SLA can change without editing views.

---

## Reporting layer — `rpt.*` (views)

| Object | Grain | Notes |
|--------|-------|-------|
| `rpt.case_enriched` | one case | Base view; joins `dim_date` twice (role-playing) + SLA policy. Adds calendar attributes and `sla_met`. |
| `rpt.agent_scorecard` | one agent | Counts/closure = all cases; resolution = resolved only. |
| `rpt.region_summary` | one region | Volume, closure, avg resolution, open/on-hold counts. |
| `rpt.priority_sla` | one priority | SLA attainment on the clean + resolved population. |
| `rpt.monthly_trend` | year × month | Created-case volume + resolution via the `dim_date` created role. |
| `rpt.data_quality_monitor` | one row | Health checks + `pipeline_healthy` flag for alerting before dashboards refresh. |
