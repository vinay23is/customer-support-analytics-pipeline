# Convenience targets. The core checks (verify, test, dry-run) need no Snowflake
# account and no third-party packages beyond pytest.

.PHONY: help verify test dry-run pipeline install-dev clean

help:
	@echo "make verify      - recompute every headline metric from the CSVs"
	@echo "make test        - run the pytest data-contract + metric-regression suite"
	@echo "make dry-run     - parse & validate the pipeline plan (no Snowflake needed)"
	@echo "make pipeline    - execute the pipeline against Snowflake (needs env vars)"
	@echo "make install-dev - install test dependencies (pytest)"
	@echo "make clean       - remove caches and run manifests"

verify:
	python3 verify_metrics.py

test:
	python3 -m pytest -q

dry-run:
	python3 run_pipeline.py --dry-run

pipeline:
	python3 run_pipeline.py

install-dev:
	python3 -m pip install -r requirements-dev.txt

clean:
	rm -rf .pytest_cache **/__pycache__ logs
