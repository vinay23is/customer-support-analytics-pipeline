"""Data-quality rule tests.

These lock the DQ-flag logic in ``verify_metrics.build()`` (the same rules as
``02_Staging_Layer.sql``) to the counts documented across the repo. If a source
change or a logic change moves a count, these fail loudly instead of letting the
docs drift.
"""


def test_closed_no_timestamp_flag(records):
    assert sum(r["f_closed_no_ts"] for r in records) == 9


def test_status_ts_mismatch_flag(records):
    assert sum(r["f_mismatch"] for r in records) == 123


def test_has_any_dq_flag_total(records):
    assert sum(r["has_any_dq_flag"] for r in records) == 132


def test_clean_row_count(records):
    clean = [r for r in records if not r["has_any_dq_flag"]]
    assert len(clean) == 68


def test_clean_resolved_count(records):
    """The 38 clean + resolved rows are the population behind every resolution KPI."""
    clean_resolved = [
        r for r in records
        if not r["has_any_dq_flag"] and r["resolution_hours"] is not None
    ]
    assert len(clean_resolved) == 38


def test_no_negative_resolution_hours(records):
    """resolution_hours is only computed when closed_at > created_at, so it is
    never negative. Mirrors post-load check 3 in 04_Analytics_layer.sql."""
    negatives = [r for r in records if (r["resolution_hours"] or 0) < 0]
    assert not negatives


def test_resolution_only_on_closed(records):
    """A non-null resolution_hours implies the case is Closed."""
    for r in records:
        if r["resolution_hours"] is not None:
            assert r["is_resolved"], "resolution_hours set on a non-Closed case"


def test_flagged_rows_are_kept_not_dropped(records):
    """Flag-don't-delete: all 200 rows survive, flagged or not."""
    assert len(records) == 200
