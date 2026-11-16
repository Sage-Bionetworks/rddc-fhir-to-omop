-- Stage: reconcile persons with the subjects the batch's sidecar lists (--subjects).
-- person_source_value holds the sidecar's subject ID (--subject-id), so the two must match
-- one to one. Counts only: qc.csv does not list identifiers.

CREATE OR REPLACE TABLE stg.subjects AS
SELECT DISTINCT subject_id
FROM read_csv(getvariable('subjects_file'), header = true, columns = {'subject_id': 'VARCHAR'});

INSERT INTO stg.qc
SELECT 'sidecar_subjects', 'person', (SELECT count(*) FROM stg.subjects), 'ok',
       'FHIR subjects listed in the sidecar (' || getvariable('subject_id_mode') || ')';

INSERT INTO stg.qc
SELECT 'sidecar_subjects_without_person', 'person', n,
       CASE WHEN n = 0 THEN 'ok' ELSE 'fail' END,
       'subjects listed in the sidecar with no converted person'
FROM (SELECT count(*) AS n FROM stg.subjects s
      WHERE s.subject_id NOT IN (SELECT person_source_value FROM person
                                 WHERE person_source_value IS NOT NULL));

INSERT INTO stg.qc
SELECT 'persons_not_in_sidecar', 'person', n,
       CASE WHEN n = 0 THEN 'ok' ELSE 'fail' END,
       'converted persons whose subject ID the sidecar does not list'
FROM (SELECT count(*) AS n FROM person p
      WHERE p.person_source_value IS NOT NULL
        AND p.person_source_value NOT IN (SELECT subject_id FROM stg.subjects));

INSERT INTO stg.qc
SELECT 'persons_without_subject_id', 'person', n,
       CASE WHEN n = 0 THEN 'ok' ELSE 'fail' END,
       'persons with no subject ID (no Patient.identifier of the declared system)'
FROM (SELECT count(*) AS n FROM person WHERE person_source_value IS NULL);
