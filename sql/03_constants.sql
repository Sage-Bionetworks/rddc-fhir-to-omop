-- Fixed concept ids and code-system lookups. All of these are standard OMOP concepts;
-- when a vocabulary is loaded, QC fails any that are missing, non-standard or deprecated
-- (check: constant_concept_invalid).

-- FHIR code system URI -> OMOP vocabulary_id: the defaults for every source. A source
-- config (--source-config, sql/04_source_*.sql) adds to these or replaces them per system.
-- `match` says how a FHIR code is compared with Athena's concept_code (macro code_norm):
--   exact             as written
--   nodot             ignoring dots: sources often send ICD codes as "E119" for "E11.9"
--   curie_underscore  ":" and "_" are the same: FHIR "HP:0000118", Athena "HP_0000118"
--   strip_prefix      only the part after the last ":": FHIR "ORPHA:558", Athena "558"
CREATE OR REPLACE TABLE stg.system_vocab (system VARCHAR, vocabulary_id VARCHAR, match VARCHAR);
INSERT INTO stg.system_vocab VALUES
    ('http://snomed.info/sct',                      'SNOMED',    'exact'),
    ('http://loinc.org',                            'LOINC',     'exact'),
    ('http://www.nlm.nih.gov/research/umls/rxnorm', 'RxNorm',    'exact'),
    ('http://hl7.org/fhir/sid/cvx',                 'CVX',       'exact'),
    ('http://hl7.org/fhir/sid/ndc',                 'NDC',       'exact'),
    ('http://hl7.org/fhir/sid/icd-10-cm',           'ICD10CM',   'exact'),
    ('http://hl7.org/fhir/sid/icd-10',              'ICD10',     'exact'),
    ('http://hl7.org/fhir/sid/icd-9-cm',            'ICD9CM',    'exact'),
    ('http://www.cms.gov/Medicare/Coding/ICD10',    'ICD10PCS',  'exact'),
    ('http://www.ama-assn.org/go/cpt',              'CPT4',      'exact'),
    ('http://www.cms.gov/Medicare/Coding/HCPCSReleaseCodeSets', 'HCPCS', 'exact'),
    ('http://unitsofmeasure.org',                   'UCUM',      'exact'),
    -- rare-disease terminologies (non-standard in OMOP; the source concept is kept, and
    -- the standard concept where Athena has a 'Maps to')
    ('http://purl.obolibrary.org/obo/hp.owl',       'HPO',       'curie_underscore'),
    ('http://human-phenotype-ontology.org',         'HPO',       'curie_underscore'),
    ('http://purl.obolibrary.org/obo/mondo.owl',    'Mondo',     'curie_underscore'),
    ('http://www.orpha.net',                        'ORPHAcode', 'strip_prefix'),
    -- the same code systems written as OIDs, as C-CDA-derived FHIR often does
    ('urn:oid:2.16.840.1.113883.6.96',              'SNOMED',    'exact'),
    ('urn:oid:2.16.840.1.113883.6.1',               'LOINC',     'exact'),
    ('urn:oid:2.16.840.1.113883.6.88',              'RxNorm',    'exact'),
    ('urn:oid:2.16.840.1.113883.12.292',            'CVX',       'exact'),
    ('urn:oid:2.16.840.1.113883.6.69',              'NDC',       'exact'),
    ('urn:oid:2.16.840.1.113883.6.90',              'ICD10CM',   'exact'),
    ('urn:oid:2.16.840.1.113883.6.103',             'ICD9CM',    'exact'),
    ('urn:oid:2.16.840.1.113883.6.4',               'ICD10PCS',  'exact'),
    ('urn:oid:2.16.840.1.113883.6.12',              'CPT4',      'exact'),
    ('urn:oid:2.16.840.1.113883.6.285',             'HCPCS',     'exact'),
    ('urn:oid:2.16.840.1.113883.6.8',               'UCUM',      'exact');

CREATE OR REPLACE MACRO code_norm(match, code) AS CASE match
    WHEN 'nodot' THEN replace(code, '.', '')
    WHEN 'curie_underscore' THEN replace(code, ':', '_')
    WHEN 'strip_prefix' THEN split_part(code, ':', -1)
    ELSE code END;

-- Source config (empty unless --source-config gives the files; see sql/04_source_*.sql).
--   source_system    the source's own code system URIs, same columns as stg.system_vocab
--   source_code_map  single codes of a local code system -> the Athena (vocabulary, code)
--                    that means the same
CREATE OR REPLACE TABLE stg.source_system (system VARCHAR, vocabulary_id VARCHAR, match VARCHAR);
CREATE OR REPLACE TABLE stg.source_code_map (system VARCHAR, code VARCHAR, vocabulary_id VARCHAR,
                                             concept_code VARCHAR);

-- Records that did not happen or were entered by mistake are not loaded (QC counts them).
-- `field` is the FHIR element: status, or verificationStatus (its first coding's code).
CREATE OR REPLACE TABLE stg.status_exclude (src_type VARCHAR, field VARCHAR, code VARCHAR);
INSERT INTO stg.status_exclude VALUES
    ('Encounter', 'status', 'entered-in-error'), ('Encounter', 'status', 'cancelled'),
    ('Encounter', 'status', 'planned'),
    ('Condition', 'verificationStatus', 'entered-in-error'),
    ('Condition', 'verificationStatus', 'refuted'),
    ('AllergyIntolerance', 'verificationStatus', 'entered-in-error'),
    ('AllergyIntolerance', 'verificationStatus', 'refuted'),
    ('Procedure', 'status', 'entered-in-error'), ('Procedure', 'status', 'not-done'),
    ('Procedure', 'status', 'preparation'),
    ('Observation', 'status', 'entered-in-error'), ('Observation', 'status', 'cancelled'),
    ('MedicationRequest', 'status', 'entered-in-error'),
    ('MedicationRequest', 'status', 'cancelled'), ('MedicationRequest', 'status', 'draft'),
    ('MedicationAdministration', 'status', 'entered-in-error'),
    ('MedicationAdministration', 'status', 'not-done'),
    ('Immunization', 'status', 'entered-in-error'), ('Immunization', 'status', 'not-done'),
    ('Device', 'status', 'entered-in-error');

-- UCUM codes as FHIR/Synthea write them -> the concept_code Athena uses for the same unit.
-- Athena's UCUM vocabulary uses its own spellings for some units, so an exact-code lookup
-- misses them. Each target was checked by name against Athena v5.0 29-AUG-26.
-- UCUM annotations ({score}, {#}, {nominal}, ...) have no OMOP unit concept and stay 0.
CREATE OR REPLACE TABLE stg.ucum_alias (code VARCHAR, athena_code VARCHAR);
INSERT INTO stg.ucum_alias VALUES
    ('U/L',              '[U]/L'),                  -- 8645 unit per liter
    ('kU/L',             '10*3.[U]/L'),             -- 8810 kilounit per liter
    ('m[IU]/L',          '10*-3.[iU]/L'),           -- 9040 milli-international unit per liter
    ('/a',               '/y'),                     -- 44777560 per year
    ('mL/min/{1.73_m2}', 'mL/min/(173.10*-2.m2)'),  -- 720870 mL per minute per 1.73 m2
    ('[pH]',             'pH'),                     -- 8482 pH
    ('{INR}',            '{ratio}');                -- 8523 ratio (OHDSI convention for INR)

CREATE OR REPLACE TABLE stg.constant_concept (name VARCHAR, code VARCHAR, concept_id INTEGER);
INSERT INTO stg.constant_concept VALUES
    -- Patient.gender
    ('gender', 'male',   8507),
    ('gender', 'female', 8532),
    -- US Core race ombCategory (CDC Race & Ethnicity code system)
    ('race', '2106-3', 8527),   -- White
    ('race', '2054-5', 8516),   -- Black or African American
    ('race', '2028-9', 8515),   -- Asian
    ('race', '1002-5', 8657),   -- American Indian or Alaska Native
    ('race', '2076-8', 8557),   -- Native Hawaiian or Other Pacific Islander
    ('ethnicity', '2135-2', 38003563),  -- Hispanic or Latino
    ('ethnicity', '2186-5', 38003564),  -- Not Hispanic or Latino
    -- Encounter.class (v3 ActCode)
    ('visit', 'AMB',    9202),  -- Outpatient Visit
    ('visit', 'EMER',   9203),  -- Emergency Room Visit
    ('visit', 'IMP',    9201),  -- Inpatient Visit
    ('visit', 'ACUTE',  9201),
    ('visit', 'NONAC',  9201),
    ('visit', 'SS',     9201),
    ('visit', 'OBSENC', 9202),
    ('visit', 'HH',     581476), -- Home Visit
    ('visit', 'VR',     722455), -- Telehealth (5083 is non-standard since v5.0 2024+)
    -- Type concepts (provenance)
    ('type', 'ehr',                  32817), -- EHR
    ('type', 'ehr_prescription',     32838), -- EHR prescription
    ('type', 'ehr_administration',   32818), -- EHR administration record
    ('cdm_version', '5.4', 756265);          -- OMOP CDM Version 5.4.0

CREATE OR REPLACE MACRO const(n, c) AS
    coalesce((SELECT concept_id FROM stg.constant_concept k WHERE k.name = n AND k.code = c), 0);

-- US state name -> postal code; location.state is varchar(2) in CDM 5.4.
CREATE OR REPLACE TABLE stg.us_state (name VARCHAR, code VARCHAR);
INSERT INTO stg.us_state VALUES
    ('Alabama','AL'),('Alaska','AK'),('Arizona','AZ'),('Arkansas','AR'),('California','CA'),
    ('Colorado','CO'),('Connecticut','CT'),('Delaware','DE'),('District of Columbia','DC'),
    ('Florida','FL'),('Georgia','GA'),('Hawaii','HI'),('Idaho','ID'),('Illinois','IL'),
    ('Indiana','IN'),('Iowa','IA'),('Kansas','KS'),('Kentucky','KY'),('Louisiana','LA'),
    ('Maine','ME'),('Maryland','MD'),('Massachusetts','MA'),('Michigan','MI'),
    ('Minnesota','MN'),('Mississippi','MS'),('Missouri','MO'),('Montana','MT'),
    ('Nebraska','NE'),('Nevada','NV'),('New Hampshire','NH'),('New Jersey','NJ'),
    ('New Mexico','NM'),('New York','NY'),('North Carolina','NC'),('North Dakota','ND'),
    ('Ohio','OH'),('Oklahoma','OK'),('Oregon','OR'),('Pennsylvania','PA'),
    ('Rhode Island','RI'),('South Carolina','SC'),('South Dakota','SD'),('Tennessee','TN'),
    ('Texas','TX'),('Utah','UT'),('Vermont','VT'),('Virginia','VA'),('Washington','WA'),
    ('West Virginia','WV'),('Wisconsin','WI'),('Wyoming','WY'),('Puerto Rico','PR');
