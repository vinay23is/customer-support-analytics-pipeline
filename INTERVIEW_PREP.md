# Interview Prep Module

> A self-contained study guide for this case study. Read it top-to-bottom the day before
> your interview and you should be ready to walk through the project, defend every design
> decision, and quote the numbers cold. Everything here is reproducible with
> [`verify_metrics.py`](verify_metrics.py).

**Contents**
1. [The 30-second pitch](#1-the-30-second-pitch)
2. [The 2-minute walkthrough (say this out loud)](#2-the-2-minute-walkthrough-say-this-out-loud)
3. [Numbers to memorise](#3-numbers-to-memorise)
4. [The star schema, explained simply](#4-the-star-schema-explained-simply)
5. [Design decisions & how to defend them](#5-design-decisions--how-to-defend-them)
6. [Data quality — the philosophy](#6-data-quality--the-philosophy)
7. [The insight that makes you look senior](#7-the-insight-that-makes-you-look-senior)
8. [Question bank (with answers)](#8-question-bank-with-answers)
9. [Snowflake / SQL concepts they may probe](#9-snowflake--sql-concepts-they-may-probe)
10. [Whiteboard cheat sheet](#10-whiteboard-cheat-sheet)
11. [Honest weaknesses (say these before they do)](#11-honest-weaknesses-say-these-before-they-do)

---

## 1. The 30-second pitch

> "I was given three raw CSVs — 200 support cases, 150 customers, 40 agents — and asked to
> make them analytics-ready. I built a four-layer pipeline on Snowflake — **Raw → Staging →
> Dimensions → Fact** — landing in a **star schema** with `fact_cases` at the centre. The key
> theme is **data quality**: I profiled the files first, found that the `status` and
> `closed_at` columns contradict each other on 132 of 200 rows, and chose to **flag those
> rows, not delete them**, so every KPI runs on trustworthy data while the pipeline stays
> transparent about what it doesn't trust. The output answers every question in the brief —
> resolution time, volume, agent and regional performance — with **no joins at query time**."

---

## 2. The 2-minute walkthrough (say this out loud)

Practice this until it's natural. It's the spine of the whole interview.

1. **The brief.** "A support platform. Customers raise cases, agents resolve them, leadership
   wants dashboards. Three CSVs, and I own the pipeline from raw file to BI-ready table."

2. **Profile first.** "Before writing any SQL I profiled all three files. That's
   non-negotiable — you never design a pipeline on assumptions. That's where I found the data
   quality problems that shaped everything downstream."

3. **The four layers.**
   - *Raw* — "Land the CSVs exactly as they are, every column a `VARCHAR`. The raw layer's
     only job is to never fail on load, so a bad value never blocks ingestion."
   - *Staging* — "This is where the real work happens: parse timestamps with `TRY_TO_*` so a
     bad value becomes `NULL` instead of crashing, normalise text, compute `resolution_hours`,
     and raise the five data-quality flags."
   - *Dimensions* — "Clean lookup tables — customer, agent, and a generated date dimension —
     each with SCD2 columns so they're history-ready in production."
   - *Fact* — "One row per case. Surrogate keys to the dimensions, plus `region` and `team`
     denormalised in so the common BI queries need zero joins."

4. **Data quality decision.** "132 of 200 rows had a status/timestamp contradiction or a
   closed case with no close time. I flagged every one and kept it — deleting hides the
   upstream bug, flagging surfaces it. KPIs just filter `has_any_dq_flag = FALSE`."

5. **The payoff.** "The fact table answers every question in the brief with no query-time
   joins, and it surfaced a real finding: Urgent cases resolve *slower* than High and close
   *least* often — a routing problem, not a capacity one."

---

## 3. Numbers to memorise

| Metric | Value |
|--------|-------|
| Cases / Customers / Agents | **200 / 150 / 40** |
| Rows with a DQ flag | **132** (of 200) |
| Clean rows | **68** — of which **38** are resolved (feed the KPIs) |
| `closed_no_timestamp` flag | **9** |
| `status_ts_mismatch` flag | **123** |
| Overall avg resolution | **96.8 h (~4 days)** |
| Priority — fastest → slowest | High **53.7** · Urgent **94.8** · Medium **113.5** · Low **126.3** (hours) |
| Team — best vs worst | Tier 2 **60.9 h** vs Tier 1 **147.6 h** (~2.4×) |
| Region volume (highest) | LATAM **62 cases** |
| Closure rate by priority (lowest) | **Urgent 14.6%** |

> ⚠️ Every number here comes from `verify_metrics.py` run against the CSVs in this repo, and
> the README and `presentation_reference.md` now match it. An earlier draft of the deck had a
> few wrong figures (status-mismatch as 76, Tier 1 as 130.1 h); I re-derived everything from
> the source and corrected them. If asked, that's a strong answer: *"I re-derived every figure
> from the raw data and shipped the script, so the numbers are reproducible."*

---

## 4. The star schema, explained simply

```
                 ┌─────────────┐
                 │  dim_date   │
                 └──────┬──────┘
                        │
┌──────────────┐  ┌─────┴───────┐  ┌────────────┐
│ dim_customer ├──┤ fact_cases  ├──┤ dim_agent  │
└──────────────┘  └─────────────┘  └────────────┘
   sk_customer      one row/case      sk_agent
   region, name     PK = case_id      name, team
   SCD2 cols        measures + FKs     SCD2 cols
                    + all DQ flags
```

- **Fact = events/measurements.** Here, one support case. Holds the numbers you aggregate
  (`resolution_hours`) and foreign keys to the dimensions.
- **Dimensions = the descriptive context** you slice by: *who* (customer, agent), *when*
  (date).
- **Grain** — the single most important word in dimensional modelling. It's "what does one
  row mean?" Here: **one row = one case.** Get grain wrong and every aggregate is wrong.

---

## 5. Design decisions & how to defend them

Each of these is a likely "why did you…?" question. Lead with the decision, then the reason,
then the alternative you rejected.

| Decision | Why | Alternative rejected |
|----------|-----|---------------------|
| **Star schema** | Single source, read-heavy BI. Snowflake (columnar) + Power BI are built for it. | *Data Vault* — only pays off at 10+ sources. *3NF* — for OLTP writes, forces joins on reads. |
| **Surrogate keys** (`sk_customer`, `sk_agent`) | Integer keys stay stable if a source ID is reused or changed; history never breaks. | Natural varchar keys — brittle, and slower to join. |
| **Denormalise `region` + `team` into the fact** | The most common queries ("cases by region") then need **zero joins**; wide tables win on columnar stores. | Keep them only in dims — forces a join on every dashboard query. |
| **`LEFT JOIN` in the fact MERGE** | Keeps orphan cases and lets the DQ flag surface them. | `INNER JOIN` — silently *drops* orphans; you'd never know the case existed. |
| **`MERGE`, not `INSERT`** | Idempotent — rerun safely after any failure, no duplicates. | `INSERT` — reruns double-load the data. |
| **Fixed step order** (customers → agents → cases) | `stg_cases` left-joins to both to detect orphans, so they must exist first. | Arbitrary order — orphan checks would misfire. |
| **`TRY_TO_TIMESTAMP_NTZ`** | A bad timestamp becomes `NULL`, not a crash. | `TO_TIMESTAMP` — one bad row fails the whole load. |
| **`EMPTY_FIELD_AS_NULL = TRUE`** | Empty `closed_at` loads as `NULL`, so `IS NULL` checks work. | Default — empty loads as `''` and every DQ check silently breaks. |
| **SCD2 columns on dims** (`valid_from`/`valid_to`/`is_current`) | History-ready with no future DDL change. | Add later — a migration on a live table. |
| **Flag, don't delete** dirty rows | Transparency; the pipeline shows what it doesn't trust. | Delete — hides the upstream bug. |

---

## 6. Data quality — the philosophy

The one-liner to have ready: **"Flag dirty rows, never delete them; filter them at query
time."**

The five flags, and what each catches:

| Flag | Rule | Count |
|------|------|------:|
| `dq_flag_closed_no_timestamp` | `status = 'Closed'` but `closed_at` is empty | 9 |
| `dq_flag_status_ts_mismatch` | non-closed status but `closed_at` is present | 123 |
| `dq_flag_invalid_created_at` | `created_at` couldn't be parsed | 0 |
| `dq_flag_orphan_customer` | `customer_id` not in `dim_customer` | 0 |
| `dq_flag_orphan_agent` | `agent_id` not in `dim_agent` | 0 |
| `has_any_dq_flag` | OR of all five — the KPI filter | 132 |

**Why status is the source of truth** (when status and `closed_at` disagree): status is what
an agent actively sets; a stray `closed_at` is more likely a system/export artefact. So a case
marked `Open` with a `closed_at` is treated as genuinely open, and flagged.

**Why the orphan checks still run even though they're zero:** the check is the deliverable,
not the current count. In production the count won't stay zero, and the LEFT JOIN + flag is
what catches it the day it changes.

---

## 7. The insight that makes you look senior

Don't just report averages — read them.

- **Urgent resolves slower than High (94.8 h vs 53.7 h)** and **Urgent has the lowest closure
  rate of any priority (14.6%)**.
- Naively, Urgent should be *fastest*. It's the slowest-to-resolve and least-likely-to-close.
- **Interpretation:** this is a **triage / routing problem, not a capacity problem.** Urgent
  cases are probably being mis-routed or bottlenecked (e.g. everything escalates and queues),
  not simply under-staffed. The fix is process, not headcount.
- **Team angle reinforces it:** Tier 1 is ~2.4× slower than Tier 2 (147.6 h vs 60.9 h) —
  a workload-distribution/skill-routing issue, again about *design* not *effort*.

Then show maturity by **caveating your own finding**: "This is 38 resolved cases after the DQ
filter, so I'd treat priority-level averages as directional and validate on a larger window
before making a staffing decision." Interviewers love a candidate who knows the limits of
their own numbers.

---

## 8. Question bank (with answers)

**Q: Walk me through your pipeline.**
→ Use the [2-minute walkthrough](#2-the-2-minute-walkthrough-say-this-out-loud).

**Q: Why a star schema and not [Data Vault / 3NF / one big table]?**
→ Single source system, read-heavy BI workload, columnar warehouse. Star is the sweet spot.
Data Vault's auditing/multi-source strengths don't pay for their complexity at one source.
3NF optimises writes and forces joins on every read. One-big-table works but loses the clean
dimension reuse and the SCD2 history story.

**Q: What's the grain of your fact table?**
→ One row per case; `case_id` is the primary key. Everything else hangs off that.

**Q: You have 132 bad rows out of 200. Why not just clean or drop them?**
→ Dropping hides an upstream bug and makes counts silently wrong. Flagging keeps the row,
keeps counts honest, and makes the problem visible to whoever owns the source system. KPIs
filter `has_any_dq_flag = FALSE`, so the flagged rows never pollute a metric — but they're
still there to investigate.

**Q: A case is `Open` but has a `closed_at`. Which do you believe?**
→ Status. It's the field an agent actively sets; a stray timestamp is more likely an export
artefact. I flag the row and treat it as open.

**Q: How is this pipeline idempotent?**
→ Every load is a `MERGE`, not an `INSERT`. If a step fails halfway and I rerun the whole
thing, matched rows update in place and unmatched rows insert — no duplicates, no double
counting. I can safely rerun after any failure.

**Q: How would you schedule / orchestrate this in production?**
→ Snowflake Tasks in the fixed dependency order (customers → agents → cases → dims → fact),
with an alert on the first failure. For heavier needs I'd lift it into Airflow or dbt, where
each layer becomes a model with tests between them.

**Q: How does this scale to millions of rows?**
→ Incremental `MERGE` on new/changed rows only; cluster the fact on `created_date_key` so date
-ranged dashboard queries prune partitions; let Snowflake auto-scale the warehouse. The star
schema itself doesn't change.

**Q: What happens when the source schema changes — a new column, a renamed field?**
→ Add new columns to RAW as `NULLABLE` first so loads keep working; propagate up the layers
deliberately. Never drop a column without a deprecation window, because a dashboard may depend
on it.

**Q: How would you monitor this in production?**
→ Track row counts per load, DQ-flag percentage over time, any negative resolution hours, and
orphan-key counts — and alert *before* the dashboards refresh, so bad data never reaches
leadership. A spike in the mismatch flag is an early warning that something changed upstream.

**Q: Why the date dimension when you already have timestamps?**
→ A `dim_date` gives BI tools clean, consistent calendar attributes (quarter labels, weekday
flags, fiscal logic) without recomputing date maths in every query, and it makes time-based
slicing uniform across every fact that joins to it.

**Q: How would you handle a customer changing region over time?**
→ That's exactly why the dimensions have SCD2 columns. I'd expire the old row
(`valid_to = today-1`, `is_current = FALSE`) and insert a new current row. The fact keeps its
surrogate key, so a case stays attached to the region that was true when it happened.

**Q: If you had more time, what would you add?**
→ dbt for tests + lineage + docs, a handful of assertion tests between layers, a true incremental
strategy keyed on an updated-at watermark, and a small semantic layer so metric definitions
live in one place.

---

## 9. Snowflake / SQL concepts they may probe

- **`MERGE`** — upsert: `WHEN MATCHED THEN UPDATE`, `WHEN NOT MATCHED THEN INSERT`. The basis
  of idempotency here.
- **`TRY_TO_TIMESTAMP_NTZ` / `TRY_TO_DATE`** — "try-cast": returns `NULL` on a bad value
  instead of erroring. `NTZ` = no time zone.
- **`COPY INTO` + file format** — Snowflake's bulk CSV loader; `ON_ERROR = 'CONTINUE'` skips
  bad rows rather than failing the load.
- **`GENERATOR` + `SEQ4()`** — generate rows out of nothing; used to build the date spine
  (`DATEADD(DAY, SEQ4(), '2020-01-01')`).
- **`QUALIFY`** — filter on a window function's result without a subquery (used for
  "top 3 agents per team" via `RANK() OVER (PARTITION BY team …)`).
- **`IS DISTINCT FROM`** — null-safe inequality; used in the fact MERGE so an update only
  fires when a value genuinely changed (keeps `_updated_at` meaningful).
- **Surrogate vs natural key** — surrogate = system-generated integer (`AUTOINCREMENT`);
  natural = the business ID (`CU001`). Facts join on surrogates for stability.
- **SCD Type 2** — keep history by versioning dimension rows with
  `valid_from`/`valid_to`/`is_current` rather than overwriting.
- **Role-playing dimension** — `dim_date` is joined to the fact **twice**, once via
  `created_date_key` and once via `closed_date_key`. One physical dimension, two roles
  ("created date" vs "closed date"). If asked, that's the term for it, and it's why the ERD
  shows two links into `dim_date`.

---

## 10. Whiteboard cheat sheet

If handed a marker, draw this and talk to it:

```
CSV ──COPY INTO──▶ RAW (all VARCHAR) ──▶ STAGING ──▶ DIMS ──▶ FACT ──▶ BI
                    never fail          parse+flag   clean     1 row/    no joins
                                        resolution   +SCD2     case      at query
                                        +DQ flags

                          dim_date
                              │
            dim_customer ─ fact_cases ─ dim_agent
                        (grain: 1 case)
```

Three sentences to say while drawing: **"Raw never fails. Staging does the thinking. The fact
is what the business queries — one row per case, no joins."**

---

## 11. Honest weaknesses (say these before they do)

Naming the limits yourself reads as senior; being caught out by them reads as junior.

- **Small sample.** 200 cases, 38 resolved after the DQ filter. Priority/team averages are
  directional, not significant. I'd want a larger window before acting on them.
- **No automated tests.** The validation checks in `04_Analytics_layer.sql` are manual
  `SELECT`s. In production they'd be dbt tests (or Snowflake tasks) that fail the build.
- **Static, single source.** No CDC / incremental watermark yet — I load the full set. The
  `MERGE` makes that safe to rerun, but a real incremental strategy would key off an
  updated-at column.
- **The numbers are only as good as one dataset snapshot.** Every figure is reproducible via
  `verify_metrics.py`, and all the docs now agree — but they describe this 200-row static
  extract, not a production trend. I'd re-validate on a live, larger window before acting.

---

*Good luck. Read section 2 out loud three times — that's the one that carries the interview.*
