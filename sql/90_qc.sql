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
SELECT 'deceased_without_date', 'death', count(*), 'warn',
       'Patient.deceasedBoolean is true with no date: no death row (death_date is required)'
FROM stg.fhir
WHERE resource_type = 'Patient' AND (res->>'deceasedBoolean') = 'true'
HAVING count(*) > 0;

INSERT INTO stg.qc
SELECT 'encounters_excluded_status', 'visit_occurrence', count(*), 'warn',
       'not loaded: Encounter.status ' || (res->>'status')
FROM stg.fhir
WHERE resource_type = 'Encounter'
  AND (res->>'status') IN (SELECT code FROM stg.status_exclude
                           WHERE src_type = 'Encounter' AND field = 'status')
GROUP BY res->>'status';

-- Records left out on purpose: they did not happen, or were entered in error.
INSERT INTO stg.qc
SELECT 'events_excluded_status', src_type, count(*), 'warn',
       'not loaded: ' || concat_ws(', ', 'status ' || status_raw, 'verificationStatus ' || verif_raw)
FROM stg.event_mapped WHERE excluded GROUP BY ALL;

INSERT INTO stg.qc
SELECT 'events_unplaced', src_type, count(*), 'warn',
       CASE WHEN person_id IS NULL THEN 'subject does not resolve to a person'
            ELSE 'no start date (none on the record or its encounter)' END
FROM stg.event_mapped
WHERE NOT excluded
  AND (person_id IS NULL OR person_id NOT IN (SELECT person_id FROM person) OR start_date IS NULL)
GROUP BY ALL;

-- The share of each resource type's records that could not be loaded. Above
-- --max-unplaced-pct this is a failure: the OMOP output is missing a material part of the
-- source (e.g. every Condition, when none has a usable date).
INSERT INTO stg.qc
SELECT 'events_unplaced_pct', src_type, round(100.0 * n_unplaced / n, 1),
       CASE WHEN n_unplaced = 0 THEN 'ok'
            WHEN 100.0 * n_unplaced / n > getvariable('max_unplaced_pct') THEN 'fail'
            ELSE 'warn' END,
       n_unplaced || ' of ' || n || ' records not loaded (no person or no date); limit '
           || getvariable('max_unplaced_pct') || '%'
FROM (SELECT src_type, count(*) AS n,
             count(*) FILTER (WHERE person_id IS NULL OR start_date IS NULL
                              OR person_id NOT IN (SELECT person_id FROM person)) AS n_unplaced
      FROM stg.event_mapped WHERE NOT excluded GROUP BY src_type);

INSERT INTO stg.qc
SELECT 'events_dated_from_encounter', src_type, count(*), 'warn',
       'no date on the record: the encounter start was used'
FROM stg.event_loadable WHERE date_from_encounter GROUP BY ALL;

INSERT INTO stg.qc
SELECT 'events_partial_date', src_type, count(*), 'warn',
       'year or year-month only: the first day of the period was used'
FROM stg.event_loadable WHERE fhir_partial(start_raw) GROUP BY ALL;

INSERT INTO stg.qc
SELECT 'events_unresolved_encounter', src_type, count(*), 'warn',
       'encounter reference present but no matching visit_occurrence'
FROM stg.event_mapped
WHERE encounter_ref IS NOT NULL AND visit_occurrence_id IS NULL
GROUP BY ALL;

INSERT INTO stg.qc
SELECT 'events_without_code', src_type, count(*), 'warn', 'no coding on the code element'
FROM stg.event_mapped WHERE source_code IS NULL AND NOT excluded GROUP BY ALL;

-- Unmapped concepts (concept_id = 0). Expected (ok) when no vocabulary is loaded.
INSERT INTO stg.qc
SELECT 'concept_unmapped_pct', domain,
       round(100.0 * count(*) FILTER (WHERE concept_id = 0) / count(*), 1),
       CASE WHEN NOT v.loaded OR count(*) FILTER (WHERE concept_id = 0) = 0 THEN 'ok'
            WHEN 100.0 * count(*) FILTER (WHERE concept_id = 0) / count(*)
                 > getvariable('max_unmapped_pct') THEN 'fail'
            ELSE 'warn' END,
       CASE WHEN v.loaded THEN 'percent of rows with concept_id 0; limit '
                               || getvariable('max_unmapped_pct') || '%'
            ELSE 'no vocabulary loaded; all concept ids are 0' END
FROM stg.event_loadable, stg.vocab_flag v GROUP BY domain, v.loaded;

INSERT INTO stg.qc
SELECT 'unit_unmapped_pct', domain,
       round(100.0 * count(*) FILTER (WHERE unit_concept_id = 0) / count(*), 1),
       CASE WHEN count(*) FILTER (WHERE unit_concept_id = 0) = 0 THEN 'ok' ELSE 'warn' END,
       'percent of rows with a unit whose unit_concept_id is 0'
FROM stg.event_loadable, stg.vocab_flag v
WHERE v.loaded AND unit_source_value IS NOT NULL AND domain IN ('Measurement', 'Observation')
GROUP BY domain;

-- Code systems the pipeline has no vocabulary for: candidates for the source config
-- (systems.csv for a system that is a standard vocabulary under another URI,
-- concept_map.csv for local codes).
INSERT INTO stg.qc
SELECT 'code_system_unrecognised', coalesce(system, '(no system)'), n, 'warn',
       'records whose code is in a code system with no vocabulary (see README: source config)'
FROM (SELECT code_system AS system, count(*) AS n
      FROM stg.event_loadable
      WHERE source_code IS NOT NULL
        AND coalesce(code_system, '') NOT IN (SELECT system FROM stg.system_vocab_eff)
        AND (coalesce(code_system, ''), source_code) NOT IN (SELECT (system, code) FROM stg.source_code_map)
      GROUP BY code_system ORDER BY n DESC LIMIT 15);

-- The source config in use, and entries in it that the loaded vocabulary cannot resolve
-- (a wrong vocabulary_id or concept_code is a config bug).
INSERT INTO stg.qc
SELECT 'source_config', 'config',
       (SELECT count(*) FROM stg.source_system) + (SELECT count(*) FROM stg.source_code_map),
       'ok',
       CASE WHEN getvariable('source_config') = '' THEN 'none: default code systems only'
            ELSE getvariable('source_config_name') || ': ' || (SELECT count(*) FROM stg.source_system)
                 || ' code systems, ' || (SELECT count(*) FROM stg.source_code_map) || ' code translations' END;

INSERT INTO stg.qc
SELECT 'source_config_invalid', 'systems.csv', count(*), 'fail',
       'unknown match mode or vocabulary_id not in the loaded vocabulary: ' || string_agg(system, ' ')
FROM stg.source_system s, stg.vocab_flag v
WHERE s.match NOT IN ('exact', 'nodot', 'curie_underscore', 'strip_prefix')
   OR (v.loaded AND s.vocabulary_id NOT IN (SELECT vocabulary_id FROM stg.concept))
HAVING count(*) > 0;

INSERT INTO stg.qc
SELECT 'source_config_invalid', 'concept_map.csv', count(*), 'fail',
       'targets not in the loaded vocabulary, e.g. ' || string_agg(m.vocabulary_id || '|' || m.concept_code, ' ' ORDER BY m.system, m.code)
           FILTER (WHERE rn <= 5)
FROM (SELECT *, row_number() OVER (ORDER BY system, code) AS rn FROM stg.source_code_map m
      WHERE (SELECT loaded FROM stg.vocab_flag)
        AND NOT EXISTS (SELECT 1 FROM stg.concept c WHERE c.vocabulary_id = m.vocabulary_id
                                                      AND c.concept_code = m.concept_code)) m
HAVING count(*) > 0;

INSERT INTO stg.qc
SELECT 'top_unmapped_codes', domain, n, 'warn', system || '|' || code
FROM (SELECT domain, code_system AS system, source_value AS code, count(*) AS n,
             row_number() OVER (PARTITION BY domain ORDER BY count(*) DESC) AS rk
      FROM stg.event_loadable, stg.vocab_flag v
      WHERE concept_id = 0 AND v.loaded
      GROUP BY domain, code_system, source_value)
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
