-- Stage: clinical resources -> one normalised event table (stg.event), then concept
-- lookup (stg.event_mapped).
--
-- Each event carries a default OMOP domain from its FHIR resource type. When a vocabulary
-- is loaded, the standard concept's domain wins (OHDSI convention), e.g. a SNOMED
-- "finding" recorded as a FHIR Condition lands in observation, not condition_occurrence.
-- Without a vocabulary every event goes to its default domain with concept_id 0.

CREATE OR REPLACE MACRO first_coding(cc) AS cc->'coding'->0;

CREATE OR REPLACE TABLE stg.event AS
-- Condition
SELECT 'Condition' AS src_type, id AS fhir_id, 0 AS comp,
       res->'subject'->>'reference' AS subject_ref, res->'encounter'->>'reference' AS encounter_ref,
       coalesce(res->>'onsetDateTime', res->'onsetPeriod'->>'start', res->>'recordedDate') AS start_raw,
       coalesce(res->>'abatementDateTime', res->'abatementPeriod'->>'end') AS end_raw,
       first_coding(res->'code') AS coding,
       'Condition' AS default_domain, 'ehr' AS type_code,
       res->'clinicalStatus'->'coding'->0->>'code' AS status_source,
       NULL::JSON AS value_quantity, NULL::JSON AS value_coding, NULL AS value_string,
       NULL AS sig, NULL AS lot_number, NULL AS unique_device_id
FROM stg.fhir WHERE resource_type = 'Condition'

UNION ALL BY NAME
-- Procedure
SELECT 'Procedure' AS src_type, id AS fhir_id, 0 AS comp,
       res->'subject'->>'reference' AS subject_ref, res->'encounter'->>'reference' AS encounter_ref,
       coalesce(res->>'performedDateTime', res->'performedPeriod'->>'start') AS start_raw,
       res->'performedPeriod'->>'end' AS end_raw,
       first_coding(res->'code') AS coding,
       'Procedure' AS default_domain, 'ehr' AS type_code
FROM stg.fhir WHERE resource_type = 'Procedure'

UNION ALL BY NAME
-- MedicationRequest: inline medicationCodeableConcept, or the referenced Medication's code
SELECT 'MedicationRequest' AS src_type, r.id AS fhir_id, 0 AS comp,
       r.res->'subject'->>'reference' AS subject_ref, r.res->'encounter'->>'reference' AS encounter_ref,
       r.res->>'authoredOn' AS start_raw, NULL AS end_raw,
       coalesce(first_coding(r.res->'medicationCodeableConcept'), first_coding(med.res->'code')) AS coding,
       'Drug' AS default_domain, 'ehr_prescription' AS type_code,
       r.res->'dosageInstruction'->0->>'text' AS sig
FROM stg.fhir r
LEFT JOIN stg.fhir med ON med.resource_type = 'Medication'
      AND med.id = ref_id(r.res->'medicationReference'->>'reference')
WHERE r.resource_type = 'MedicationRequest'

UNION ALL BY NAME
SELECT 'MedicationAdministration' AS src_type, r.id AS fhir_id, 0 AS comp,
       r.res->'subject'->>'reference' AS subject_ref,
       coalesce(r.res->'context'->>'reference', r.res->'encounter'->>'reference') AS encounter_ref,
       coalesce(r.res->>'effectiveDateTime', r.res->'effectivePeriod'->>'start') AS start_raw,
       r.res->'effectivePeriod'->>'end' AS end_raw,
       coalesce(first_coding(r.res->'medicationCodeableConcept'), first_coding(med.res->'code')) AS coding,
       'Drug' AS default_domain, 'ehr_administration' AS type_code
FROM stg.fhir r
LEFT JOIN stg.fhir med ON med.resource_type = 'Medication'
      AND med.id = ref_id(r.res->'medicationReference'->>'reference')
WHERE r.resource_type = 'MedicationAdministration'

UNION ALL BY NAME
SELECT 'Immunization' AS src_type, id AS fhir_id, 0 AS comp,
       res->'patient'->>'reference' AS subject_ref, res->'encounter'->>'reference' AS encounter_ref,
       res->>'occurrenceDateTime' AS start_raw, NULL AS end_raw,
       first_coding(res->'vaccineCode') AS coding,
       'Drug' AS default_domain, 'ehr_administration' AS type_code,
       res->>'lotNumber' AS lot_number
FROM stg.fhir WHERE resource_type = 'Immunization'

UNION ALL BY NAME
-- Synthea's Device has no use period; manufactureDate is when it was assigned to the patient.
SELECT 'Device' AS src_type, id AS fhir_id, 0 AS comp,
       res->'patient'->>'reference' AS subject_ref, NULL AS encounter_ref,
       res->>'manufactureDate' AS start_raw, NULL AS end_raw,
       first_coding(res->'type') AS coding,
       'Device' AS default_domain, 'ehr' AS type_code,
       coalesce(res->'udiCarrier'->0->>'deviceIdentifier', res->>'distinctIdentifier') AS unique_device_id,
       res->>'lotNumber' AS lot_number
FROM stg.fhir WHERE resource_type = 'Device'

UNION ALL BY NAME
SELECT 'AllergyIntolerance' AS src_type, id AS fhir_id, 0 AS comp,
       res->'patient'->>'reference' AS subject_ref, res->'encounter'->>'reference' AS encounter_ref,
       coalesce(res->>'onsetDateTime', res->>'recordedDate') AS start_raw, NULL AS end_raw,
       first_coding(res->'code') AS coding,
       'Observation' AS default_domain, 'ehr' AS type_code,
       res->'clinicalStatus'->'coding'->0->>'code' AS status_source
FROM stg.fhir WHERE resource_type = 'AllergyIntolerance'

UNION ALL BY NAME
-- Observation with its own value (or no components): one event.
SELECT 'Observation' AS src_type, id AS fhir_id, 0 AS comp,
       res->'subject'->>'reference' AS subject_ref, res->'encounter'->>'reference' AS encounter_ref,
       coalesce(res->>'effectiveDateTime', res->'effectivePeriod'->>'start', res->>'issued') AS start_raw,
       NULL AS end_raw,
       first_coding(res->'code') AS coding,
       CASE WHEN (res->'valueQuantity') IS NOT NULL
              OR (res->'category'->0->'coding'->0->>'code') IN ('laboratory', 'vital-signs')
            THEN 'Measurement' ELSE 'Observation' END AS default_domain,
       'ehr' AS type_code,
       res->'valueQuantity' AS value_quantity,
       first_coding(res->'valueCodeableConcept') AS value_coding,
       coalesce(res->>'valueString', res->'valueCodeableConcept'->>'text') AS value_string
FROM stg.fhir
WHERE resource_type = 'Observation'
  AND ((res->'component') IS NULL OR (res->'valueQuantity') IS NOT NULL
       OR (res->'valueCodeableConcept') IS NOT NULL OR (res->'valueString') IS NOT NULL)

UNION ALL BY NAME
-- Observation components (e.g. blood pressure panel -> systolic + diastolic): one event each.
SELECT 'Observation' AS src_type, id AS fhir_id, comp,
       res->'subject'->>'reference' AS subject_ref, res->'encounter'->>'reference' AS encounter_ref,
       coalesce(res->>'effectiveDateTime', res->'effectivePeriod'->>'start', res->>'issued') AS start_raw,
       NULL AS end_raw,
       first_coding(c->'code') AS coding,
       CASE WHEN (c->'valueQuantity') IS NOT NULL
              OR (res->'category'->0->'coding'->0->>'code') IN ('laboratory', 'vital-signs')
            THEN 'Measurement' ELSE 'Observation' END AS default_domain,
       'ehr' AS type_code,
       c->'valueQuantity' AS value_quantity,
       first_coding(c->'valueCodeableConcept') AS value_coding,
       coalesce(c->>'valueString', c->'valueCodeableConcept'->>'text') AS value_string
FROM (SELECT id, res,
             unnest(json_extract(res, '$.component[*]')) AS c,
             generate_subscripts(json_extract(res, '$.component[*]'), 1) AS comp
      FROM stg.fhir WHERE resource_type = 'Observation' AND (res->'component') IS NOT NULL);

-- Every code we need a concept for: event codes, coded values, units.
CREATE OR REPLACE TABLE stg.code AS
SELECT DISTINCT system, code FROM (
    SELECT coding->>'system' AS system, coding->>'code' AS code FROM stg.event
    UNION ALL
    SELECT value_coding->>'system', value_coding->>'code' FROM stg.event
    UNION ALL
    SELECT coalesce(value_quantity->>'system', 'http://unitsofmeasure.org'),
           value_quantity->>'code' FROM stg.event
) WHERE code IS NOT NULL;

-- (system, code) -> source concept and its standard 'Maps to' target(s).
-- A source code can map to several standard concepts; each becomes its own OMOP row.
CREATE OR REPLACE TABLE stg.code_map AS
SELECT c.system, c.code,
       coalesce(src.concept_id, 0) AS source_concept_id,
       coalesce(tgt.concept_id, 0) AS concept_id,
       tgt.domain_id AS domain_id
FROM stg.code c
LEFT JOIN stg.system_vocab sv ON sv.system = c.system
LEFT JOIN stg.concept src ON src.vocabulary_id = sv.vocabulary_id AND src.concept_code = c.code
LEFT JOIN stg.maps_to mt ON mt.concept_id_1 = src.concept_id
LEFT JOIN stg.concept tgt ON tgt.concept_id = mt.concept_id_2 AND tgt.standard_concept = 'S';

-- Single target per code, for value_as_concept_id and unit_concept_id.
CREATE OR REPLACE TABLE stg.code_map1 AS
SELECT system, code, max(source_concept_id) AS source_concept_id, min(concept_id) AS concept_id
FROM stg.code_map GROUP BY ALL;

CREATE OR REPLACE TABLE stg.event_mapped AS
SELECT e.*,
       pm.omop_id AS person_id,
       vo.visit_occurrence_id,
       vo.provider_id,
       fhir_date(e.start_raw) AS start_date, fhir_ts(e.start_raw) AS start_datetime,
       fhir_date(e.end_raw) AS end_date, fhir_ts(e.end_raw) AS end_datetime,
       e.coding->>'code' AS source_value,
       coalesce(cm.source_concept_id, 0) AS source_concept_id,
       coalesce(cm.concept_id, 0) AS concept_id,
       CASE WHEN cm.domain_id IN ('Condition', 'Drug', 'Procedure', 'Measurement',
                                  'Observation', 'Device')
            THEN cm.domain_id ELSE e.default_domain END AS domain,
       const('type', e.type_code) AS type_concept_id,
       TRY_CAST(e.value_quantity->>'value' AS DOUBLE) AS value_number,
       coalesce(e.value_quantity->>'code', e.value_quantity->>'unit') AS unit_source_value,
       -- NULL when there is no unit at all; 0 when there is one that doesn't map.
       CASE WHEN coalesce(e.value_quantity->>'code', e.value_quantity->>'unit') IS NOT NULL
            THEN coalesce(um.concept_id, 0) END AS unit_concept_id,
       CASE WHEN coalesce(e.value_quantity->>'code', e.value_quantity->>'unit') IS NOT NULL
            THEN coalesce(um.source_concept_id, 0) END AS unit_source_concept_id,
       e.value_coding->>'code' AS value_code,
       CASE WHEN e.value_coding->>'code' IS NOT NULL
            THEN coalesce(vm.concept_id, 0) END AS value_as_concept_id
FROM stg.event e
LEFT JOIN stg.id_map pm ON pm.resource_type = 'Patient' AND pm.fhir_id = ref_id(e.subject_ref)
LEFT JOIN stg.id_map em ON em.resource_type = 'Encounter' AND em.fhir_id = ref_id(e.encounter_ref)
LEFT JOIN visit_occurrence vo ON vo.visit_occurrence_id = em.omop_id
LEFT JOIN stg.code_map cm ON cm.system = e.coding->>'system' AND cm.code = e.coding->>'code'
LEFT JOIN stg.code_map1 um
       ON um.system = coalesce(e.value_quantity->>'system', 'http://unitsofmeasure.org')
      AND um.code = e.value_quantity->>'code'
LEFT JOIN stg.code_map1 vm
       ON vm.system = e.value_coding->>'system' AND vm.code = e.value_coding->>'code';

-- Rows that can't be placed (no resolvable person, no start date) stay in event_mapped
-- for QC but are not loaded.
CREATE OR REPLACE TABLE stg.event_loadable AS
SELECT *, row_number() OVER (PARTITION BY domain
                             ORDER BY src_type, fhir_id, comp, concept_id)::INTEGER AS row_id
FROM stg.event_mapped
WHERE person_id IN (SELECT person_id FROM person) AND start_date IS NOT NULL;
