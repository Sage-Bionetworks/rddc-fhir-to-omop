#!/usr/bin/env bash
# End-to-end tests for bin/fhir_to_omop.sh on tests/data/batch/fhir, without and with the
# mini vocabulary. Each check is a SQL query that must return true.
# Usage: tests/run_tests.sh   (needs duckdb on PATH; `make tools` puts one in .tools/)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PATH=$root/.tools:$PATH DUCKDB_AGENT_MODE=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0

check() {  # check <out_dir> <description> <sql returning one boolean>
  local got
  got=$(cd "$1/omop" && duckdb -noheader -list -c "SELECT ($3)::BOOLEAN" 2>&1) || true
  if [[ $got == true ]]; then echo "  ok    $2"; else echo "  FAIL  $2 (got: $got)"; fails=$((fails + 1)); fi
}
qc() {  # qc <out_dir> <description> <where clause on qc.csv returning boolean>
  check "$1" "$2" "SELECT $3 FROM '$1/qc.csv'"
}

n_patients=$(gzip -dc "$root/tests/data/batch/fhir/Patient.ndjson.gz" | wc -l)

echo "== no vocabulary"
o=$work/novocab
"$root/bin/fhir_to_omop.sh" --fhir-dir "$root/tests/data/batch/fhir" --out-dir "$o" --strict >"$work/novocab.log" 2>&1 \
  || { cat "$work/novocab.log"; exit 1; }
check "$o" "one person per Patient ($n_patients)" "SELECT count(*) = $n_patients FROM 'person.parquet'"
check "$o" "every person has an observation_period" \
  "SELECT count(*) = 0 FROM 'person.parquet' WHERE person_id NOT IN (SELECT person_id FROM 'observation_period.parquet')"
check "$o" "gender/race/ethnicity constants applied" \
  "SELECT bool_and(gender_concept_id IN (8507, 8532) AND race_concept_id > 0 AND ethnicity_concept_id > 0) FROM 'person.parquet'"
check "$o" "all visits typed and resolved to a care site" \
  "SELECT bool_and(visit_concept_id > 0 AND care_site_id IS NOT NULL) FROM 'visit_occurrence.parquet'"
check "$o" "no eras without vocabulary (all concept ids are 0)" \
  "SELECT (SELECT count(*) FROM 'condition_era.parquet') + (SELECT count(*) FROM 'drug_era.parquet') = 0"
check "$o" "clinical concept ids are 0 without vocabulary" \
  "SELECT bool_and(condition_concept_id = 0) FROM 'condition_occurrence.parquet'"
check "$o" "BP panel split into systolic + diastolic, panel code dropped" \
  "SELECT count(*) FILTER (WHERE measurement_source_value = '8480-6') = count(*) FILTER (WHERE measurement_source_value = '8462-4')
          AND count(*) FILTER (WHERE measurement_source_value = '85354-9') = 0 FROM 'measurement.parquet'"
check "$o" "lab values keep full precision" \
  "SELECT count(*) > 0 FROM 'measurement.parquet' WHERE value_as_number <> round(value_as_number, 3)"
check "$o" "drugs via medicationReference get a code" \
  "SELECT count(*) = 0 FROM 'drug_exposure.parquet' WHERE drug_source_value IS NULL"
check "$o" "date and datetime agree" \
  "SELECT count(*) = 0 FROM 'measurement.parquet' WHERE measurement_date <> measurement_datetime::DATE"
qc "$o" "QC: no failures" "count(*) FILTER (WHERE status = 'fail') = 0"
qc "$o" "QC: nothing unplaced or unresolved" \
  "count(*) FILTER (WHERE check_name IN ('events_unplaced', 'events_unresolved_encounter')) = 0"
qc "$o" "QC: CarePlan reported as not mapped" \
  "count(*) FILTER (WHERE check_name = 'fhir_resources' AND table_name = 'CarePlan' AND status = 'warn') = 1"

echo "== mini vocabulary"
o=$work/vocab
"$root/bin/fhir_to_omop.sh" --fhir-dir "$root/tests/data/batch/fhir" --out-dir "$o" \
  --vocab-dir "$root/tests/data/vocab_mini" --format csv --strict --max-unmapped-pct 100 >"$work/vocab.log" 2>&1 \
  || { cat "$work/vocab.log"; exit 1; }
check "$o" "standard condition mapped" \
  "SELECT count(*) > 0 FROM 'condition_occurrence.csv' WHERE condition_source_value = '444814009' AND condition_concept_id = 2000000001"
check "$o" "Condition with an Observation-domain concept is routed to observation" \
  "SELECT (SELECT count(*) FROM 'condition_occurrence.csv' WHERE condition_source_value = '73595000') = 0
      AND (SELECT count(*) FROM 'observation.csv' WHERE observation_concept_id = 2000000002) > 0"
check "$o" "non-standard CVX source keeps source_concept_id, gets standard target" \
  "SELECT bool_and(drug_concept_id = 2000000041 AND drug_source_concept_id = 2000000040)
     FROM 'drug_exposure.csv' WHERE drug_source_value = '140'"
check "$o" "one-to-many map gives one row per target domain" \
  "SELECT (SELECT count(*) FROM 'procedure_occurrence.csv' WHERE procedure_concept_id = 2000000050)
        = (SELECT count(*) FROM 'drug_exposure.csv' WHERE drug_concept_id = 2000000051)
      AND (SELECT count(*) FROM 'drug_exposure.csv' WHERE drug_concept_id = 2000000051) > 0"
check "$o" "invalid relationship ignored" \
  "SELECT count(*) = 0 FROM 'drug_exposure.csv' WHERE drug_source_value = '140' AND drug_concept_id = 2000000001"
check "$o" "unit mapped (mm[Hg] -> 8876)" \
  "SELECT bool_and(unit_concept_id = 8876) FROM 'measurement.csv' WHERE unit_source_value = 'mm[Hg]'"
check "$o" "unit source concept carried (mm[Hg] -> 8876)" \
  "SELECT bool_and(unit_source_concept_id = 8876) FROM 'measurement.csv' WHERE unit_source_value = 'mm[Hg]'"
check "$o" "optional concept fields without source data are NULL, not 0" \
  "SELECT (SELECT count(*) FROM 'drug_exposure.csv' WHERE route_concept_id IS NOT NULL) = 0
      AND (SELECT count(*) FROM 'observation.csv' WHERE unit_source_value IS NULL AND unit_concept_id IS NOT NULL) = 0
      AND (SELECT count(*) FROM 'measurement.csv' WHERE operator_concept_id IS NOT NULL) = 0"
check "$o" "UCUM alias: U/L resolves to Athena's [U]/L (8645)" \
  "SELECT count(*) > 0 AND bool_and(unit_concept_id = 8645) FROM 'measurement.csv' WHERE unit_source_value = 'U/L'"
check "$o" "telehealth visits use the standard concept 722455" \
  "SELECT count(*) = 0 FROM 'visit_occurrence.csv' WHERE visit_concept_id = 5083"
check "$o" "ids unique within each table" \
  "SELECT count(*) = count(DISTINCT drug_exposure_id) FROM 'drug_exposure.csv'"
check "$o" "vocabulary version recorded" \
  "SELECT vocabulary_version = 'mini-test 2026-11' FROM 'cdm_source.csv'"
qc "$o" "QC: constants all present in vocabulary" \
  "count(*) FILTER (WHERE check_name = 'constant_concept_invalid') = 0"
qc "$o" "QC: unmapped codes reported" "count(*) FILTER (WHERE check_name = 'top_unmapped_codes') > 0"

check "$o" "condition_era covers every mapped condition occurrence exactly once" \
  "SELECT (SELECT sum(condition_occurrence_count) FROM 'condition_era.csv')
        = (SELECT count(*) FROM 'condition_occurrence.csv' WHERE condition_concept_id <> 0)"
check "$o" "consecutive eras of the same concept are > 30 days apart" \
  "SELECT count(*) = 0 FROM (
     SELECT condition_era_start_date - lag(condition_era_end_date) OVER (
              PARTITION BY person_id, condition_concept_id ORDER BY condition_era_start_date) AS gap
     FROM 'condition_era.csv') WHERE gap <= 30"
check "$o" "drug_era rolls up to ingredients only" \
  "SELECT count(*) > 0 AND bool_and(drug_concept_id IN (2000000031, 2000000042, 2000000051)) FROM 'drug_era.csv'"
check "$o" "drug_era counts every exposure with an ingredient" \
  "SELECT (SELECT sum(drug_exposure_count) FROM 'drug_era.csv')
        = (SELECT count(*) FROM 'drug_exposure.csv'
           WHERE drug_concept_id IN (2000000030, 2000000031, 2000000041, 2000000042, 2000000051))"
check "$o" "gap_days within [0, era length]" \
  "SELECT bool_and(gap_days BETWEEN 0 AND drug_era_end_date - drug_era_start_date) FROM 'drug_era.csv'"

echo "== era logic (hand-computed cases)"
got=$( {
  echo "CREATE SCHEMA stg;"
  cat "$root/sql/10_cdm_ddl.sql"
  cat <<'SQL'
CREATE TABLE stg.ingredient AS SELECT 100 AS drug_concept_id, 1000 AS ingredient_concept_id;
INSERT INTO condition_occurrence (condition_occurrence_id, person_id, condition_concept_id,
    condition_start_date, condition_end_date, condition_type_concept_id) VALUES
  (1, 1, 10, DATE '2020-01-01', DATE '2020-01-10', 0),
  (2, 1, 10, DATE '2020-01-03', DATE '2020-01-05', 0),   -- nested in the first
  (3, 1, 10, DATE '2020-02-05', DATE '2020-02-06', 0),   -- 26 days after: same era
  (4, 1, 10, DATE '2020-04-01', NULL, 0),                -- 55 days after: new era, end = +1
  (5, 1, 0,  DATE '2020-01-01', NULL, 0);                -- concept 0: no era
INSERT INTO drug_exposure (drug_exposure_id, person_id, drug_concept_id, drug_exposure_start_date,
    drug_exposure_end_date, drug_type_concept_id) VALUES
  (1, 1, 100, DATE '2020-01-01', DATE '2020-01-11', 0),
  (2, 1, 100, DATE '2020-01-05', DATE '2020-01-20', 0),  -- overlaps: covered Jan 1-20 (19 d)
  (3, 1, 100, DATE '2020-02-10', DATE '2020-02-15', 0),  -- 21-day gap: same era (5 d)
  (4, 1, 100, DATE '2020-06-01', DATE '2020-06-01', 0),  -- new era; same-day end -> +1
  (5, 1, 999, DATE '2020-01-01', DATE '2020-01-02', 0);  -- no ingredient: no era
SQL
  cat "$root/sql/55_eras.sql"
  echo "SELECT string_agg(x, ' ' ORDER BY x) FROM (
          SELECT 'C' || condition_concept_id || ':' || condition_era_start_date || '/' ||
                 condition_era_end_date || '/' || condition_occurrence_count AS x FROM condition_era
          UNION ALL
          SELECT 'D' || drug_concept_id || ':' || drug_era_start_date || '/' || drug_era_end_date
                 || '/' || drug_exposure_count || '/' || gap_days FROM drug_era);"
} | duckdb -noheader -list 2>&1 | tail -1)
want="C10:2020-01-01/2020-02-06/3 C10:2020-04-01/2020-04-02/1 D1000:2020-01-01/2020-02-15/3/21 D1000:2020-06-01/2020-06-02/1/0"
if [[ $got == "$want" ]]; then echo "  ok    eras match hand-computed result"
else echo "  FAIL  eras: got '$got', want '$want'"; fails=$((fails + 1)); fi

echo "== Bundle JSON input (Synthea default export)"
o=$work/bundle
mkdir -p "$work/bundles"
duckdb -c "COPY (SELECT 'Bundle' AS resourceType, 'collection' AS type,
                        list({'resource': json}) AS entry
                 FROM read_json_objects('$root/tests/data/batch/fhir/*.ndjson.gz'))
           TO '$work/bundles/all.json' (FORMAT json)" >/dev/null
"$root/bin/fhir_to_omop.sh" --fhir-dir "$work/bundles" --out-dir "$o" >"$work/bundle.log" 2>&1 \
  || { cat "$work/bundle.log"; exit 1; }
check "$o" "Bundle input gives the same row counts as NDJSON" \
  "SELECT (SELECT count(*) FROM 'measurement.parquet') = (SELECT count(*) FROM '$work/novocab/omop/measurement.parquet')
      AND (SELECT count(*) FROM 'person.parquet') = $n_patients"

echo "== subjects from the batch sidecar (tests/data/batch/_sidecar.json)"
sidecar=$root/tests/data/batch/_sidecar.json
duckdb -c "COPY (SELECT s.subjectId AS subject_id FROM (SELECT unnest(subjects) AS s FROM read_json('$sidecar'))
                 WHERE s.idSystem = 'fhir_patient_id') TO '$work/subjects.csv' (HEADER)" >/dev/null
o=$work/subjects
"$root/bin/fhir_to_omop.sh" --fhir-dir "$root/tests/data/batch/fhir" --out-dir "$o" --subjects "$work/subjects.csv" \
  --strict >"$work/subjects.log" 2>&1 || { cat "$work/subjects.log"; exit 1; }
qc "$o" "sidecar lists every person and nothing else (strict run passed)" \
  "bool_and(status = 'ok') FILTER (WHERE check_name IN ('sidecar_subjects_without_person', 'persons_not_in_sidecar',
                                                       'persons_without_subject_id'))"
qc "$o" "all $n_patients sidecar subjects counted" "any_value(value) FILTER (WHERE check_name = 'sidecar_subjects') = $n_patients"
check "$o" "person_source_value is Patient.id (fhir_patient_id)" \
  "SELECT bool_and(person_source_value IN (SELECT subject_id FROM '$work/subjects.csv')) FROM 'person.parquet'"

{ head -n -1 "$work/subjects.csv"; echo "not-a-patient"; } > "$work/subjects_bad.csv"
o=$work/subjects_bad
"$root/bin/fhir_to_omop.sh" --fhir-dir "$root/tests/data/batch/fhir" --out-dir "$o" --subjects "$work/subjects_bad.csv" \
  >"$work/subjects_bad.log" 2>&1 || { cat "$work/subjects_bad.log"; exit 1; }
qc "$o" "an unlisted person and a listed non-patient both fail" \
  "any_value(status || value) FILTER (WHERE check_name = 'persons_not_in_sidecar') = 'fail1.0'
   AND any_value(status || value) FILTER (WHERE check_name = 'sidecar_subjects_without_person') = 'fail1.0'"
"$root/bin/fhir_to_omop.sh" --fhir-dir "$root/tests/data/batch/fhir" --out-dir "$work/subjects_strict" \
  --subjects "$work/subjects_bad.csv" --strict >/dev/null 2>&1 && strict_rc=0 || strict_rc=$?
if [[ $strict_rc == 3 ]]; then echo "  ok    --strict exits 3 on a subject mismatch"
else echo "  FAIL  --strict on a subject mismatch exited $strict_rc, want 3"; fails=$((fails + 1)); fi

# identifier mode: person_source_value is a Patient.identifier of the declared system.
subjects_for() {  # subjects_for <system> <csv>: that identifier's values from Patient.ndjson
  duckdb -c "COPY (SELECT i->>'value' AS subject_id
                   FROM (SELECT unnest(json_extract(json, '\$.identifier[*]')) AS i
                         FROM read_json_objects('$root/tests/data/batch/fhir/Patient.ndjson.gz'))
                   WHERE i->>'system' = '$1') TO '$2' (HEADER)" >/dev/null
}
ssn=http://hl7.org/fhir/sid/us-ssn                # every Synthea patient has one (synthetic)
subjects_for "$ssn" "$work/subjects_ssn.csv"
o=$work/subjects_ssn
"$root/bin/fhir_to_omop.sh" --fhir-dir "$root/tests/data/batch/fhir" --out-dir "$o" --subjects "$work/subjects_ssn.csv" \
  --subject-id identifier --identifier-system "$ssn" --strict >"$work/subjects_ssn.log" 2>&1 \
  || { cat "$work/subjects_ssn.log"; exit 1; }
check "$o" "identifier mode: person_source_value is the declared system's identifier" \
  "SELECT bool_and(person_source_value IN (SELECT subject_id FROM '$work/subjects_ssn.csv'))
          AND bool_and(person_source_value LIKE '999-%') AND count(*) = $n_patients FROM 'person.parquet'"

dl=urn:oid:2.16.840.1.113883.4.3.25               # driver's licence: the children have none
subjects_for "$dl" "$work/subjects_dl.csv"
o=$work/subjects_dl
"$root/bin/fhir_to_omop.sh" --fhir-dir "$root/tests/data/batch/fhir" --out-dir "$o" --subjects "$work/subjects_dl.csv" \
  --subject-id identifier --identifier-system "$dl" >"$work/subjects_dl.log" 2>&1 || { cat "$work/subjects_dl.log"; exit 1; }
n_dl=$(wc -l < "$work/subjects_dl.csv"); n_dl=$((n_dl - 1))
qc "$o" "persons without the declared identifier fail ($((n_patients - n_dl)) of $n_patients)" \
  "any_value(status || value) FILTER (WHERE check_name = 'persons_without_subject_id') = 'fail$((n_patients - n_dl)).0'"

echo "== non-Synthea shapes (tests/data/edge) with its source config"
edge=$root/tests/data/edge
o=$work/edge
"$root/bin/fhir_to_omop.sh" --fhir-dir "$edge/fhir" --out-dir "$o" --vocab-dir "$root/tests/data/vocab_mini" \
  --source-config "$edge/source_config" --strict --max-unmapped-pct 100 >"$work/edge.log" 2>&1 \
  || { cat "$work/edge.log"; exit 1; }
check "$o" "year-only birthDate keeps the person (year set, month and datetime NULL)" \
  "SELECT count(*) = 2 AND bool_or(year_of_birth = 1980 AND month_of_birth IS NULL AND birth_datetime IS NULL)
          AND bool_or(year_of_birth = 1975 AND month_of_birth = 6 AND day_of_birth = 15) FROM 'person.parquet'"
check "$o" "deceasedBoolean without a date gives no death row, and QC says so" \
  "SELECT (SELECT count(*) FROM 'death.parquet') = 0
      AND (SELECT count(*) FROM '$o/qc.csv' WHERE check_name = 'deceased_without_date' AND value = 1) = 1"
check "$o" "cancelled encounter is not a visit; versioned subject reference resolves" \
  "SELECT count(*) = 1 AND bool_and(person_id IS NOT NULL) FROM 'visit_occurrence.parquet'"
check "$o" "Condition with no date takes its encounter's start" \
  "SELECT count(*) = 1 FROM 'condition_occurrence.parquet' c JOIN 'visit_occurrence.parquet' v USING (visit_occurrence_id)
    WHERE c.condition_start_date = DATE '2020-03-01' AND c.condition_start_datetime = v.visit_start_datetime"
check "$o" "the coding that maps is used, not the first one" \
  "SELECT count(*) = 1 FROM 'condition_occurrence.parquet'
    WHERE condition_source_value = '444814009' AND condition_concept_id = 2000000001 AND condition_start_date = DATE '2020-03-01'"
check "$o" "entered-in-error Condition and cancelled MedicationRequest are not loaded" \
  "SELECT (SELECT count(*) FROM 'condition_occurrence.parquet') = 3 AND (SELECT count(*) FROM 'drug_exposure.parquet') = 3
      AND (SELECT sum(value) FROM '$o/qc.csv' WHERE check_name = 'events_excluded_status') = 2"
check "$o" "source config: local ICD-10-CM URI without dots maps (J0190 -> J01.90 -> standard)" \
  "SELECT count(*) = 1 FROM 'condition_occurrence.parquet'
    WHERE condition_source_value = 'J0190' AND condition_source_concept_id = 2000000060 AND condition_concept_id = 2000000001"
check "$o" "partial onset dates: 2019 -> 2019-01-01, 2019-05 -> 2019-05-01" \
  "SELECT bool_or(condition_start_date = DATE '2019-01-01') AND bool_or(condition_start_date = DATE '2019-05-01')
          AND (SELECT sum(value) FROM '$o/qc.csv' WHERE check_name = 'events_partial_date') = 2
     FROM 'condition_occurrence.parquet'"
check "$o" "HPO code (HP:0000118) keeps its source concept" \
  "SELECT count(*) = 1 FROM 'condition_occurrence.parquet'
    WHERE condition_source_value = 'HP:0000118' AND condition_source_concept_id = 2000000061 AND condition_concept_id = 0"
check "$o" "contained Medication gives the drug code" \
  "SELECT count(*) = 1 FROM 'drug_exposure.parquet'
    WHERE drug_exposure_start_date = DATE '2020-03-01' AND drug_concept_id = 2000000030"
check "$o" "Medication without a code: one exposure per ingredient" \
  "SELECT count(*) = 2 AND count(DISTINCT drug_concept_id) = 2 AND bool_and(drug_concept_id IN (2000000030, 2000000041))
     FROM 'drug_exposure.parquet' WHERE drug_exposure_start_date = DATE '2019-05-02'"
check "$o" "source config: local unit code maps (bpm -> /min)" \
  "SELECT count(*) = 1 FROM 'measurement.parquet' WHERE unit_source_value = 'bpm' AND unit_concept_id = 2000000021"
check "$o" "unit given as text only is looked up as UCUM (kg)" \
  "SELECT count(*) = 1 FROM 'measurement.parquet' WHERE unit_source_value = 'kg' AND unit_concept_id = 2000000020"
qc "$o" "QC: unrecognised code system reported" \
  "count(*) FILTER (WHERE check_name = 'code_system_unrecognised' AND table_name = 'urn:local:obs' AND value = 1) = 1"
qc "$o" "QC: source config recorded, no invalid entries" \
  "count(*) FILTER (WHERE check_name = 'source_config' AND value = 2 AND detail LIKE 'source_config:%') = 1
   AND count(*) FILTER (WHERE check_name = 'source_config_invalid') = 0"

echo "== QC limits"
o=$work/edge_limit
"$root/bin/fhir_to_omop.sh" --fhir-dir "$edge/fhir" --out-dir "$o" --vocab-dir "$root/tests/data/vocab_mini" \
  --source-config "$edge/source_config" >"$work/edge_limit.log" 2>&1 || { cat "$work/edge_limit.log"; exit 1; }
qc "$o" "unmapped concepts above the default limit (25%) fail" \
  "count(*) FILTER (WHERE check_name = 'concept_unmapped_pct' AND status = 'fail') >= 1"
mkdir -p "$work/edge_nodate"
sed 's#"encounter":{"reference":"Encounter/E1"},"code":{"coding":\[{"system":"urn:local:dx"#"code":{"coding":[{"system":"urn:local:dx"#' \
  "$edge/fhir/edge.ndjson" > "$work/edge_nodate/edge.ndjson"
o=$work/edge_unplaced
"$root/bin/fhir_to_omop.sh" --fhir-dir "$work/edge_nodate" --out-dir "$o" --strict >"$work/edge_unplaced.log" 2>&1 \
  && unplaced_rc=0 || unplaced_rc=$?
qc "$o" "records that cannot be loaded above the limit (5%) fail: 1 of 3 Conditions" \
  "any_value(status || value) FILTER (WHERE check_name = 'events_unplaced_pct' AND table_name = 'Condition') = 'fail33.3'"
if [[ $unplaced_rc == 3 ]]; then echo "  ok    --strict exits 3 when records cannot be loaded"
else echo "  FAIL  --strict with unloadable records exited $unplaced_rc, want 3"; fails=$((fails + 1)); fi
"$root/bin/fhir_to_omop.sh" --fhir-dir "$work/edge_nodate" --out-dir "$work/edge_unplaced_ok" --strict \
  --max-unplaced-pct 50 >/dev/null 2>&1 && rc=0 || rc=$?
if [[ $rc == 0 ]]; then echo "  ok    --max-unplaced-pct raises the limit"
else echo "  FAIL  --max-unplaced-pct 50 exited $rc, want 0"; fails=$((fails + 1)); fi
mkdir -p "$work/bad_config"
printf 'system,vocabulary_id,match\nurn:local:icd10,NOPE,nodot\n' > "$work/bad_config/systems.csv"
printf 'system,code,vocabulary_id,concept_code\nurn:local:units,bpm,UCUM,no-such-unit\n' > "$work/bad_config/concept_map.csv"
o=$work/edge_badcfg
"$root/bin/fhir_to_omop.sh" --fhir-dir "$edge/fhir" --out-dir "$o" --vocab-dir "$root/tests/data/vocab_mini" \
  --source-config "$work/bad_config" >"$work/edge_badcfg.log" 2>&1 || { cat "$work/edge_badcfg.log"; exit 1; }
qc "$o" "source config entries the vocabulary cannot resolve fail (systems.csv and concept_map.csv)" \
  "count(*) FILTER (WHERE check_name = 'source_config_invalid' AND status = 'fail') = 2"

echo
if ((fails)); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
