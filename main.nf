#!/usr/bin/env nextflow
/*
 * rddc-fhir-to-omop: FHIR R4 -> OMOP CDM 5.4 on a single node, in one DuckDB process.
 *
 * Input: a directory of FHIR resources, either bulk-export NDJSON (one file per resource
 * type, optionally .gz) or Bundle JSON files (Synthea's default output).
 * Optional: an Athena vocabulary download (CONCEPT.csv, CONCEPT_RELATIONSHIP.csv,
 * VOCABULARY.csv). Without it every clinical concept_id is 0 and source codes are kept.
 */

// Pipeline parameters (declared before the include below). Shared params (input, outdir) are in nextflow.config.
params.vocab_dir     = null        // Athena vocabulary directory
params.output_format = 'parquet'   // parquet | csv
params.source_name   = 'RDDC FHIR' // cdm_source.cdm_source_name
params.strict_qc     = false       // fail the run if any QC check has status 'fail'
params.max_object_mb = 128         // largest single JSON object (e.g. one patient Bundle)

// After the params: an included module sees params as they are at include time.
include { FHIR_TO_OMOP } from './modules/local/fhir_to_omop/main.nf'

workflow {
    if (!params.input)  error "--input (directory of FHIR NDJSON/JSON) is required"
    if (!params.outdir) error "--outdir is required"
    if (!(params.output_format in ['parquet', 'csv'])) error "--output_format must be parquet or csv"

    fhir  = channel.value(file(params.input, checkIfExists: true, type: 'dir'))
    vocab = channel.value(params.vocab_dir
        ? file(params.vocab_dir, checkIfExists: true, type: 'dir')
        : file("${projectDir}/assets/NO_VOCAB", checkIfExists: true))
    sql   = channel.value(file("${projectDir}/sql", checkIfExists: true, type: 'dir'))

    FHIR_TO_OMOP(fhir, vocab, sql)

    FHIR_TO_OMOP.out.versions
        .map { f -> f.text }
        .unique()
        .collectFile(name: 'software_versions.yml', storeDir: "${params.outdir}/pipeline_info")
}
