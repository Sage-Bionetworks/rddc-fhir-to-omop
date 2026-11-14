# Run the OHDSI Data Quality Dashboard on a CDM 5.4 DuckDB database built by build_cdm_db.sh.
#
# Usage: Rscript run_dqd.R <db_file> <out_dir> [source_name] [num_threads]
# Writes <out_dir>/dqd_results.json (open with DataQualityDashboard::viewDqDashboard),
# <out_dir>/dqd_summary.csv (one row per check result that failed or errored) and prints
# the overview.
options(width = 200)
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("usage: run_dqd.R <db_file> <out_dir> [source_name] [num_threads]")
db <- normalizePath(args[1], mustWork = TRUE)
out <- args[2]
source_name <- if (length(args) >= 3) args[3] else "rddc-fhir-to-omop"
threads <- if (length(args) >= 4) as.integer(args[4]) else 1L
dir.create(out, recursive = TRUE, showWarnings = FALSE)

cd <- DatabaseConnector::createConnectionDetails(dbms = "duckdb", server = db)
results <- DataQualityDashboard::executeDqChecks(
  connectionDetails     = cd,
  cdmDatabaseSchema     = "cdm",
  resultsDatabaseSchema = "cdm",
  vocabDatabaseSchema   = "cdm",
  cdmSourceName         = source_name,
  cdmVersion            = "5.4",
  numThreads            = threads,
  outputFolder          = out,
  outputFile            = "dqd_results.json",
  writeToTable          = FALSE,
  writeToCsv            = FALSE,
  verboseMode           = FALSE
)

cr <- results$CheckResults
flag <- function(col) if (col %in% names(cr)) cr[[col]] %in% c(1, "1", TRUE) else rep(FALSE, nrow(cr))
cr$is_failed <- flag("failed"); cr$is_error <- flag("isError"); cr$is_na <- flag("notApplicable")
keep <- intersect(c("category", "subcategory", "context", "checkLevel", "checkName",
                    "cdmTableName", "cdmFieldName", "conceptId", "unitConceptId",
                    "numViolatedRows", "pctViolatedRows", "thresholdValue", "error"), names(cr))
bad <- cr[cr$is_failed | cr$is_error, c(keep, "is_error"), drop = FALSE]
bad <- bad[order(-bad$is_error, bad$cdmTableName, bad$checkName), ]
if ("error" %in% names(bad)) bad$error <- substr(gsub("[\r\n]+", " ", bad$error), 1, 300)
write.csv(bad, file.path(out, "dqd_summary.csv"), row.names = FALSE)

ov <- results$Overview
cat(sprintf("\nDQD %s on %s: %d checks, %d passed, %d failed, %d errors, %d not applicable (%.0f%% pass)\n",
            as.character(packageVersion("DataQualityDashboard")), source_name, nrow(cr),
            sum(!cr$is_failed & !cr$is_error & !cr$is_na), sum(cr$is_failed), sum(cr$is_error),
            sum(cr$is_na), ov$percentPassed))
if (nrow(bad)) {
  agg <- aggregate(list(n = rep(1L, nrow(bad))),
                   list(status = ifelse(bad$is_error, "ERROR", "fail"),
                        check = bad$checkName, table = bad$cdmTableName), sum)
  agg$fields <- mapply(function(ch, tb) {
    f <- bad$cdmFieldName[bad$checkName == ch & bad$cdmTableName == tb]
    paste(sort(unique(tolower(f[!is.na(f)]))), collapse = ", ")
  }, agg$check, agg$table)
  cat("\nFailed / errored checks (details in dqd_summary.csv):\n")
  print(agg[order(agg$status, agg$check, agg$table), ], row.names = FALSE, right = FALSE)
}
