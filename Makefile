# Common tasks. Tools are fetched into .tools/ (gitignored); nothing is installed system-wide.
DUCKDB_VERSION ?= 2.0.0
SHELL := /bin/bash
export NXF_HOME ?= $(CURDIR)/.tools/nxf-home
NEXTFLOW := $(CURDIR)/.tools/nextflow

.PHONY: tools test nf-test nf-test-docker image synthea clean

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

clean:
	rm -rf work results .nextflow .nextflow.log*
