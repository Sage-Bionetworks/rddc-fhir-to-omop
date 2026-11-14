# Runtime for the FHIR_TO_OMOP process: bash + the DuckDB CLI.
FROM debian:bookworm-slim
ARG DUCKDB_VERSION=2.0.0
ARG TARGETARCH=amd64
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gawk procps \
 && curl -fsSL "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb-cli-linux-${TARGETARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin duckdb \
 && apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/* \
 && DUCKDB_AGENT_MODE=0 duckdb --version
