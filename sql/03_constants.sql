-- Fixed concept ids and code-system lookups. All of these are standard OMOP concepts;
-- when a vocabulary is loaded, the QC stage checks they exist (check: constant_concept_missing).

-- FHIR code system URI -> OMOP vocabulary_id.
CREATE OR REPLACE TABLE stg.system_vocab (system VARCHAR, vocabulary_id VARCHAR);
INSERT INTO stg.system_vocab VALUES
    ('http://snomed.info/sct',                     'SNOMED'),
    ('http://loinc.org',                           'LOINC'),
    ('http://www.nlm.nih.gov/research/umls/rxnorm', 'RxNorm'),
    ('http://hl7.org/fhir/sid/cvx',                'CVX'),
    ('http://hl7.org/fhir/sid/ndc',                'NDC'),
    ('http://hl7.org/fhir/sid/icd-10-cm',          'ICD10CM'),
    ('http://hl7.org/fhir/sid/icd-9-cm',           'ICD9CM'),
    ('http://www.ama-assn.org/go/cpt',             'CPT4'),
    ('http://unitsofmeasure.org',                  'UCUM');

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
    ('visit', 'VR',     5083),   -- Telehealth
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
