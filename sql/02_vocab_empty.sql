-- Stage 2 (no vocabulary): empty OMOP vocabulary tables.
-- Every clinical concept_id becomes 0 and the source code is kept in *_source_value.
-- Pass --vocab-dir with an Athena download to get real concept ids.
CREATE OR REPLACE TABLE stg.concept (
    concept_id INTEGER, concept_name VARCHAR, domain_id VARCHAR, vocabulary_id VARCHAR,
    concept_class_id VARCHAR, standard_concept VARCHAR, concept_code VARCHAR,
    valid_start_date DATE, valid_end_date DATE, invalid_reason VARCHAR);
CREATE OR REPLACE TABLE stg.maps_to (concept_id_1 INTEGER, concept_id_2 INTEGER);
CREATE OR REPLACE TABLE stg.vocabulary (vocabulary_id VARCHAR, vocabulary_version VARCHAR);
