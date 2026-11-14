#!/usr/bin/env bash
# FHIR R4 (bulk NDJSON or Bundle JSON) -> OMOP CDM 5.4, in a single DuckDB process.
#
# Usage:
#   fhir_to_omop.sh --fhir-dir DIR --out-dir DIR [--vocab-dir DIR] [--sql-dir DIR]
#                   [--threads N] [--memory 8GB] [--format parquet|csv]
#                   [--db FILE] [--source-name NAME] [--max-object-mb 128] [--strict]
#
# Writes <out-dir>/omop/<table>.{parquet,csv}, <out-dir>/source_id_map.<ext>,
# <out-dir>/qc.csv. --db keeps the DuckDB database file (default: temporary).
# --strict exits 3 if any QC check has status 'fail'.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
fhir_dir= out_dir= vocab_dir= sql_dir=$here/../sql
threads=${DUCKDB_THREADS:-2} memory=${DUCKDB_MEMORY:-4GB} format=parquet
db= source_name="RDDC FHIR" strict=0 max_object_mb=128

while (($#)); do
  case $1 in
    --fhir-dir) fhir_dir=$2; shift ;;
    --out-dir) out_dir=$2; shift ;;
    --vocab-dir) vocab_dir=$2; shift ;;
    --sql-dir) sql_dir=$2; shift ;;
    --threads) threads=$2; shift ;;
    --memory) memory=$2; shift ;;
    --format) format=$2; shift ;;
    --db) db=$2; shift ;;
    --source-name) source_name=$2; shift ;;
    --max-object-mb) max_object_mb=$2; shift ;;   # largest single JSON object (Bundle)
    --strict) strict=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n $fhir_dir && -n $out_dir ]] || { echo "--fhir-dir and --out-dir are required" >&2; exit 2; }
[[ $format == parquet || $format == csv ]] || { echo "--format must be parquet or csv" >&2; exit 2; }
command -v duckdb >/dev/null || { echo "duckdb CLI not found on PATH" >&2; exit 2; }

fhir_dir=$(cd "$fhir_dir" && pwd)
shopt -s nullglob
inputs=("$fhir_dir"/*.ndjson "$fhir_dir"/*.ndjson.gz "$fhir_dir"/*.json "$fhir_dir"/*.json.gz)
inputs=("${inputs[@]##*/export_status.json}")   # bulk export manifest, not a resource
mapfile -t inputs < <(printf '%s\n' "${inputs[@]}" | grep -v '^$' || true)
((${#inputs[@]})) || { echo "no *.ndjson / *.json files in $fhir_dir" >&2; exit 1; }
if [[ -n $vocab_dir ]]; then
  vocab_dir=$(cd "$vocab_dir" && pwd)
  for f in CONCEPT CONCEPT_RELATIONSHIP VOCABULARY; do
    [[ -f $vocab_dir/$f.csv ]] || { echo "missing $vocab_dir/$f.csv (Athena download)" >&2; exit 1; }
  done
fi

mkdir -p "$out_dir/omop"
out_dir=$(cd "$out_dir" && pwd)
tmp=$(mktemp -d "$out_dir/.duckdb_tmp.XXXX")
trap 'rm -rf "$tmp"' EXIT
db=${db:-$tmp/omop.duckdb}
rm -f "$db" "$db.wal"

sq() { printf "'%s'" "${1//\'/\'\'}"; }   # SQL string literal
file_list="[$(for f in "${inputs[@]}"; do printf '%s,' "$(sq "$f")"; done | sed 's/,$//')]"

tables=(location care_site provider person observation_period death visit_occurrence
        condition_occurrence drug_exposure procedure_occurrence device_exposure
        measurement observation cdm_source)
copy_opts=$([[ $format == parquet ]] && echo "FORMAT parquet, COMPRESSION zstd" || echo "FORMAT csv, HEADER")

{
  echo ".bail on"
  echo "SET threads = $threads;"
  echo "SET memory_limit = $(sq "$memory");"
  echo "SET temp_directory = $(sq "$tmp/spill");"
  echo "SET preserve_insertion_order = false;"
  echo "SET VARIABLE max_object_size = $((max_object_mb * 1024 * 1024));"
  echo ".timer on"
  echo "SET VARIABLE fhir_glob = $file_list;"
  echo "SET VARIABLE vocab_dir = $(sq "${vocab_dir:-}");"
  echo "SET VARIABLE source_name = $(sq "$source_name");"
  echo "SET VARIABLE source_abbr = $(sq "${source_name// /_}");"
  echo "SET VARIABLE cdm_holder = $(sq "${CDM_HOLDER:-Sage Bionetworks}");"
  stages=(01_load_fhir.sql "$([[ -n $vocab_dir ]] && echo 02_vocab_athena.sql || echo 02_vocab_empty.sql)"
          03_constants.sql 10_cdm_ddl.sql 20_person.sql 30_visit.sql 40_events.sql
          50_domains.sql 60_period_and_source.sql 90_qc.sql)
  for s in "${stages[@]}"; do
    echo ".print '== $s'"
    cat "$sql_dir/$s"
    echo
  done
  echo ".print '== export'"
  for t in "${tables[@]}"; do
    echo "COPY (SELECT * FROM $t ORDER BY 1) TO $(sq "$out_dir/omop/$t.$format") ($copy_opts);"
  done
  echo "COPY (SELECT * FROM stg.id_map ORDER BY 1, 3) TO $(sq "$out_dir/source_id_map.$format") ($copy_opts);"
  echo "COPY stg.qc TO $(sq "$out_dir/qc.csv") (FORMAT csv, HEADER);"
  echo ".timer off"
  echo ".mode box"
  echo "SELECT check_name, table_name, value, status, detail FROM stg.qc WHERE status <> 'ok' OR check_name = 'row_count' ORDER BY status = 'ok', check_name, table_name;"
} > "$tmp/run.sql"

# DuckDB >= 2.0 switches to an "agent" output mode when it detects an AI agent; force it off
# so logs look the same wherever this runs. Older CLIs ignore the variable.
DUCKDB_AGENT_MODE=0 duckdb "$db" < "$tmp/run.sql"

if ((strict)) && grep -q ',fail,' "$out_dir/qc.csv"; then
  echo "QC failures (see $out_dir/qc.csv)" >&2
  exit 3
fi
