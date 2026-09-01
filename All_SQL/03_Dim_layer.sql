-- dimension tables
-- keeping SCD2 columns (valid_from, valid_to, is_current) on both dims
-- not needed for static CSV but good to have ready for production

CREATE TABLE IF NOT EXISTS dim.dim_customer (
    sk_customer   INTEGER AUTOINCREMENT PRIMARY KEY,
    customer_id   VARCHAR(10)  NOT NULL,
    customer_name VARCHAR(100),
    region        VARCHAR(50),
    signup_date   DATE,
    valid_from    DATE         NOT NULL DEFAULT CURRENT_DATE(),
    valid_to      DATE         DEFAULT TO_DATE('9999-12-31', 'YYYY-MM-DD'),
    is_current    BOOLEAN      DEFAULT TRUE,
    _loaded_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS dim.dim_agent (
    sk_agent    INTEGER AUTOINCREMENT PRIMARY KEY,
    agent_id    VARCHAR(10)  NOT NULL,
    agent_name  VARCHAR(100),
    team        VARCHAR(50),
    valid_from  DATE         NOT NULL DEFAULT CURRENT_DATE(),
    valid_to    DATE         DEFAULT TO_DATE('9999-12-31', 'YYYY-MM-DD'),
    is_current  BOOLEAN      DEFAULT TRUE,
    _loaded_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- date dim - generate one row per day from 2020 to 2030
-- quarter_label needs VARCHAR(10) not VARCHAR(6) - 'Q1 2020' is 7 chars
CREATE OR REPLACE TABLE dim.dim_date (
    date_key        INTEGER  PRIMARY KEY,
    full_date       DATE     NOT NULL,
    day_of_week     VARCHAR(10),
    day_of_week_num TINYINT,
    day_of_month    TINYINT,
    week_of_year    TINYINT,
    month_num       TINYINT,
    month_name      VARCHAR(10),
    quarter_num     TINYINT,
    quarter_label   VARCHAR(10),
    year_num        SMALLINT,
    is_weekend      BOOLEAN,
    is_weekday      BOOLEAN
);


-- populate dim_date - run once, covers 2020-01-01 to 2030-12-31
INSERT INTO dim.dim_date
WITH date_spine AS (
    SELECT DATEADD(DAY, SEQ4(), '2020-01-01')::DATE AS full_date
    FROM TABLE(GENERATOR(ROWCOUNT => 4018))
)
SELECT
    TO_NUMBER(TO_CHAR(full_date, 'YYYYMMDD'))           AS date_key,
    full_date,
    DAYNAME(full_date)                                   AS day_of_week,
    DAYOFWEEK(full_date)                                 AS day_of_week_num,
    DAYOFMONTH(full_date)                                AS day_of_month,
    WEEKOFYEAR(full_date)                                AS week_of_year,
    MONTH(full_date)                                     AS month_num,
    MONTHNAME(full_date)                                 AS month_name,
    QUARTER(full_date)                                   AS quarter_num,
    'Q' || QUARTER(full_date) || ' ' || YEAR(full_date) AS quarter_label,
    YEAR(full_date)                                      AS year_num,
    CASE WHEN DAYOFWEEK(full_date) IN (0,6) THEN TRUE ELSE FALSE END AS is_weekend,
    CASE WHEN DAYOFWEEK(full_date) IN (0,6) THEN FALSE ELSE TRUE END AS is_weekday
FROM date_spine;

-- verify - should be 20200101 to 20301231, 4018 rows
SELECT MIN(date_key), MAX(date_key), COUNT(*) AS total_days FROM dim.dim_date;


-- load dim_customer
-- two steps for SCD2: expire changed rows first, then insert new/changed ones
-- for static CSV this is effectively just a first-time insert

-- step 1: expire any rows where something changed
UPDATE dim.dim_customer AS tgt
SET
    valid_to   = CURRENT_DATE() - 1,
    is_current = FALSE
WHERE is_current = TRUE
  AND EXISTS (
    SELECT 1 FROM stg.stg_customers src
    WHERE src.customer_id = tgt.customer_id
      AND (
          src.customer_name <> tgt.customer_name OR
          src.region        <> tgt.region        OR
          src.signup_date   <> tgt.signup_date
      )
  );

-- step 2: insert new customers and any that just got expired above
INSERT INTO dim.dim_customer (
    customer_id, customer_name, region, signup_date,
    valid_from, valid_to, is_current, _loaded_at
)
SELECT
    src.customer_id,
    src.customer_name,
    src.region,
    src.signup_date,
    CURRENT_DATE(),
    TO_DATE('9999-12-31', 'YYYY-MM-DD'),
    TRUE,
    CURRENT_TIMESTAMP()
FROM stg.stg_customers src
WHERE NOT EXISTS (
    SELECT 1 FROM dim.dim_customer tgt
    WHERE tgt.customer_id  = src.customer_id
      AND tgt.is_current   = TRUE
      AND tgt.customer_name = src.customer_name
      AND tgt.region        = src.region
      AND tgt.signup_date   = src.signup_date
);


-- load dim_agent - same pattern
-- step 1: expire changed rows
UPDATE dim.dim_agent AS tgt
SET
    valid_to   = CURRENT_DATE() - 1,
    is_current = FALSE
WHERE is_current = TRUE
  AND EXISTS (
    SELECT 1 FROM stg.stg_agents src
    WHERE src.agent_id = tgt.agent_id
      AND (
          src.agent_name <> tgt.agent_name OR
          src.team       <> tgt.team
      )
  );

-- step 2: insert new and changed agents
INSERT INTO dim.dim_agent (
    agent_id, agent_name, team,
    valid_from, valid_to, is_current, _loaded_at
)
SELECT
    src.agent_id,
    src.agent_name,
    src.team,
    CURRENT_DATE(),
    TO_DATE('9999-12-31', 'YYYY-MM-DD'),
    TRUE,
    CURRENT_TIMESTAMP()
FROM stg.stg_agents src
WHERE NOT EXISTS (
    SELECT 1 FROM dim.dim_agent tgt
    WHERE tgt.agent_id   = src.agent_id
      AND tgt.is_current = TRUE
      AND tgt.agent_name = src.agent_name
      AND tgt.team       = src.team
);


-- spot check
SELECT * FROM dim.dim_agent    LIMIT 5;
SELECT * FROM dim.dim_customer LIMIT 5;

-- verify counts - should be 40 agents, 150 customers
SELECT 'dim_customer' AS tbl, COUNT(*) AS rows FROM dim.dim_customer
UNION ALL
SELECT 'dim_agent'    AS tbl, COUNT(*) AS rows FROM dim.dim_agent;