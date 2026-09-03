# Customer Support Analytics Pipeline
### Senior Data Architect — Interview Presentation

---

## The Problem

A company runs a customer support platform. Customers raise support tickets (called cases). Agents work on those cases. Leadership wants to see dashboards and reports answering questions like:

- How long does it take to resolve a case on average?
- Which regions have the most cases?
- Which agents are performing best?
- Are Urgent cases being resolved faster than Low priority ones?

We were given 3 raw CSV files and asked to design and build a pipeline that turns that raw data into something analytics-ready. That means clean, structured, well-modelled data that a BI tool like Power BI or Tableau can sit on top of.

Three CSV files. **200 cases. 150 customers. 40 agents.**


### cases.csv — 200 rows

| Column | Type | Notes |
|---|---|---|
| case_id | String | Unique ID e.g. C0001 |
| created_at | String | ISO timestamp — needs parsing |
| closed_at | String | Empty for open cases — critical DQ source |
| customer_id | String | FK to customers |
| agent_id | String | FK to agents |
| category | String | Technical / Account / Billing / Other |
| priority | String | Low / Medium / High / Urgent |
| status | String | Open / Closed / In Progress / On Hold |

### customers.csv — 150 rows

| Column | Notes |
|---|---|
| customer_id | Natural key |
| customer_name | |
| region | APAC / LATAM / Europe / North America |
| signup_date | |

### agents.csv — 40 rows

| Column | Notes |
|---|---|
| agent_id | Natural key |
| agent_name | |
| team | Billing / Tier 1 / Tier 2 / Escalations |



---

## Architecture

```
CSV Files  →  RAW  →  STAGING  →  DIMENSIONS  →  FACT TABLE
```

| Layer | Single Job |
|---|---|
| Raw | Minimally transformed landing. All strings + ingestion metadata; empties → NULL. Tolerates bad rows without failing the batch (`ON_ERROR = CONTINUE`). |
| Staging | Parse types. Normalise. Compute DQ flags + resolution time. |
| Dimensions | Clean lookup tables — customer, agent, date. |
| Fact | One analytics-ready row per case. No joins needed at query time. |

**Choice: Star Schema** — a small number of stable source files and a read-heavy BI workload, which Snowflake (columnar) and Power BI both handle well. Data Vault would add modelling/operational complexity without enough benefit at this scope. A 3NF model preserves source relationships but needs more joins for these BI questions, so a star is simpler for analytical consumption.

---

## Data Quality — What I Found First

> *"I profiled all three files before writing a single line of SQL. Non-negotiable. You never design a pipeline on assumptions."*

| Issue | Rows | Decision |
|---|---|---|
| Closed — no `closed_at` | **9** | Flag. `resolution_hours = NULL`. Row stays. |
| Open/On Hold/In Progress — has `closed_at` | **123** | Flag. Status is source of truth. |
| Non-closed with NULL `closed_at` | 30 | Expected. No flag needed. |
| Orphan customer / agent | 0 | Check still runs every load. |

**Rule: Flag dirty rows, never delete.** Resolution-time KPIs use clean rows only
(`has_any_dq_flag = FALSE`); volume and status-based closure metrics use all cases, because
status is the source of truth.

Deleting hides the upstream bug. Flagging surfaces it.

---

## Data Model — Star Schema

```
          dim_date
             |
dim_customer — fact_cases — dim_agent
```

**Fact grain:** One row per case. `case_id` = PK.

**Three key design decisions:**

1. **Surrogate keys** (sk_customer, sk_agent) — not natural varchar keys. If source IDs change or get reused, surrogate integers stay stable. Historical joins never break.

2. **Denormalised region + team** into the fact table — fewer joins for the main dashboard queries. Snowflake's columnar storage makes that trade-off practical for this workload.

3. **LEFT JOIN in the fact MERGE, not INNER JOIN** — an INNER JOIN silently drops orphan rows. You'd never know the case existed. LEFT JOIN keeps it, flags it.

---

## DQ Flags in the Fact Table

| Flag | Count | What it catches |
|---|---|---|
| `dq_flag_closed_no_timestamp` | 9 | Closed status, no close time |
| `dq_flag_status_ts_mismatch` | 123 | Status and timestamp contradict |
| `dq_flag_orphan_customer` | 0 | customer_id not in dim_customer |
| `dq_flag_orphan_agent` | 0 | agent_id not in dim_agent |
| **`has_any_dq_flag`** | **132** | **Summary — filtered FALSE for resolution-time KPIs** |

---

## Key Insights

| Finding | Value |
|---|---|
| Overall avg resolution | **96.8 hours — 4 days** (38 resolved clean cases) |
| Fastest priority | High — **53.7 hours** |
| Slowest priority | Low — **126.3 hours** |
| ⚠️ Counterintuitive | **Urgent (94.8h) slower than High (53.7h)** + **lowest closure rate (14.6%)** — routing problem |
| Best team | Tier 2 — **60.9 hours** |
| Slowest team | Tier 1 — **147.6 hours** (~2.4× slower — workload design issue) |
| Highest volume | LATAM — **62 cases** |
| Lowest closure rate | North America **18.4%**, LATAM **19.4%** |

---

## Pipeline Design Decisions

**Idempotent loading patterns** → staging + fact use MERGE; SCD2 dims use expire-and-insert; date dim is generated with CREATE OR REPLACE; RAW uses COPY INTO. Reruns don't duplicate rows.

**Fixed step order** → stg_customers → stg_agents → stg_cases (cases LEFT JOINs to both — run it last)

**`TRY_TO_TIMESTAMP_NTZ`** → bad timestamp = NULL, not a pipeline crash.

**`EMPTY_FIELD_AS_NULL = TRUE`** → without this, empty `closed_at` is `''` not NULL. Every DQ check silently breaks.

---

## Production & Scale

| Concern | Approach |
|---|---|
| Volume | Incremental MERGE · cluster fact on `created_date_key` · Snowflake auto-scale |
| Orchestration | Snowflake Tasks · fixed step order · alert on first failure |
| Schema changes | Add NULLABLE to RAW first · never drop without deprecation window |
| Monitoring | Row count · DQ flag % · negative hours · orphan keys — alert before dashboard loads |
| SCD2 | `valid_from / valid_to / is_current` on dimensions — SCD2-ready, so as-of history can be enabled later without a schema redesign (not yet exercised; fact joins to `is_current = TRUE`) |

---

## Closing

> *"A single fact table that answers every question in the brief with no joins at query time — resolution time, volume, agent performance, regional trends. DQ flags mean the pipeline is transparent about what it doesn't trust. Each layer evolves independently when we go to production. That's what I'd hand to a data engineering team."*

---

## Quick Numbers — Have These Ready

| | |
|---|---|
| Cases / Customers / Agents | 200 / 150 / 40 |
| DQ: Closed no timestamp | **9 rows** |
| DQ: Status mismatch | **123 rows** |
| DQ: Any flag (has_any) | **132 rows** · **68 clean**, 38 resolved |
| Avg resolution | **96.8 hours** |
| Tier 2 vs Tier 1 | **60.9h vs 147.6h** |
| High vs Urgent | **53.7h vs 94.8h** ← counterintuitive |
| LATAM | **62 cases, 19.4% closure** |
