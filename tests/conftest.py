"""Shared pytest fixtures.

Tests import the pipeline's data-quality logic from ``verify_metrics`` so there is
a single source of truth: the same flag rules and resolution-time calculation that
``verify_metrics.py`` (and, in SQL, ``02_Staging_Layer.sql``) apply are the ones the
tests assert against. Aggregations in the test files are recomputed independently as
a cross-check.
"""
import csv
import os
import sys

import pytest

# Make the repo root importable regardless of where pytest is invoked from.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

import verify_metrics  # noqa: E402

DATA = os.path.join(ROOT, "Data_Set")


def _load(name):
    with open(os.path.join(DATA, name)) as f:
        return list(csv.DictReader(f))


@pytest.fixture(scope="session")
def cases():
    return _load("cases.csv")


@pytest.fixture(scope="session")
def customers():
    return _load("customers.csv")


@pytest.fixture(scope="session")
def agents():
    return _load("agents.csv")


@pytest.fixture(scope="session")
def records():
    """The staged records with DQ flags + resolution_hours, from the pipeline logic."""
    recs, _, _ = verify_metrics.build()
    return recs
