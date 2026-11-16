#!/usr/bin/env nextflow
/*
 * rddc-fhir-to-omop: FHIR R4 -> OMOP CDM 5.4 on a single node, in one DuckDB process.
 *
 * Input: the batch's Croissant sidecar (--sidecar, _sidecar.json; rddc-model), not a
 * directory. SIDECAR_INTAKE stages the files it lists and checks their checksums:
 *   FhirNdjsonFile, FhirBundleFile, FhirResourceFile  -> convert
 *   anything else                                     -> skipped, with a reason
 * The sidecar also gives the subjects (person_source_value follows their idSystem, and QC
 * reconciles persons with them) and cdm_source defaults (source, batch, export time).
 * The sidecar's sourceId also selects the source's mapping config, if there is one
 * (assets/sources/<sourceId>/: its own code system URIs and local codes).
 * Optional: an Athena vocabulary download (CONCEPT.csv, CONCEPT_RELATIONSHIP.csv,
 * VOCABULARY.csv). Without it every clinical concept_id is 0 and source codes are kept.
 */

// Pipeline parameters (declared before the includes below). Shared params (outdir) are in nextflow.config.
params.sidecar       = null        // _sidecar.json of the batch
params.vocab_dir     = null        // Athena vocabulary directory
params.output_format = 'parquet'   // parquet | csv
params.source_name   = null        // cdm_source.cdm_source_name (default: the sidecar's name)
params.strict_qc     = false       // fail the run if any QC check has status 'fail'
params.max_object_mb = 128         // largest single JSON object (e.g. one patient Bundle)
params.source_config     = null    // the source's mapping config directory (default: by sourceId, below)
params.source_config_dir = "${projectDir}/assets/sources"   // <sourceId>/ under here is used if it exists
params.max_unplaced_pct  = 5       // QC fail: records of one resource type that could not be loaded
params.max_unmapped_pct  = 25      // QC fail: rows of one domain with concept_id 0 (with a vocabulary)

// After the params: an included module sees params as they are at include time.
include { SIDECAR_INTAKE } from './subworkflows/local/sidecar_intake/main.nf'
include { FHIR_TO_OMOP   } from './modules/local/fhir_to_omop/main.nf'

// Sidecar classes this pipeline converts, and subject ID systems it can reconcile.
def fhirClasses()   { return ['FhirNdjsonFile', 'FhirBundleFile', 'FhirResourceFile'] }
def fhirIdSystems() { return ['fhir_patient_id', 'fhir_patient_identifier'] }

// The batch's FHIR subjects: how person_source_value is taken, and the IDs to reconcile.
def fhirSubjects(Map batch) {
    def subjects = batch.subjects.findAll { s -> s.idSystem in fhirIdSystems() }
    def systems = subjects*.idSystem.unique()
    if (systems.size() > 1) {
        error "the sidecar mixes FHIR subject ID systems ${systems}; use one per batch"
    }
    if (systems == ['fhir_patient_identifier']) {
        def uris = subjects*.identifierSystemUri.unique()
        if (uris.size() != 1 || !uris[0]) {
            error "fhir_patient_identifier subjects need one identifierSystemUri; the sidecar gives ${uris}"
        }
        return [mode: 'identifier', system: uris[0], ids: subjects*.subjectId]
    }
    return [mode: 'id', system: '', ids: subjects*.subjectId]
}

// The source's mapping config: --source_config, else <source_config_dir>/<sourceId> if it exists.
def sourceConfig(Map batch) {
    if (params.source_config) return file(params.source_config, checkIfExists: true, type: 'dir')
    def id = batch.sourceId as String
    if (id ==~ /[A-Za-z0-9][A-Za-z0-9._-]*/) {
        def dir = file("${params.source_config_dir}/${id}")
        if (dir.isDirectory()) return dir
    }
    return file("${projectDir}/assets/NO_SOURCE_CONFIG", checkIfExists: true)
}

def intakeRow(Map meta, String route, String reason) {
    return [meta.id, meta.name, meta.additionalType, meta.resourceType ?: '', meta.encodingFormat ?: '',
            meta.subjectIds.size(), route, reason].join('\t') + '\n'
}

workflow {
    if (!params.sidecar) error "--sidecar (the batch's _sidecar.json) is required"
    if (!params.outdir)  error "--outdir is required"
    if (!(params.output_format in ['parquet', 'csv'])) error "--output_format must be parquet or csv"

    SIDECAR_INTAKE(file(params.sidecar, checkIfExists: true))

    routed = SIDECAR_INTAKE.out.files.map { meta, f ->
        def convert = meta.additionalType in fhirClasses()
        [meta + [route: convert ? 'convert' : 'skipped', route_reason: convert ? '' : 'not_applicable_class'], f]
    }
    fhir = routed.filter { meta, _f -> meta.route == 'convert' }
        .map { _meta, f -> f }
        .collect()
        .ifEmpty { error "the sidecar lists no FHIR files (${fhirClasses().join(', ')}) that passed intake" }

    routed.map { meta, _f -> intakeRow(meta, meta.route, meta.route_reason) }
        .mix(SIDECAR_INTAKE.out.rejected.map { meta, reason -> intakeRow(meta, 'rejected', reason) })
        .mix(SIDECAR_INTAKE.out.sets.map { meta -> intakeRow(meta, 'file_set', '') })
        .collectFile(name: 'intake.tsv', storeDir: "${params.outdir}/intake", sort: true,
                     seed: "file_id\tname\tclass\tresource_type\tencoding_format\tsubject_count\troute\treason\n")

    batch = SIDECAR_INTAKE.out.batch
    batch.map { b -> groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(b.findAll { k, _v -> k != 'subjects' })) + '\n' }
        .collectFile(name: 'batch.json', storeDir: "${params.outdir}/intake")

    subjects = batch.map { b -> fhirSubjects(b) }
    subjects_csv = subjects.flatMap { s -> s.ids ? ['subject_id'] + s.ids : [] }
        .collectFile(name: 'subjects.csv', newLine: true, sort: false)
        .ifEmpty { file("${projectDir}/assets/NO_SUBJECTS", checkIfExists: true) }

    // cdm_source from the sidecar: its name and source, the export time of the FHIR bulk
    // export the converted files belong to (earliest, if several), and the sidecar's @id as
    // the documentation reference.
    export_time = routed.filter { meta, _f -> meta.route == 'convert' && meta.fileSet?.exportTime }
        .map { meta, _f -> meta.fileSet.exportTime as String }
        .unique()
        .toList()
    // FHIR files the sidecar lists but intake rejected: the OMOP output would be incomplete,
    // so the converter reports them as a QC failure.
    rejected_fhir = SIDECAR_INTAKE.out.rejected
        .filter { meta, _reason -> meta.additionalType in fhirClasses() }
        .count()
    source = batch.combine(subjects).combine(export_time.map { t -> [t] }).combine(rejected_fhir)
        .map { b, s, times, n_rejected ->
            [name             : params.source_name ?: b.name,
             abbr             : b.sourceId ?: '',
             release_date     : times ? (times.min() as String).take(10) : '',
             reference        : b.urn ?: '',
             subject_id       : s.mode,
             identifier_system: s.system,
             rejected_files   : n_rejected]
        }

    vocab = channel.value(params.vocab_dir
        ? file(params.vocab_dir, checkIfExists: true, type: 'dir')
        : file("${projectDir}/assets/NO_VOCAB", checkIfExists: true))
    sql   = channel.value(file("${projectDir}/sql", checkIfExists: true, type: 'dir'))

    source_config = batch.map { b -> sourceConfig(b) }.first()

    FHIR_TO_OMOP(fhir, vocab, sql, subjects_csv, source, source_config)

    FHIR_TO_OMOP.out.versions
        .map { f -> f.text }
        .unique()
        .collectFile(name: 'software_versions.yml', storeDir: "${params.outdir}/pipeline_info")
}
