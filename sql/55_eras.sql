-- Stage: condition_era and drug_era, following the OHDSI era rules (as in the CDM's era
-- scripts): records of the same concept for a person are merged into one era when the gap
-- between them is at most 30 days. Records with concept_id 0 are skipped.
--
-- Gaps and islands: sort by start; a record starts a new era when it begins more than
-- 30 days after the latest end seen so far in the current group.

CREATE OR REPLACE MACRO era_window() AS 30;

-- condition_era: missing end date -> start + 1 day.
INSERT INTO condition_era
WITH t AS (
    SELECT person_id, condition_concept_id AS c, condition_start_date AS s,
           coalesce(condition_end_date, condition_start_date + 1) AS e
    FROM condition_occurrence WHERE condition_concept_id <> 0
), w AS (
    SELECT *, max(e) OVER (PARTITION BY person_id, c ORDER BY s, e
                           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_e
    FROM t
), g AS (
    SELECT *, sum(CASE WHEN prev_e IS NULL OR s > prev_e + era_window() THEN 1 ELSE 0 END)
                  OVER (PARTITION BY person_id, c ORDER BY s, e ROWS UNBOUNDED PRECEDING) AS grp
    FROM w
)
SELECT row_number() OVER (ORDER BY person_id, c, min(s))::INTEGER,
       person_id, c, min(s), max(e), count(*)::INTEGER
FROM g GROUP BY person_id, c, grp;

-- drug_era: exposures roll up to their RxNorm ingredient. End date is
-- end_date, else start + days_supply, else start + 1 day.
-- gap_days = era length minus the days actually covered by exposures (overlaps counted once).
INSERT INTO drug_era
WITH t AS (
    SELECT d.person_id, i.ingredient_concept_id AS c, d.drug_exposure_start_date AS s,
           greatest(coalesce(d.drug_exposure_end_date,
                             d.drug_exposure_start_date + d.days_supply,
                             d.drug_exposure_start_date + 1),
                    d.drug_exposure_start_date + 1) AS e
    FROM drug_exposure d
    JOIN stg.ingredient i ON i.drug_concept_id = d.drug_concept_id
    WHERE d.drug_concept_id <> 0
), w AS (
    SELECT *, max(e) OVER (PARTITION BY person_id, c ORDER BY s, e
                           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_e
    FROM t
), g AS (
    -- grp: 30-day era; sub: overlapping/abutting exposures (0-day window), for coverage
    SELECT *,
           sum(CASE WHEN prev_e IS NULL OR s > prev_e + era_window() THEN 1 ELSE 0 END)
               OVER (PARTITION BY person_id, c ORDER BY s, e ROWS UNBOUNDED PRECEDING) AS grp,
           sum(CASE WHEN prev_e IS NULL OR s > prev_e THEN 1 ELSE 0 END)
               OVER (PARTITION BY person_id, c ORDER BY s, e ROWS UNBOUNDED PRECEDING) AS sub
    FROM w
), covered AS (
    SELECT person_id, c, grp, min(s) AS s, max(e) AS e, count(*) AS n
    FROM g GROUP BY person_id, c, grp, sub
)
SELECT row_number() OVER (ORDER BY person_id, c, min(s))::INTEGER,
       person_id, c, min(s), max(e), sum(n)::INTEGER,
       ((max(e) - min(s)) - sum(e - s))::INTEGER
FROM covered GROUP BY person_id, c, grp;
