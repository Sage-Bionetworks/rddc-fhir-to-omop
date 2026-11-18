# rddc-fhir-to-omop

Prototype: convert FHIR R4 to the OMOP CDM 5.4 on a single node. The input is a deposited
batch described by its Croissant sidecar (`_sidecar.json`, [rddc-model](https://github.com/Sage-Bionetworks/rddc-model)).
A single Nextflow process runs one DuckDB job over the batch's FHIR files and writes OMOP
tables as Parquet (or CSV), plus a QC report.

Status: prototype. It's tested on Synthea output and on the MIMIC-IV FHIR demo (see
[Non-Synthea data](#non-synthea-data-mimic-iv-fhir-demo)). See [Limitations](#limitations).

## Quick start

```bash
make tools          # fetch the DuckDB CLI and Nextflow into .tools/ (gitignored)
make test           # ETL checks on tests/data (DuckDB only, ~2 s)
make nf-test        # the same fixture through Nextflow, no container (tests/data/batch/_sidecar.json)
make nf-test-errors # intake rejection: a wrong checksum is reported as a QC failure
make nf-test-docker # ...in the Docker image (builds it locally under its ghcr.io name)
make mimic VOCAB=/path/to/athena_vocab   # MIMIC-IV FHIR demo (downloads ~50 MB from PhysioNet)
```

Real run:

```bash
make sidecar BATCH=/path/to/batch          # once: write the batch's _sidecar.json (rddc-sidecar)
.tools/nextflow run . -profile docker \
    --sidecar /path/to/batch/_sidecar.json \
    --vocab_dir /path/to/athena_vocab \
    --outdir results
```

Run the converter without Nextflow:

```bash
PATH=.tools:$PATH bin/fhir_to_omop.sh --fhir-dir DIR --out-dir OUT [--vocab-dir ATHENA] \
    [--threads 8] [--memory 16GB] [--format parquet|csv] [--db keep.duckdb] [--strict] \
    [--source-config assets/sources/ID] [--max-unplaced-pct 5] [--max-unmapped-pct 25]
```

## Parameters

| Param | Default | |
|---|---|---|
| `--sidecar` | required | The batch's `_sidecar.json` (local path or `s3://`). Its FHIR files are converted; see [Input](#input-the-batch-sidecar) |
| `--outdir` | required | |
| `--vocab_dir` | none | Athena download containing `CONCEPT.csv`, `CONCEPT_RELATIONSHIP.csv` and `VOCABULARY.csv`. Without it, clinical `concept_id`s are 0 and source codes are kept |
| `--output_format` | `parquet` | `parquet` or `csv` |
| `--source_name` | the sidecar's `name` | `cdm_source.cdm_source_name` |
| `--strict_qc` | `false` | Fail the run if any QC check has status `fail` |
| `--max_object_mb` | `128` | Largest single JSON object, e.g. one patient Bundle |
| `--source_config` | `assets/sources/<sourceId>` if it exists | The source's mapping config; see [Source config](#source-config) |
| `--max_unplaced_pct` | `5` | QC fails when more than this share of one resource type's records can't be loaded |
| `--max_unmapped_pct` | `25` | QC fails when more than this share of one domain's rows has `concept_id` 0 (only with a vocabulary) |

The process uses the `process_medium` label (6 CPUs, 36 GB). It passes `task.cpus` and 80% of
`task.memory` to DuckDB as `threads` and `memory_limit`. DuckDB spills to the work directory
when it runs past the memory limit, so less memory makes the run slower but it still finishes.

## Input: the batch sidecar

The pipeline finds its files from the sidecar, as the other RDDC pipelines do
(rddc-genomics-workflows' `report-findings`); `subworkflows/local/sidecar_intake` is a
vendored copy of the shared intake there.

- **Files.** Each `contentUrl` is resolved against the sidecar's location and staged; md5 (and
  sha256 if given) are checked. `FhirNdjsonFile`, `FhirBundleFile` and `FhirResourceFile` are
  converted; other classes are skipped. A file that fails intake (checksum mismatch, a path
  outside the batch) is not converted and counts as an `intake_rejected_files` QC failure,
  since the OMOP output would be incomplete. `intake/intake.tsv` lists every entry with its
  route and reason.
- **Subjects.** The sidecar's subjects with a FHIR ID system set `person_source_value`:
  `fhir_patient_id` → `Patient.id`; `fhir_patient_identifier` → the `Patient.identifier`
  value of its `identifierSystemUri`. QC then checks that persons and listed subjects match
  one to one. One FHIR ID system per batch.
- **cdm_source.** `cdm_source_name` = the sidecar's `name` (`<sourceId>/<batchId>`),
  `cdm_source_abbreviation` = `sourceId`, `source_release_date` = the `exportTime` of the
  `FhirBulkExport` the files belong to, `source_documentation_reference` = the sidecar's `@id`.

- **Source config.** The sidecar's `sourceId` selects `assets/sources/<sourceId>/`, if the
  repository has one.

`bin/fhir_to_omop.sh` still runs on a plain directory (`--fhir-dir`, searched recursively);
the sidecar values are options there (`--subjects`, `--subject-id`, `--source-*`).

## Source config

Synthea writes every code under its standard FHIR URI. Real sources don't: they send ICD or
NDC codes under their own URIs, write ICD codes without the dot, and use local codes for
labs and units. A source config says how to read one source's codes, without changing the
SQL:

```
assets/sources/<sourceId>/
  systems.csv       system,vocabulary_id,match         a code system URI -> an OMOP vocabulary
  concept_map.csv   system,code,vocabulary_id,concept_code   one local code -> the Athena code that means the same
```

`match` is `exact`, `nodot` (`E119` for `E11.9`), `curie_underscore` (`HP:0000118` for
Athena's `HP_0000118`) or `strip_prefix` (`ORPHA:558` for `558`). The defaults, used for
every source, are in `sql/03_constants.sql`: SNOMED, LOINC, RxNorm, CVX, NDC, ICD-10-CM,
ICD-10, ICD-9-CM, ICD-10-PCS, CPT4, HCPCS, UCUM, HPO, Mondo and ORPHAcode, under their
FHIR URIs and, for most, their OIDs. See [assets/sources/README.md](assets/sources/README.md).

To write a config for a new source, run it once and read `qc.csv`:
`code_system_unrecognised` lists the code systems with no vocabulary and how many records
use them. `source_config` records which config a run used.

## Outputs

```
<outdir>/
  omop/<table>.parquet     16 CDM 5.4 tables in official column order (list below)
  source_id_map.parquet    resource_type, fhir_id -> omop_id (provenance back to FHIR)
  qc.csv                   check_name, table_name, value, status (ok|warn|fail), detail
  intake/intake.tsv        every sidecar entry: class, resource type, route (convert|skipped|rejected|file_set), reason
  intake/batch.json        the batch header (source, batch, contributor, sensitivity)
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
| `03_constants.sql` | Default FHIR system URI → OMOP vocabulary, the statuses that are not loaded, and the fixed concept ids for gender, race, ethnicity, visit class and type concepts |
| `04_source_*.sql` | Loads the [source config](#source-config), when there is one |
| `10_cdm_ddl.sql` | CDM 5.4 DDL for the tables listed above |
| `20_person.sql`, `30_visit.sql` | Patient/Practitioner/Organization → person, death, location, provider, care_site. Encounter → visit_occurrence |
| `40_events.sql` | All clinical resources go into one event table (`stg.event`) with every coding they carry, then concept lookup and the choice of coding (`stg.event_mapped`) |
| `50_domains.sql` | Writes each event to the table for its **domain** |
| `55_eras.sql` | condition_era and drug_era, using the OHDSI rules: same-concept records 30 days apart or less merge into one era. drug_era rolls exposures up to their ingredient (needs `CONCEPT_ANCESTOR.csv`), and `gap_days` is the uncovered days inside the era |
| `60_period_and_source.sql` | observation_period (span of each person's activity), cdm_source |
| `90_qc.sql` | QC checks (listed below) |
| `91_subjects.sql` / `91_subjects_none.sql` | Reconcile persons with the sidecar's subjects; without a subject list, a `warn` |
| `92_intake.sql` | FHIR files rejected at intake (`fail` if any) |

**Domain routing.** Each FHIR resource type has a default domain, listed below. When a
vocabulary is loaded, the domain of the standard concept takes precedence, which is the
OHDSI convention. For example, Synthea records "Stress (finding)" as a FHIR Condition, and
it lands in `observation`. A source code that maps to several standard concepts gives one
row per target.

**Which coding.** A CodeableConcept can carry several codings. The one used is the first
that maps to a standard concept, else the first the vocabulary knows, else the first.

**Dates.** A record with no date of its own takes its encounter's start (encounter
diagnoses often have only the encounter reference). Partial dates are kept: `2019` is
loaded as 2019-01-01 and `2019-03` as 2019-03-01, and a year-only `birthDate` gives a
person with only `year_of_birth`. QC counts both cases.

**Status.** Records that did not happen or were entered by mistake are not loaded:
`entered-in-error` everywhere, refuted Conditions and allergies, cancelled or planned
Encounters, cancelled Observations, cancelled or draft MedicationRequests, and not-done
Procedures, MedicationAdministrations and Immunizations (`stg.status_exclude` in
`03_constants.sql`). QC counts them. Stopped or on-hold records are loaded.

| FHIR | Default OMOP table | Notes |
|---|---|---|
| Patient | person, location, death | race/ethnicity from US Core extensions; state names → 2-letter codes; `deceasedBoolean` with no date gives no death row |
| Encounter | visit_occurrence | `class` → 9201/9202/9203/581476/5083; provider and care_site from conditional refs |
| Condition | condition_occurrence | onset/abatement; clinicalStatus → `condition_status_source_value` |
| Procedure | procedure_occurrence | |
| MedicationRequest / MedicationAdministration | drug_exposure | code from `medicationCodeableConcept`, a contained Medication or the referenced Medication; a Medication with ingredients but no code gives one row per ingredient; end date = start when FHIR has none |
| Immunization | drug_exposure | CVX |
| Observation | measurement if it has a numeric value or is lab/vital-signs; else observation | components (e.g. a BP panel) become one row each and the panel row is dropped |
| AllergyIntolerance | observation | |
| Device | device_exposure | Synthea gives no use period, so `manufactureDate` is the start date |
| Practitioner / Organization | provider / care_site | |

Timestamps keep the local wall-clock time and drop the UTC offset, so `*_date` and
`*_datetime` always agree.

**QC (`qc.csv`).** The report lists:

- resources per type, and whether each type is mapped
- events dropped because no person resolves or there's no start date, and the share per
  resource type (`fail` above `--max_unplaced_pct`)
- records not loaded because of their status; records dated from their encounter or from a
  partial date; patients deceased with no date
- encounter references with no matching visit
- percentage of unmapped concepts per domain (`fail` above `--max_unmapped_pct`), of
  unmapped units, and the top unmapped codes
- code systems with no vocabulary, with record counts
- the source config used, and entries in it the vocabulary can't resolve (`fail`)
- hard-coded constants missing, non-standard or deprecated in the loaded vocabulary (`fail`)
- person and visit foreign-key orphans (`fail`)
- persons with no observation period
- source values longer than 50 characters
- row counts
- sidecar subjects with no person, persons the sidecar does not list, and persons without a
  subject ID (`fail`)
- FHIR files the sidecar lists that intake rejected (`fail`)

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

## Non-Synthea data: MIMIC-IV FHIR demo

`make mimic VOCAB=/path/to/athena` downloads the
[MIMIC-IV Clinical Database Demo on FHIR](https://physionet.org/content/mimic-iv-fhir-demo/2.1.0/)
(PhysioNet, open access, ODbL: 100 real de-identified patients, 915,000 resources) and
converts it with `assets/sources/src-mimic-demo`. It is the check that the converter does
not depend on Synthea's habits. With Athena v5.0 29-AUG-26, about 17 s on a laptop:

| | Without the source config and fixes | Now |
|---|---|---|
| `condition_occurrence` rows | 0 of 5,051 Conditions (none has a date) | 4,433, dated from the encounter; 1.0% unmapped |
| Measurement units mapped | under 3% | 99% |
| Drug rows unmapped | 100% | 80.4% (NDC maps; formulary and ICU item codes are local) |
| Procedure rows unmapped | 63.5% | 42.1% (ICD maps; ICU item codes are local) |
| Measurement / observation rows unmapped | 97.8% / 99.6% | 97.8% / 99.4% (MIMIC's chart and lab item codes are local) |
| QC | 0 failures | 4 failures: the unmapped share of four domains is over the limit |

The run still fails QC, as it should: most MIMIC records carry only MIMIC's own item
codes, and `concept_map.csv` does not translate those yet. MedicationDispense,
MedicationStatement and Specimen are not mapped, and ICU and ED stays inside an admission
(`Encounter.partOf`) become visits of their own rather than `visit_detail`.

## Test data

- `tests/data/edge/`: hand-written FHIR for shapes Synthea never produces (partial dates,
  no dates, several codings, contained Medications, statuses, local code systems), with its
  source config. See its README.

- `tests/data/batch/_sidecar.json`: the batch's sidecar, written by rddc-sidecar
  (`make test-sidecar`); `_sidecar.errors.json` is a copy with one wrong checksum.
- `tests/data/batch/fhir/`: 8 Synthea patients (`-p 6 -s 7`, including deceased), bulk NDJSON,
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
  out for "finding + value" codes. Coded values (`valueCodeableConcept`) use their first
  coding only. Local codes map only through a source config.
- **Not mapped:** `dose_era`, `visit_detail` (child Encounters become visits), `note` (from
  DocumentReference), `specimen`, `cost` / `payer_plan_period` (from Claim/EOB),
  MedicationDispense, MedicationStatement, FamilyMemberHistory, QuestionnaireResponse and
  DiagnosticReport. Its results are already mapped as Observations. Observation
  `valueDateTime`, reference ranges and `dataAbsentReason` are not carried.
- **Drugs:** no `days_supply` or `quantity` from dispenseRequest, and no route. Vaccines
  (CVX) have no RxNorm ingredient ancestor in current Athena releases, so they aren't in
  `drug_era`. QC reports them as `drug_without_ingredient`.
- **IDs:** `INTEGER` ids come from `row_number`, so they're stable for the same input but not
  across incremental loads.
- **Validation:** checked by `tests/run_tests.sh`, `qc.csv` and DQD (`make dqd`), including
  DQD with a full Athena vocabulary on 100 Synthea patients (see
  [Data quality](#data-quality-ohdsi-dqd)), and the MIMIC-IV FHIR demo (`make mimic`). Not yet
  compared with an independent conversion of the same patients (OHDSI's ETL-Synthea, or
  the MIMIC-IV demo in OMOP), and DQD has not been run on the MIMIC output.

## License

Apache-2.0. See [LICENSE](LICENSE).
