-- Stage (source config): <source-config>/systems.csv, the source's own code system URIs.
-- Columns: system, vocabulary_id, match (exact | nodot | curie_underscore | strip_prefix; see
-- sql/03_constants.sql). A system listed here replaces the default for that system.
INSERT INTO stg.source_system
SELECT trim(system), trim(vocabulary_id), coalesce(nullif(trim(match), ''), 'exact')
FROM read_csv(getvariable('source_config') || '/systems.csv', header = true, delim = ',', quote = '"',
              columns = {'system': 'VARCHAR', 'vocabulary_id': 'VARCHAR', 'match': 'VARCHAR'});
