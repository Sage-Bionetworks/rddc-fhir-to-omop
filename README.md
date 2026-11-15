# rddc-fhir-to-omop

Prototype: convert FHIR R4 to the OMOP CDM 5.4 on a single node. A single Nextflow process
runs one DuckDB job over a directory of FHIR resources and writes OMOP tables as Parquet
(or CSV), plus a QC report.

Status: prototype. It's tested against Synthea output only. See [Limitations](#limitations).

## Quick start

```bash
make tools          # fetch the DuckDB CLI and Nextflow into .tools/ (gitignored)
make test           # ETL checks on tests/data (DuckDB only, ~2 s)
make nf-test        # the same fixture through Nextflow, no container
make nf-test-docker # ...in the Docker image (builds rddc-fhir-to-omop:dev)
```

Real run:

```bash
.tools/nextflow run . -profile docker \
    --input /path/to/fhir_ndjson \
    --vocab_dir /path/to/athena_vocab \
    --outdir results
```

Run the converter without Nextflow:

```bash
PATH=.tools:$PATH bin/fhir_to_omop.sh --fhir-dir DIR --out-dir OUT [--vocab-dir ATHENA] \
    [--threads 8] [--memory 16GB] [--format parquet|csv] [--db keep.duckdb] [--strict]
```

## Parameters

| Param | Default | |
|---|---|---|
| `--input` | required | Directory of FHIR resources: bulk-export NDJSON (`*.ndjson`, `*.ndjson.gz`) or Bundle JSON (`*.json`) |
| `--outdir` | required | |
| `--vocab_dir` | none | Athena download containing `CONCEPT.csv`, `CONCEPT_RELATIONSHIP.csv` and `VOCABULARY.csv`. Without it, clinical `concept_id`s are 0 and source codes are kept |
| `--output_format` | `parquet` | `parquet` or `csv` |
| `--source_name` | `RDDC FHIR` | `cdm_source.cdm_source_name` |
| `--strict_qc` | `false` | Fail the run if any QC check has status `fail` |
| `--max_object_mb` | `128` | Largest single JSON object, e.g. one patient Bundle |

The process uses the `process_medium` label (6 CPUs, 36 GB). It passes `task.cpus` and 80% of
`task.memory` to DuckDB as `threads` and `memory_limit`. DuckDB spills to the work directory
when it runs past the memory limit, so less memory makes the run slower but it still finishes.

## Outputs

```
<outdir>/
  omop/<table>.parquet     16 CDM 5.4 tables in official column order (list below)
  source_id_map.parquet    resource_type, fhir_id -> omop_id (provenance back to FHIR)
  qc.csv                   check_name, table_name, value, status (ok|warn|fail), detail
  pipeline_info/software_versions.yml
```

Tables: `person`, `observation_period`, `visit_occurrence`, `condition_occurrence`,
`drug_exposure`, `procedure_occurrence`, `device_exposure`, `measurement`, `observation`,
`death`, `location`, `care_site`, `provider`, `condition_era`, `drug_era`, `cdm_source`.

## How it works

`bin/fhir_to_omop.sh` joins the files in `sql/` into one script and runs it in one DuckDB
session:

| Stage | |
|---|---|
| `01_load_fhir.sql` | `read_json_objects` loads every resource as **untyped JSON** into `stg.fhir`, and flattens Bundles into their entries. A missing resource type or a new field can't break the load. Builds integer ids (`stg.id_map`, ordered by FHIR id, so the same input gives the same ids) and an index to resolve conditional references (`Practitioner?identifier=…`) |
| `02_vocab_*.sql`, `02_ancestor_*.sql` | Loads the Athena vocabulary, keeping only `Maps to` relationships, plus drug → RxNorm ingredient from `CONCEPT_ANCESTOR` if that file is present. Without `--vocab-dir`, creates empty tables |
| `03_constants.sql` | FHIR system URI → OMOP vocabulary, and the fixed concept ids for gender, race, ethnicity, visit class and type concepts |
| `10_cdm_ddl.sql` | CDM 5.4 DDL for the tables listed above |
| `20_person.sql`, `30_visit.sql` | Patient/Practitioner/Organization → person, death, location, provider, care_site. Encounter → visit_occurrence |
| `40_events.sql` | All clinical resources go into one event table (`stg.event`), then concept lookup (`stg.event_mapped`) |
| `50_domains.sql` | Writes each event to the table for its **domain** |
| `55_eras.sql` | condition_era and drug_era, using the OHDSI rules: same-concept records 30 days apart or less merge into one era. drug_era rolls exposures up to their ingredient (needs `CONCEPT_ANCESTOR.csv`), and `gap_days` is the uncovered days inside the era |
| `60_period_and_source.sql` | observation_period (span of each person's activity), cdm_source |
| `90_qc.sql` | QC checks (listed below) |

**Domain routing.** Each FHIR resource type has a default domain, listed below. When a
vocabulary is loaded, the domain of the standard concept takes precedence, which is the
OHDSI convention. For example, Synthea records "Stress (finding)" as a FHIR Condition, and
it lands in `observation`. A source code that maps to several standard concepts gives one
row per target.

| FHIR | Default OMOP table | Notes |
|---|---|---|
| Patient | person, location, death | race/ethnicity from US Core extensions; state names → 2-letter codes |
| Encounter | visit_occurrence | `class` → 9201/9202/9203/581476/5083; provider and care_site from conditional refs |
| Condition | condition_occurrence | onset/abatement; clinicalStatus → `condition_status_source_value` |
| Procedure | procedure_occurrence | |
| MedicationRequest / MedicationAdministration | drug_exposure | code from `medicationCodeableConcept` or the referenced Medication; end date = start when FHIR has none |
| Immunization | drug_exposure | CVX |
| Observation | measurement if it has a numeric value or is lab/vital-signs; else observation | components (e.g. a BP panel) become one row each and the panel row is dropped |
| AllergyIntolerance | observation | |
| Device | device_exposure | Synthea gives no use period, so `manufactureDate` is the start date |
| Practitioner / Organization | provider / care_site | |

Timestamps keep the local wall-clock time and drop the UTC offset, so `*_date` and
`*_datetime` always agree.

**QC (`qc.csv`).** The report lists:

- resources per type, and whether each type is mapped
- events dropped because no person resolves or there's no start date
- encounter references with no matching visit
- percentage of unmapped concepts per domain, and the top unmapped codes
- hard-coded constants missing, non-standard or deprecated in the loaded vocabulary (`fail`)
- person and visit foreign-key orphans (`fail`)
- persons with no observation period
- source values longer than 50 characters
- row counts

## Data quality (OHDSI DQD)

`qa/dqd/` runs the OHDSI [Data Quality Dashboard](https://github.com/OHDSI/DataQualityDashboard)
directly on DuckDB:

```bash
make dqd-deps     # one-time: DQD, DatabaseConnector, CommonDataModel, duckdb into .tools/R-lib
make dqd          # fixture + tests/data/vocab_mini -> results/dqd/
make dqd INPUT=data/synthea-100 VOCAB=/path/to/athena
```

`build_cdm_db.sh` creates a complete CDM 5.4 database (all 39 tables, official DDL from
`CommonDataModel`, saved in `cdm54_ddl_duckdb.sql`). It loads the pipeline output and any
Athena files present. `run_dqd.R` then runs `executeDqChecks` and writes:

- `dqd_results.json`: open it with `DataQualityDashboard::viewDqDashboard()`
- `dqd_summary.csv`: the checks that failed or errored

Needs R >= 4.2 and a JDK. `run.sh` finds `JAVA_HOME` from `java` on PATH.

Results on the test fixture with `vocab_mini` (DQD 2.9.1): 2,384 checks, 1,164 passed,
17 failed, 0 errors, 1,203 not applicable. Most of the not-applicable checks are on empty
tables.

All 17 failures are codes missing from the ~30-concept test vocabulary.

With the full Athena vocabulary (v5.0 29-AUG-26, 134 vocabularies including SNOMED,
LOINC, RxNorm, RxNorm Extension, CVX and UCUM) on 100 fresh Synthea patients (`make
synthea N=100 SEED=1`): **2,384 checks, 1,298 passed, 5 failed, 0 errors**. The run takes
about 1 minute. Unmapped rows are 0% for drugs, measurements and observations, 1.0% for
procedures and 1.1% for conditions. The unmapped codes are deprecated SNOMED codes with no
replacement, and Synthea's placeholder LOINC codes `X9999-*`. None of the 5 failures is an
ETL bug:

| Failure | Cause |
|---|---|
| Device concepts 18% unmapped | Synthea records "Operating room" and "Hospital bed" as devices; both are non-standard SNOMED with no mapping |
| Measurement / observation units 8% / 78% unmapped | UCUM annotations (`{score}`, `{#}`, `{nominal}`) have no OMOP unit concept |
| `plausibleUnitConceptIds` | Synthea reports RDW (LOINC 788-0, a %) in `fL` |
| `fkClass` on `DRUG_STRENGTH` | Inside the Athena vocabulary data, not ETL output |

Fixed after the first run with the full vocabulary:

- Telehealth visits now use concept 722455; 5083 is no longer standard in this release.
- An earlier bundle without CVX left 22% of drug rows unmapped (all immunizations).
  Include CVX when downloading from Athena.
- Synthea's UCUM spellings now resolve through `stg.ucum_alias`, e.g. `U/L` → Athena
  `[U]/L`.

## Test data

- `tests/data/fhir/`: 8 Synthea patients (`-p 6 -s 7`, including deceased), bulk NDJSON,
  gzipped. Claims and other billing resources are dropped to keep it small. CarePlan is kept
  as an example of an unmapped type.
- `tests/data/vocab_mini/`: a hand-made Athena-format vocabulary for testing domain routing,
  non-standard → standard mapping, one-to-many maps and invalid relationships. Not real data;
  see its README.
- `scripts/generate_synthea.sh OUT [N] [SEED] [YEARS]` (or `make synthea N=…`) writes a
  fresh bulk export. It uses `../rddc-sidecar/synthea/synthea-with-dependencies.jar` by
  default; set `SYNTHEA_JAR` to use a different jar.

## Performance (laptop, DuckDB 2.0.0)

| Patients | FHIR NDJSON | Threads / memory | Wall time |
|---|---|---|---|
| 8 (fixture) | 0.2 MB gz | 2 / 4 GB | <1 s |
| 1,120 (`-p 1000 -s 1`, incl. deceased) | 2.6 GB | 8 / 8 GB | 12.5 s → 19 MB Parquet, 1.08 M OMOP rows |

## Limitations

These are deliberate scope cuts for the prototype, roughly in priority order:

- **Vocabulary:** only `Maps to` is used. There's no `Maps to value`, so the value isn't split
  out for "finding + value" codes, and the first coding of each CodeableConcept is used even
  if a later coding maps.
- **Not mapped:** `dose_era`, `visit_detail`, `note` (from
  DocumentReference), `specimen`, `cost` / `payer_plan_period` (from Claim/EOB), and
  DiagnosticReport. Its results are already mapped as Observations.
- **Drugs:** no `days_supply` or `quantity` from dispenseRequest, and no route. Vaccines
  (CVX) have no RxNorm ingredient ancestor in current Athena releases, so they aren't in
  `drug_era`. QC reports them as `drug_without_ingredient`.
- **IDs:** `INTEGER` ids come from `row_number`, so they're stable for the same input but not
  across incremental loads.
- **Validation:** checked by `tests/run_tests.sh`, `qc.csv` and DQD (`make dqd`), including
  DQD with a full Athena vocabulary on 100 Synthea patients (see
  [Data quality](#data-quality-ohdsi-dqd)). Not yet compared with OHDSI's ETL-Synthea, and
  only tested on Synthea data.

## License

Apache-2.0. See [LICENSE](LICENSE).
