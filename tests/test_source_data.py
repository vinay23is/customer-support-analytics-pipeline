"""Source-data contracts.

These are the pytest equivalents of dbt schema tests (``unique``, ``not_null``,
``accepted_values``, ``relationships``). They assert the guarantees the pipeline
relies on, straight against the source CSVs, so a bad extract fails the build
before it ever reaches Snowflake.
"""

EXPECTED_ROWS = {"cases": 200, "customers": 150, "agents": 40}

VALID_PRIORITIES = {"Low", "Medium", "High", "Urgent"}
VALID_STATUSES = {"Open", "Closed", "In Progress", "On Hold"}
VALID_CATEGORIES = {"Technical", "Account", "Billing", "Other"}
VALID_REGIONS = {"APAC", "LATAM", "Europe", "North America"}
VALID_TEAMS = {"Billing", "Tier 1", "Tier 2", "Escalations"}


# --- row counts -------------------------------------------------------------

def test_row_counts(cases, customers, agents):
    assert len(cases) == EXPECTED_ROWS["cases"]
    assert len(customers) == EXPECTED_ROWS["customers"]
    assert len(agents) == EXPECTED_ROWS["agents"]


# --- uniqueness (primary keys) ---------------------------------------------

def test_case_id_is_unique(cases):
    ids = [r["case_id"] for r in cases]
    assert len(ids) == len(set(ids)), "duplicate case_id in cases.csv"


def test_customer_id_is_unique(customers):
    ids = [r["customer_id"] for r in customers]
    assert len(ids) == len(set(ids)), "duplicate customer_id in customers.csv"


def test_agent_id_is_unique(agents):
    ids = [r["agent_id"] for r in agents]
    assert len(ids) == len(set(ids)), "duplicate agent_id in agents.csv"


# --- not null (keys that the model treats as NOT NULL) ---------------------

def test_business_keys_not_null(cases, customers, agents):
    assert all(r["case_id"].strip() for r in cases)
    assert all(r["customer_id"].strip() for r in customers)
    assert all(r["agent_id"].strip() for r in agents)


# --- accepted values (enum columns) ----------------------------------------

def test_priority_accepted_values(cases):
    bad = {r["priority"] for r in cases} - VALID_PRIORITIES
    assert not bad, f"unexpected priority values: {bad}"


def test_status_accepted_values(cases):
    bad = {r["status"] for r in cases} - VALID_STATUSES
    assert not bad, f"unexpected status values: {bad}"


def test_category_accepted_values(cases):
    bad = {r["category"] for r in cases} - VALID_CATEGORIES
    assert not bad, f"unexpected category values: {bad}"


def test_region_accepted_values(customers):
    bad = {r["region"] for r in customers} - VALID_REGIONS
    assert not bad, f"unexpected region values: {bad}"


def test_team_accepted_values(agents):
    bad = {r["team"] for r in agents} - VALID_TEAMS
    assert not bad, f"unexpected team values: {bad}"


# --- relationships (referential integrity) ---------------------------------

def test_every_case_customer_resolves(cases, customers):
    """No orphan customer FKs. Mirrors dq_flag_orphan_customer (expected 0)."""
    valid = {c["customer_id"] for c in customers}
    orphans = [r["case_id"] for r in cases if r["customer_id"] not in valid]
    assert not orphans, f"orphan customer_id on cases: {orphans}"


def test_every_case_agent_resolves(cases, agents):
    """No orphan agent FKs. Mirrors dq_flag_orphan_agent (expected 0)."""
    valid = {a["agent_id"] for a in agents}
    orphans = [r["case_id"] for r in cases if r["agent_id"] not in valid]
    assert not orphans, f"orphan agent_id on cases: {orphans}"
