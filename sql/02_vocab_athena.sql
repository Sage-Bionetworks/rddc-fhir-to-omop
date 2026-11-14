-- Stage 2 (with vocabulary): load an Athena vocabulary download (tab-delimited CSVs).
-- Only CONCEPT, CONCEPT_RELATIONSHIP ('Maps to') and VOCABULARY are needed for mapping.
-- Athena files are unquoted and contain literal quote characters, hence quote = ''.
CREATE OR REPLACE TABLE stg.concept AS
SELECT * FROM read_csv(getvariable('vocab_dir') || '/CONCEPT.csv',
    delim = '\t', quote = '', escape = '', header = true, dateformat = '%Y%m%d',
    columns = {'concept_id': 'INTEGER', 'concept_name': 'VARCHAR', 'domain_id': 'VARCHAR',
               'vocabulary_id': 'VARCHAR', 'concept_class_id': 'VARCHAR',
               'standard_concept': 'VARCHAR', 'concept_code': 'VARCHAR',
               'valid_start_date': 'DATE', 'valid_end_date': 'DATE',
               'invalid_reason': 'VARCHAR'});

CREATE OR REPLACE TABLE stg.maps_to AS
SELECT concept_id_1, concept_id_2
FROM read_csv(getvariable('vocab_dir') || '/CONCEPT_RELATIONSHIP.csv',
    delim = '\t', quote = '', escape = '', header = true, dateformat = '%Y%m%d',
    columns = {'concept_id_1': 'INTEGER', 'concept_id_2': 'INTEGER',
               'relationship_id': 'VARCHAR', 'valid_start_date': 'DATE',
               'valid_end_date': 'DATE', 'invalid_reason': 'VARCHAR'})
WHERE relationship_id = 'Maps to' AND invalid_reason IS NULL;

CREATE OR REPLACE TABLE stg.vocabulary AS
SELECT vocabulary_id, vocabulary_version
FROM read_csv(getvariable('vocab_dir') || '/VOCABULARY.csv',
    delim = '\t', quote = '', escape = '', header = true, all_varchar = true);
