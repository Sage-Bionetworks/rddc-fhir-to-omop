#!/usr/bin/env bash
# Build a complete CDM 5.4 DuckDB database. Don't name the file cdm.duckdb: the catalog name
# would clash with the "cdm" schema.
# Builds (schema "cdm", all 39 tables) for DQD:
# official DDL + the pipeline's OMOP output + a vocabulary.
#
# Usage: build_cdm_db.sh <omop_dir> <vocab_dir|-> <db_file>
#   omop_dir   the pipeline's omop/ directory (*.parquet or *.csv)
#   vocab_dir  Athena download (tab-delimited CONCEPT.csv, ...); '-' for none.
#              Any of the 9 Athena vocabulary files that are present are loaded.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
omop=$(cd "${1:?omop_dir}" && pwd)
vocab=${2:?vocab_dir or -}
db=${3:?db_file}
[[ $vocab == - ]] || vocab=$(cd "$vocab" && pwd)
export DUCKDB_AGENT_MODE=0
rm -f "$db" "$db.wal"
sq() { printf "'%s'" "${1//\'/\'\'}"; }

{
  echo ".bail on"
  cat "$here/cdm54_ddl_duckdb.sql"
  # Clinical tables from the pipeline. Column names match the DDL, so insert by name.
  for f in "$omop"/*.parquet "$omop"/*.csv; do
    [[ -e $f ]] || continue
    t=$(basename "${f%.*}")
    if [[ $f == *.parquet ]]; then src="read_parquet($(sq "$f"))"; else src="read_csv($(sq "$f"), header = true)"; fi
    echo "INSERT INTO cdm.$t BY NAME SELECT * FROM $src;"
  done
} | duckdb "$db"

# Athena files: tab-delimited, unquoted, dates as YYYYMMDD. Build one INSERT per file from
# the target table's column types so every value is cast explicitly (errors stay loud).
if [[ $vocab != - ]]; then
  for t in concept concept_relationship concept_ancestor concept_synonym concept_class domain \
           vocabulary relationship drug_strength; do
    f=$vocab/${t^^}.csv
    [[ -f $f ]] || continue
    echo "loading $t" >&2
    stmt=$(duckdb -list -noheader "$db" -c "
      SELECT 'INSERT INTO cdm.$t SELECT ' || string_agg(
               CASE WHEN data_type = 'DATE'
                    THEN 'strptime(nullif(\"' || column_name || '\", ''''), ''%Y%m%d'')::DATE'
                    ELSE 'CAST(nullif(\"' || column_name || '\", '''') AS ' || data_type || ')' END,
               ', ' ORDER BY ordinal_position)
             || ' FROM read_csv($(sq "$f" | sed "s/'/''/g"), delim = ''\t'', quote = '''', escape = '''', header = true, all_varchar = true, normalize_names = true);'
      FROM information_schema.columns WHERE table_schema = 'cdm' AND table_name = '$t'")
    duckdb "$db" -c "$stmt"
  done
fi

duckdb -box "$db" -c "
  SELECT table_name, estimated_size AS approx_rows FROM duckdb_tables()
  WHERE schema_name = 'cdm' AND estimated_size > 0 ORDER BY table_name"
