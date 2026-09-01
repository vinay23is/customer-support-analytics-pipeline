#!/usr/bin/env python3
"""
verify_metrics.py — reproduce every headline number in this repo straight from the CSVs.

This mirrors the SQL pipeline's logic in plain Python so any figure quoted in the
README / interview prep can be independently checked:

    python3 verify_metrics.py

Data-quality rules (same as 02_Staging_Layer.sql):
  - dq_flag_closed_no_timestamp : status = 'Closed' AND closed_at is empty
  - dq_flag_status_ts_mismatch  : status in (Open, On Hold, In Progress) AND closed_at is present
  - dq_flag_invalid_created_at  : created_at cannot be parsed
  - dq_flag_orphan_customer     : customer_id not in customers.csv
  - dq_flag_orphan_agent        : agent_id not in agents.csv
  - has_any_dq_flag             : OR of the above

resolution_hours is computed only for Closed cases with valid created_at < closed_at.
KPIs are reported on clean rows (has_any_dq_flag = FALSE), matching the SQL.
"""
import csv
import os
from datetime import datetime
from statistics import mean, median
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "Data_Set")


def load(name):
    with open(os.path.join(DATA, name)) as f:
        return list(csv.DictReader(f))


def empty(v):
    return v is None or v.strip() == ""


def parse_ts(v):
    try:
        return datetime.fromisoformat(v.strip())
    except (ValueError, AttributeError):
        return None


def build():
    cases = load("cases.csv")
    customers = {c["customer_id"]: c for c in load("customers.csv")}
    agents = {a["agent_id"]: a for a in load("agents.csv")}

    recs = []
    for r in cases:
        status = r["status"].strip()
        created = parse_ts(r["created_at"])
        closed = parse_ts(r["closed_at"])

        f_closed_no_ts = status == "Closed" and empty(r["closed_at"])
        f_mismatch = status in ("Open", "On Hold", "In Progress") and not empty(r["closed_at"])
        f_bad_created = created is None
        f_orphan_customer = r["customer_id"] not in customers
        f_orphan_agent = r["agent_id"] not in agents
        has_any = any([f_closed_no_ts, f_mismatch, f_bad_created,
                       f_orphan_customer, f_orphan_agent])

        resolution_hours = None
        if status == "Closed" and created and closed and closed > created:
            resolution_hours = (closed - created).total_seconds() / 3600

        recs.append({
            "priority": r["priority"].strip(),
            "category": r["category"].strip(),
            "status": status,
            "region": customers.get(r["customer_id"], {}).get("region", "UNKNOWN").strip(),
            "team": agents.get(r["agent_id"], {}).get("team", "UNKNOWN").strip(),
            "resolution_hours": resolution_hours,
            "is_resolved": status == "Closed",
            "has_any_dq_flag": has_any,
            "f_closed_no_ts": f_closed_no_ts,
            "f_mismatch": f_mismatch,
        })
    return recs, len(customers), len(agents)


def avg(values):
    vals = [v for v in values if v is not None]
    return round(mean(vals), 1) if vals else None


def main():
    recs, n_customers, n_agents = build()
    n = len(recs)
    clean = [r for r in recs if not r["has_any_dq_flag"]]

    print(f"Row counts        : cases={n}  customers={n_customers}  agents={n_agents}")
    print()
    print("Data quality")
    print(f"  closed_no_timestamp : {sum(r['f_closed_no_ts'] for r in recs)}")
    print(f"  status_ts_mismatch  : {sum(r['f_mismatch'] for r in recs)}")
    print(f"  has_any_dq_flag     : {sum(r['has_any_dq_flag'] for r in recs)}")
    print(f"  clean rows          : {len(clean)}")
    print()

    resolved = [r["resolution_hours"] for r in clean if r["resolution_hours"] is not None]
    print(f"Overall avg resolution: {round(mean(resolved), 1)} h "
          f"(~{round(mean(resolved) / 24, 2)} days) over {len(resolved)} resolved clean cases")
    print()

    print("Avg resolution by priority (clean, resolved)")
    for p in ("Low", "Medium", "High", "Urgent"):
        vals = [r["resolution_hours"] for r in clean
                if r["priority"] == p and r["resolution_hours"] is not None]
        print(f"  {p:8} {avg(vals):>7} h   (n={len(vals)})")
    print()

    print("Avg resolution by team (clean, resolved)")
    for t in sorted({r["team"] for r in clean}):
        vals = [r["resolution_hours"] for r in clean
                if r["team"] == t and r["resolution_hours"] is not None]
        print(f"  {t:12} {avg(vals):>7} h   (n={len(vals)})")
    print()

    print("Volume & closure by region (all cases)")
    for rg in sorted({r["region"] for r in recs}):
        grp = [r for r in recs if r["region"] == rg]
        closed = sum(r["is_resolved"] for r in grp)
        print(f"  {rg:14} cases={len(grp):>3}  closure={round(closed * 100 / len(grp), 1)}%")
    print()

    print("Closure rate by priority (all cases)")
    for p in ("Low", "Medium", "High", "Urgent"):
        grp = [r for r in recs if r["priority"] == p]
        closed = sum(r["is_resolved"] for r in grp)
        print(f"  {p:8} cases={len(grp):>3}  closure={round(closed * 100 / len(grp), 1)}%")


if __name__ == "__main__":
    main()
