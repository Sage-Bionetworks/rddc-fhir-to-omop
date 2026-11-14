-- No CONCEPT_ANCESTOR.csv: no ingredient roll-up, so drug_era stays empty (QC reports it).
CREATE OR REPLACE TABLE stg.ingredient (drug_concept_id INTEGER, ingredient_concept_id INTEGER);
