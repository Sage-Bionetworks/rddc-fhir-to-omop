# vocab_mini

A hand-made, Athena-format (tab-delimited) vocabulary for tests. **Not real vocabulary data.**

- Concept `0` ("No matching concept") is included, as in every real Athena download; DQD
  foreign-key checks fail on 0 without it.
- Other concept ids below 2,000,000,000 are the real OMOP ids for the constants the ETL hard-codes
  (gender, race, ethnicity, visit, type concepts, CDM version, `mm[Hg]`).
- Concept ids at or above 2,000,000,000 are fabricated (OMOP's local-concept range), attached
  to real codes that occur in `../fhir`, so `tests/run_tests.sh` can check:
  - domain routing: SNOMED `73595000` (Stress, a *finding*) is a FHIR Condition but lands in
    `observation`;
  - source vs standard: CVX `140` is non-standard and maps to a TEST RxNorm concept;
  - one-to-many: SNOMED `180256009` maps to a procedure and a drug, giving one row in each;
  - invalid relationships (`invalid_reason = 'D'`) are ignored.
- `CONCEPT_ANCESTOR.csv` rolls the TEST drugs up to TEST ingredients, for `drug_era`. It also
  has a self-row for a clinical drug (`2000000030`), which must be ignored because only
  ingredients count as roll-up targets.
