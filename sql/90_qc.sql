-- Stage: QC report (stg.qc). status is ok | warn | fail; the wrapper exits non-zero
-- on any fail when run with --strict.

CREATE OR REPLACE TABLE stg.qc (check_name VARCHAR, table_name VARCHAR, value DOUBLE,
                                status VARCHAR, detail VARCHAR);

CREATE OR REPLACE TABLE stg.vocab_flag AS SELECT count(*) > 0 AS loaded FROM stg.concept;

-- Per-table checks for tables with person_id / visit_occurrence_id / a main concept column.
CREATE OR REPLACE MACRO person_orphans(t) AS TABLE
    SELECT count(*) AS n FROM query_table(t) x
    WHERE x.person_id NOT IN (SELECT person_id FROM person);
CREATE OR REPLACE MACRO visit_orphans(t) AS TABLE
    SELECT count(*) AS n FROM query_table(t) x
    WHERE x.visit_occurrence_id IS NOT NULL
      AND x.visit_occurrence_id NOT IN (SELECT visit_occurrence_id FROM visit_occurrence);

-- Source resources: how many of each type, and whether the pipeline maps that type.
INSERT INTO stg.qc
SELECT 'fhir_resources', resource_type, count(*),
       CASE WHEN resource_type IN ('Patient', 'Encounter', 'Practitioner', 'Organization',
            'Condition', 'Procedure', 'MedicationRequest', 'MedicationAdministration',
            'Medication', 'Immunization', 'Device', 'AllergyIntolerance', 'Observation')
            THEN 'ok' ELSE 'warn' END,
       CASE WHEN resource_type IN ('Patient', 'Encounter', 'Practitioner', 'Organization',
            'Condition', 'Procedure', 'MedicationRequest', 'MedicationAdministration',
            'Medication', 'Immunization', 'Device', 'AllergyIntolerance', 'Observation')
            THEN 'mapped' ELSE 'not mapped (ignored)' END
FROM stg.fhir GROUP BY resource_type;

INSERT INTO stg.qc
SELECT 'duplicate_fhir_id', resource_type, count(*) - count(DISTINCT id),
       CASE WHEN count(*) = count(DISTINCT id) THEN 'ok' ELSE 'warn' END,
       'same resource id appears more than once'
FROM stg.fhir GROUP BY resource_type HAVING count(*) > count(DISTINCT id);

INSERT INTO stg.qc
SELECT 'patients_dropped', 'person',
       (SELECT count(*) FROM stg.fhir WHERE resource_type = 'Patient') - (SELECT count(*) FROM person),
       CASE WHEN (SELECT count(*) FROM stg.fhir WHERE resource_type = 'Patient')
                 = (SELECT count(*) FROM person) THEN 'ok' ELSE 'warn' END,
       'Patient without a usable birthDate';

INSERT INTO stg.qc
SELECT 'events_unplaced', src_type, count(*), 'warn',
       CASE WHEN person_id IS NULL THEN 'subject does not resolve to a person'
            ELSE 'no start date' END
FROM stg.event_mapped
WHERE person_id IS NULL OR person_id NOT IN (SELECT person_id FROM person) OR start_date IS NULL
GROUP BY ALL;

INSERT INTO stg.qc
SELECT 'events_unresolved_encounter', src_type, count(*), 'warn',
       'encounter reference present but no matching visit_occurrence'
FROM stg.event_mapped
WHERE encounter_ref IS NOT NULL AND visit_occurrence_id IS NULL
GROUP BY ALL;

INSERT INTO stg.qc
SELECT 'events_without_code', src_type, count(*), 'warn', 'no coding on the code element'
FROM stg.event_mapped WHERE source_value IS NULL GROUP BY ALL;

-- Unmapped concepts (concept_id = 0). Expected (ok) when no vocabulary is loaded.
INSERT INTO stg.qc
SELECT 'concept_unmapped_pct', domain,
       round(100.0 * count(*) FILTER (WHERE concept_id = 0) / count(*), 1),
       CASE WHEN NOT v.loaded OR count(*) FILTER (WHERE concept_id = 0) = 0 THEN 'ok'
            ELSE 'warn' END,
       CASE WHEN v.loaded THEN 'percent of rows with concept_id 0'
            ELSE 'no vocabulary loaded; all concept ids are 0' END
FROM stg.event_loadable, stg.vocab_flag v GROUP BY domain, v.loaded;

INSERT INTO stg.qc
SELECT 'top_unmapped_codes', domain, n, 'warn', system || '|' || code
FROM (SELECT domain, coding->>'system' AS system, source_value AS code, count(*) AS n,
             row_number() OVER (PARTITION BY domain ORDER BY count(*) DESC) AS rk
      FROM stg.event_loadable, stg.vocab_flag v
      WHERE concept_id = 0 AND v.loaded
      GROUP BY domain, coding->>'system', source_value)
WHERE rk <= 5;

-- A hard-coded concept id that is missing, non-standard or deprecated in the loaded
-- vocabulary is an ETL bug (vocabulary releases do retire concepts).
INSERT INTO stg.qc
SELECT 'constant_concept_invalid', k.name, k.concept_id, 'fail',
       k.code || ': ' || CASE WHEN c.concept_id IS NULL THEN 'not in vocabulary'
                              WHEN c.invalid_reason IS NOT NULL THEN 'invalid_reason ' || c.invalid_reason
                              ELSE 'not standard' END
FROM stg.constant_concept k
LEFT JOIN stg.concept c ON c.concept_id = k.concept_id
WHERE (SELECT loaded FROM stg.vocab_flag)
  AND (c.concept_id IS NULL OR c.standard_concept IS DISTINCT FROM 'S' OR c.invalid_reason IS NOT NULL);

-- Referential integrity.
INSERT INTO stg.qc
SELECT 'person_orphans', t, n, CASE WHEN n = 0 THEN 'ok' ELSE 'fail' END,
       'person_id not in person'
FROM (SELECT 'visit_occurrence' AS t, n FROM person_orphans('visit_occurrence')
      UNION ALL SELECT 'condition_occurrence', n FROM person_orphans('condition_occurrence')
      UNION ALL SELECT 'drug_exposure', n FROM person_orphans('drug_exposure')
      UNION ALL SELECT 'procedure_occurrence', n FROM person_orphans('procedure_occurrence')
      UNION ALL SELECT 'device_exposure', n FROM person_orphans('device_exposure')
      UNION ALL SELECT 'measurement', n FROM person_orphans('measurement')
      UNION ALL SELECT 'observation', n FROM person_orphans('observation')
      UNION ALL SELECT 'death', n FROM person_orphans('death')
      UNION ALL SELECT 'observation_period', n FROM person_orphans('observation_period')
      UNION ALL SELECT 'condition_era', n FROM person_orphans('condition_era')
      UNION ALL SELECT 'drug_era', n FROM person_orphans('drug_era'));

-- drug_era needs CONCEPT_ANCESTOR to roll drugs up to ingredients.
INSERT INTO stg.qc
SELECT 'drug_era_skipped', 'drug_era', (SELECT count(*) FROM drug_exposure WHERE drug_concept_id <> 0),
       'warn', 'mapped drug exposures but no ingredient roll-up (CONCEPT_ANCESTOR.csv not in --vocab-dir)'
WHERE (SELECT count(*) FROM stg.ingredient) = 0
  AND (SELECT count(*) FROM drug_exposure WHERE drug_concept_id <> 0) > 0;

-- Mapped drugs with no RxNorm ingredient ancestor can't be in drug_era (e.g. CVX vaccines
-- in the 2026 Athena releases).
INSERT INTO stg.qc
SELECT 'drug_without_ingredient', 'drug_era', count(*), 'warn',
       'mapped drug exposures with no RxNorm ingredient ancestor (not in drug_era)'
FROM drug_exposure
WHERE drug_concept_id <> 0
  AND drug_concept_id NOT IN (SELECT drug_concept_id FROM stg.ingredient)
  AND (SELECT count(*) FROM stg.ingredient) > 0
HAVING count(*) > 0;

INSERT INTO stg.qc
SELECT 'visit_orphans', t, n, CASE WHEN n = 0 THEN 'ok' ELSE 'fail' END,
       'visit_occurrence_id not in visit_occurrence'
FROM (SELECT 'condition_occurrence' AS t, n FROM visit_orphans('condition_occurrence')
      UNION ALL SELECT 'drug_exposure', n FROM visit_orphans('drug_exposure')
      UNION ALL SELECT 'procedure_occurrence', n FROM visit_orphans('procedure_occurrence')
      UNION ALL SELECT 'measurement', n FROM visit_orphans('measurement')
      UNION ALL SELECT 'observation', n FROM visit_orphans('observation'));

INSERT INTO stg.qc
SELECT 'person_without_observation_period', 'observation_period', count(*),
       CASE WHEN count(*) = 0 THEN 'ok' ELSE 'warn' END, 'person has no recorded activity'
FROM person WHERE person_id NOT IN (SELECT person_id FROM observation_period);

-- Values longer than the CDM varchar(50) would be truncated or rejected by a stricter DB.
INSERT INTO stg.qc
SELECT 'source_value_too_long', domain, count(*), 'warn', 'source_value longer than 50 chars'
FROM stg.event_loadable WHERE length(source_value) > 50 GROUP BY ALL;

-- Row counts last so they read as a summary.
CREATE OR REPLACE MACRO n_rows(t) AS TABLE SELECT t AS table_name, count(*) AS n FROM query_table(t);
INSERT INTO stg.qc
SELECT 'row_count', table_name, n, 'ok', NULL FROM (
SELECT * FROM n_rows('location')
    UNION ALL SELECT * FROM n_rows('care_site')
    UNION ALL SELECT * FROM n_rows('provider')
    UNION ALL SELECT * FROM n_rows('person')
    UNION ALL SELECT * FROM n_rows('observation_period')
    UNION ALL SELECT * FROM n_rows('death')
    UNION ALL SELECT * FROM n_rows('visit_occurrence')
    UNION ALL SELECT * FROM n_rows('condition_occurrence')
    UNION ALL SELECT * FROM n_rows('drug_exposure')
    UNION ALL SELECT * FROM n_rows('procedure_occurrence')
    UNION ALL SELECT * FROM n_rows('device_exposure')
    UNION ALL SELECT * FROM n_rows('measurement')
    UNION ALL SELECT * FROM n_rows('observation')
    UNION ALL SELECT * FROM n_rows('condition_era')
    UNION ALL SELECT * FROM n_rows('drug_era')
    UNION ALL SELECT * FROM n_rows('cdm_source')
);
