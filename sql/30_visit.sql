-- Stage: Encounter -> visit_occurrence.
-- provider/care_site come from the first participant and serviceProvider, which Synthea
-- writes as conditional references (resolved through stg.identifier_ref).
INSERT INTO visit_occurrence
SELECT m.omop_id, p.person_id,
       const('visit', e.cls),
       fhir_date(e.s), fhir_ts(e.s),
       coalesce(fhir_date(e.e), fhir_date(e.s)), coalesce(fhir_ts(e.e), fhir_ts(e.s)),
       const('type', 'ehr'),
       omop_id('Practitioner', resolve_ref(e.practitioner_ref)),
       omop_id('Organization', resolve_ref(e.org_ref)),
       e.cls, 0,
       0, NULL, 0, NULL,
       lag(m.omop_id) OVER (PARTITION BY p.person_id ORDER BY fhir_ts(e.s), m.omop_id)
FROM (
    SELECT id,
           res->'class'->>'code' AS cls,
           res->'period'->>'start' AS s,
           res->'period'->>'end' AS e,
           ref_id(res->'subject'->>'reference') AS patient_id,
           res->'participant'->0->'individual'->>'reference' AS practitioner_ref,
           res->'serviceProvider'->>'reference' AS org_ref
    FROM stg.fhir WHERE resource_type = 'Encounter'
) e
JOIN stg.id_map m ON m.resource_type = 'Encounter' AND m.fhir_id = e.id
JOIN stg.id_map pm ON pm.resource_type = 'Patient' AND pm.fhir_id = e.patient_id
JOIN person p ON p.person_id = pm.omop_id
WHERE fhir_date(e.s) IS NOT NULL;
