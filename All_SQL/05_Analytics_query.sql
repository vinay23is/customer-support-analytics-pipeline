Select * from DEMO_DB.FACTS.FACT_CASES;




---- A. AVG CASE Resolution Time

Select 
    ROUND(AVG(Resolution_hours),1) as avg_resolution_hours,
    ROUND(AVG(Resolution_hours)/ 24,2) as avg_resolution_days,
    COUNT(*) as Counts
From DEMO_DB.FACTS.FACT_CASES



SELECT
    PRIORITY,
    COUNT(*)                                 AS Counts,
    ROUND(AVG(RESOLUTION_HOURS), 1)          AS AVG_RESOLUTION_HOURS,
    ROUND(MEDIAN(RESOLUTION_HOURS), 1)       AS MEDIAN_HOURS,
    ROUND(MIN(RESOLUTION_HOURS), 1)          AS MIN_HOURS,
    ROUND(MAX(RESOLUTION_HOURS), 1)          AS MAX_HOURS
FROM FACTS.FACT_CASES
GROUP BY PRIORITY
ORDER BY AVG_RESOLUTION_HOURS ASC;


SELECT
    CATEGORY,
    COUNT(*)                                 AS Counts,
    ROUND(AVG(RESOLUTION_HOURS), 1)          AS AVG_RESOLUTION_HOURS,
    ROUND(MEDIAN(RESOLUTION_HOURS), 1)       AS MEDIAN_HOURS
FROM FACTS.FACT_CASES
GROUP BY CATEGORY
ORDER BY AVG_RESOLUTION_HOURS ASC;


SELECT
    TEAM,
    COUNT(*)                                 AS Counts,
    ROUND(AVG(RESOLUTION_HOURS), 1)          AS AVG_HOURS,
    ROUND(MEDIAN(RESOLUTION_HOURS), 1)       AS MEDIAN_HOURS
FROM FACTS.FACT_CASES
GROUP BY TEAM
ORDER BY AVG_HOURS ASC;



SELECT
    RESOLUTION_BUCKET,
    COUNT(*)                                                     AS CASES,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)          AS PCT_OF_CLOSED
FROM FACTS.FACT_CASES
WHERE  HAS_ANY_DQ_FLAG = FALSE
GROUP BY RESOLUTION_BUCKET
ORDER BY CASES DESC;





------ B. Number of cases by category, priority, and status 

SELECT
    CATEGORY,
    COUNT(*)                                                     AS TOTAL_CASES,
    SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END)                AS CLOSED,
    ROUND(SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 1)                                AS CLOSURE_RATE_PCT
FROM FACTS.FACT_CASES
GROUP BY CATEGORY
ORDER BY TOTAL_CASES DESC;

-- By priority
SELECT
    PRIORITY,
    COUNT(*)                                                     AS TOTAL_CASES,
    SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END)                AS CLOSED,
    ROUND(SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 1)                                AS CLOSURE_RATE_PCT
FROM FACTS.FACT_CASES
GROUP BY PRIORITY
ORDER BY TOTAL_CASES DESC;


-- By status
SELECT
    STATUS,
    COUNT(*)                                                     AS TOTAL_CASES,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)          AS PCT_OF_TOTAL
FROM FACTS.FACT_CASES
GROUP BY STATUS
ORDER BY TOTAL_CASES DESC;



 WITH CTE AS (

Select 
    CATEGORY,
    PRIORITY,
    STATUS,
    COUNT(*) AS COUNT_CASES,
    SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END) AS CLOSED,
    ROUND(SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END) *100.0/COUNT(*), 1) AS CLOSURE_RATE_PCT
FROM FACTS.FACT_CASES
GROUP BY CATEGORY, PRIORITY,STATUS
ORDER BY COUNT_CASES DESC

 ) Select * from CTE where CATEGORY = 'Account' and PRIORITY = 'Urgent'




-- Category x Status pivot
SELECT
    CATEGORY,
    SUM(CASE WHEN STATUS = 'Closed'      THEN 1 ELSE 0 END)     AS CLOSED,
    SUM(CASE WHEN STATUS = 'In Progress' THEN 1 ELSE 0 END)     AS IN_PROGRESS,
    SUM(CASE WHEN STATUS = 'On Hold'     THEN 1 ELSE 0 END)     AS ON_HOLD,
    SUM(CASE WHEN STATUS = 'Open'        THEN 1 ELSE 0 END)     AS OPEN,
    COUNT(*)                                                     AS TOTAL
FROM FACTS.FACT_CASES
GROUP BY CATEGORY
ORDER BY TOTAL DESC;


-- Priority x Status pivot
SELECT
    PRIORITY,
    SUM(CASE WHEN STATUS = 'Closed'      THEN 1 ELSE 0 END)     AS CLOSED,
    SUM(CASE WHEN STATUS = 'In Progress' THEN 1 ELSE 0 END)     AS IN_PROGRESS,
    SUM(CASE WHEN STATUS = 'On Hold'     THEN 1 ELSE 0 END)     AS ON_HOLD,
    SUM(CASE WHEN STATUS = 'Open'        THEN 1 ELSE 0 END)     AS OPEN,
    COUNT(*)                                                     AS TOTAL
FROM FACTS.FACT_CASES
GROUP BY PRIORITY
ORDER BY TOTAL DESC;




---   C. AGENT PERFORMANCE METRICS


-- Agent scorecard
SELECT
    AGENT_NAME,
    TEAM,
    COUNT(*)                                                          AS TOTAL_CASES,
    SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END)                     AS CLOSED_CASES,
    ROUND(SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 1)                                     AS CLOSURE_RATE_PCT,
    ROUND(AVG(CASE WHEN IS_RESOLVED THEN RESOLUTION_HOURS END), 1)   AS AVG_RESOLUTION_HOURS,
    ROUND(MEDIAN(CASE WHEN IS_RESOLVED THEN RESOLUTION_HOURS END), 1) AS MEDIAN_RESOLUTION_HOURS,
    SUM(CASE WHEN STATUS = 'On Hold' THEN 1 ELSE 0 END)              AS ON_HOLD_CASES,
    SUM(CASE WHEN HAS_ANY_DQ_FLAG    THEN 1 ELSE 0 END)              AS DQ_FLAGGED_CASES
FROM FACTS.FACT_CASES
GROUP BY AGENT_NAME, TEAM
ORDER BY CLOSURE_RATE_PCT DESC, TOTAL_CASES DESC;

-- Team rollup
SELECT
    TEAM,
    COUNT(*)                                                          AS TOTAL_CASES,
    SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END)                     AS CLOSED_CASES,
    ROUND(SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 1)                                     AS CLOSURE_RATE_PCT,
    ROUND(AVG(CASE WHEN IS_RESOLVED THEN RESOLUTION_HOURS END), 1)   AS AVG_RESOLUTION_HOURS,
    COUNT(DISTINCT AGENT_NAME)                                        AS AGENT_COUNT,
    ROUND(COUNT(*) / COUNT(DISTINCT AGENT_NAME), 1)                  AS CASES_PER_AGENT
FROM FACTS.FACT_CASES
GROUP BY TEAM
ORDER BY AVG_RESOLUTION_HOURS ASC;



-- Agent ranked within team
SELECT
    AGENT_NAME,
    TEAM,
    TOTAL_CASES,
    CLOSED_CASES,
    AVG_RESOLUTION_HOURS,
    CLOSURE_RATE_PCT,
    RANK() OVER (PARTITION BY TEAM ORDER BY AVG_RESOLUTION_HOURS ASC) AS RANK_IN_TEAM
FROM (
    SELECT
        AGENT_NAME,
        TEAM,
        COUNT(*)                                                          AS TOTAL_CASES,
        SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END)                     AS CLOSED_CASES,
        ROUND(AVG(CASE WHEN IS_RESOLVED THEN RESOLUTION_HOURS END), 1)   AS AVG_RESOLUTION_HOURS,
        ROUND(SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END)
              * 100.0 / COUNT(*), 1)                                     AS CLOSURE_RATE_PCT
    FROM FACTS.FACT_CASES
    GROUP BY AGENT_NAME, TEAM
) T
QUALIFY RANK_IN_TEAM <= 3
ORDER BY TEAM, RANK_IN_TEAM;




--   D. CUSTOMER AND REGION-LEVEL TRENDS


-- By region
SELECT
    REGION,
    COUNT(*)                                                          AS TOTAL_CASES,
    SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END)                     AS CLOSED_CASES,
    ROUND(SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END)
          * 100.0 / COUNT(*), 1)                                     AS CLOSURE_RATE_PCT,
    ROUND(AVG(CASE WHEN IS_RESOLVED THEN RESOLUTION_HOURS END), 1)   AS AVG_RESOLUTION_HOURS,
    SUM(CASE WHEN STATUS = 'On Hold' THEN 1 ELSE 0 END)              AS ON_HOLD,
    SUM(CASE WHEN STATUS = 'Open'    THEN 1 ELSE 0 END)              AS OPEN
FROM FACTS.FACT_CASES
GROUP BY REGION
ORDER BY TOTAL_CASES DESC;


-- Region x Category breakdown
SELECT
    REGION,
    CATEGORY,
    COUNT(*)                                                          AS TOTAL_CASES,
    ROUND(AVG(CASE WHEN IS_RESOLVED THEN RESOLUTION_HOURS END), 1)   AS AVG_RESOLUTION_HOURS
FROM FACTS.FACT_CASES
GROUP BY REGION, CATEGORY
ORDER BY REGION, TOTAL_CASES DESC;


-- Top 10 customers by case volume
SELECT
    CUSTOMER_NAME,
    REGION,
    COUNT(*)                                                          AS TOTAL_CASES,
    SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END)                     AS CLOSED_CASES,
    ROUND(AVG(CASE WHEN IS_RESOLVED THEN RESOLUTION_HOURS END), 1)   AS AVG_RESOLUTION_HOURS,
    SUM(CASE WHEN PRIORITY = 'Urgent' THEN 1 ELSE 0 END)             AS URGENT_CASES
FROM FACTS.FACT_CASES
GROUP BY CUSTOMER_NAME, REGION
ORDER BY TOTAL_CASES DESC
LIMIT 10;


-- Monthly volume trend
SELECT
    DATE_TRUNC('month', CREATED_AT)                                   AS MONTH,
    COUNT(*)                                                          AS TOTAL_CASES,
    SUM(CASE WHEN IS_RESOLVED THEN 1 ELSE 0 END)                     AS CLOSED_CASES,
    ROUND(AVG(CASE WHEN IS_RESOLVED THEN RESOLUTION_HOURS END), 1)   AS AVG_RESOLUTION_HOURS
FROM FACTS.FACT_CASES
GROUP BY DATE_TRUNC('month', CREATED_AT)
ORDER BY MONTH ASC;


-- Region trend by quarter
SELECT
    REGION,
    DATE_TRUNC('quarter', CREATED_AT)                                 AS QUARTER,
    COUNT(*)                                                          AS TOTAL_CASES,
    ROUND(AVG(CASE WHEN IS_RESOLVED THEN RESOLUTION_HOURS END), 1)   AS AVG_RESOLUTION_HOURS
FROM FACTS.FACT_CASES
GROUP BY REGION, DATE_TRUNC('quarter', CREATED_AT)
ORDER BY QUARTER ASC, REGION;
