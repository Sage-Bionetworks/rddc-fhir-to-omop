# Source configs

One directory per source, named by the `sourceId` in the batch's sidecar. The pipeline
picks `assets/sources/<sourceId>/` up by itself; `--source_config DIR` names one directly
(`--source-config` for `bin/fhir_to_omop.sh`). A source with no directory runs on the
default code systems (`sql/03_constants.sql`).

Both files are optional, plain CSV with a header and no comment lines:

- `systems.csv`: `system,vocabulary_id,match`. A code system URI the source uses for a
  vocabulary Athena has. `match` is how its codes compare with Athena's `concept_code`:
  `exact`, `nodot` (ICD codes sent without the dot), `curie_underscore` (`HP:0000118` for
  `HP_0000118`) or `strip_prefix` (`ORPHA:558` for `558`). A system listed here replaces
  the default for that URI.
- `concept_map.csv`: `system,code,vocabulary_id,concept_code`. One local code and the
  Athena code that means the same (a local lab or unit code). The target is looked up like
  any source code, so a non-standard target still reaches its standard concept.

QC reports what to add: `code_system_unrecognised` lists the code systems with no
vocabulary and how many records use them, and `top_unmapped_codes` the codes. An entry the
loaded vocabulary cannot resolve is a `source_config_invalid` failure.

`src-mimic-demo/` is the worked example, for the MIMIC-IV FHIR demo (`make mimic`): MIMIC's
own URIs for ICD-9/10 and NDC, and its unit strings. MIMIC's local chart, lab and
medication item codes are not mapped.
