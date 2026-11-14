-- Stage 1: load every FHIR resource as raw JSON into stg.fhir.
--
-- Reads either bulk-export NDJSON (one resource per line) or per-patient
-- Bundle JSON (Synthea's default). Bundles are flattened into their entries.
-- Resources stay untyped JSON, so a missing resource type or a new field never
-- breaks the load; each mapping stage extracts only what it needs.
CREATE SCHEMA IF NOT EXISTS stg;

CREATE OR REPLACE TABLE stg.fhir AS
WITH raw AS (
    SELECT json AS res
    FROM read_json_objects(getvariable('fhir_glob'), format = 'auto',
                           maximum_object_size = getvariable('max_object_size'))
),
flat AS (
    SELECT res FROM raw WHERE res->>'resourceType' <> 'Bundle'
    UNION ALL
    SELECT unnest(json_extract(res, '$.entry[*].resource')) AS res
    FROM raw WHERE res->>'resourceType' = 'Bundle'
)
SELECT res->>'resourceType' AS resource_type, res->>'id' AS id, res
FROM flat;

-- Integer surrogate keys for every resource we turn into an OMOP row with its own id.
-- Deterministic (ordered by FHIR id) so reruns over the same input give the same ids.
-- Exported as source_id_map for provenance back to FHIR.
CREATE OR REPLACE TABLE stg.id_map AS
SELECT resource_type, id AS fhir_id,
       row_number() OVER (PARTITION BY resource_type ORDER BY id)::INTEGER AS omop_id
FROM (SELECT DISTINCT resource_type, id FROM stg.fhir
      WHERE resource_type IN ('Patient', 'Encounter', 'Practitioner', 'Organization')
        AND id IS NOT NULL);

-- Conditional references (Practitioner?identifier=system|value), as Synthea uses for
-- practitioners, organizations and locations, resolve through their identifiers.
CREATE OR REPLACE TABLE stg.identifier_ref AS
SELECT DISTINCT ON (ref) ref, resource_type, id
FROM (
    SELECT resource_type || '?identifier=' || (i->>'system') || '|' || (i->>'value') AS ref,
           resource_type, id
    FROM (SELECT resource_type, id, unnest(json_extract(res, '$.identifier[*]')) AS i
          FROM stg.fhir
          WHERE resource_type IN ('Patient', 'Practitioner', 'Organization', 'Location'))
)
ORDER BY ref, id;

-- FHIR id from a literal reference: "Patient/abc", "urn:uuid:abc", or an absolute URL.
-- Conditional references return NULL here; join stg.identifier_ref for those.
CREATE OR REPLACE MACRO ref_id(r) AS CASE
    WHEN r IS NULL OR r LIKE '%?%' THEN NULL
    WHEN r LIKE 'urn:uuid:%' THEN substr(r, 10)
    ELSE split_part(r, '/', -1)
END;

CREATE OR REPLACE MACRO resolve_ref(r) AS
    coalesce(ref_id(r), (SELECT x.id FROM stg.identifier_ref x WHERE x.ref = r));

-- FHIR dateTime -> OMOP DATE / TIMESTAMP. Keeps the local wall-clock time and drops the
-- UTC offset, so the date and datetime columns always agree.
CREATE OR REPLACE MACRO fhir_date(s) AS TRY_CAST(substr(s, 1, 10) AS DATE);
CREATE OR REPLACE MACRO fhir_ts(s) AS
    CASE WHEN length(s) >= 19 THEN TRY_CAST(replace(substr(s, 1, 19), 'T', ' ') AS TIMESTAMP)
         ELSE TRY_CAST(fhir_date(s) AS TIMESTAMP) END;
