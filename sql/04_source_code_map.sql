-- Stage (source config): <source-config>/concept_map.csv, single codes of a local code
-- system -> the Athena (vocabulary_id, concept_code) that means the same. The target is then
-- looked up like any other source code (its 'Maps to' gives the standard concept).
-- Columns: system, code, vocabulary_id, concept_code.
INSERT INTO stg.source_code_map
SELECT DISTINCT ON (system, code) trim(system) AS system, trim(code) AS code, trim(vocabulary_id), trim(concept_code)
FROM read_csv(getvariable('source_config') || '/concept_map.csv', header = true, delim = ',', quote = '"',
              columns = {'system': 'VARCHAR', 'code': 'VARCHAR', 'vocabulary_id': 'VARCHAR',
                         'concept_code': 'VARCHAR'});
