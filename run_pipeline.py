#!/usr/bin/env python3
"""
run_pipeline.py — orchestrate the Snowflake pipeline end to end.

The README describes the pipeline as five SQL files run "in order". This script is
that orchestration in code: it runs the layers in their fixed dependency order
(RAW -> STAGING -> DIMENSIONS -> FACT -> REPORTING), times every step, captures row
counts, streams structured logs, and writes a JSON run manifest for observability.
It is deliberately dependency-light — a single connector — rather than pulling in a
full scheduler, which would be overkill at this scope (Airflow/dbt are the noted
next step for production).

Two modes:

  # No credentials needed — validate the plan, parse every statement, print the DAG.
  python3 run_pipeline.py --dry-run

  # Execute against Snowflake (reads connection from environment variables).
  export SNOWFLAKE_ACCOUNT=... SNOWFLAKE_USER=... SNOWFLAKE_PASSWORD=...
  export SNOWFLAKE_WAREHOUSE=... SNOWFLAKE_DATABASE=DEMO_DB
  python3 run_pipeline.py

Idempotency note: every step is rerun-safe (MERGE / expire-and-insert / CREATE OR
REPLACE / COPY INTO), so a failed run can simply be re-executed from the top.
"""
import argparse
import glob
import json
import logging
import os
import re
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SQL_DIR = os.path.join(HERE, "All_SQL")
LOG_DIR = os.path.join(HERE, "logs")

# Fixed dependency order. The numeric filename prefixes encode it; we resolve them
# explicitly so a stray file can never reorder the run.
PIPELINE_STEPS = [
    ("01_CSV_to_RAW.sql",       "RAW"),
    ("02_Staging_Layer.sql",    "STAGING"),
    ("03_Dim_layer.sql",        "DIMENSIONS"),
    ("04_Analytics_layer.sql",  "FACT"),
    ("06_Reporting_Views.sql",  "REPORTING"),
]

# Tables whose row counts are worth recording after a run (observability).
ROWCOUNT_TARGETS = [
    "raw.cases", "raw.customers", "raw.agents",
    "stg.stg_cases",
    "dim.dim_customer", "dim.dim_agent", "dim.dim_date",
    "facts.fact_cases",
]

log = logging.getLogger("pipeline")


def setup_logging(verbose=False):
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s  %(levelname)-7s  %(message)s",
        datefmt="%H:%M:%S",
    )


def split_statements(sql_text):
    """Split a SQL script into individual statements.

    Strips ``--`` line comments and respects single-quoted string literals so a
    semicolon inside a string never splits a statement. Sufficient for the SQL in
    this repo (no dollar-quoting or stored-proc bodies)."""
    statements, buf, in_string = [], [], False
    for raw_line in sql_text.splitlines():
        line = raw_line
        if not in_string:
            line = re.sub(r"--.*$", "", line)  # drop line comments outside strings
        i = 0
        while i < len(line):
            ch = line[i]
            if ch == "'":
                in_string = not in_string
                buf.append(ch)
            elif ch == ";" and not in_string:
                stmt = "".join(buf).strip()
                if stmt:
                    statements.append(stmt)
                buf = []
            else:
                buf.append(ch)
            i += 1
        buf.append("\n")
    tail = "".join(buf).strip()
    if tail:
        statements.append(tail)
    return statements


def resolve_steps():
    """Return [(path, layer, [statements])], erroring if a required file is missing."""
    steps = []
    for filename, layer in PIPELINE_STEPS:
        path = os.path.join(SQL_DIR, filename)
        if not os.path.exists(path):
            raise FileNotFoundError(f"pipeline step missing: {path}")
        with open(path) as f:
            statements = split_statements(f.read())
        steps.append((path, layer, statements))
    return steps


def connect():
    """Open a Snowflake connection from environment variables (imported lazily so
    --dry-run needs neither the package nor credentials)."""
    try:
        import snowflake.connector  # noqa: WPS433 (lazy import is intentional)
    except ImportError:
        log.error("snowflake-connector-python not installed. "
                  "Run `pip install -r requirements.txt`, or use --dry-run.")
        sys.exit(2)

    required = ["SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER", "SNOWFLAKE_PASSWORD"]
    missing = [v for v in required if not os.environ.get(v)]
    if missing:
        log.error("missing environment variables: %s", ", ".join(missing))
        sys.exit(2)

    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE"),
        database=os.environ.get("SNOWFLAKE_DATABASE", "DEMO_DB"),
        role=os.environ.get("SNOWFLAKE_ROLE"),
    )


def capture_rowcounts(cursor):
    counts = {}
    for tbl in ROWCOUNT_TARGETS:
        try:
            cursor.execute(f"SELECT COUNT(*) FROM {tbl}")
            counts[tbl] = cursor.fetchone()[0]
        except Exception as exc:  # a table may not exist yet on a partial run
            counts[tbl] = f"ERROR: {exc}"
    return counts


def run(dry_run=False, verbose=False):
    setup_logging(verbose)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    manifest = {
        "run_id": run_id,
        "mode": "dry-run" if dry_run else "execute",
        "started_at": datetime.now(timezone.utc).isoformat(),
        "database": os.environ.get("SNOWFLAKE_DATABASE", "DEMO_DB"),
        "warehouse": os.environ.get("SNOWFLAKE_WAREHOUSE"),
        "steps": [],
        "status": "success",
    }

    steps = resolve_steps()
    total_statements = sum(len(s[2]) for s in steps)
    log.info("run %s | mode=%s | %d steps | %d statements",
             run_id, manifest["mode"], len(steps), total_statements)

    conn = cursor = None
    if not dry_run:
        conn = connect()
        cursor = conn.cursor()

    pipeline_start = time.perf_counter()
    try:
        for idx, (path, layer, statements) in enumerate(steps, start=1):
            name = os.path.basename(path)
            step = {"step": idx, "layer": layer, "file": name,
                    "statements": len(statements), "status": "success"}
            log.info("[%d/%d] %-11s %-24s (%d statements)",
                     idx, len(steps), layer, name, len(statements))
            t0 = time.perf_counter()

            if dry_run:
                for n, stmt in enumerate(statements, start=1):
                    log.debug("    stmt %02d: %s", n, stmt.split("\n", 1)[0][:80])
            else:
                for n, stmt in enumerate(statements, start=1):
                    try:
                        cursor.execute(stmt)
                    except Exception as exc:
                        step["status"] = "failed"
                        step["failed_statement"] = n
                        step["error"] = str(exc)
                        manifest["status"] = "failed"
                        log.error("    stmt %02d FAILED: %s", n, exc)
                        raise

            step["duration_s"] = round(time.perf_counter() - t0, 3)
            manifest["steps"].append(step)
            log.info("        done in %.3fs", step["duration_s"])

        if not dry_run:
            manifest["row_counts"] = capture_rowcounts(cursor)
            log.info("row counts: %s", json.dumps(manifest["row_counts"]))

    except Exception:
        manifest["status"] = "failed"
    finally:
        if cursor:
            cursor.close()
        if conn:
            conn.close()

    manifest["duration_s"] = round(time.perf_counter() - pipeline_start, 3)
    manifest["finished_at"] = datetime.now(timezone.utc).isoformat()

    os.makedirs(LOG_DIR, exist_ok=True)
    manifest_path = os.path.join(LOG_DIR, f"run_{run_id}.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
    log.info("manifest written: %s", os.path.relpath(manifest_path, HERE))
    log.info("pipeline %s in %.3fs", manifest["status"].upper(), manifest["duration_s"])

    return 0 if manifest["status"] == "success" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true",
                        help="validate + parse the plan without a Snowflake connection")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="log every statement")
    args = parser.parse_args()
    sys.exit(run(dry_run=args.dry_run, verbose=args.verbose))


if __name__ == "__main__":
    main()
