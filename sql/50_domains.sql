-- Stage: route stg.event_loadable rows into the OMOP domain tables by `domain`.
-- Optional concept fields with no source data are NULL, not 0: OHDSI uses 0 for "a source
-- value exists but has no standard concept", and DQD counts 0s as unmapped records.
-- Drug end dates are required in CDM 5.4; FHIR rarely carries them, so they default
-- to the start date (OHDSI convention when days_supply is unknown).

INSERT INTO condition_occurrence
SELECT row_id, person_id, concept_id, start_date, start_datetime, end_date, end_datetime,
       type_concept_id, NULL, NULL, provider_id, visit_occurrence_id, NULL,
       source_value, source_concept_id, status_source
FROM stg.event_loadable WHERE domain = 'Condition';

INSERT INTO procedure_occurrence
SELECT row_id, person_id, concept_id, start_date, start_datetime, end_date, end_datetime,
       type_concept_id, NULL, NULL, provider_id, visit_occurrence_id, NULL,
       source_value, source_concept_id, NULL
FROM stg.event_loadable WHERE domain = 'Procedure';

INSERT INTO drug_exposure
SELECT row_id, person_id, concept_id, start_date, start_datetime,
       coalesce(end_date, start_date), coalesce(end_datetime, start_datetime), end_date,
       type_concept_id, NULL, NULL, NULL, NULL, sig, NULL, lot_number,
       provider_id, visit_occurrence_id, NULL, source_value, source_concept_id, NULL, NULL
FROM stg.event_loadable WHERE domain = 'Drug';

INSERT INTO device_exposure
SELECT row_id, person_id, concept_id, start_date, start_datetime, end_date, end_datetime,
       type_concept_id, unique_device_id, lot_number, NULL, provider_id,
       visit_occurrence_id, NULL, source_value, source_concept_id, NULL, NULL, NULL
FROM stg.event_loadable WHERE domain = 'Device';

INSERT INTO measurement
SELECT row_id, person_id, concept_id, start_date, start_datetime,
       strftime(start_datetime, '%H:%M:%S'),
       type_concept_id, NULL, value_number, value_as_concept_id, unit_concept_id,
       NULL, NULL, provider_id, visit_occurrence_id, NULL,
       source_value, source_concept_id, unit_source_value, unit_source_concept_id,
       left(coalesce(value_code, value_number::VARCHAR), 50), NULL, NULL
FROM stg.event_loadable WHERE domain = 'Measurement';

INSERT INTO observation
SELECT row_id, person_id, concept_id, start_date, start_datetime, type_concept_id,
       value_number, left(value_string, 60), value_as_concept_id, NULL, unit_concept_id,
       provider_id, visit_occurrence_id, NULL,
       source_value, source_concept_id, unit_source_value, NULL,
       left(coalesce(value_code, value_number::VARCHAR, value_string), 50), NULL, NULL
FROM stg.event_loadable WHERE domain = 'Observation';
