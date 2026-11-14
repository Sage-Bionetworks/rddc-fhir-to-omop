-- Stage: Patient, Practitioner, Organization -> person, death, location, provider, care_site.

-- First extension with the given url (FHIR extensions are a list keyed by url).
CREATE OR REPLACE MACRO fhir_ext(j, u) AS
    list_filter(json_extract(j, '$.extension[*]'), lambda e: e->>'url' = u)[1];

CREATE OR REPLACE MACRO omop_id(rt, fid) AS
    (SELECT m.omop_id FROM stg.id_map m WHERE m.resource_type = rt AND m.fhir_id = fid);

-- One location per patient (from Patient.address[0]); location_id = person_id.
INSERT INTO location
SELECT m.omop_id,
       a->'line'->>0, a->'line'->>1, a->>'city',
       CASE WHEN length(a->>'state') = 2 THEN a->>'state'
            ELSE (SELECT code FROM stg.us_state s WHERE s.name = a->>'state') END,
       left(a->>'postalCode', 9),
       NULL,
       left(concat_ws(', ', a->'line'->>0, a->>'city', a->>'state', a->>'postalCode'), 50),
       NULL,
       a->>'country',
       TRY_CAST(fhir_ext(geo, 'latitude')->>'valueDecimal' AS DOUBLE),
       TRY_CAST(fhir_ext(geo, 'longitude')->>'valueDecimal' AS DOUBLE)
FROM (SELECT id, res->'address'->0 AS a,
             fhir_ext(res->'address'->0, 'http://hl7.org/fhir/StructureDefinition/geolocation') AS geo
      FROM stg.fhir WHERE resource_type = 'Patient') p
JOIN stg.id_map m ON m.resource_type = 'Patient' AND m.fhir_id = p.id
WHERE a IS NOT NULL;

INSERT INTO care_site
SELECT m.omop_id, f.res->>'name', NULL, NULL, f.id, NULL
FROM stg.fhir f
JOIN stg.id_map m ON m.resource_type = 'Organization' AND m.fhir_id = f.id
WHERE f.resource_type = 'Organization';

INSERT INTO provider
SELECT m.omop_id,
       concat_ws(' ', f.res->'name'->0->'given'->>0, f.res->'name'->0->>'family'),
       list_filter(json_extract(f.res, '$.identifier[*]'),
                   lambda i: i->>'system' = 'http://hl7.org/fhir/sid/us-npi')[1]->>'value',
       NULL, NULL, NULL, NULL,
       const('gender', f.res->>'gender'),
       f.id, NULL, NULL, f.res->>'gender', NULL
FROM stg.fhir f
JOIN stg.id_map m ON m.resource_type = 'Practitioner' AND m.fhir_id = f.id
WHERE f.resource_type = 'Practitioner';

INSERT INTO person
SELECT m.omop_id,
       const('gender', p.gender),
       year(p.birth), month(p.birth), day(p.birth),
       p.birth::TIMESTAMP,
       const('race', p.race_code),
       const('ethnicity', p.eth_code),
       (SELECT location_id FROM location l WHERE l.location_id = m.omop_id),
       omop_id('Practitioner', resolve_ref(p.gp_ref)),
       NULL,
       p.id, p.gender, NULL,
       left(coalesce(p.race_code || ' ' || p.race_text, p.race_text), 50), NULL,
       left(coalesce(p.eth_code || ' ' || p.eth_text, p.eth_text), 50), NULL
FROM (
    SELECT id,
           res->>'gender' AS gender,
           TRY_CAST(res->>'birthDate' AS DATE) AS birth,
           res->'generalPractitioner'->0->>'reference' AS gp_ref,
           fhir_ext(fhir_ext(res, 'http://hl7.org/fhir/us/core/StructureDefinition/us-core-race'),
                    'ombCategory')->'valueCoding'->>'code' AS race_code,
           fhir_ext(fhir_ext(res, 'http://hl7.org/fhir/us/core/StructureDefinition/us-core-race'),
                    'text')->>'valueString' AS race_text,
           fhir_ext(fhir_ext(res, 'http://hl7.org/fhir/us/core/StructureDefinition/us-core-ethnicity'),
                    'ombCategory')->'valueCoding'->>'code' AS eth_code,
           fhir_ext(fhir_ext(res, 'http://hl7.org/fhir/us/core/StructureDefinition/us-core-ethnicity'),
                    'text')->>'valueString' AS eth_text
    FROM stg.fhir WHERE resource_type = 'Patient'
) p
JOIN stg.id_map m ON m.resource_type = 'Patient' AND m.fhir_id = p.id
WHERE p.birth IS NOT NULL;   -- year_of_birth is required; QC counts the drops

INSERT INTO death
SELECT m.omop_id, fhir_date(f.res->>'deceasedDateTime'), fhir_ts(f.res->>'deceasedDateTime'),
       const('type', 'ehr'), NULL, NULL, NULL
FROM stg.fhir f
JOIN stg.id_map m ON m.resource_type = 'Patient' AND m.fhir_id = f.id
WHERE f.resource_type = 'Patient' AND (f.res->>'deceasedDateTime') IS NOT NULL;
