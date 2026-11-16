-- Stage: observation_period (one per person, spanning all of their recorded activity)
-- and cdm_source.

INSERT INTO observation_period
SELECT row_number() OVER (ORDER BY person_id)::INTEGER, person_id, min(d), max(d),
       const('type', 'ehr')
FROM (
    SELECT person_id, visit_start_date AS d FROM visit_occurrence
    UNION ALL SELECT person_id, visit_end_date FROM visit_occurrence
    UNION ALL SELECT person_id, start_date FROM stg.event_loadable
    UNION ALL SELECT person_id, end_date FROM stg.event_loadable
    UNION ALL SELECT person_id, death_date FROM death
) WHERE d IS NOT NULL
GROUP BY person_id;

INSERT INTO cdm_source
SELECT getvariable('source_name'), left(getvariable('source_abbr'), 25), getvariable('cdm_holder'),
       'FHIR R4 converted to OMOP CDM 5.4 by rddc-fhir-to-omop (DuckDB)',
       nullif(getvariable('source_reference'), ''),            -- the batch's sidecar
       'rddc-fhir-to-omop',
       coalesce(TRY_CAST(nullif(getvariable('source_release_date'), '') AS DATE), current_date),
       current_date, 'v5.4',
       const('cdm_version', '5.4'),
       coalesce((SELECT vocabulary_version FROM stg.vocabulary WHERE vocabulary_id = 'None'),
                'none');
