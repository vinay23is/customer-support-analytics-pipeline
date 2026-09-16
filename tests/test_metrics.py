"""Headline-metric regression tests.

Every number quoted in the README, INTERVIEW_PREP.md and the deck is pinned here.
The project's whole premise is "reproducible numbers"; these tests are what make
that claim enforceable rather than aspirational. Values are recomputed from the
staged records and compared to the documented figures (rounded to 1 dp).
"""
from statistics import mean

import pytest


def _clean_resolved(records):
    return [
        r for r in records
        if not r["has_any_dq_flag"] and r["resolution_hours"] is not None
    ]


def _avg_resolution(records, key, value):
    vals = [
        r["resolution_hours"] for r in _clean_resolved(records)
        if r[key] == value
    ]
    return round(mean(vals), 1) if vals else None


def _closure_rate(records, key, value):
    grp = [r for r in records if r[key] == value]
    closed = sum(r["is_resolved"] for r in grp)
    return len(grp), round(closed * 100 / len(grp), 1)


# --- overall ---------------------------------------------------------------

def test_overall_avg_resolution(records):
    vals = [r["resolution_hours"] for r in _clean_resolved(records)]
    assert round(mean(vals), 1) == 96.8
    assert len(vals) == 38


# --- by priority (resolution time) -----------------------------------------

@pytest.mark.parametrize("priority,expected", [
    ("Low", 126.3),
    ("Medium", 113.5),
    ("High", 53.7),
    ("Urgent", 94.8),
])
def test_avg_resolution_by_priority(records, priority, expected):
    assert _avg_resolution(records, "priority", priority) == expected


def test_high_resolves_faster_than_urgent(records):
    """The headline counterintuitive finding: Urgent is slower than High."""
    high = _avg_resolution(records, "priority", "High")
    urgent = _avg_resolution(records, "priority", "Urgent")
    assert urgent > high


# --- by team (resolution time) ---------------------------------------------

@pytest.mark.parametrize("team,expected", [
    ("Billing", 107.5),
    ("Escalations", 121.8),
    ("Tier 1", 147.6),
    ("Tier 2", 60.9),
])
def test_avg_resolution_by_team(records, team, expected):
    assert _avg_resolution(records, "team", team) == expected


def test_tier2_is_fastest_team(records):
    teams = {"Billing", "Escalations", "Tier 1", "Tier 2"}
    by_team = {t: _avg_resolution(records, "team", t) for t in teams}
    assert min(by_team, key=by_team.get) == "Tier 2"
    assert max(by_team, key=by_team.get) == "Tier 1"


# --- volume + closure (all cases) ------------------------------------------

@pytest.mark.parametrize("region,vol,closure", [
    ("APAC", 42, 31.0),
    ("Europe", 47, 27.7),
    ("LATAM", 62, 19.4),
    ("North America", 49, 18.4),
])
def test_region_volume_and_closure(records, region, vol, closure):
    n, rate = _closure_rate(records, "region", region)
    assert n == vol
    assert rate == closure


def test_latam_is_highest_volume_region(records):
    regions = {"APAC", "Europe", "LATAM", "North America"}
    vols = {rg: _closure_rate(records, "region", rg)[0] for rg in regions}
    assert max(vols, key=vols.get) == "LATAM"


@pytest.mark.parametrize("priority,closure", [
    ("Low", 23.8),
    ("Medium", 30.5),
    ("High", 23.5),
    ("Urgent", 14.6),
])
def test_closure_rate_by_priority(records, priority, closure):
    assert _closure_rate(records, "priority", priority)[1] == closure


def test_urgent_has_lowest_closure_rate(records):
    priorities = {"Low", "Medium", "High", "Urgent"}
    rates = {p: _closure_rate(records, "priority", p)[1] for p in priorities}
    assert min(rates, key=rates.get) == "Urgent"
