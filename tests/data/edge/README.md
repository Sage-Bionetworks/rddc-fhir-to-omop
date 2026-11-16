# edge

Hand-written FHIR for shapes Synthea never produces, with the source config
(`source_config/`) that maps its local code systems. Used by `tests/run_tests.sh`
("non-Synthea shapes") with `../vocab_mini`. Not real data.

| Resource | Shape under test |
|---|---|
| P1 | year-only `birthDate`; `deceasedBoolean` with no date |
| E1 / E2 | versioned subject reference (`Patient/P1/_history/3`); a cancelled encounter |
| C1 | no date (takes the encounter's); a local coding before the SNOMED one |
| C2 | `verificationStatus` entered-in-error |
| C3 | year-only onset; ICD-10-CM under a local URI and without the dot (`systems.csv`) |
| C4 | year-month onset; an HPO code (source concept only) |
| M1 | contained Medication (`#m`) |
| M2 | Medication with no code, only ingredients (one by reference, one inline) |
| M3 | cancelled MedicationRequest |
| O1 | unit in a local code system (`concept_map.csv`) |
| O2 | unit as text only, no UCUM code |
| O3 | a code system with no vocabulary |
