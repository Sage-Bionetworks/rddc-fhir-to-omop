# Common tasks. Tools are fetched into .tools/ (gitignored); nothing is installed system-wide.
DUCKDB_VERSION ?= 2.0.0
SHELL := /bin/bash
export NXF_HOME ?= $(CURDIR)/.tools/nxf-home
NEXTFLOW := $(CURDIR)/.tools/nextflow

.PHONY: tools test nf-test nf-test-errors nf-test-docker image synthea sidecar test-sidecar dqd-deps dqd clean

tools: .tools/duckdb .tools/nextflow   ## fetch duckdb CLI + nextflow into .tools/

.tools/duckdb:
	mkdir -p .tools
	curl -fsSL https://github.com/duckdb/duckdb/releases/download/v$(DUCKDB_VERSION)/duckdb-cli-linux-amd64.tar.gz | tar -xz -C .tools duckdb

.tools/nextflow:
	mkdir -p .tools
	curl -fsSL https://get.nextflow.io -o $@ && chmod +x $@ && $@ -version >/dev/null

test: .tools/duckdb   ## SQL/ETL checks against tests/data (no Nextflow)
	tests/run_tests.sh

nf-test: tools   ## full pipeline via Nextflow, no container
	$(NEXTFLOW) run . -profile test,local --outdir results/test

nf-test-errors: tools   ## intake rejection: a wrong checksum is a QC fail (and exit 3 under strict QC)
	$(NEXTFLOW) run . -profile test,local --sidecar tests/data/batch/_sidecar.errors.json --strict_qc false \
	    --outdir results/test-errors
	grep -q $$'Observation.ndjson.gz\trejected\tchecksum_mismatch_md5' <(cut -f2,7,8 results/test-errors/intake/intake.tsv)
	grep -q '^intake_rejected_files,fhir,1.0,fail,' results/test-errors/qc.csv
	@echo "intake rejection reported"

nf-test-docker: tools image   ## full pipeline via Nextflow in the Docker image
	$(NEXTFLOW) run . -profile test,docker --outdir results/test-docker

image:   ## build rddc-fhir-to-omop:dev
	docker build --build-arg DUCKDB_VERSION=$(DUCKDB_VERSION) -t rddc-fhir-to-omop:dev .

# Fresh Synthea bulk export: make synthea N=100 SEED=1 OUT=data/synthea-100
N ?= 100
SEED ?= 1
OUT ?= data/synthea-$(N)
synthea:
	scripts/generate_synthea.sh $(OUT) $(N) $(SEED)

# The pipeline's input is a batch sidecar (_sidecar.json), written by rddc-sidecar.
#   make sidecar BATCH=data/synthea-100 [EXPORT_TIME=...]   any directory of FHIR NDJSON / Bundles
#   make test-sidecar                                         regenerate the test batch's sidecars
# The test batch also holds _sidecar.errors.json (intake rejection case), so generate and
# validate it with --exclude _sidecar.errors.json.
RDDC_SIDECAR ?= ../rddc-sidecar/target/release/rddc-sidecar
BATCH ?= $(OUT)
EXPORT_TIME ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
SIDECAR_ARGS = --contributor-id test-site --source-id src-synthea-01 --bucket rddc-deposit-test \
    --prefix '{sourceId}/{batchId}/' --attest-direct-identifiers-removed --synthetic --fhir-subject id
sidecar:
	$(RDDC_SIDECAR) generate $(BATCH) $(SIDECAR_ARGS) --batch-id $(notdir $(BATCH)) --export-time $(EXPORT_TIME)

test-sidecar:
	$(RDDC_SIDECAR) generate tests/data/batch $(SIDECAR_ARGS) --batch-id 2026-11-synthea-p6 \
	    --export-time 2026-11-11T00:00:00Z --sidecar-id urn:uuid:5e1d0c2a-0000-4000-8000-000000000001 \
	    --created-at 2026-11-16T00:00:00Z --exclude _sidecar.errors.json --force
	python3 -I tests/make_error_sidecar.py

# OHDSI Data Quality Dashboard. R packages go into .tools/R-lib (binary builds from Posit
# Package Manager for this distro, CRAN as fallback); needs R >= 4.2 and a JDK.
#   make dqd                                   fixture + tests/data/vocab_mini
#   make dqd INPUT=data/synthea-100 VOCAB=/path/to/athena
INPUT ?= tests/data/batch/fhir
VOCAB ?= tests/data/vocab_mini
DQD_OUT ?= results/dqd
dqd-deps:
	mkdir -p .tools/R-lib
	R_LIBS_USER=$(CURDIR)/.tools/R-lib Rscript -e 'codename <- tryCatch(sub("VERSION_CODENAME=", "", grep("^VERSION_CODENAME=", readLines("/etc/os-release"), value = TRUE)), error = function(e) ""); \
	  options(repos = c(P3M = sprintf("https://packagemanager.posit.co/cran/__linux__/%s/latest", codename), CRAN = "https://cloud.r-project.org"), \
	          HTTPUserAgent = sprintf("R/%s R (%s)", getRversion(), paste(getRversion(), R.version["platform"], R.version["arch"], R.version["os"]))); \
	  install.packages(c("DataQualityDashboard", "DatabaseConnector", "SqlRender", "duckdb", "CommonDataModel"), lib = Sys.getenv("R_LIBS_USER"))'

dqd: .tools/duckdb
	PATH=$(CURDIR)/.tools:$$PATH bin/fhir_to_omop.sh --fhir-dir $(INPUT) --out-dir $(DQD_OUT)/etl $(if $(VOCAB),--vocab-dir $(VOCAB))
	qa/dqd/run.sh $(DQD_OUT)/etl/omop $(or $(VOCAB),-) $(DQD_OUT) "$(notdir $(INPUT))"

clean:
	rm -rf work results .nextflow .nextflow.log*
