process FHIR_TO_OMOP {
    label 'process_medium'
    publishDir "${params.outdir}", mode: 'copy', pattern: '{omop,qc.csv,source_id_map.*}'

    input:
    path fhir,  stageAs: 'fhir'
    path vocab, stageAs: 'vocab/*'
    path sql,   stageAs: 'sql'

    output:
    path 'omop',            emit: omop
    path 'qc.csv',          emit: qc
    path 'source_id_map.*', emit: id_map
    path 'versions.yml',    emit: versions

    script:
    def vocab_arg = vocab.name == 'NO_VOCAB' ? '' : "--vocab-dir ${vocab}"
    def strict    = params.strict_qc ? '--strict' : ''
    // Leave ~20% of the task's memory for DuckDB's own overhead outside memory_limit.
    def mem_gb    = Math.max(1, (task.memory.toGiga() * 0.8) as int)
    """
    fhir_to_omop.sh \\
        --fhir-dir ${fhir} \\
        --out-dir . \\
        --sql-dir ${sql} \\
        ${vocab_arg} \\
        --threads ${task.cpus} \\
        --memory ${mem_gb}GB \\
        --format ${params.output_format} \\
        --max-object-mb ${params.max_object_mb} \\
        --source-name '${params.source_name}' \\
        ${strict}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        duckdb: \$(DUCKDB_AGENT_MODE=0 duckdb --version | awk '{print \$1}')
    END_VERSIONS
    """

    stub:
    """
    mkdir omop
    touch omop/person.${params.output_format} qc.csv source_id_map.${params.output_format}
    printf '"%s":\\n    duckdb: stub\\n' "${task.process}" > versions.yml
    """
}
