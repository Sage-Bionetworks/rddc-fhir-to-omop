process FHIR_TO_OMOP {
    label 'process_medium'
    publishDir "${params.outdir}", mode: 'copy', pattern: '{omop,qc.csv,source_id_map.*}'

    input:
    path fhir,     stageAs: 'fhir/??/*'   // the sidecar's FHIR files, one subfolder each (names may repeat)
    path vocab,    stageAs: 'vocab/*'
    path sql,      stageAs: 'sql'
    path subjects                         // subjects.csv from the sidecar, or NO_SUBJECTS
    val  source                           // cdm_source and subject ID settings (main.nf)
    path source_config, stageAs: 'source_config/*'   // assets/sources/<sourceId>, or NO_SOURCE_CONFIG

    output:
    path 'omop',            emit: omop
    path 'qc.csv',          emit: qc
    path 'source_id_map.*', emit: id_map
    path 'versions.yml',    emit: versions

    script:
    def vocab_arg = vocab.toString().endsWith('NO_VOCAB') ? '' : "--vocab-dir ${vocab}"
    def strict    = params.strict_qc.toString() == 'true' ? '--strict' : ''   // CLI gives "false" as a string
    def subj_arg  = subjects.name == 'NO_SUBJECTS' ? '' : "--subjects ${subjects}"
    def cfg_arg   = source_config.toString().endsWith('NO_SOURCE_CONFIG') ? '' : "--source-config ${source_config}"
    def ident_arg = source.subject_id == 'identifier' ? "--identifier-system '${source.identifier_system}'" : ''
    // Leave ~20% of the task's memory for DuckDB's own overhead outside memory_limit.
    def mem_gb    = Math.max(1, (task.memory.toGiga() * 0.8) as int)
    """
    fhir_to_omop.sh \\
        --fhir-dir fhir \\
        --out-dir . \\
        --sql-dir ${sql} \\
        ${vocab_arg} \\
        --threads ${task.cpus} \\
        --memory ${mem_gb}GB \\
        --format ${params.output_format} \\
        --max-object-mb ${params.max_object_mb} \\
        --source-name '${source.name}' \\
        --source-abbr '${source.abbr}' \\
        --source-release-date '${source.release_date}' \\
        --source-reference '${source.reference}' \\
        --subject-id ${source.subject_id} ${ident_arg} ${subj_arg} \\
        --rejected-files ${source.rejected_files} \\
        ${cfg_arg} \\
        --max-unplaced-pct ${params.max_unplaced_pct} \\
        --max-unmapped-pct ${params.max_unmapped_pct} \\
        ${strict}

    # What the conversion used besides the code: the image, DuckDB, the vocabulary release (the 'None'
    # row of VOCABULARY.csv, as in cdm_source) and the source config with a checksum of its files.
    vocabulary=none
    if [ -n "${vocab_arg}" ]; then
        vocabulary=\$(awk -F'\\t' '\$1 == "None" { print \$4 }' ${vocab}/VOCABULARY.csv)
    fi
    source_config=none
    if [ -n "${cfg_arg}" ]; then
        source_config="\$(basename ${source_config}) md5:\$(cat \$(find -L ${source_config} -type f -name '*.csv' | sort) | md5sum | cut -d' ' -f1)"
    fi
    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        container: "${task.container ?: 'none'}"
        duckdb: "\$(DUCKDB_AGENT_MODE=0 duckdb --version | awk '{print \$1}')"
        vocabulary: "\$vocabulary"
        source_config: "\$source_config"
    END_VERSIONS
    """

    stub:
    """
    mkdir omop
    touch omop/person.${params.output_format} qc.csv source_id_map.${params.output_format}
    printf '"%s":\\n    duckdb: stub\\n' "${task.process}" > versions.yml
    """
}
