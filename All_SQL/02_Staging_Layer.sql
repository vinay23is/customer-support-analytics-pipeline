-- staging layer DDL
-- this is where all the actual work happens
-- parse types, normalize values, compute resolution time and dq flags

CREATE TABLE IF NOT EXISTS stg.stg_cases (
    case_id                      VARCHAR(10)  NOT NULL,
    created_at                   TIMESTAMP_NTZ,
    closed_at                    TIMESTAMP_NTZ,
    customer_id                  VARCHAR(10),
    agent_id                     VARCHAR(10),
    category                     VARCHAR(50),
    priority                     VARCHAR(20),
    status                       VARCHAR(20),
    resolution_hours             NUMBER(10,2),
    resolution_bucket            VARCHAR(20),
    dq_flag_closed_no_timestamp  BOOLEAN DEFAULT FALSE,
    dq_flag_status_ts_mismatch   BOOLEAN DEFAULT FALSE,
    dq_flag_invalid_created_at   BOOLEAN DEFAULT FALSE,
    dq_flag_orphan_customer      BOOLEAN DEFAULT FALSE,
    dq_flag_orphan_agent         BOOLEAN DEFAULT FALSE,
    has_any_dq_flag              BOOLEAN DEFAULT FALSE,
    _loaded_at                   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS stg.stg_customers (
    customer_id    VARCHAR(10)  NOT NULL,
    customer_name  VARCHAR(100),
    region         VARCHAR(50),
    signup_date    DATE,
    _loaded_at     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS stg.stg_agents (
    agent_id    VARCHAR(10)  NOT NULL,
    agent_name  VARCHAR(100),
    team        VARCHAR(50),
    _loaded_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);


-- load customers first
-- cases merge needs this to exist before it runs (orphan check)
MERGE INTO stg.stg_customers AS tgt
USING (
    SELECT
        customer_id,
        TRIM(customer_name)                   AS customer_name,
        TRIM(UPPER(region))                   AS region,
        TRY_TO_DATE(signup_date, 'YYYY-MM-DD') AS signup_date
    FROM raw.customers
    WHERE customer_id IS NOT NULL
) AS src
ON tgt.customer_id = src.customer_id
WHEN MATCHED THEN UPDATE SET
    tgt.customer_name = src.customer_name,
    tgt.region        = src.region,
    tgt.signup_date   = src.signup_date,
    tgt._loaded_at    = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    customer_id, customer_name, region, signup_date, _loaded_at
) VALUES (
    src.customer_id, src.customer_name, src.region, src.signup_date, CURRENT_TIMESTAMP()
);


-- load agents second, same reason
MERGE INTO stg.stg_agents AS tgt
USING (
    SELECT
        agent_id,
        TRIM(agent_name) AS agent_name,
        TRIM(team)       AS team
    FROM raw.agents
    WHERE agent_id IS NOT NULL
) AS src
ON tgt.agent_id = src.agent_id
WHEN MATCHED THEN UPDATE SET
    tgt.agent_name = src.agent_name,
    tgt.team       = src.team,
    tgt._loaded_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    agent_id, agent_name, team, _loaded_at
) VALUES (
    src.agent_id, src.agent_name, src.team, CURRENT_TIMESTAMP()
);


-- cases merge runs last
-- does the heavy lifting: timestamp parsing, resolution time, all five dq flags
-- using TRY_TO_TIMESTAMP_NTZ throughout - bad string becomes NULL instead of crashing
MERGE INTO stg.stg_cases AS tgt
USING (
    SELECT
        c.case_id,
        TRY_TO_TIMESTAMP_NTZ(c.created_at) AS created_at,
        TRY_TO_TIMESTAMP_NTZ(c.closed_at)  AS closed_at,
        c.customer_id,
        c.agent_id,
        TRIM(c.category) AS category,
        TRIM(c.priority) AS priority,
        TRIM(c.status)   AS status,

        -- resolution hours: only compute for closed cases where both timestamps are valid
        -- and closed_at is actually after created_at
        CASE
            WHEN TRIM(c.status) = 'Closed'
             AND TRY_TO_TIMESTAMP_NTZ(c.created_at) IS NOT NULL
             AND TRY_TO_TIMESTAMP_NTZ(c.closed_at)  IS NOT NULL
             AND TRY_TO_TIMESTAMP_NTZ(c.closed_at) > TRY_TO_TIMESTAMP_NTZ(c.created_at)
            THEN DATEDIFF('second',
                     TRY_TO_TIMESTAMP_NTZ(c.created_at),
                     TRY_TO_TIMESTAMP_NTZ(c.closed_at)
                 ) / 3600.0
            ELSE NULL
        END AS resolution_hours,

        -- bucket the resolution time for histogram-style reporting
        CASE
            WHEN TRIM(c.status) = 'Closed'
             AND TRY_TO_TIMESTAMP_NTZ(c.closed_at) > TRY_TO_TIMESTAMP_NTZ(c.created_at)
            THEN
                CASE
                    WHEN DATEDIFF('second',
                             TRY_TO_TIMESTAMP_NTZ(c.created_at),
                             TRY_TO_TIMESTAMP_NTZ(c.closed_at)
                         ) / 3600.0 < 24 THEN '<24h'
                    WHEN DATEDIFF('second',
                             TRY_TO_TIMESTAMP_NTZ(c.created_at),
                             TRY_TO_TIMESTAMP_NTZ(c.closed_at)
                         ) / 3600.0 < 72 THEN '1-3 days'
                    ELSE '>3 days'
                END
            ELSE NULL
        END AS resolution_bucket,

        --- flag 1: closed but no closed_at - genuine upstream bug (9 rows in our dataset)
        CASE WHEN TRIM(c.status) = 'Closed' AND c.closed_at IS NULL
             THEN TRUE ELSE FALSE END AS dq_flag_closed_no_timestamp,

        ---- flag 2: open/in progress but has a closed_at - status and timestamp disagree
        CASE WHEN TRIM(c.status) IN ('Open', 'On Hold', 'In Progress') AND c.closed_at IS NOT NULL
             THEN TRUE ELSE FALSE END AS dq_flag_status_ts_mismatch,

        ---- flag 3: created_at string could not be parsed at all
        CASE WHEN TRY_TO_TIMESTAMP_NTZ(c.created_at) IS NULL
             THEN TRUE ELSE FALSE END AS dq_flag_invalid_created_at,

        --- flag 4: customer not found in staging - left join returns null
        CASE WHEN sc.customer_id IS NULL
             THEN TRUE ELSE FALSE END AS dq_flag_orphan_customer,

        -- flag 5: agent not found in staging
        CASE WHEN sa.agent_id IS NULL
             THEN TRUE ELSE FALSE END AS dq_flag_orphan_agent

    FROM raw.cases c
    LEFT JOIN stg.stg_customers sc ON c.customer_id = sc.customer_id
    LEFT JOIN stg.stg_agents    sa ON c.agent_id    = sa.agent_id
    WHERE c.case_id IS NOT NULL

) AS src
ON tgt.case_id = src.case_id
WHEN MATCHED THEN UPDATE SET
    tgt.created_at                  = src.created_at,
    tgt.closed_at                   = src.closed_at,
    tgt.customer_id                 = src.customer_id,
    tgt.agent_id                    = src.agent_id,
    tgt.category                    = src.category,
    tgt.priority                    = src.priority,
    tgt.status                      = src.status,
    tgt.resolution_hours            = src.resolution_hours,
    tgt.resolution_bucket           = src.resolution_bucket,
    tgt.dq_flag_closed_no_timestamp = src.dq_flag_closed_no_timestamp,
    tgt.dq_flag_status_ts_mismatch  = src.dq_flag_status_ts_mismatch,
    tgt.dq_flag_invalid_created_at  = src.dq_flag_invalid_created_at,
    tgt.dq_flag_orphan_customer     = src.dq_flag_orphan_customer,
    tgt.dq_flag_orphan_agent        = src.dq_flag_orphan_agent,
    tgt.has_any_dq_flag             = (
        src.dq_flag_closed_no_timestamp OR
        src.dq_flag_status_ts_mismatch  OR
        src.dq_flag_invalid_created_at  OR
        src.dq_flag_orphan_customer     OR
        src.dq_flag_orphan_agent
    ),
    tgt._loaded_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    case_id, created_at, closed_at, customer_id, agent_id,
    category, priority, status,
    resolution_hours, resolution_bucket,
    dq_flag_closed_no_timestamp, dq_flag_status_ts_mismatch,
    dq_flag_invalid_created_at, dq_flag_orphan_customer, dq_flag_orphan_agent,
    has_any_dq_flag, _loaded_at
) VALUES (
    src.case_id, src.created_at, src.closed_at, src.customer_id, src.agent_id,
    src.category, src.priority, src.status,
    src.resolution_hours, src.resolution_bucket,
    src.dq_flag_closed_no_timestamp, src.dq_flag_status_ts_mismatch,
    src.dq_flag_invalid_created_at, src.dq_flag_orphan_customer, src.dq_flag_orphan_agent,
    (
        src.dq_flag_closed_no_timestamp OR src.dq_flag_status_ts_mismatch OR
        src.dq_flag_invalid_created_at  OR src.dq_flag_orphan_customer    OR
        src.dq_flag_orphan_agent
    ),
    CURRENT_TIMESTAMP()
);


-- spot check
SELECT * FROM stg.stg_cases LIMIT 10;

-- quick dq summary - want to see all 5 flag counts
SELECT
    SUM(CASE WHEN dq_flag_closed_no_timestamp THEN 1 ELSE 0 END) AS closed_no_ts,
    SUM(CASE WHEN dq_flag_status_ts_mismatch  THEN 1 ELSE 0 END) AS status_mismatch,
    SUM(CASE WHEN dq_flag_invalid_created_at  THEN 1 ELSE 0 END) AS bad_created_at,
    SUM(CASE WHEN dq_flag_orphan_customer     THEN 1 ELSE 0 END) AS orphan_customer,
    SUM(CASE WHEN dq_flag_orphan_agent        THEN 1 ELSE 0 END) AS orphan_agent,
    SUM(CASE WHEN has_any_dq_flag             THEN 1 ELSE 0 END) AS total_flagged,
    COUNT(*)                                                       AS total_rows
FROM stg.stg_cases;