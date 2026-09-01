# Customer Support Analytics Pipeline

An end-to-end analytics engineering case study: three raw CSV files are turned into a
clean, analytics-ready **star schema** on **Snowflake**, ready for a BI tool (Power BI /
Tableau) to sit on top of. Built as a Senior Data Architect interview exercise.

> **The brief:** A company runs a customer support platform. Customers raise support
> tickets ("cases"), agents work them, and leadership wants dashboards answering:
> *How long do cases take to resolve? Which regions generate the most cases? Which agents
> perform best? Are Urgent cases actually resolved faster than Low-priority ones?*
>
> We were handed **3 raw CSVs — 200 cases, 150 customers, 40 agents** — and asked to design
> and build the pipeline that makes that data trustworthy and query-ready.

---

## Architecture

```
CSV files  ─▶  RAW  ─▶  STAGING  ─▶  DIMENSIONS  ─▶  FACT TABLE  ─▶  BI / Analytics
              (land)   (parse +      (clean          (one analytics-
                        DQ flags)     lookups)         ready row/case)
```

| Layer | Single responsibility |
|-------|----------------------|
| **Raw** | Land the CSVs as-is. Everything `VARCHAR`. Never fail on load. |
| **Staging** | Parse types, normalise values, compute resolution time + all DQ flags. |
| **Dimensions** | Clean lookup tables — `dim_customer`, `dim_agent`, `dim_date` (SCD2-ready). |
| **Fact** | One analytics-ready row per case. No joins needed at query time. |

Each layer has one job and can evolve independently in production.

### Data model — star schema

```
              dim_date
                 │
  dim_customer ─ fact_cases ─ dim_agent
```

- **Grain:** one row per case — `case_id` is the primary key.
- **Why a star schema?** Single source system, read-heavy BI workload. Snowflake (columnar)
  and Power BI are both optimised for it. Data Vault only pays off at 10+ sources; 3NF is
  for OLTP write workloads.

See [`Data_Model.png`](Data_Model.png) for the full diagram.

---

## Repository structure

```
.
├── All_SQL/                      # The pipeline, in run order
│   ├── 01_CSV_to_RAW.sql         # Schemas, raw tables, file format, COPY INTO
│   ├── 02_Staging_Layer.sql      # Type parsing, normalisation, resolution time, DQ flags
│   ├── 03_Dim_layer.sql          # dim_customer, dim_agent, dim_date (SCD2 columns)
│   ├── 04_Analytics_layer.sql    # fact_cases MERGE + post-load validation checks
│   └── 05_Analytics_query.sql    # Business questions answered against the fact table
├── Data_Set/                     # Source data
│   ├── cases.csv                 # 200 rows
│   ├── customers.csv             # 150 rows
│   └── agents.csv                # 40 rows
├── Data_Model.png                # Star-schema diagram
├── Case_Study_Presentation_PPT.pptx
├── verify_metrics.py             # Reproduces every headline number from the CSVs
├── INTERVIEW_PREP.md             # Self-contained interview prep module (start here)
├── presentation_reference.md     # Original talking-points / speaker notes
└── README.md
```

> **Preparing for the interview?** Read [`INTERVIEW_PREP.md`](INTERVIEW_PREP.md) — it's a
> self-contained study guide: the elevator pitch, a walkthrough script, a bank of likely
> questions with strong answers, and the numbers to memorise.

---

## Source data

**`cases.csv`** (200 rows)

| Column | Type | Notes |
|--------|------|-------|
| `case_id` | String | Unique, e.g. `C0001` |
| `created_at` | String | ISO timestamp — needs parsing |
| `closed_at` | String | Empty for open cases — a key data-quality source |
| `customer_id` | String | FK → customers |
| `agent_id` | String | FK → agents |
| `category` | String | Technical / Account / Billing / Other |
| `priority` | String | Low / Medium / High / Urgent |
| `status` | String | Open / Closed / In Progress / On Hold |

**`customers.csv`** (150 rows) — `customer_id`, `customer_name`, `region` (APAC / LATAM /
Europe / North America), `signup_date`.

**`agents.csv`** (40 rows) — `agent_id`, `agent_name`, `team` (Billing / Tier 1 / Tier 2 /
Escalations).

---

## Data quality — profiled before writing any SQL

> *Profile the data before you design the pipeline. You never build on assumptions.*

| Issue | Rows | Decision |
|-------|-----:|----------|
| Closed status, but no `closed_at` | **9** | Flag. `resolution_hours = NULL`. Keep the row. |
| Open / On Hold / In Progress, but has a `closed_at` | **123** | Flag. **Status is the source of truth.** |
| Non-closed with `NULL closed_at` | 30 | Expected — no flag needed. |
| Orphan customer / agent (bad FK) | 0 | Check still runs every load. |

**Rule: flag dirty rows, never delete them.** Deleting hides the upstream bug; flagging
surfaces it. Every KPI query filters `has_any_dq_flag = FALSE`.

Of 200 cases, **132 carry at least one DQ flag** and **68 are clean** — of which **38** are
resolved (Closed with a valid `closed_at`) and feed the resolution-time KPIs. Every number
in this README is reproducible with [`verify_metrics.py`](verify_metrics.py).

### DQ flags carried through to the fact table

| Flag | Count | Catches |
|------|------:|---------|
| `dq_flag_closed_no_timestamp` | 9 | Closed status with no close time |
| `dq_flag_status_ts_mismatch` | 123 | Status and timestamp contradict each other |
| `dq_flag_invalid_created_at` | 0 | `created_at` couldn't be parsed |
| `dq_flag_orphan_customer` | 0 | `customer_id` not in `dim_customer` |
| `dq_flag_orphan_agent` | 0 | `agent_id` not in `dim_agent` |
| **`has_any_dq_flag`** | **132** | Summary flag — filter `FALSE` for all KPIs |

---

## Key design decisions

- **Surrogate keys** (`sk_customer`, `sk_agent`) instead of natural varchar keys — if source
  IDs get reused or changed, integer surrogates keep historical joins stable.
- **Denormalised `region` and `team`** into the fact table — zero joins for the most common
  BI queries. On a columnar warehouse, wide beats normalised-with-joins.
- **`LEFT JOIN` in the fact MERGE, not `INNER JOIN`** — an inner join silently drops orphan
  rows; a left join keeps them and lets the DQ flag surface them.
- **`MERGE` everywhere, not `INSERT`** — the pipeline is idempotent. Rerun it safely after
  any failure; no duplicates.
- **Fixed step order** — `stg_customers` → `stg_agents` → `stg_cases` (cases left-join to
  both, so it runs last).
- **`TRY_TO_TIMESTAMP_NTZ`** — a bad timestamp becomes `NULL`, never a pipeline crash.
- **`EMPTY_FIELD_AS_NULL = TRUE`** — without it, an empty `closed_at` loads as `''` not
  `NULL`, and every DQ check silently breaks.
- **SCD2 columns** (`valid_from` / `valid_to` / `is_current`) already on the dimensions —
  history-ready with no future DDL change.

---

## Key insights

| Finding | Value |
|---------|-------|
| Overall average resolution | **96.8 hours (~4 days)** — over 38 resolved clean cases |
| Fastest priority | High — **53.7 h** |
| Slowest priority | Low — **126.3 h** |
| ⚠️ Counterintuitive #1 | **Urgent (94.8 h) resolves slower than High (53.7 h)** → routing problem |
| ⚠️ Counterintuitive #2 | **Urgent has the *lowest* closure rate (14.6%)** of any priority |
| Best team | Tier 2 — **60.9 h** |
| Slowest team | Tier 1 — **147.6 h** (~2.4× slower → workload-design issue) |
| Highest volume region | LATAM — **62 cases** |
| Lowest closure rates | North America **18.4%**, LATAM **19.4%** |

The story isn't the averages — it's that **Urgent cases resolve *slower* than High and close
*least often***. That points at a triage/routing problem, not a capacity one. **Caveat:** only
38 resolved cases survive the DQ filter, so priority-level averages are directional, not
statistically significant — worth stating out loud in the interview.

---

## How to run (Snowflake)

1. Create a database (the scripts assume `DEMO_DB`) and upload the three CSVs to a stage
   named `@DEMO_DB.PUBLIC.CSV`.
2. Run the SQL files **in order**:

   | Step | File | Does |
   |------|------|------|
   | 1 | `All_SQL/01_CSV_to_RAW.sql` | Creates `raw` / `stg` / `dim` / `facts` schemas, raw tables, file format, and `COPY INTO` loads. |
   | 2 | `All_SQL/02_Staging_Layer.sql` | Parses types, normalises, computes `resolution_hours` and the five DQ flags. |
   | 3 | `All_SQL/03_Dim_layer.sql` | Builds `dim_customer`, `dim_agent`, and a 2020–2030 `dim_date`. |
   | 4 | `All_SQL/04_Analytics_layer.sql` | MERGEs `fact_cases` and runs post-load validation. |
   | 5 | `All_SQL/05_Analytics_query.sql` | The business-question queries. |

3. Point Power BI / Tableau at `FACTS.FACT_CASES`.

> **Note:** `04_Analytics_layer.sql` contains a `TRUNCATE` that is **commented out on
> purpose** — it was a testing leftover that, if run, would empty the fact table right after
> it's built (making every validation check return 0). Left in, commented, for transparency.

---

## Production & scale considerations

| Concern | Approach |
|---------|----------|
| Volume | Incremental `MERGE`; cluster the fact on `created_date_key`; Snowflake auto-scale. |
| Orchestration | Snowflake Tasks with the fixed step order; alert on the first failure. |
| Schema changes | Add columns as `NULLABLE` to RAW first; never drop without a deprecation window. |
| Monitoring | Track row counts, DQ-flag %, negative resolution hours, and orphan keys — alert *before* dashboards load. |
| History | SCD2 columns already present — turn on history tracking with no DDL change. |

---

## Tech stack

**Snowflake SQL** (MERGE, `TRY_TO_*`, `GENERATOR`/`SEQ4` date spine, window functions,
`QUALIFY`) · star-schema dimensional modelling · CSV → warehouse ingestion · BI-ready
output for Power BI / Tableau.

---

*Case study / interview exercise. Data is synthetic.*
