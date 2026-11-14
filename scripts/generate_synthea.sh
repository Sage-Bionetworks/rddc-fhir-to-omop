#!/usr/bin/env bash
# Generate a Synthea FHIR R4 bulk export (NDJSON, one file per resource type).
#
# Usage: scripts/generate_synthea.sh <out_dir> [patients=10] [seed=42] [years_of_history=10]
#
# Reuses the jar vendored in ../rddc-sidecar/synthea by default; override with SYNTHEA_JAR.
# Get one from https://github.com/synthetichealth/synthea/releases if you don't have it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
out=${1:?usage: generate_synthea.sh <out_dir> [patients] [seed] [years_of_history]}
patients=${2:-10}
seed=${3:-42}
years=${4:-10}
jar=${SYNTHEA_JAR:-$here/../../rddc-sidecar/synthea/synthea-with-dependencies.jar}

[[ -f $jar ]] || { echo "Synthea jar not found: $jar (set SYNTHEA_JAR)" >&2; exit 1; }
mkdir -p "$out"
out=$(cd "$out" && pwd)

# -s population seed, -cs clinician seed: both fixed so output is reproducible.
# Synthea writes into exporter.baseDirectory; run from a temp dir so no stray ./output appears.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && java -jar "$jar" -p "$patients" -s "$seed" -cs "$seed" -r 20261101 \
  --exporter.baseDirectory="$tmp/output" \
  --exporter.years_of_history="$years" \
  --exporter.fhir.export=true \
  --exporter.fhir.bulk_data=true \
  --exporter.hospital.fhir.export=true \
  --exporter.practitioner.fhir.export=true \
  --exporter.ccda.export=false \
  --exporter.csv.export=false \
  --exporter.text.export=false \
  --exporter.metadata.export=false \
  --generate.only_alive_patients=false \
  Massachusetts >/dev/null)

rm -rf "$out"/*.ndjson "$out"/*.ndjson.gz
cp "$tmp"/output/fhir/*.ndjson "$out"/
echo "wrote $(ls "$out" | wc -l) NDJSON files to $out"
