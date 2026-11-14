-- Drug concept -> RxNorm ingredient, from CONCEPT_ANCESTOR, for drug_era. CONCEPT_ANCESTOR
-- is large (tens of millions of rows), so only rows whose ancestor is an ingredient are kept.
-- An ingredient is its own ancestor (min_levels_of_separation = 0), so those rows are included.
CREATE OR REPLACE TABLE stg.ingredient AS
SELECT ca.descendant_concept_id AS drug_concept_id, ca.ancestor_concept_id AS ingredient_concept_id
FROM read_csv(getvariable('vocab_dir') || '/CONCEPT_ANCESTOR.csv',
    delim = '\t', quote = '', escape = '', header = true,
    columns = {'ancestor_concept_id': 'INTEGER', 'descendant_concept_id': 'INTEGER',
               'min_levels_of_separation': 'INTEGER', 'max_levels_of_separation': 'INTEGER'}) ca
JOIN stg.concept i ON i.concept_id = ca.ancestor_concept_id
WHERE i.concept_class_id = 'Ingredient' AND i.standard_concept = 'S'
  AND i.vocabulary_id IN ('RxNorm', 'RxNorm Extension');
