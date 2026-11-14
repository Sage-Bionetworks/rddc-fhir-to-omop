#!/usr/bin/env bash
# One-shot DQD: build the CDM database from pipeline output, then run DQD.
# Usage: qa/dqd/run.sh <omop_dir> <vocab_dir|-> <out_dir> [source_name]
# Needs the R packages from `make dqd-deps` (installed into .tools/R-lib) and a JDK.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
omop=${1:?omop_dir}; vocab=${2:?vocab_dir or -}; out=${3:?out_dir}; name=${4:-rddc-fhir-to-omop}
mkdir -p "$out"
export PATH=$root/.tools:$PATH
export R_LIBS_USER=${R_LIBS_USER:-$root/.tools/R-lib}
if [[ -z ${JAVA_HOME:-} || ! -d ${JAVA_HOME:-} ]]; then
  JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
fi
export JAVA_HOME LD_LIBRARY_PATH=$JAVA_HOME/lib/server${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

"$here/build_cdm_db.sh" "$omop" "$vocab" "$out/omop_cdm.duckdb"
Rscript "$here/run_dqd.R" "$out/omop_cdm.duckdb" "$out" "$name" "${DQD_THREADS:-1}"
