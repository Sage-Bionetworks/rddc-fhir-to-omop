-- Stage: clinical resources -> one normalised event table (stg.event), then concept
-- lookup (stg.event_mapped).
--
-- Each event carries a default OMOP domain from its FHIR resource type. When a vocabulary
-- is loaded, the standard concept's domain wins (OHDSI convention), e.g. a SNOMED
-- "finding" recorded as a FHIR Condition lands in observation, not condition_occurrence.
-- Without a vocabulary every event goes to its default domain with concept_id 0.
--
-- `codings` holds every coding of the event's CodeableConcept; the one used is chosen after
-- the vocabulary lookup (stg.event_pick). status_raw / verif_raw decide whether the record
-- is loaded at all (stg.status_exclude).

CREATE OR REPLACE MACRO first_coding(cc) AS cc->'coding'->0;

-- Medication resources as (id -> codings). A Medication with no code of its own but with
-- ingredients (a mix) gives one row per ingredient, from the ingredient's own
-- CodeableConcept or the Medication it references.
CREATE OR REPLACE TABLE stg.medication_code AS
SELECT id, 0 AS comp, res->'code'->'coding' AS codings, res->'code'->>'text' AS code_text
FROM stg.fhir WHERE resource_type = 'Medication' AND (res->'code') IS NOT NULL
UNION ALL
SELECT i.id, i.comp,
       coalesce(i.ing->'itemCodeableConcept'->'coding', im.res->'code'->'coding'),
       coalesce(i.ing->'itemCodeableConcept'->>'text', im.res->'code'->>'text')
FROM (SELECT id, unnest(json_extract(res, '$.ingredient[*]')) AS ing,
             generate_subscripts(json_extract(res, '$.ingredient[*]'), 1) AS comp
      FROM stg.fhir WHERE resource_type = 'Medication' AND (res->'code') IS NULL) i
LEFT JOIN stg.fhir im ON im.resource_type = 'Medication'
      AND im.id = ref_id(i.ing->'itemReference'->>'reference');

CREATE OR REPLACE TABLE stg.event AS
SELECT row_number() OVER () AS eid, * FROM (
-- Condition
SELECT 'Condition' AS src_type, id AS fhir_id, 0 AS comp,
       res->'subject'->>'reference' AS subject_ref, res->'encounter'->>'reference' AS encounter_ref,
       coalesce(res->>'onsetDateTime', res->'onsetPeriod'->>'start', res->>'recordedDate') AS start_raw,
       coalesce(res->>'abatementDateTime', res->'abatementPeriod'->>'end') AS end_raw,
       res->'code'->'coding' AS codings, res->'code'->>'text' AS code_text,
       'Condition' AS default_domain, 'ehr' AS type_code,
       NULL AS status_raw, res->'verificationStatus'->'coding'->0->>'code' AS verif_raw,
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
       res->'code'->'coding' AS codings, res->'code'->>'text' AS code_text,
       'Procedure' AS default_domain, 'ehr' AS type_code, res->>'status' AS status_raw
FROM stg.fhir WHERE resource_type = 'Procedure'

UNION ALL BY NAME
-- MedicationRequest: inline medicationCodeableConcept, else the Medication it references
-- (contained in the request, or a resource of its own).
SELECT 'MedicationRequest' AS src_type, r.id AS fhir_id, coalesce(med.comp, 0) AS comp,
       r.res->'subject'->>'reference' AS subject_ref, r.res->'encounter'->>'reference' AS encounter_ref,
       r.res->>'authoredOn' AS start_raw, NULL AS end_raw,
       coalesce(r.res->'medicationCodeableConcept'->'coding',
                contained_res(r.res, r.res->'medicationReference'->>'reference')->'code'->'coding',
                med.codings) AS codings,
       coalesce(r.res->'medicationCodeableConcept'->>'text',
                contained_res(r.res, r.res->'medicationReference'->>'reference')->'code'->>'text',
                med.code_text) AS code_text,
       'Drug' AS default_domain, 'ehr_prescription' AS type_code, r.res->>'status' AS status_raw,
       r.res->'dosageInstruction'->0->>'text' AS sig
FROM stg.fhir r
LEFT JOIN stg.medication_code med ON med.id = ref_id(r.res->'medicationReference'->>'reference')
WHERE r.resource_type = 'MedicationRequest'

UNION ALL BY NAME
SELECT 'MedicationAdministration' AS src_type, r.id AS fhir_id, coalesce(med.comp, 0) AS comp,
       r.res->'subject'->>'reference' AS subject_ref,
       coalesce(r.res->'context'->>'reference', r.res->'encounter'->>'reference') AS encounter_ref,
       coalesce(r.res->>'effectiveDateTime', r.res->'effectivePeriod'->>'start') AS start_raw,
       r.res->'effectivePeriod'->>'end' AS end_raw,
       coalesce(r.res->'medicationCodeableConcept'->'coding',
                contained_res(r.res, r.res->'medicationReference'->>'reference')->'code'->'coding',
                med.codings) AS codings,
       coalesce(r.res->'medicationCodeableConcept'->>'text',
                contained_res(r.res, r.res->'medicationReference'->>'reference')->'code'->>'text',
                med.code_text) AS code_text,
       'Drug' AS default_domain, 'ehr_administration' AS type_code, r.res->>'status' AS status_raw
FROM stg.fhir r
LEFT JOIN stg.medication_code med ON med.id = ref_id(r.res->'medicationReference'->>'reference')
WHERE r.resource_type = 'MedicationAdministration'

UNION ALL BY NAME
SELECT 'Immunization' AS src_type, id AS fhir_id, 0 AS comp,
       res->'patient'->>'reference' AS subject_ref, res->'encounter'->>'reference' AS encounter_ref,
       res->>'occurrenceDateTime' AS start_raw, NULL AS end_raw,
       res->'vaccineCode'->'coding' AS codings, res->'vaccineCode'->>'text' AS code_text,
       'Drug' AS default_domain, 'ehr_administration' AS type_code, res->>'status' AS status_raw,
       res->>'lotNumber' AS lot_number
FROM stg.fhir WHERE resource_type = 'Immunization'

UNION ALL BY NAME
-- Synthea's Device has no use period; manufactureDate is when it was assigned to the patient.
SELECT 'Device' AS src_type, id AS fhir_id, 0 AS comp,
       res->'patient'->>'reference' AS subject_ref, NULL AS encounter_ref,
       res->>'manufactureDate' AS start_raw, NULL AS end_raw,
       res->'type'->'coding' AS codings, res->'type'->>'text' AS code_text,
       'Device' AS default_domain, 'ehr' AS type_code, res->>'status' AS status_raw,
       coalesce(res->'udiCarrier'->0->>'deviceIdentifier', res->>'distinctIdentifier') AS unique_device_id,
       res->>'lotNumber' AS lot_number
FROM stg.fhir WHERE resource_type = 'Device'

UNION ALL BY NAME
SELECT 'AllergyIntolerance' AS src_type, id AS fhir_id, 0 AS comp,
       res->'patient'->>'reference' AS subject_ref, res->'encounter'->>'reference' AS encounter_ref,
       coalesce(res->>'onsetDateTime', res->>'recordedDate') AS start_raw, NULL AS end_raw,
       res->'code'->'coding' AS codings, res->'code'->>'text' AS code_text,
       'Observation' AS default_domain, 'ehr' AS type_code,
       res->'verificationStatus'->'coding'->0->>'code' AS verif_raw,
       res->'clinicalStatus'->'coding'->0->>'code' AS status_source
FROM stg.fhir WHERE resource_type = 'AllergyIntolerance'

UNION ALL BY NAME
-- Observation with its own value (or no components): one event.
SELECT 'Observation' AS src_type, id AS fhir_id, 0 AS comp,
       res->'subject'->>'reference' AS subject_ref, res->'encounter'->>'reference' AS encounter_ref,
       coalesce(res->>'effectiveDateTime', res->'effectivePeriod'->>'start', res->>'issued') AS start_raw,
       NULL AS end_raw,
       res->'code'->'coding' AS codings, res->'code'->>'text' AS code_text,
       CASE WHEN (res->'valueQuantity') IS NOT NULL
              OR (res->'category'->0->'coding'->0->>'code') IN ('laboratory', 'vital-signs')
            THEN 'Measurement' ELSE 'Observation' END AS default_domain,
       'ehr' AS type_code, res->>'status' AS status_raw,
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
       c->'code'->'coding' AS codings, c->'code'->>'text' AS code_text,
       CASE WHEN (c->'valueQuantity') IS NOT NULL
              OR (res->'category'->0->'coding'->0->>'code') IN ('laboratory', 'vital-signs')
            THEN 'Measurement' ELSE 'Observation' END AS default_domain,
       'ehr' AS type_code, res->>'status' AS status_raw,
       c->'valueQuantity' AS value_quantity,
       first_coding(c->'valueCodeableConcept') AS value_coding,
       coalesce(c->>'valueString', c->'valueCodeableConcept'->>'text') AS value_string
FROM (SELECT id, res,
             unnest(json_extract(res, '$.component[*]')) AS c,
             generate_subscripts(json_extract(res, '$.component[*]'), 1) AS comp
      FROM stg.fhir WHERE resource_type = 'Observation' AND (res->'component') IS NOT NULL)
);

-- Every coding of every event, in the order the source gave them.
CREATE OR REPLACE TABLE stg.event_coding AS
SELECT eid, idx, c->>'system' AS system, c->>'code' AS code
FROM (SELECT eid, unnest(json_extract(codings, '$[*]')) AS c,
             generate_subscripts(json_extract(codings, '$[*]'), 1) AS idx
      FROM stg.event WHERE codings IS NOT NULL)
WHERE (c->>'code') IS NOT NULL;

-- A unit is looked up by its UCUM code, or by the unit text when there is no code.
CREATE OR REPLACE MACRO unit_system(q) AS coalesce(q->>'system', 'http://unitsofmeasure.org');
CREATE OR REPLACE MACRO unit_code(q) AS coalesce(q->>'code', q->>'unit');

-- Every code we need a concept for: event codes, coded values, units.
CREATE OR REPLACE TABLE stg.code AS
SELECT DISTINCT system, code FROM (
    SELECT system, code FROM stg.event_coding
    UNION ALL
    SELECT value_coding->>'system', value_coding->>'code' FROM stg.event
    UNION ALL
    SELECT unit_system(value_quantity), unit_code(value_quantity) FROM stg.event
) WHERE code IS NOT NULL;

-- Code system -> vocabulary: the source's own systems first, then the defaults.
CREATE OR REPLACE TABLE stg.system_vocab_eff AS
SELECT system, vocabulary_id, match, 'source config' AS origin FROM stg.source_system
UNION ALL
SELECT system, vocabulary_id, match, 'default' FROM stg.system_vocab
WHERE system NOT IN (SELECT system FROM stg.source_system);

-- (system, code) -> the Athena (vocabulary, code) to look up: a single-code translation
-- from the source config if there is one, else the system's vocabulary.
CREATE OR REPLACE TABLE stg.code_target AS
SELECT c.system, c.code,
       coalesce(m.vocabulary_id, sv.vocabulary_id) AS vocabulary_id,
       CASE WHEN m.code IS NOT NULL THEN 'exact' ELSE coalesce(sv.match, 'exact') END AS match,
       coalesce(m.concept_code, ua.athena_code, c.code) AS lookup_code
FROM stg.code c
LEFT JOIN stg.source_code_map m ON m.system = c.system AND m.code = c.code
LEFT JOIN stg.system_vocab_eff sv ON sv.system = c.system
LEFT JOIN stg.ucum_alias ua ON m.code IS NULL AND sv.vocabulary_id = 'UCUM' AND ua.code = c.code;

-- The concepts of the vocabularies in use, keyed the way each match mode compares codes.
-- One concept per key: a valid one before a deprecated one.
CREATE OR REPLACE TABLE stg.concept_key AS
SELECT DISTINCT ON (vocabulary_id, match, key) vocabulary_id, match, key, concept_id
FROM (SELECT c.vocabulary_id, m.match, code_norm(m.match, c.concept_code) AS key, c.concept_id,
             c.invalid_reason, c.standard_concept
      FROM stg.concept c
      JOIN (SELECT DISTINCT vocabulary_id, match FROM stg.code_target
            WHERE vocabulary_id IS NOT NULL) m ON m.vocabulary_id = c.vocabulary_id)
ORDER BY vocabulary_id, match, key, invalid_reason IS NOT NULL,
         standard_concept IS DISTINCT FROM 'S', concept_id;

-- (system, code) -> source concept and its standard 'Maps to' target(s).
-- A source code can map to several standard concepts; each becomes its own OMOP row.
CREATE OR REPLACE TABLE stg.code_map AS
SELECT t.system, t.code, t.vocabulary_id,
       coalesce(k.concept_id, 0) AS source_concept_id,
       coalesce(tgt.concept_id, 0) AS concept_id,
       tgt.domain_id AS domain_id
FROM stg.code_target t
LEFT JOIN stg.concept_key k ON k.vocabulary_id = t.vocabulary_id AND k.match = t.match
      AND k.key = code_norm(t.match, t.lookup_code)
LEFT JOIN (SELECT mt.concept_id_1, c.concept_id, c.domain_id
           FROM stg.maps_to mt
           JOIN stg.concept c ON c.concept_id = mt.concept_id_2 AND c.standard_concept = 'S') tgt
       ON tgt.concept_id_1 = k.concept_id;

-- Single target per code, for value_as_concept_id and unit_concept_id.
CREATE OR REPLACE TABLE stg.code_map1 AS
SELECT system, code, max(source_concept_id) AS source_concept_id, min(concept_id) AS concept_id
FROM stg.code_map GROUP BY ALL;

-- The coding each event is mapped by: the first one with a standard concept, else the
-- first one known to the vocabulary, else the first one. Real feeds often put a local code
-- first and the SNOMED / ICD / LOINC code after it.
CREATE OR REPLACE TABLE stg.event_pick AS
SELECT ec.eid, ec.system, ec.code
FROM stg.event_coding ec
LEFT JOIN (SELECT system, code,
                  max(CASE WHEN concept_id <> 0 THEN 2 WHEN source_concept_id <> 0 THEN 1 ELSE 0 END) AS score
           FROM stg.code_map GROUP BY ALL) s ON s.system = ec.system AND s.code = ec.code
QUALIFY row_number() OVER (PARTITION BY ec.eid ORDER BY coalesce(s.score, 0) DESC, ec.idx) = 1;

CREATE OR REPLACE TABLE stg.event_mapped AS
SELECT e.*,
       pm.omop_id AS person_id,
       vo.visit_occurrence_id,
       vo.provider_id,
       -- A record with no date of its own takes its encounter's start (e.g. encounter
       -- diagnoses, which often carry only the encounter reference).
       coalesce(fhir_date(e.start_raw), vo.visit_start_date) AS start_date,
       coalesce(fhir_ts(e.start_raw), vo.visit_start_datetime) AS start_datetime,
       fhir_date(e.start_raw) IS NULL AND vo.visit_start_date IS NOT NULL AS date_from_encounter,
       fhir_date(e.end_raw) AS end_date, fhir_ts(e.end_raw) AS end_datetime,
       pk.system AS code_system,
       pk.code AS source_code,
       coalesce(pk.code, left(e.code_text, 50)) AS source_value,
       coalesce(cm.source_concept_id, 0) AS source_concept_id,
       coalesce(cm.concept_id, 0) AS concept_id,
       CASE WHEN cm.domain_id IN ('Condition', 'Drug', 'Procedure', 'Measurement',
                                  'Observation', 'Device')
            THEN cm.domain_id ELSE e.default_domain END AS domain,
       const('type', e.type_code) AS type_concept_id,
       TRY_CAST(e.value_quantity->>'value' AS DOUBLE) AS value_number,
       unit_code(e.value_quantity) AS unit_source_value,
       -- NULL when there is no unit at all; 0 when there is one that doesn't map.
       CASE WHEN unit_code(e.value_quantity) IS NOT NULL
            THEN coalesce(um.concept_id, 0) END AS unit_concept_id,
       CASE WHEN unit_code(e.value_quantity) IS NOT NULL
            THEN coalesce(um.source_concept_id, 0) END AS unit_source_concept_id,
       e.value_coding->>'code' AS value_code,
       CASE WHEN e.value_coding->>'code' IS NOT NULL
            THEN coalesce(vm.concept_id, 0) END AS value_as_concept_id,
       (xs.code IS NOT NULL OR xv.code IS NOT NULL) AS excluded
FROM stg.event e
LEFT JOIN stg.id_map pm ON pm.resource_type = 'Patient' AND pm.fhir_id = ref_id(e.subject_ref)
LEFT JOIN stg.id_map em ON em.resource_type = 'Encounter' AND em.fhir_id = ref_id(e.encounter_ref)
LEFT JOIN visit_occurrence vo ON vo.visit_occurrence_id = em.omop_id
LEFT JOIN stg.event_pick pk ON pk.eid = e.eid
LEFT JOIN stg.code_map cm ON cm.system = pk.system AND cm.code = pk.code
LEFT JOIN stg.code_map1 um
       ON um.system = unit_system(e.value_quantity) AND um.code = unit_code(e.value_quantity)
LEFT JOIN stg.code_map1 vm
       ON vm.system = e.value_coding->>'system' AND vm.code = e.value_coding->>'code'
LEFT JOIN stg.status_exclude xs
       ON xs.src_type = e.src_type AND xs.field = 'status' AND xs.code = e.status_raw
LEFT JOIN stg.status_exclude xv
       ON xv.src_type = e.src_type AND xv.field = 'verificationStatus' AND xv.code = e.verif_raw;

-- Rows that can't be placed (no resolvable person, no start date) and rows excluded by
-- their status stay in event_mapped for QC but are not loaded.
CREATE OR REPLACE TABLE stg.event_loadable AS
SELECT *, row_number() OVER (PARTITION BY domain
                             ORDER BY src_type, fhir_id, comp, concept_id)::INTEGER AS row_id
FROM stg.event_mapped
WHERE person_id IN (SELECT person_id FROM person) AND start_date IS NOT NULL AND NOT excluded;
