--- Created a STAGE LAYER where I can just load the RAW csv

-- first let me check what files we have in the stage
LIST @DEMO_DB.PUBLIC.CSV;


-- schema setup - need all four layers before we do anything else
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS dim;
CREATE SCHEMA IF NOT EXISTS facts;


-- raw layer tables
-- keeping everything as varchar here intentionally
-- dont want type errors killing the load, we handle that in staging

CREATE TABLE IF NOT EXISTS raw.cases (
    case_id         VARCHAR(10),
    created_at      VARCHAR(50),
    closed_at       VARCHAR(50),
    customer_id     VARCHAR(10),
    agent_id        VARCHAR(10),
    category        VARCHAR(50),
    priority        VARCHAR(20),
    status          VARCHAR(20),
    _loaded_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _source_file    VARCHAR(255)
);

CREATE TABLE IF NOT EXISTS raw.customers (
    customer_id     VARCHAR(10),
    customer_name   VARCHAR(100),
    region          VARCHAR(50),
    signup_date     VARCHAR(20),
    _loaded_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _source_file    VARCHAR(255)
);

CREATE TABLE IF NOT EXISTS raw.agents (
    agent_id        VARCHAR(10),
    agent_name      VARCHAR(100),
    team            VARCHAR(50),
    _loaded_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    _source_file    VARCHAR(255)
);


-- file format - create once and reuse for all three loads
CREATE OR REPLACE FILE FORMAT DEMO_DB.PUBLIC.CSV_FORMAT
    TYPE                         = 'CSV'
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    SKIP_HEADER                  = 1
    EMPTY_FIELD_AS_NULL          = TRUE
    NULL_IF                      = ('NULL', 'null', '', '\\N')
    TRIM_SPACE                   = TRUE
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;


-- load agents
COPY INTO DEMO_DB.RAW.AGENTS (
    agent_id, agent_name, team, _source_file
)
FROM (
    SELECT $1, $2, $3, METADATA$FILENAME
    FROM @DEMO_DB.PUBLIC.CSV/agents.csv
)
FILE_FORMAT = (FORMAT_NAME = 'DEMO_DB.PUBLIC.CSV_FORMAT')
ON_ERROR    = 'CONTINUE';


-- load customers
COPY INTO DEMO_DB.RAW.CUSTOMERS (
    customer_id, customer_name, region, signup_date, _source_file
)
FROM (
    SELECT $1, $2, $3, $4, METADATA$FILENAME
    FROM @DEMO_DB.PUBLIC.CSV/customers.csv
)
FILE_FORMAT = (FORMAT_NAME = 'DEMO_DB.PUBLIC.CSV_FORMAT')
ON_ERROR    = 'CONTINUE';


-- load cases
COPY INTO DEMO_DB.RAW.CASES (
    case_id, created_at, closed_at,
    customer_id, agent_id,
    category, priority, status,
    _source_file
)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8, METADATA$FILENAME
    FROM @DEMO_DB.PUBLIC.CSV/cases.csv
)
FILE_FORMAT = (FORMAT_NAME = 'DEMO_DB.PUBLIC.CSV_FORMAT')
ON_ERROR    = 'CONTINUE';


-- quick check - row counts and source file per table
SELECT 'agents'    AS tbl, COUNT(*) AS rows_, _source_file FROM DEMO_DB.RAW.AGENTS    GROUP BY _source_file
UNION ALL
SELECT 'customers' AS tbl, COUNT(*) AS rows_, _source_file FROM DEMO_DB.RAW.CUSTOMERS GROUP BY _source_file
UNION ALL
SELECT 'cases'     AS tbl, COUNT(*) AS rows_, _source_file FROM DEMO_DB.RAW.CASES     GROUP BY _source_file
ORDER BY tbl;

-- expected: agents=40, customers=150, cases=200


-- spot check the data
SELECT * FROM DEMO_DB.RAW.AGENTS    LIMIT 5;
SELECT * FROM DEMO_DB.RAW.CUSTOMERS LIMIT 5;
SELECT * FROM DEMO_DB.RAW.CASES     LIMIT 5;


























